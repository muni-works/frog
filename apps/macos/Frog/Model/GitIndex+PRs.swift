import AppKit
import Foundation

/// Bound PRs' state for the composer's git line (docs/plans/2026-11-12-composer-tray.md): one
/// `gh pr view <n> --repo <repo>` per bound PR, polled every 60 s while Frog is in front and
/// right after any git action. The engine owns the bindings (`Event::Prs`); this only looks.
extension GitIndex {
    nonisolated static let prFields = "number,title,state,isDraft,reviewDecision,statusCheckRollup,mergeable"

    /// What the composer shows for `prs`: the last state seen, else the engine's cached one.
    func prs(_ bound: [PrBinding]) -> [ComposerModel.Pr] {
        bound.map { b in
            prSeen["\(b.repo)#\(b.number)"] ?? ComposerModel.Pr(
                repo: b.repo,
                number: b.number,
                title: b.title,
                state: ComposerModel.PrState(rawValue: b.state) ?? .checks,
                checks: .init(ok: b.checks?.first ?? 0, total: b.checks?.last ?? 0)
            )
        }
    }

    /// Ask gh about each bound PR now (after an action, or on the poll).
    func refreshPrs(_ bound: [PrBinding], in dir: String) {
        guard !bound.isEmpty else { return }
        Task {
            let seen = await Task.detached(priority: .utility) { () -> [String: ComposerModel.Pr] in
                guard let gh = Self.ghPath() else { return [:] }
                var out: [String: ComposerModel.Pr] = [:]
                for b in bound {
                    let json = Self.runGh(gh, ["pr", "view", String(b.number), "--repo", b.repo, "--json", Self.prFields], in: dir)
                    out["\(b.repo)#\(b.number)"] = Self.pr(b, json: json)
                }
                return out
            }.value
            prSeen.merge(seen) { $1 }
        }
    }

    /// Poll while `bound` is on screen: now, then every 60 s while Frog is the active app.
    func watchPrs(_ bound: [PrBinding], in dir: String) async {
        while !Task.isCancelled {
            if NSApplication.shared.isActive { refreshPrs(bound, in: dir) }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// A PR from `gh pr view --json`; nil output (no access, not found) keeps it bound, marked.
    nonisolated static func pr(_ b: PrBinding, json: String?) -> ComposerModel.Pr {
        guard let json, let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return ComposerModel.Pr(repo: b.repo, number: b.number, title: b.title, state: ComposerModel.PrState(rawValue: b.state) ?? .checks,
                                    checks: .init(ok: 0, total: 0), access: false)
        }
        let rollup = o["statusCheckRollup"] as? [[String: Any]] ?? []
        let outcome = rollup.map { ($0["conclusion"] as? String ?? $0["state"] as? String ?? "").uppercased() }
        let ok = outcome.filter { ["SUCCESS", "NEUTRAL", "SKIPPED"].contains($0) }.count
        let failed = outcome.contains { ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains($0) }
        let state: ComposerModel.PrState = switch (o["state"] as? String ?? "").uppercased() {
        case "MERGED": .merged
        case "CLOSED": .closed
        default:
            if o["isDraft"] as? Bool == true { .draft }
            else if failed { .failing }
            else if ok < outcome.count { .checks }
            else if (o["reviewDecision"] as? String) == "APPROVED" { .approved }
            else { .checks }
        }
        return ComposerModel.Pr(repo: b.repo, number: b.number, title: o["title"] as? String ?? b.title, state: state,
                                checks: .init(ok: ok, total: outcome.count))
    }

    nonisolated static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func runGh(_ gh: String, _ args: [String], in dir: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
