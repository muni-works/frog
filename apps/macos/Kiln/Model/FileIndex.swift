import Foundation

/// Project files for `@` mentions: `git ls-files` when available, otherwise a bounded walk that
/// skips hidden and build directories.
enum FileIndex {
    static func load(_ root: URL) async -> [String] {
        await Task.detached(priority: .utility) {
            if let git = gitFiles(root), !git.isEmpty { return git }
            return walk(root)
        }.value
    }

    private static func gitFiles(_ root: URL) -> [String]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["ls-files", "--cached", "--others", "--exclude-standard"]
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private static let skip: Set<String> = ["node_modules", "target", "build", "dist", ".build", "DerivedData", "__pycache__"]

    private static func walk(_ root: URL) -> [String] {
        var out: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        let base = root.standardizedFileURL.path + "/"
        for case let url as URL in e {
            if skip.contains(url.lastPathComponent) {
                e.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            out.append(url.standardizedFileURL.path.replacingOccurrences(of: base, with: ""))
            if out.count >= 20_000 { break }
        }
        return out
    }

    /// Fuzzy match: every query character must appear in order. Matches in the file name, at word
    /// starts, and in runs score higher; shorter paths win ties.
    static func search(_ files: [String], _ query: String, limit: Int = 8) -> [String] {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return Array(files.prefix(limit)) }
        var scored: [(String, Int)] = []
        for path in files {
            let p = Array(path.lowercased())
            let nameStart = (path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 }) ?? 0
            var qi = 0, score = 0, prev = -2
            for (i, c) in p.enumerated() where qi < q.count && c == q[qi] {
                score += 1
                if i == prev + 1 { score += 3 }
                if i >= nameStart { score += 2 }
                if i == 0 || "/_-. ".contains(p[i - 1]) { score += 4 }
                prev = i
                qi += 1
            }
            if qi == q.count {
                scored.append((path, score * 100 - p.count))
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
