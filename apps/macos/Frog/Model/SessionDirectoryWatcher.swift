import Foundation

/// Watches CLI-written session logs and feeds complete appended records to open conversations.
final class SessionDirectoryWatcher: @unchecked Sendable { // state confined to `queue`
    static let shared = SessionDirectoryWatcher()

    private let queue = DispatchQueue(label: "frog.sessions.watch")
    private let rescanInterval: DispatchTimeInterval = .seconds(1)
    private let directoryFD: Int32
    private var directorySource: DispatchSourceFileSystemObject?
    private var rescanTimer: DispatchSourceTimer?
    private var files: [String: Tail] = [:]
    private var snapshot: [String: Date] = [:]

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
        scan()
    }

    private func scan() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: FrogPaths.sessions, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var current: [String: Date] = [:]
        for log in urls {
            guard log.pathExtension == "jsonl",
                  (try? log.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { continue }
            let id = log.deletingPathExtension().lastPathComponent
            guard let modified = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            current[id] = modified
            if files[id] == nil { watch(log, id: id) }
        }
        let changed = SessionDirectoryRescan.changedSessions(previous: snapshot, current: current)
        snapshot = current
        guard !changed.isEmpty else { return }
        DispatchQueue.main.async { Library.shared.refresh() }
    }

    private func watch(_ url: URL, id: String) {
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
    static func changedSessions(previous: [String: Date], current: [String: Date]) -> Set<String> {
        Set(current.compactMap { id, modified in previous[id] == modified ? nil : id })
            .union(previous.keys.filter { current[$0] == nil })
    }
}
