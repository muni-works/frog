import Foundation

/// A `frog --serve` process is how a conversation reaches its engine on the Mac.
extension EngineProcess: ConversationLink {
    var endDescription: String {
        let tail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
        return tail.isEmpty ? "The frog engine exited (\(exitDescription))." : tail
    }

    /// The process is there to send events. False once it has exited (the pipe's `nil` may
    /// still be on its way), which is what a stale busy conversation checks.
    var isAlive: Bool { isRunning }

    /// The drain deadline passed without the engine stopping: kill it, and say why in the log.
    func forceKill(reason: String) { kill(reason: reason) }
}

extension Conversation {
    /// A conversation with its own engine. `arguments` are extra CLI flags, e.g. `["-r", id]`
    /// or `["--fork", "id@3"]`.
    convenience init(folder: URL, arguments: [String], model: String?) {
        let replay = arguments.contains("-r") || arguments.contains("--fork")
        // A reopened session is known before the engine says so: the sidebar selects it now.
        var session: String?
        if let i = arguments.firstIndex(of: "-r"), arguments.indices.contains(i + 1) { session = arguments[i + 1] }
        guard let binary = Frog.binary else {
            self.init(folder: folder, link: nil, replay: replay, session: session,
                      failure: FrogError.missingBinary.localizedDescription)
            return
        }
        var args = arguments
        if let model { args += ["-m", model] }
        // Always measured (a sensor read ten times a second), so "Show energy use" shows every
        // turn's figure the moment it's on, earlier turns included.
        args.append("--energy")
        let engine = EngineProcess(binary: binary, cwd: folder, arguments: args)
        engine.onLine = { RemoteBridge.shared.forward($0) }
        do {
            try engine.start()
            // The Mac shows the engine's panes (a shared terminal, a live preview) and puts
            // the model's questions to the user, and lets sessions reach each other.
            engine.send(.setClientCaps(panes: true, ask: true, sessions: true))
        } catch {
            self.init(folder: folder, link: nil, replay: replay, session: session,
                      failure: "Couldn't start frog: \(error.localizedDescription)")
            return
        }
        self.init(folder: folder, link: engine, replay: replay, session: session)
    }
}

/// What the Mac does when things happen in a conversation: the sidebar's live state, stats,
/// notifications, and a title from the on-device model after the first turn.
@MainActor
final class MacEffects: ConversationEffects {
    static let shared = MacEffects()

    func turnEnded(_ c: Conversation, turn: TurnState) {
        if let id = c.sessionID { Library.shared.turnEnded(id) }
        if let usage = turn.usage { ModelStats.shared.record(usage, model: c.status?.model) }
        Notifier.shared.turnFinished(project: c.folder.lastPathComponent, text: Conversation.summary(turn))
        if c.title == nil, case .complete? = turn.end { nameSession(c, from: turn) }
    }

    func asked(_ c: Conversation, _ request: PermissionRequest) {
        Notifier.shared.needsPermission(project: c.folder.lastPathComponent, request: request) { [weak c] d in
            c?.answer(d)
        }
    }

    func answered(_ c: Conversation, permission id: String) {
        Notifier.shared.resolved(id)
    }

    func live(_ c: Conversation, running: Bool, waiting: Bool) {
        guard let id = c.sessionID else { return }
        Library.shared.report(id, conversation: c, running: running, waiting: waiting)
    }

    /// Name the session with the on-device model after its first completed turn.
    private func nameSession(_ c: Conversation, from turn: TurnState) {
        let answer = Titler.answerContext(for: turn)
        let request = turn.input
        Task { [weak c] in
            guard let t = await Titler.title(for: request, answer: answer) else { return }
            c?.send(.setTitle(t))
        }
    }
}
