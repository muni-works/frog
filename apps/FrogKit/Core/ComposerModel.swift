import Foundation

/// The composer's behaviour: a pure reducer (docs/plans/2026-11-12-composer-tray.md). The view
/// renders `State` plus `derive(_:)` and sends intents; effects come back as data for a thin
/// runner to perform, which feeds results back as intents. The web has the same reducer in
/// `apps/web/src/composer.ts`; both pass `docs/design/composer/cases.json`.
enum ComposerModel {
    enum Mode: String, Codable, CaseIterable, Sendable { case auto, `default`, accept_edits, yolo }
    enum Place: String, Codable, Sendable { case local, cloud }
    enum Busy: String, Codable, Sendable { case idle, working, sending, loading_model }
    enum PrState: String, Codable, CaseIterable, Sendable { case draft, checks, failing, approved, merged, closed }
    enum Action: String, Codable, Sendable { case dictate, send, stop, queue }
    enum GitAction: String, Codable, Sendable { case commit, open_pr, push, fix, merge, archive, reopen }
    enum Pending: String, Codable, Sendable { case draft, aside }
    enum Confirm: String, Codable, Sendable { case yolo, merge, archive }

    struct Attachment: Codable, Equatable, Sendable { var name: String; var size: Int; var type: String }
    struct Model: Codable, Equatable, Sendable { var id: String; var name: String; var place: Place; var node: String? }
    struct Checks: Codable, Equatable, Sendable { var ok: Int; var total: Int }
    struct Pr: Codable, Equatable, Sendable {
        var repo: String
        var number: Int
        var title: String
        var state: PrState
        var checks: Checks
        var access: Bool?
        var url: String { "https://github.com/\(repo)/pull/\(number)" }
    }
    struct Diff: Codable, Equatable, Sendable { var add: Int; var del: Int; var files: Int }

    enum Where: Equatable, Sendable {
        case folder(folder: String, branch: String, worktree: Bool, git: Bool, dirty: Bool)
        case cloud(repo: String, branch: String)
        case chat
        case session(Session)
    }
    struct Session: Codable, Equatable, Sendable {
        var repo: String?
        var branch: String
        var worktree: Bool
        var worktreePath: String?
        var diff: Diff
        var dirty: Bool
        var ahead: Int
        var prs: [Pr]
    }

    struct Failure: Codable, Equatable, Sendable {
        var code: String
        var message: String
        var actions: [String]
        var control: String?
        var detail: String?
        var retryIn: Int?
    }

    struct Draft: Codable, Equatable, Sendable { var text = ""; var attachments: [Attachment] = []; var caret = 0 }
    struct Defaults: Codable, Equatable, Sendable { var local: Model?; var cloud: Model? }
    struct Memory: Codable, Equatable, Sendable {
        var modelByPlace: [String: Model] = [:]
        var worktreeByRepo: [String: Bool] = [:]
        var branchByRepo: [String: String] = [:]
    }

    struct State: Codable, Equatable, Sendable {
        var draft = Draft()
        var lastSent = ""
        var mode: Mode = .auto
        var yoloConfirmed = false
        var model: Model
        var defaults = Defaults()
        var signedIn = false
        var `where`: Where
        var busy: Busy = .idle
        /// What the send in flight carries: the draft (cleared on ack) or a git action's own text.
        var pending: Pending?
        var queued = 0
        var error: Failure?
        var notice: String?
        var confirm: Confirm?
        var stackOpen = false
        var memory = Memory()
    }

    struct Derived: Codable, Equatable, Sendable {
        struct Summary: Codable, Equatable, Sendable { var count: Int; var worst: PrState; var label: String }
        var action: Action
        var sendDisabled: Bool
        var gitAction: GitAction?
        var prSummary: Summary?
        var canSwitchBranch: Bool
    }

    enum Intent: Equatable, Sendable {
        case type(String, caret: Int?)
        case attach([Attachment])
        case removeAttachment(Int)
        case suggestion(String)
        case recall, send, action, ack
        case sendFailed(code: String, retryIn: Int?)
        case turnDone, stop, esc, modelLoading, modelReady, micDenied
        case setMode(Mode)
        case cycleMode, confirm, cancelConfirm
        case pickModel(Model)
        case chooseFolder(folder: String, branch: String, git: Bool, dirty: Bool)
        case chooseCloud(repo: String, branch: String)
        case justChat
        case pickBranch(String)
        case switchBranch(String)
        case toggleWorktree
        case failed(code: String, detail: String?)
        case errorAction(String)
        case dismissError, gitAction
        case prClick(Int, alt: Bool)
        case openStack, closeStack
        case bindPr(String)
        case prs([Pr])
    }

