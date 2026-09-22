import Foundation
import Observation

/// A project folder: its sessions, the available models, and the conversation in view.
@MainActor
@Observable
final class Workspace {
    let folder: URL
    private(set) var sessions: [SessionInfo] = []
    private(set) var models: [ModelEntry] = []
    private(set) var conversation: Conversation?
    var selection: String?
    var preferredModel: String?

    init(folder: URL) {
        self.folder = folder
        start(arguments: [])
        Task { await refresh() }
    }

    var name: String { folder.lastPathComponent }

    func refresh() async {
        if let s = try? await Kiln.json([SessionInfo].self, args: ["--sessions", "--json"], cwd: folder) {
            sessions = s
        }
        if models.isEmpty, let m = try? await Kiln.json([ModelEntry].self, args: ["--models", "--json"], cwd: folder) {
            models = m
        }
    }

    func newSession() {
        start(arguments: [])
    }

    func open(_ id: String) {
        guard id != conversation?.sessionID else { return }
        start(arguments: ["-r", id])
    }

    /// Branch the current session right after `turn`, and switch to the branch.
    func fork(afterTurn turn: UInt64) {
        guard let id = conversation?.sessionID else { return }
        start(arguments: ["--fork", "\(id)@\(turn)"])
    }

    func stop() {
        conversation?.stop()
    }

    private func start(arguments: [String]) {
        conversation?.stop()
        let c = Conversation(folder: folder, arguments: arguments, model: preferredModel)
        c.onSessionChange = { [weak self, weak c] in
            guard let self else { return }
            self.selection = c?.sessionID
            Task { await self.refresh() }
        }
        conversation = c
    }
}
