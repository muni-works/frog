import Foundation
import Observation

/// The account's Frog Cloud sessions for the sidebar, as the web lists them: refreshed every
/// 15 s (the gateway has no push for the list). The key is frog's Frog Cloud key, or
/// `FROG_GATEWAY_KEY` against a local gateway.
@MainActor
@Observable
final class CloudSessions {
    static let shared = CloudSessions()

    private(set) var sessions: [CloudGateway.Session] = []
    private(set) var error: String?
    private var poll: Task<Void, Never>?

    var gateway: CloudGateway? {
        let env = ProcessInfo.processInfo.environment["FROG_GATEWAY_KEY"]
        return (env ?? CloudAccount.shared.key).map(CloudGateway.init(token:))
    }

    /// Whether Frog Cloud can run a session here: a gateway key, or a signed-in account. For
    /// views that only need the yes/no — `gateway` reads the account on every call, which the
    /// composer did on every body pass.
    var available: Bool { ProcessInfo.processInfo.environment["FROG_GATEWAY_KEY"] != nil || CloudAccount.shared.signedIn }

    var live: [CloudGateway.Session] { sessions.filter { $0.archived != true } }

    func start() {
        guard poll == nil else { return }
        poll = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func refresh() async {
        await CloudAccount.shared.ensureKey()
        guard let gateway else { sessions = []; Library.shared.cloudChanged([]); return }
        do {
            sessions = try await gateway.sessions().sorted { ($0.last_turn ?? $0.updated) > ($1.last_turn ?? $1.updated) }
            error = nil
            Library.shared.cloudChanged(sessions)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func create(repo: String?) async throws -> CloudGateway.Session? {
        guard let gateway else { return nil }
        let s = try await gateway.create(repo: repo, model: nil)
        await refresh()
        return s
    }

    func archive(_ id: String, _ archived: Bool) async {
        try? await gateway?.archive(id, archived)
        await refresh()
    }

    func remove(_ id: String) async {
        try? await gateway?.remove(id)
        await refresh()
    }

    /// owner/name from a folder's GitHub `origin`, for "Run in Frog Cloud".
    nonisolated static func githubRepo(of folder: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", folder.path, "remote", "get-url", "origin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let url = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = url.range(of: "github.com[:/]", options: .regularExpression) else { return nil }
        var name = String(url[r.upperBound...])
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.split(separator: "/").count == 2 ? name : nil
    }
}