    /// What the runner does: `type` plus its fields, flat (as the cases spell them).
    struct Effect: Equatable, Sendable {
        var type: String
        var fields: [String: JSON] = [:]
        init(_ type: String, _ fields: [String: JSON] = [:]) { self.type = type; self.fields = fields }
    }

    static let maxAttachment = 20_000_000
    /// Worst first: the stack pill and the action follow the worst PR.
    static let prOrder: [PrState] = [.failing, .checks, .draft, .approved, .closed, .merged]
    private static let prWord: [PrState: String] = [.failing: "failing", .checks: "checking", .draft: "draft", .approved: "approved", .closed: "closed", .merged: "merged"]
    private static let modes: [Mode] = [.auto, .default, .accept_edits, .yolo]

    /// Every error both apps show, worded once.
    private static let errors: [String: (String, [String], String?)] = [
        "engine_stopped": ("Frog's engine stopped", ["restart_engine"], nil),
        "signed_out": ("Signed out of Frog Cloud", ["sign_in"], nil),
        "no_credit": ("Out of credit", ["add_credit", "use_local"], nil),
        "cloud_busy": ("Frog Cloud is busy", ["retry"], nil),
        "mic_denied": ("Allow microphone in System Settings", ["open_settings"], "action"),
        "worktree_failed": ("Couldn't make a worktree", ["use_checkout"], "worktree"),
        "clone_failed": ("Couldn't clone the repo", ["retry"], "where"),
        "hook_failed": ("A commit hook failed", ["show_output"], "git_action"),
        "gh_auth": ("Connect GitHub to open a PR", ["connect_github"], "git_action"),
        "push_rejected": ("Branch moved on GitHub", ["pull_retry"], "git_action"),
        "merge_conflict": ("This PR has conflicts", ["resolve_conflicts"], "git_action"),
        "branch_protected": ("Branch protection blocks the merge", [], "git_action"),
        "pr_not_found": ("Couldn't find that PR", [], nil),
    ]

    static func failure(_ s: State, _ code: String, detail: String? = nil, retryIn: Int? = nil) -> Failure {
        let (message, actions, control) = errors[code] ?? ("Something went wrong", [], nil)
        return Failure(
            code: code,
            message: code == "branch_protected" ? (detail ?? message) : message,
            actions: code == "no_credit" && s.defaults.local == nil ? actions.filter { $0 != "use_local" } : actions,
            control: control,
            detail: detail,
            retryIn: retryIn
        )
    }

    static func hasContent(_ s: State) -> Bool {
        !s.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !s.draft.attachments.isEmpty
    }

    private static func accepts(_ a: Attachment) -> Bool {
        a.type.hasPrefix("image/") || a.type.hasPrefix("text/") || a.type == "application/pdf" || a.type == "application/json"
    }

    static func worst(_ prs: [Pr]) -> Pr? {
        prs.min { prOrder.firstIndex(of: $0.state)! < prOrder.firstIndex(of: $1.state)! }
    }

    static func derive(_ s: State) -> Derived {
        let content = hasContent(s)
        let action: Action = switch s.busy {
        case .working: content ? .queue : .stop
        case .loading_model: .stop
        case .sending: .send
        case .idle: content ? .send : .dictate
        }
        var git: GitAction?
        var summary: Derived.Summary?
        var canSwitch = true
        if case .session(let w) = s.where {
            canSwitch = !w.dirty
            let top = worst(w.prs)
            if top?.state == .merged { git = .archive }
            else if w.dirty { git = .commit }
            else if top == nil { git = w.ahead > 0 ? .open_pr : nil }
            else if top?.state == .closed { git = .reopen }
            else if top?.state == .failing { git = .fix }
            else if w.ahead > 0 { git = .push }
            else if top?.state == .approved { git = .merge }
            if let top {
                let n = w.prs.count
                let k = w.prs.filter { $0.state == top.state }.count
                let label = n == 1 ? "#\(top.number)" : "\(n) PRs, \(k == n ? "all" : String(k)) \(prWord[top.state]!)"
                summary = .init(count: n, worst: top.state, label: label)
            }
        }
        let disabled = s.busy == .sending || (s.busy == .idle && !content)
        return Derived(action: action, sendDisabled: disabled, gitAction: git, prSummary: summary, canSwitchBranch: canSwitch)
    }

