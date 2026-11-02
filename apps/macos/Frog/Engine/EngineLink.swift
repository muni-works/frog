import Foundation

/// A `frog --serve` process is how a conversation reaches its engine on the Mac.
extension EngineProcess: ConversationLink {
    var endDescription: String {
        Self.endDescription(stderr: stderr, out: outText, signal: exitSignal, exit: exitDescription)
    }

    /// Why an engine the app didn't stop is gone, for the transcript's red line: its own last
    /// words — the fatal error it printed before it died (a worktree another engine holds, a
    /// bad config) ahead of a generic status. Its per-call timing traces ("call 2 done in
    /// 12.6s · …", stderr's only content while it lives) read as a crash when another session
    /// killed the process, so they're dropped; a signal from outside said so.
    nonisolated static func endDescription(stderr: String, out: String, signal: Int32?, exit: String) -> String {
        for source in [out, stderr] {
            let lines = source.split(separator: "\n").map(String.init).filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && t.firstMatch(of: /^call \d+ (done|thinking|failed)\b/) == nil
            }
            if let tail = lines.last { return tail }
        }
        if let signal {
            let name = [9: "SIGKILL", 15: "SIGTERM", 2: "SIGINT"][signal] ?? "signal \(signal)"
            return "The frog engine was stopped from outside frog (\(name))."
        }
        return "The frog engine exited (\(exit))."
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
        // The newest rows straight from the log, before the engine has started (see
        // `SessionHistory`); the engine sends only what came after them.
        let history = replay ? session.flatMap { SessionHistory.open($0, at: Frog.sessions.appending(path: "\($0).jsonl")) } : nil
        self.init(folder: folder, link: engine, replay: replay, session: session, history: history)
    }
}

/// What the Mac does when things happen in a conversation: the sidebar's live state, stats,
/// notifications, and a title from the on-device model after the first turn.
@MainActor
final class MacEffects: ConversationEffects {
    static let shared = MacEffects()

    func turnEnded(_ c: Conversation, turn: TurnState) {
        if let id = c.cloudSession ?? c.sessionID { Library.shared.turnEnded(id) }
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
        // A cloud session's events carry its engine's own id; its row is the gateway's.
        guard let id = c.cloudSession ?? c.sessionID else { return }
        Library.shared.report(id, conversation: c, running: running, waiting: waiting)
    }

    /// Name the session with the on-device model after its first completed turn.
    private func nameSession(_ c: Conversation, from turn: TurnState) {
        let answer = Titler.answerContext(for: turn)
        let request = turn.input
        Task { [weak c] in
            guard let t = await Titler.title(for: request, answer: answer) else { return }
            // The model's SetTitle (or a rename) may have landed while this ran; it wins.
            guard let c, c.title == nil else { return }
            c.send(.setTitle(t))
        }
    }
}
