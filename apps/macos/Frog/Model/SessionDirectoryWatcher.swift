import Foundation

/// Watches CLI-written session logs and feeds complete appended records to open conversations.
final class SessionDirectoryWatcher: @unchecked Sendable { // state confined to `queue`
    static let shared = SessionDirectoryWatcher()

    private let queue = DispatchQueue(label: "frog.sessions.watch")
    /// Belt for what the directory source can miss (an append that emits no event, a rename
    /// carrying a live write). One `getattrlistbulk` answers for the whole directory, so a scan
    /// costs ~5 ms for 1,500 files — a 1 Hz one still wasted that every second, and each change
    /// it "found" queued a 1.5 MB listing. 10 s keeps the belt with none of the cost.
    private let rescanInterval: DispatchTimeInterval = .seconds(10)
    private let directoryFD: Int32
    private var directorySource: DispatchSourceFileSystemObject?
    private var rescanTimer: DispatchSourceTimer?
    private var files: [String: Tail] = [:]
    /// Each flat log's id and its (mtime ns, size) from the last scan's one bulk read.
    private var snapshot: [String: (UInt64, UInt64)] = [:]

    private struct Tail {
        var source: DispatchSourceFileSystemObject
        var offset: UInt64
        var pending = Data()
    }

    private init() {
        try? FileManager.default.createDirectory(at: FrogPaths.sessions, withIntermediateDirectories: true)
        directoryFD = open(FrogPaths.sessions.path, O_EVTONLY)
        guard directoryFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.scan() }
        source.setCancelHandler { close(self.directoryFD) }
        directorySource = source
        source.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + rescanInterval, repeating: rescanInterval)
        timer.setEventHandler { [weak self] in self?.scan() }
        rescanTimer = timer
        timer.resume()
        // On the queue, like every other scan: the sources above are already live, and a scan
        // here on the caller's (main) thread raced theirs over `files` and `snapshot`. That's
        // heap corruption, e.g. the 2026-10-22 crash in `Dictionary` lookup under `scan` on main.
        queue.async { self.scan() }
    }

    private func scan() {
        dispatchPrecondition(condition: .onQueue(queue))
        let current = SessionDirectoryRescan.listing(FrogPaths.sessions.path)
        guard !current.isEmpty || !snapshot.isEmpty else { return }
        for id in current.keys where files[id] == nil {
            watch(FrogPaths.sessions.appending(path: "\(id).jsonl"), id: id)
        }
        let changed = SessionDirectoryRescan.changedSessions(previous: snapshot, current: current)
        snapshot = current
        guard !changed.isEmpty else { return }
        DispatchQueue.main.async { Library.shared.refresh(ids: changed) }
    }

    private func watch(_ url: URL, id: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        let initialOffset = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        files[id] = Tail(source: source, offset: initialOffset)
        source.setEventHandler { [weak self] in self?.readAppended(id: id, url: url) }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private func readAppended(id: String, url: URL) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var tail = files[id], let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? tail.offset
        if size < tail.offset { tail.offset = 0; tail.pending.removeAll() }
        do {
            try handle.seek(toOffset: tail.offset)
            let data = try handle.readToEnd() ?? Data()
            tail.offset += UInt64(data.count)
            tail.pending.append(data)
        } catch { return }

        while let newline = tail.pending.firstIndex(of: 0x0A) {
            let line = tail.pending.prefix(upTo: newline)
            tail.pending.removeSubrange(...newline)
            guard !line.isEmpty,
                  let event = try? JSONDecoder.frog.decode(Envelope.self, from: Data(line)),
                  event.session == id else { continue }
            DispatchQueue.main.async {
                Library.shared.conversation(id)?.ingest(event)
            }
        }
        files[id] = tail
    }
}

