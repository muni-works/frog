import Foundation

/// One-line gists of shell commands ("git log of the sleep-events worktree"), written by
/// the engine's small side-model in one batched call per turn flush. Kept by command hash,
/// so identical commands across rows (and across turns) reuse the one gist; persisted to
/// disk so a reopened conversation doesn't show raw commands again. Absent where none
/// arrived (dart unavailable, a replayed log) — the row then shows the raw command, as it
/// always did. See `Gist.swift` for the reasoning-thoughts twin of this.
@MainActor
@Observable
final class CommandGists {
    static let shared = CommandGists()

    private(set) var byCommand: [String: String] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Enough for a long history; the oldest go first.
    private static let limit = 2_000
    @ObservationIgnored private var order: [String] = []

    private static let file: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "eco.frog")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "command-gists.json")
    }()

    private init() {
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode([[String]].self, from: data) else { return }
        for pair in saved where pair.count == 2 {
            byCommand[pair[0]] = pair[1]
            order.append(pair[0])
        }
    }

    /// The cache key: the command's stable hash. Session-scoped by content only — the same
    /// command means the same work wherever it ran.
    static func key(_ command: String) -> String {
        "\(command.hashValue.magnitude)"
    }

    func gist(for command: String) -> String? {
        byCommand[Self.key(command)]
    }

    /// Forget everything in memory (tests; the disk file keeps what was saved).
    func reset() {
        byCommand.removeAll()
        order.removeAll()
    }

    /// Record one engine `command_gisted` event: a finished command with its line. Empty
    /// gists never arrive, but a repeat landing here is a no-op.
    func record(command: String, gist: String) {
        let key = Self.key(command)
        guard !gist.isEmpty, byCommand[key] == nil else { return }
        byCommand[key] = gist
        order.append(key)
        if order.count > Self.limit {
            for old in order.prefix(order.count - Self.limit) { byCommand[old] = nil }
            order.removeFirst(order.count - Self.limit)
        }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            let pairs = order.compactMap { k in byCommand[k].map { [k, $0] } }
            try? JSONEncoder().encode(pairs).write(to: Self.file, options: .atomic)
        }
    }
}

/// Paths in a command, elided for display so a worktree path never eats the row:
/// "cd /Users/x/Developer/frog/.frog/worktrees/foo && git log" reads as
/// "cd worktrees/foo && git log". A frog worktree (any absolute path with a
/// `worktrees/<name>` tail) elides to that tail — the worktree's own name is what the
/// row is about, wherever this session runs. Other absolute paths elide against the
/// session root when they're under it, and stay absolute otherwise.
enum CommandElision {
    static func elide(_ command: String, from root: String) -> String {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        // Escape-free token walk: split on spaces, keeping them.
        var pieces: [String] = []
        var token = ""
        for ch in command {
            if ch == " " {
                if !token.isEmpty { pieces.append(elideToken(token, root: root)); token = "" }
                pieces.append(" ")
            } else {
                token.append(ch)
            }
        }
        if !token.isEmpty { pieces.append(elideToken(token, root: root)) }
        return pieces.joined()
    }

    /// One token: separators (`,`, `;`, `&&`) split off, a quoted path keeps its own quotes,
    /// and the path inside shortens.
    private static func elideToken(_ token: String, root: String) -> String {
        var body = token
        var suffix = ""
        for sep in ["&&", "||", ";", ",", ")"] where body.hasSuffix(sep) {
            suffix = sep + suffix
            body = String(body.dropLast(sep.count))
        }
        var quote = ""
        if let first = body.first, first == "\"" || first == "'", body.last == first, body.count > 1 {
            quote = String(first)
            body = String(body.dropFirst().dropLast())
        }
        return quote + shorten(body, root: root) + quote + suffix
    }

    private static func shorten(_ path: String, root: String) -> String {
        // Under the session root (or the root itself): relative, and that wins — the
        // session's own worktree is "here", not "worktrees/…".
        if path.hasPrefix(root + "/") {
            let rel = path.dropFirst(root.count + 1)
            return rel.isEmpty ? "." : String(rel)
        }
        if path == root { return "." }
        // A frog worktree elsewhere in the path (a sibling of this session's root, usually):
        // name it by its tail, which is what the row is about.
        if let r = path.range(of: "worktrees/") {
            let tail = path[r.upperBound...]
            if !tail.isEmpty, !tail.contains("/") { return "worktrees/\(tail)" }
        }
        return path
    }
}
