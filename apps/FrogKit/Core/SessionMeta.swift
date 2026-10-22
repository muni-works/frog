import Foundation

/// "2m" — the age of a row's last activity. Kept tiny: it sits beside the state glyph.
enum SessionAgeShort {
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        case ..<(86400 * 7): return "\(s / 86400)d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// A worktree session's commits ahead of its repo's main branch, for the row's trailing meta
/// ("3↑"). Never blocking: refreshed at most once a minute per worktree folder, off the main
/// thread, and only when a row asks.
@MainActor
final class SessionMetaCache: @unchecked Sendable {
    static let shared = SessionMetaCache()

    struct Meta: Equatable {
        var ahead: Int?
    }

    private struct Entry {
        var meta: Meta?
        var refreshed: Date
    }

    /// Worktree folder path → cached meta and when it was refreshed.
    private var entries: [String: Entry] = [:]
    private var refreshing: Set<String> = []

    /// The cached meta for `folder`, when fresh; nil for plain folders (never cached).
    func value(for folder: URL?) -> Meta? {
        guard let folder, Self.isWorktree(folder) else { return nil }
        let key = folder.standardizedFileURL.path
        guard let entry = entries[key], Date().timeIntervalSince(entry.refreshed) < 60 else { return nil }
        return entry.meta
    }

    /// Refresh the cached meta for `folder` (a no-op for plain folders, fresh entries, and
    /// refreshes already in flight). The new value arrives via `value`; the row re-reads it.
    func refresh(_ folder: URL?) async {
        guard let folder, Self.isWorktree(folder) else { return }
        let key = folder.standardizedFileURL.path
        if let entry = entries[key], Date().timeIntervalSince(entry.refreshed) < 60 { return }
        guard refreshing.insert(key).inserted else { return }
        defer { refreshing.remove(key) }
        let ahead = await Task.detached(priority: .utility) { () -> Int? in
            Self.commitsAhead(folder)
        }.value
        entries[key] = Entry(meta: Meta(ahead: ahead), refreshed: Date())
    }

    /// Run `git rev-list --count <base>..HEAD` in the worktree at `folder`. Nil when git or
    /// the base branch can't be found. Worktrees carry their branch's commits; the main
    /// checkout compares against itself (always 0), so only worktrees count.
    /// Whether a folder is a worker worktree under its repo (`<repo>/.frog/worktrees/<name>`
    /// or `<repo>/.claude/worktrees/<name>`).
    nonisolated static func isWorktree(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return path.contains("/.frog/worktrees/") || path.contains("/.claude/worktrees/")
    }

    nonisolated static func commitsAhead(_ folder: URL) -> Int? {
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git), isWorktree(folder) else { return nil }
        let base = ["main", "master"].first {
            run(git, ["rev-parse", "--verify", "--quiet", $0], in: folder) != nil
        }
        guard let base,
              let out = run(git, ["rev-list", "--count", "\(base)..HEAD"], in: folder),
              let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return n
    }

    @discardableResult
    nonisolated private static func run(_ git: String, _ args: [String], in folder: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.currentDirectoryURL = folder
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