    /// The key a model is remembered under: the folder, the cloud repo, or chat.
    private static func placeKey(_ w: Where) -> String {
        switch w {
        case .folder(let folder, _, _, _, _): folder
        case .cloud: "cloud"
        case .chat: "chat"
        case .session(let s): s.repo ?? "session"
        }
    }

    typealias Out = (State, [Effect])

    private static func send(_ s: State) -> Out {
        guard hasContent(s) else { return (s, []) }
        let text = s.draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = JSON.array(s.draft.attachments.map(JSON.init))
        var n = s
        switch s.busy {
        case .sending: return (s, [])
        case .loading_model:
            n.pending = .draft
            return (n, [])
        case .working:
            n.draft = Draft()
            n.lastSent = text
            n.queued += 1
            return (n, [Effect("queued", ["text": .string(text), "attachments": files])])
        case .idle:
            n.busy = .sending
            n.pending = .draft
            n.error = nil
            if case .session = s.where { return (n, [Effect("submit", ["text": .string(text), "attachments": files])]) }
            return (n, [Effect("start_session", ["where": JSON(s.where), "text": .string(text), "attachments": files])])
        }
    }

    /// A turn a git action asks for (Fix, Resolve conflicts): the draft stays put.
    private static func sendAside(_ s: State, _ text: String) -> Out {
        var n = s
        let effect = ["text": JSON.string(text), "attachments": .array([])]
        if s.busy == .working {
            n.queued += 1
            return (n, [Effect("queued", effect)])
        }
        n.busy = .sending
        n.pending = .aside
        n.error = nil
        return (n, [Effect("submit", effect)])
    }

    private static func setMode(_ s: State, _ mode: Mode) -> Out {
        var n = s
        if mode == .yolo, !s.yoloConfirmed {
            n.confirm = .yolo
            return (n, [])
        }
        guard mode != s.mode else { return (s, []) }
        n.mode = mode
        n.confirm = nil
        return (n, [Effect("set_mode", ["mode": .string(mode.rawValue)])])
    }

    private static func switchModel(_ s: State, _ model: Model?, _ place: String) -> Out {
        guard let model, model.id != s.model.id else { return (s, []) }
        var n = s
        if model.place != s.model.place { n.notice = "Switched to \(model.name) \(place)" }
        n.model = model
        return (n, [Effect("set_model", ["model": JSON(model)])])
    }

    private static func cleared(_ s: State) -> State {
        var n = s
        n.notice = nil
        n.error = nil
        return n
    }

