import AppKit
import Foundation

/// The git line's direct actions (docs/plans/2026-11-12-composer-tray.md): push, pull and push,
/// merge and reopen a PR. Each returns nil on success, else the reducer's error code and detail.
/// Never force-pushes.
enum GitActions {
    struct Failure: Error { var code: String; var detail: String? }

    static func push(in dir: URL) async -> Failure? {
        let r = await run("/usr/bin/git", ["push", "-u", "origin", "HEAD"], in: dir)
        guard let err = r else { return nil }
        let rejected = err.contains("non-fast-forward") || err.contains("[rejected]") || err.contains("fetch first")
        return Failure(code: rejected ? "push_rejected" : "cloud_busy", detail: err)
    }

    static func pullAndPush(in dir: URL) async -> Failure? {
        if let err = await run("/usr/bin/git", ["pull", "--rebase", "--autostash"], in: dir) {
            return Failure(code: "merge_conflict", detail: err)
        }
        return await push(in: dir)
    }

    static func merge(_ repo: String, _ number: Int, in dir: URL) async -> Failure? {
        guard let gh = GitIndex.ghPath() else { return Failure(code: "gh_auth") }
        guard let err = await run(gh, ["pr", "merge", String(number), "--repo", repo], in: dir) else { return nil }
        if err.localizedCaseInsensitiveContains("conflict") { return Failure(code: "merge_conflict", detail: err) }
        if err.localizedCaseInsensitiveContains("auth") { return Failure(code: "gh_auth", detail: err) }
        return Failure(code: "branch_protected", detail: err.split(separator: "\n").first.map(String.init))
    }

    static func reopen(_ repo: String, _ number: Int, in dir: URL) async -> Failure? {
        guard let gh = GitIndex.ghPath() else { return Failure(code: "gh_auth") }
        guard let err = await run(gh, ["pr", "reopen", String(number), "--repo", repo], in: dir) else { return nil }
        return Failure(code: err.localizedCaseInsensitiveContains("auth") ? "gh_auth" : "pr_not_found", detail: err)
    }

    /// `gh auth login`, in Terminal: it's interactive.
    static func ghAuthLogin() {
        let script = "tell application \"Terminal\" to do script \"gh auth login\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    /// Nil on success, else stderr (or stdout).
    private static func run(_ exe: String, _ args: [String], in dir: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            guard (try? p.run()) != nil else { return "couldn't run \(exe)" }
            let e = err.fileHandleForReading.readDataToEndOfFile()
            let o = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus != 0 else { return nil }
            let text = String(data: e.isEmpty ? o : e, encoding: .utf8) ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    /// The session's GitHub slug and how far the branch is ahead of its upstream (else the
    /// remote's default branch). Off the main thread.
    static func slugAndAhead(_ dir: URL) async -> (String?, Int) {
        await Task.detached(priority: .utility) { () -> (String?, Int) in
            let slug = CloudSessions.githubRepo(of: dir)
            func count(_ range: String) -> Int? {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-C", dir.path, "rev-list", "--count", range]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return nil }
                let d = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { return nil }
                return Int(String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }
            return (slug, count("@{upstream}..HEAD") ?? count("origin/HEAD..HEAD") ?? 0)
        }.value
    }
}
