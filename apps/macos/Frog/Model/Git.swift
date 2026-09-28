import Foundation

/// The branch and uncommitted changes of a folder's git repository, for the composer's git bar.
struct GitInfo: Equatable, Sendable {
    var branch: String
    /// Files with uncommitted changes (including untracked ones).
    var changed: Int
    /// Lines added and removed in tracked files since the last commit.
    var added = 0
    var removed = 0
}

enum Git {
    /// Nil when the folder isn't in a git repository (or git isn't installed).
    static func status(_ folder: URL) async -> GitInfo? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", folder.path, "status", "--porcelain=v1", "--branch"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
            let lines = text.split(separator: "\n")
            guard let head = lines.first, head.hasPrefix("## ") else { return nil }
            // "## main...origin/main [ahead 1]", "## HEAD (no branch)", "## No commits yet on main"
            var branch = String(head.dropFirst(3))
            if let dots = branch.range(of: "...") { branch = String(branch[..<dots.lowerBound]) }
            if let space = branch.firstIndex(of: " "), !branch.hasPrefix("No commits") { branch = String(branch[..<space]) }
            branch = branch.replacingOccurrences(of: "No commits yet on ", with: "")
            var info = GitInfo(branch: branch, changed: lines.count - 1)
            if info.changed > 0, let stat = Git.run(folder, ["diff", "--shortstat", "HEAD"]) {
                // " 3 files changed, 645 insertions(+), 63 deletions(-)"
                for part in stat.split(separator: ",") {
                    let n = Int(part.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0
                    if part.contains("insertion") { info.added = n }
                    if part.contains("deletion") { info.removed = n }
                }
            }
            return info
        }.value
    }

    /// A git command's output, or nil if it failed.
    static func run(_ folder: URL, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", folder.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