    static func reduce(_ s: State, _ intent: Intent) -> Out {
        var n = s
        switch intent {
        case .type(let text, let caret):
            n.draft.text = text
            n.draft.caret = caret ?? text.utf16.count
            return (n, [])
        case .attach(let files):
            let refused = files.filter { $0.size > maxAttachment || !accepts($0) }
            n.draft.attachments += files.filter { !refused.contains($0) }
            guard !refused.isEmpty else {
                if s.error?.code == "attach_refused" { n.error = nil }
                return (n, [])
            }
            let why = refused.map { "\($0.name) (\($0.size > maxAttachment ? "over 20 MB" : "not a supported type"))" }
            n.error = Failure(code: "attach_refused", message: "Couldn't attach " + why.joined(separator: ", "), actions: [])
            return (n, [])
        case .removeAttachment(let i):
            if n.draft.attachments.indices.contains(i) { n.draft.attachments.remove(at: i) }
            return (n, [])
        case .suggestion(let text):
            if case .session = s.where { return (s, []) }
            guard s.draft.text.isEmpty else { return (s, []) }
            n.draft.text = text
            n.draft.caret = text.utf16.count
            return (n, [])
        case .recall:
            guard s.draft.text.isEmpty, !s.lastSent.isEmpty else { return (s, []) }
            n.draft.text = s.lastSent
            n.draft.caret = s.lastSent.utf16.count
            return (n, [])
        case .send:
            return send(s)
        case .action:
            switch derive(s).action {
            case .dictate: return (s, [Effect("start_dictation")])
            case .stop: return reduce(s, .stop)
            default: return send(s)
            }
        case .ack:
            let sent = s.pending == .draft
            n.busy = .working
            n.pending = nil
            n.error = nil
            if sent {
                n.lastSent = s.draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                n.draft = Draft()
            }
            return (n, [])
        case .sendFailed(let code, let retryIn):
            n.busy = .idle
            n.pending = nil
            n.error = failure(s, code, retryIn: retryIn)
            return (n, [])
        case .turnDone:
            n.busy = .idle
            n.queued = 0
            return (n, [])
        case .stop:
            if s.busy == .working { return (s, [Effect("interrupt")]) }
            if s.busy == .loading_model {
                n.busy = .idle
                n.pending = nil
                return (n, [Effect("cancel_load")])
            }
            return (s, [])
        case .esc:
            if s.busy == .working || s.busy == .loading_model { return reduce(s, .stop) }
            if s.confirm != nil { n.confirm = nil }
            else if s.error != nil { n.error = nil }
            else if s.stackOpen { n.stackOpen = false }
            return (n, [])
        case .modelLoading:
            n.busy = .loading_model
            return (n, [])
        case .modelReady:
            n.busy = .idle
            guard s.pending == .draft else { return (n, []) }
            n.pending = nil
            return send(n)
        case .micDenied:
            n.error = failure(s, "mic_denied")
            return (n, [])
        case .setMode(let m):
            return setMode(s, m)
        case .cycleMode:
            let i = modes.firstIndex(of: s.mode) ?? 0
            return setMode(s, modes[(i + 1) % modes.count])
        case .confirm:
            switch s.confirm {
            case .yolo:
                n.mode = .yolo
                n.yoloConfirmed = true
                n.confirm = nil
                return (n, [Effect("set_mode", ["mode": .string("yolo")])])
            case .merge:
                guard case .session(let w) = s.where else { return (s, []) }
                n.confirm = nil
                guard let top = worst(w.prs) else { return (n, []) }
                return (n, [Effect("merge", ["repo": .string(top.repo), "number": .number(Double(top.number))])])
            case .archive:
                n.confirm = nil
                return (n, [Effect("archive", ["discard": .bool(true)])])
            case nil:
                return (s, [])
            }
        case .cancelConfirm:
            n.confirm = nil
            return (n, [])
        case .pickModel(let m):
            if m.place == .cloud, !s.signedIn { return (s, [Effect("open_login")]) }
            n.memory.modelByPlace[placeKey(s.where)] = m
            n.model = m
            if s.busy == .working, m.node != nil { n.notice = "Swaps after this turn" }
            return (n, [Effect("set_model", ["model": JSON(m)])])
        case .chooseFolder(let folder, let branch, let git, let dirty):
            n = cleared(s)
            n.where = .folder(
                folder: folder,
                branch: s.memory.branchByRepo[folder] ?? branch,
                worktree: git && (s.memory.worktreeByRepo[folder] ?? true),
                git: git,
                dirty: dirty
            )
            let want = s.memory.modelByPlace[folder] ?? (s.model.place == .cloud ? s.defaults.local : nil)
            return switchModel(n, want, "on this Mac")
        case .chooseCloud(let repo, let branch):
            n = cleared(s)
            n.where = .cloud(repo: repo, branch: s.memory.branchByRepo[repo] ?? branch)
            let want = s.memory.modelByPlace["cloud"] ?? (s.model.place == .local ? s.defaults.cloud : nil)
            return switchModel(n, want, "for Frog Cloud")
        case .justChat:
            n = cleared(s)
            n.where = .chat
            return switchModel(n, s.memory.modelByPlace["chat"], "")
        case .pickBranch(let b):
            switch s.where {
            case .folder(let folder, _, let worktree, let git, let dirty):
                n.where = .folder(folder: folder, branch: b, worktree: worktree, git: git, dirty: dirty)
                n.memory.branchByRepo[folder] = b
            case .cloud(let repo, _):
                n.where = .cloud(repo: repo, branch: b)
                n.memory.branchByRepo[repo] = b
            default:
                return (s, [])
            }
            return (n, [])
        case .switchBranch(let b):
            guard case .session(let w) = s.where, !w.dirty else { return (s, []) }
            return (s, [Effect("switch_branch", ["branch": .string(b)])])
        case .toggleWorktree:
            guard case .folder(let folder, let branch, let worktree, true, let dirty) = s.where else { return (s, []) }
            let on = !worktree
            n.where = .folder(folder: folder, branch: branch, worktree: on, git: true, dirty: dirty)
            n.memory.worktreeByRepo[folder] = on
            n.notice = !on && dirty ? "Frog will work in your checkout" : nil
            if s.error?.control == "worktree" { n.error = nil }
            return (n, [])
        case .failed(let code, let detail):
            if s.busy == .sending {
                n.busy = .idle
                n.pending = nil
            }
            n.error = failure(s, code, detail: detail)
            return (n, [])
        case .dismissError:
            n.error = nil
            return (n, [])
        case .errorAction(let a):
            return errorAction(s, a)
        case .gitAction:
            guard let a = derive(s).gitAction, case .session(let w) = s.where else { return (s, []) }
            let top = worst(w.prs)
            switch a {
            case .commit: return (s, [Effect("draft_commit")])
            case .open_pr: return (s, [Effect("open_pr")])
            case .push: return (s, [Effect("push")])
            case .fix: return sendAside(s, "Fix the failing checks on #\(top!.number)")
            case .merge:
                n.confirm = .merge
                return (n, [])
            case .archive:
                if w.dirty {
                    n.confirm = .archive
                    return (n, [])
                }
                return (s, [Effect("archive", ["discard": .bool(false)])])
            case .reopen:
                return (s, [Effect("reopen", ["repo": .string(top!.repo), "number": .number(Double(top!.number))])])
            }
        case .prClick(let i, let alt):
            guard case .session(let w) = s.where, w.prs.indices.contains(i) else { return (s, []) }
            let url = w.prs[i].url
            return (s, [alt ? Effect("copy", ["text": .string(url)]) : Effect("open_url", ["url": .string(url)])])
        case .openStack:
            if case .session(let w) = s.where { n.stackOpen = w.prs.count > 1 } else { n.stackOpen = false }
            return (n, [])
        case .closeStack:
            n.stackOpen = false
            return (n, [])
        case .bindPr(let ref):
            let r = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.isEmpty ? (s, []) : (s, [Effect("bind_pr", ["ref": .string(r)])])
        case .prs(let prs):
            guard case .session(var w) = s.where else { return (s, []) }
            w.prs = prs
            n.where = .session(w)
            return (n, [])
        }
    }

