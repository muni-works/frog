import Foundation
import Observation

/// One entry in a turn: a message, reasoning, a tool call, or an engine notice.
struct ItemState: Identifiable {
    enum Kind: Equatable {
        case message
        case reasoning
        case tool(name: String, arg: String)
        case notice(warning: Bool)
    }

    let id: String
    var kind: Kind
    var text = ""
    var result: Item.ToolResult?
    var done = false
    var needsPermission = false
}

struct TurnState: Identifiable {
    let id = UUID()
    /// Assigned by the engine; nil until `turn_started` arrives for a locally echoed prompt.
    var number: UInt64?
    var input: String
    var items: [ItemState] = []
    var end: EndReason?
    var usage: TurnUsage?

    var finished: Bool { end != nil }
}

/// A running session: owns one `kiln --serve` process and folds its events into turns.
@MainActor
@Observable
final class Conversation {
    let folder: URL
    private(set) var sessionID: String?
    private(set) var status: Status?
    private(set) var turns: [TurnState] = []
    private(set) var busy = true
    private(set) var progress: String?
    private(set) var permission: PermissionRequest?
    private(set) var failure: String?
    private(set) var replaying = false

    @ObservationIgnored private var engine: EngineProcess?
    @ObservationIgnored private let replayOnStart: Bool
    @ObservationIgnored private var sawFirstIdle = false
    @ObservationIgnored private var stopping = false
    /// Called when the session id changes or a turn ends, so the sidebar can refresh.
    @ObservationIgnored var onSessionChange: (() -> Void)?

    /// `arguments` are extra CLI flags, e.g. `["-r", id]` or `["--fork", "id@3"]`.
    init(folder: URL, arguments: [String], model: String?) {
        self.folder = folder
        replayOnStart = arguments.contains("-r") || arguments.contains("--fork")
        guard let binary = Kiln.binary else {
            failure = KilnError.missingBinary.localizedDescription
            busy = false
            return
        }
        var args = arguments
        if let model { args += ["-m", model] }
        let engine = EngineProcess(binary: binary, cwd: folder, arguments: args)
        engine.onEvent = { [weak self] env in self?.handle(env) }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            failure = "Couldn't start kiln: \(error.localizedDescription)"
            busy = false
        }
    }

    // MARK: - Actions

    func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        if text.hasPrefix("!") {
            let command = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            turns.append(TurnState(number: nil, input: text, end: .complete))
            busy = true
            engine?.send(.shell(command))
            return
        }
        turns.append(TurnState(number: nil, input: text))
        busy = true
        engine?.send(.submit(text))
    }

    func interrupt() {
        engine?.send(.interrupt)
    }

    func answer(_ decision: Decision) {
        guard let p = permission else { return }
        engine?.send(.permission(id: p.id, decision: decision))
        permission = nil
    }

    func setMode(_ mode: Mode) {
        engine?.send(.setMode(mode))
        status?.mode = mode
    }

    func setModel(_ spec: String) {
        engine?.send(.setModel(spec))
    }

    func compact() {
        busy = true
        engine?.send(.compact(focus: nil))
    }

    func stop() {
        stopping = true
        engine?.stop()
    }

    // MARK: - Events

    private func handle(_ env: Envelope?) {
        guard let env else {
            if !stopping {
                let tail = engine?.stderr.split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
                let how = engine?.exitDescription ?? "unknown"
                failure = tail.isEmpty ? "The kiln engine exited (\(how))." : tail
            }
            busy = false
            progress = nil
            return
        }
        if sessionID != env.session {
            sessionID = env.session
            onSessionChange?()
        }
        switch env.event {
        case .turnStarted(let n, let input):
            if let i = turns.lastIndex(where: { $0.number == nil && !$0.finished && $0.input == input }) {
                turns[i].number = n
            } else {
                turns.append(TurnState(number: n, input: input))
            }
        case .turnEnded(let n, let reason, let usage):
            if let i = turns.lastIndex(where: { $0.number == n }) {
                turns[i].end = reason
                turns[i].usage = usage
            }
            progress = nil
            onSessionChange?()
        case .itemStarted(let id, let kind):
            upsert(id) { $0.kind = Self.kind(kind) }
        case .itemDelta(let id, let delta):
            upsert(id) { item in
                switch delta {
                case .text(let t), .reasoning(let t): item.text += t
                }
            }
            progress = nil
        case .itemCompleted(let id, let item):
            upsert(id) { state in
                state.done = true
                state.needsPermission = false
                switch item {
                case .message(let t):
                    state.kind = .message
                    state.text = t
                case .reasoning(let t):
                    state.kind = .reasoning
                    state.text = t
                case .toolCall(let r):
                    state.kind = .tool(name: r.name, arg: r.arg)
                    state.result = r
                }
            }
        case .permissionRequest(let req):
            permission = req
            upsert(req.item) { $0.needsPermission = true }
            progress = nil
        case .permissionResolved:
            permission = nil
        case .progress(let label):
            progress = label
        case .notice(let level, let message):
            note(message, warning: level == "warn")
        case .error(let e):
            note(e.description, warning: true)
        case .compacted(let before, let after):
            note("Summarized the conversation to save context (\(before.tokens) → \(after.tokens) tokens)", warning: false)
        case .contextPruned(let n, let before, let after):
            note("Trimmed \(n) old tool result\(n == 1 ? "" : "s") to save context (\(before.tokens) → \(after.tokens) tokens)", warning: false)
        case .status(let s):
            status = s
        case .synced:
            replaying = false
        case .idle:
            if !sawFirstIdle {
                sawFirstIdle = true
                if replayOnStart {
                    replaying = true
                    engine?.send(.subscribe(after: 0))
                    return
                }
            }
            busy = false
            progress = nil
            permission = nil
        case .modelChanged, .modeChanged, .unknown:
            break
        }
    }

    private static func kind(_ k: ItemKind) -> ItemState.Kind {
        switch k {
        case .message: .message
        case .reasoning: .reasoning
        case .toolCall(let name, let arg): .tool(name: name, arg: arg)
        }
    }

    /// Update the item with this id, creating it in the current turn if needed.
    private func upsert(_ id: String, _ update: (inout ItemState) -> Void) {
        for t in turns.indices.reversed() {
            if let i = turns[t].items.firstIndex(where: { $0.id == id }) {
                update(&turns[t].items[i])
                return
            }
        }
        if turns.isEmpty {
            turns.append(TurnState(number: nil, input: ""))
        }
        var item = ItemState(id: id, kind: .message)
        update(&item)
        turns[turns.count - 1].items.append(item)
    }

    private func note(_ text: String, warning: Bool) {
        let item = ItemState(id: UUID().uuidString, kind: .notice(warning: warning), text: text, done: true)
        if turns.isEmpty {
            turns.append(TurnState(number: nil, input: "", end: .complete))
        }
        turns[turns.count - 1].items.append(item)
    }
}

extension UInt64 {
    /// 12345 → "12.3k"
    var tokens: String {
        self >= 1000 ? String(format: "%.1fk", Double(self) / 1000) : "\(self)"
    }
}
