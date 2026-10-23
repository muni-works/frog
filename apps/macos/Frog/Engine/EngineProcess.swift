import Foundation

/// Locating and running the `frog` binary.
enum Frog {
    /// Where plain chats (no folder) live, so their sessions are grouped together.
    static let chatFolder: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/frog/chat")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Where the engine keeps session logs.
    static let sessions = FrogPaths.sessions

    /// Returns once no engine holds session `id`'s log (a stopped engine takes a moment to exit),
    /// or after `limit`. The engine holds an exclusive `flock` on the log while it's open.
    static func released(session id: String, within limit: Duration) async {
        let path = sessions.appending(path: "\(id).jsonl").path
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            let fd = open(path, O_WRONLY | O_APPEND)
            guard fd >= 0 else { return }
            let held = flock(fd, LOCK_EX | LOCK_NB) != 0
            close(fd)
            if !held { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Whether `url` is the chat folder (compared by path: a restored URL may carry a trailing
    /// slash or a symlinked prefix).
    static func isChat(_ url: URL) -> Bool { FrogPaths.isChat(url) }

    /// The bundled engine first; then an override; then a dev build; then PATH.
    static var binary: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "frog", withExtension: nil) {
            candidates.append(bundled)
        }
        if let env = ProcessInfo.processInfo.environment["FROG_BIN"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        let home = fm.homeDirectoryForCurrentUser
        candidates += [
            home.appending(path: "Developer/frog/target/release/frog"),
            home.appending(path: ".cargo/bin/frog"),
            URL(fileURLWithPath: "/opt/homebrew/bin/frog"),
            URL(fileURLWithPath: "/usr/local/bin/frog"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Apps launched from Finder get a bare PATH. Tools the model runs (cargo, python3, rg…)
    /// need the one a terminal would have.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.cargo/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let current = env["PATH", default: "/usr/bin:/bin:/usr/sbin:/sbin"]
        env["PATH"] = (extra + [current]).joined(separator: ":")
        return env
    }

    /// Run a one-shot `frog` command for its effect.
    static func run(args: [String], cwd: URL) async throws {
        guard let binary else { throw FrogError.missingBinary }
        try await Task.detached {
            let p = Process()
            p.executableURL = binary
            p.arguments = args
            p.currentDirectoryURL = cwd
            p.environment = environment
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }.value
    }

    /// Run a one-shot `frog` command, feeding it `input` on stdin (for secrets, which never go
    /// on the command line); throws frog's own error message if it fails.
    static func command(_ args: [String], input: String? = nil) async throws {
        guard let binary else { throw FrogError.missingBinary }
        try await Task.detached {
            let p = Process()
            p.executableURL = binary
            p.arguments = args
            p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            p.environment = environment
            let stdin = Pipe(), err = Pipe()
            p.standardInput = stdin
            p.standardOutput = FileHandle.nullDevice
            p.standardError = err
            try p.run()
            if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
            try? stdin.fileHandleForWriting.close()
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let line = message.split(separator: "\n").last.map(String.init) ?? "frog failed"
                throw FrogError.failed(line.replacingOccurrences(of: "Error: ", with: ""))
            }
        }.value
    }

    /// Run a one-shot `frog` command and decode its JSON output.
    static func json<T: Decodable & Sendable>(_ type: T.Type, args: [String], cwd: URL) async throws -> T {
        guard let binary else { throw FrogError.missingBinary }
        return try await Task.detached {
            let p = Process()
            p.executableURL = binary
            p.arguments = args
            p.currentDirectoryURL = cwd
            p.environment = environment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return try JSONDecoder.frog.decode(T.self, from: data)
        }.value
    }
}

enum FrogError: LocalizedError {
    case missingBinary
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingBinary: "Couldn't find the frog engine. Build it with `cargo build --release -p frog` or set FROG_BIN."
        case .failed(let message): message
        }
    }
}

/// One `frog --serve` process: ops in over stdin, event envelopes out over stdout.
@MainActor
final class EngineProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let encoder = JSONEncoder()
    private var reader: Task<Void, Never>?

    /// What the `exit:` line in the log says about this engine: which session it ran and why
    /// the app stopped it, if the app did. A box, not properties of `self`: the exit is logged
    /// even when nothing holds the EngineProcess any more (a background engine the broker
    /// let go of), which used to leave its exit unlogged.
    private final class Identity: @unchecked Sendable {
        var session: String?
        var stopReason: String?
    }
    private let identity = Identity()