    private static func errorAction(_ s: State, _ action: String) -> Out {
        var clear = s
        clear.error = nil
        switch action {
        case "restart_engine": return (clear, [Effect("restart_engine")])
        case "sign_in": return (clear, [Effect("open_login")])
        case "add_credit": return (clear, [Effect("open_billing")])
        case "use_local":
            guard let local = s.defaults.local else { return (s, []) }
            clear.model = local
            return (clear, [Effect("set_model", ["model": JSON(local)])])
        case "retry": return send(clear)
        case "open_settings": return (clear, [Effect("open_mic_settings")])
        case "use_checkout":
            guard case .folder(let folder, let branch, _, let git, let dirty) = s.where else { return (clear, []) }
            clear.where = .folder(folder: folder, branch: branch, worktree: false, git: git, dirty: dirty)
            return send(clear)
        case "pull_retry": return (clear, [Effect("pull_push")])
        case "connect_github": return (clear, [Effect("gh_auth_login")])
        case "show_output": return (s, [Effect("show_output", ["detail": .string(s.error?.detail ?? "")])])
        case "resolve_conflicts":
            guard case .session(let w) = s.where, let top = worst(w.prs) else { return (clear, []) }
            return sendAside(clear, "Resolve the merge conflicts on #\(top.number)")
        default: return (s, [])
        }
    }
}

// MARK: - Coding