/// Tracks flat session JSONL files and their modification times independently from watcher sources.
/// Periodic scans catch file creation and appends that do not emit directory events.
enum SessionDirectoryRescan {
    /// Previous snapshot keyed by id, current one likewise: a change is a different stamp or a
    /// file present in only one of the two. Both stamps are plain words from the same bulk read
    /// (mtime ns and size), compared as integers — comparing `Date`s sent every scan's diff
    /// through String NFC normalization (Unicode._NFCNormalizer in the profile), which was
    /// seconds of CPU an hour.
    static func changedSessions(
        previous: [String: (UInt64, UInt64)],
        current: [String: (UInt64, UInt64)]
    ) -> Set<String> {
        Set(current.compactMap { id, stamp in
            guard let before = previous[id] else { return id }  // new file
            return before == stamp ? nil : id
        })
            .union(previous.keys.filter { current[$0] == nil })
    }

    /// One `getattrlistbulk` over the directory: id → (mtime ns, size) for each flat .jsonl.
    /// No `contentsOfDirectory`, no per-URL `resourceValues`, no string normalization. Names are
    /// read as raw bytes and the suffix matched on bytes, so a scan builds a String only for the
    /// ~1,029 logs, never for the `.live` companions and `.json` summaries around them.
    static func listing(_ path: String) -> [String: (UInt64, UInt64)] {
        var out: [String: (UInt64, UInt64)] = [:]
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return out }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)  // ~1,050 entries per call at ~1 kB each
        var count: Int32 = 0
        repeat {
            count = withUnsafePointer(to: attrBitmap) { list in
                buffer.withUnsafeMutableBytes { buf in
                    getattrlistbulk(fd, UnsafeMutableRawPointer(mutating: list), buf.baseAddress!, buf.count, 0)
                }
            }
            guard count > 0 else { break }
            buffer.withUnsafeBytes { buf -> Void in
                let base = buf.baseAddress!
                var cursor = 0
                for _ in 0..<Int(count) {
                    // Entry layout (verified against `stat` on the real store):
                    // [u32 entry bytes][returned attribute_set (20)][attrreference name]
                    // [u32 objtype][timespec mtime][u32 size] — the requested attributes land in
                    // bitmap order after the name, each padded to its natural alignment start.
                    let entryLength = Int(base.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
                    let nameReference = base.loadUnaligned(fromByteOffset: cursor + 24, as: attrreference_t.self)
                    let nameStart = cursor + 24 + Int(nameReference.attr_dataoffset)
                    let nameLength = Int(nameReference.attr_length) - 1  // trailing NUL
                    defer { cursor += entryLength }
                    guard nameLength > 6 else { continue }
                    let bytes = buf[nameStart..<nameStart + nameLength]
                    guard bytes.suffix(6).elementsEqual([0x2e, 0x6a, 0x73, 0x6f, 0x6e, 0x6c]) else { continue }  // ".jsonl"
                    let type = base.loadUnaligned(fromByteOffset: cursor + 32, as: UInt32.self)
                    guard type == 1 else { continue }  // DT_REG; directories read as 4
                    let modified = base.loadUnaligned(fromByteOffset: cursor + 36, as: timespec.self)
                    let size = base.loadUnaligned(fromByteOffset: cursor + 52, as: UInt32.self)
                    let id = String(decoding: bytes[bytes.startIndex..<bytes.endIndex - 6], as: UTF8.self)
                    out[id] = (UInt64(modified.tv_sec) &* 1_000_000_000 &+ UInt64(max(0, modified.tv_nsec)), UInt64(size))
                }
            }
        } while count == 1533  // the call filled its buffer; ask again for the rest
        return out
    }
}

/// What `getattrlistbulk` asks for: the name (to id each file), the object type (to skip
/// directories) and the modification time — one syscall answers for the whole directory. The
/// name and the returned-attrs set are always included (ATTR_BULK_REQUIRED).
private let attrBitmap: attrlist = {
    var list = attrlist()
    list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
    list.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
    return list
}()