    /// Called on the main actor for every event, then once with `nil` when the process exits.
    var onEvent: (Envelope?) -> Void = { _ in }
    /// Every stdout line, verbatim, before it's decoded (for the iPhone bridge).
    var onLine: (String) -> Void = { _ in }
    private(set) var stderr = ""

    /// How the process ended, for error messages.
    var exitDescription: String { Self.describeExit(process) }

    private nonisolated static func describeExit(_ process: Process) -> String {
        guard !process.isRunning else { return "still running" }
        let how = process.terminationReason == .uncaughtSignal ? "signal" : "status"
        return "\(how) \(process.terminationStatus)"
    }

    /// The `exit:` log line: how it ended, its pid and session, and whether the app stopped it
    /// (and why) or it ended on its own.
    nonisolated static func exitLine(_ how: String, pid: Int32, session: String?, stopReason: String?) -> String {
        let why = stopReason.map { "stop: \($0)" } ?? "not stopped by the app"
        return "exit: \(how) pid \(pid) session \(session ?? "?") (\(why))"
    }

    /// The engine process is still running (see `ConversationLink.isAlive`).
    var isRunning: Bool { process.isRunning }

    /// Engine stderr is also appended here, for debugging.
    nonisolated static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Frog")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "engine.log")
    }()

    init(binary: URL, cwd: URL, arguments: [String]) {
        process.executableURL = binary
        process.arguments = ["--serve", "--rich"] + arguments
        process.currentDirectoryURL = cwd
        process.environment = Frog.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        if let i = arguments.firstIndex(of: "-r"), arguments.indices.contains(i + 1) {
            identity.session = arguments[i + 1]
        }
    }

    func start() throws {
        try process.run()
        Self.log("start pid \(process.processIdentifier) \(process.executableURL?.path ?? "?") \(process.arguments?.joined(separator: " ") ?? "") in \(process.currentDirectoryURL?.path ?? "?")")
        let lines = Self.lines(output.fileHandleForReading)
        let errLines = Self.lines(errors.fileHandleForReading)
        let identity = identity
        let process = process
        reader = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await line in lines {
                        await MainActor.run { self?.onLine(line) }
                        guard let env = try? JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)) else { continue }
                        await MainActor.run {
                            if identity.session != env.session { identity.session = env.session }
                            self?.onEvent(env)
                        }
                    }
                }
                group.addTask {
                    for await line in errLines {
                        Self.log(line)
                        await MainActor.run { self?.stderr += line + "\n" }
                    }
                }
            }
            // The pipes close a moment before the process is reaped: wait for it (briefly), so
            // the line says how it ended rather than "still running".
            for _ in 0..<50 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(20))
            }
            // Logged whether or not anything still holds this EngineProcess.
            Self.log(Self.exitLine(Self.describeExit(process), pid: process.processIdentifier,
                                   session: identity.session, stopReason: identity.stopReason))
            self?.onEvent(nil)
        }
    }

    /// Lines from a pipe as they arrive. (`FileHandle.bytes.lines` can hold pipe output back
    /// until the buffer fills, which stalls a streaming protocol.)
    private nonisolated static func lines(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = LineBuffer()
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    if let rest = buffer.drain() { continuation.yield(rest) }
                    continuation.finish()
                    return
                }
                for line in buffer.push(chunk) { continuation.yield(line) }
            }
        }
    }

    nonisolated static func log(_ line: String) {
        guard let data = "\(Date.now.ISO8601Format()) \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    func send(_ op: Op) {
        guard process.isRunning, var data = try? encoder.encode(op) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Ask the engine to save and exit; force it if it doesn't within a second.
    func stop() { stop(reason: "unspecified") }

    /// `stop()`, with why the app is stopping it, for the log's `exit:` line.
    func stop(reason: String) {
        if identity.stopReason == nil {
            identity.stopReason = reason
            Self.log("stop pid \(process.processIdentifier) session \(identity.session ?? "?"): \(reason)")
        }
        send(.shutdown)
        try? input.fileHandleForWriting.close()
        let p = process
        Task.detached {
            try? await Task.sleep(for: .seconds(1))
            if p.isRunning { p.terminate() }
        }
    }
}

/// Splits a byte stream into lines. Only touched from one readability handler at a time.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    func push(_ chunk: Data) -> [String] {
        data.append(chunk)
        var lines: [String] = []
        while let i = data.firstIndex(of: 0x0A) {
            lines.append(String(decoding: data[data.startIndex..<i], as: UTF8.self))
            data.removeSubrange(data.startIndex...i)
        }
        return lines
    }

    func drain() -> String? {
        defer { data.removeAll() }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }
}