extension ComposerModel.Where: Codable {
    private enum K: String, CodingKey { case kind, folder, branch, worktree, git, dirty, repo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "folder":
            self = .folder(
                folder: try c.decode(String.self, forKey: .folder),
                branch: try c.decode(String.self, forKey: .branch),
                worktree: try c.decode(Bool.self, forKey: .worktree),
                git: try c.decode(Bool.self, forKey: .git),
                dirty: try c.decode(Bool.self, forKey: .dirty)
            )
        case "cloud": self = .cloud(repo: try c.decode(String.self, forKey: .repo), branch: try c.decode(String.self, forKey: .branch))
        case "chat": self = .chat
        default: self = .session(try ComposerModel.Session(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .folder(let folder, let branch, let worktree, let git, let dirty):
            try c.encode("folder", forKey: .kind)
            try c.encode(folder, forKey: .folder)
            try c.encode(branch, forKey: .branch)
            try c.encode(worktree, forKey: .worktree)
            try c.encode(git, forKey: .git)
            try c.encode(dirty, forKey: .dirty)
        case .cloud(let repo, let branch):
            try c.encode("cloud", forKey: .kind)
            try c.encode(repo, forKey: .repo)
            try c.encode(branch, forKey: .branch)
        case .chat:
            try c.encode("chat", forKey: .kind)
        case .session(let s):
            try c.encode("session", forKey: .kind)
            try s.encode(to: encoder)
        }
    }
}

extension ComposerModel.Intent: Decodable {
    private struct Raw: Decodable {
        var type: String
        var text: String?
        var caret: Int?
        var files: [ComposerModel.Attachment]?
        var index: Int?
        var code: String?
        var retryIn: Int?
        var detail: String?
        var mode: ComposerModel.Mode?
        var model: ComposerModel.Model?
        var folder: String?
        var branch: String?
        var git: Bool?
        var dirty: Bool?
        var repo: String?
        var action: String?
        var alt: Bool?
        var ref: String?
        var prs: [ComposerModel.Pr]?
    }

    init(from decoder: Decoder) throws {
        let r = try Raw(from: decoder)
        switch r.type {
        case "type": self = .type(r.text ?? "", caret: r.caret)
        case "attach": self = .attach(r.files ?? [])
        case "remove_attachment": self = .removeAttachment(r.index ?? 0)
        case "suggestion": self = .suggestion(r.text ?? "")
        case "recall": self = .recall
        case "send": self = .send
        case "action": self = .action
        case "ack": self = .ack
        case "send_failed": self = .sendFailed(code: r.code ?? "", retryIn: r.retryIn)
        case "turn_done": self = .turnDone
        case "stop": self = .stop
        case "esc": self = .esc
        case "model_loading": self = .modelLoading
        case "model_ready": self = .modelReady
        case "mic_denied": self = .micDenied
        case "set_mode": self = .setMode(r.mode ?? .auto)
        case "cycle_mode": self = .cycleMode
        case "confirm": self = .confirm
        case "cancel_confirm": self = .cancelConfirm
        case "pick_model":
            guard let m = r.model else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "pick_model needs a model")) }
            self = .pickModel(m)
        case "choose_folder": self = .chooseFolder(folder: r.folder ?? "", branch: r.branch ?? "", git: r.git ?? false, dirty: r.dirty ?? false)
        case "choose_cloud": self = .chooseCloud(repo: r.repo ?? "", branch: r.branch ?? "")
        case "just_chat": self = .justChat
        case "pick_branch": self = .pickBranch(r.branch ?? "")
        case "switch_branch": self = .switchBranch(r.branch ?? "")
        case "toggle_worktree": self = .toggleWorktree
        case "failed": self = .failed(code: r.code ?? "", detail: r.detail)
        case "error_action": self = .errorAction(r.action ?? "")
        case "dismiss_error": self = .dismissError
        case "git_action": self = .gitAction
        case "pr_click": self = .prClick(r.index ?? 0, alt: r.alt ?? false)
        case "open_stack": self = .openStack
        case "close_stack": self = .closeStack
        case "bind_pr": self = .bindPr(r.ref ?? "")
        case "prs": self = .prs(r.prs ?? [])
        default: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown intent \(r.type)"))
        }
    }
}

extension ComposerModel.Effect: Encodable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(type, forKey: Key(stringValue: "type"))
        for (k, v) in fields { try c.encode(v, forKey: Key(stringValue: k)) }
    }
}

/// A JSON value: effect fields, and the shape the shared cases compare.
enum JSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    /// Any encodable value, as JSON (a round trip through the encoder).
    init(_ value: some Encodable) {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        self = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
