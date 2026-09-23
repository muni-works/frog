import Foundation

/// The branch and uncommitted changes of a folder's git repository, for the composer's git bar.
struct GitInfo: Equatable, Sendable {
    var branch: String
    /// Files with uncommitted changes (including untracked ones).
    var changed: Int
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
            return GitInfo(branch: branch, changed: lines.count - 1)
        }.value
    }
}
