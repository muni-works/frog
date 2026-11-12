import Foundation

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
