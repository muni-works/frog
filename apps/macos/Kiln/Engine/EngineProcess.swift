import Foundation

/// Locating and running the `kiln` binary.
enum Kiln {
    /// Where plain chats (no folder) live, so their sessions are grouped together.
    static let chatFolder: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/kiln/chat")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The bundled engine first; then an override; then a dev build; then PATH.
    static var binary: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "kiln", withExtension: nil) {
            candidates.append(bundled)
        }
        if let env = ProcessInfo.processInfo.environment["KILN_BIN"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        let home = fm.homeDirectoryForCurrentUser
        candidates += [
            home.appending(path: "Developer/kiln/target/release/kiln"),
            home.appending(path: ".cargo/bin/kiln"),
            URL(fileURLWithPath: "/opt/homebrew/bin/kiln"),
            URL(fileURLWithPath: "/usr/local/bin/kiln"),
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

    /// Run a one-shot `kiln` command and decode its JSON output.
    static func json<T: Decodable & Sendable>(_ type: T.Type, args: [String], cwd: URL) async throws -> T {
        guard let binary else { throw KilnError.missingBinary }
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
            return try JSONDecoder.kiln.decode(T.self, from: data)
        }.value
    }
}

enum KilnError: LocalizedError {
    case missingBinary

    var errorDescription: String? {
        "Couldn't find the kiln engine. Build it with `cargo build --release -p kiln` or set KILN_BIN."
    }
}

/// One `kiln --serve` process: ops in over stdin, event envelopes out over stdout.
@MainActor
final class EngineProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let encoder = JSONEncoder()
    private var reader: Task<Void, Never>?

    /// Called on the main actor for every event, then once with `nil` when the process exits.
    var onEvent: (Envelope?) -> Void = { _ in }
    private(set) var stderr = ""

    /// How the process ended, for error messages.
    var exitDescription: String {
        guard !process.isRunning else { return "still running" }
        let how = process.terminationReason == .uncaughtSignal ? "signal" : "status"
        return "\(how) \(process.terminationStatus)"
    }

    /// Engine stderr is also appended here, for debugging.
    nonisolated static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Kiln")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "engine.log")
    }()

    init(binary: URL, cwd: URL, arguments: [String]) {
        process.executableURL = binary
        process.arguments = ["--serve", "--rich"] + arguments
        process.currentDirectoryURL = cwd
        process.environment = Kiln.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start() throws {
        Self.log("start \(process.executableURL?.path ?? "?") \(process.arguments?.joined(separator: " ") ?? "") in \(process.currentDirectoryURL?.path ?? "?")")
        try process.run()
        let lines = Self.lines(output.fileHandleForReading)
        let errLines = Self.lines(errors.fileHandleForReading)
        reader = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await line in lines {
                        guard let env = try? JSONDecoder.kiln.decode(Envelope.self, from: Data(line.utf8)) else { continue }
                        await MainActor.run { self?.onEvent(env) }
                    }
                }
                group.addTask {
                    for await line in errLines {
                        Self.log(line)
                        await MainActor.run { self?.stderr += line + "\n" }
                    }
                }
            }
            await MainActor.run {
                if let self { Self.log("exit: \(self.exitDescription)") }
                self?.onEvent(nil)
            }
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
    func stop() {
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
