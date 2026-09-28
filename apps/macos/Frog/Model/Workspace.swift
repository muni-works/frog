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
    /// Parallel attempts in progress, shown instead of the transcript.
    var race: Race?
    private(set) var raceError: String?

    func startRace(prompt: String, models: [String], check: String?) {
        raceError = nil
        Task {
            do {
                race = try await Race.start(in: folder, prompt: prompt, models: models, check: check)
            } catch {
                raceError = "Couldn't start attempts: \(error.localizedDescription). Racing needs a git repository."
            }
        }
    }

    func endRace() {
        race = nil
        Task { await refresh() }
    }

    /// Project files for `@` mentions, loaded on first use.
    private(set) var files: [String] = []
    /// The folder's git branch and uncommitted changes (nil outside a repository, and for chats).
    private(set) var git: GitInfo?
    /// Agent Skills this folder sees, for `/skill` completion.
    private(set) var skills: [SkillInfo] = []

    /// Whether this folder's code may go to cloud models (frog keeps and enforces the answer).
    enum CloudPolicy: String, Codable, Sendable {
        case ask, allow, deny
    }

    private(set) var cloud: CloudPolicy = .ask
    /// "Just this conversation": cloud allowed until the conversation changes.
    var cloudForThisConversation = false

    /// What this folder is called when asking about it: "kiln", or "Chats".
    var policyName: String { isChat ? "Chats" : name }

    func setCloud(_ c: CloudPolicy) async {
        struct Answer: Decodable { var cloud: CloudPolicy }
        if let a = try? await Frog.json(Answer.self, args: ["--cloud-policy", c.rawValue, "--json"], cwd: folder) {
            cloud = a.cloud
        }
    }

    /// Whether choosing a cloud model needs asking first.
    var mustAskForCloud: Bool {
        switch cloud {
        case .allow: false
        case .ask: !cloudForThisConversation
        case .deny: true
        }
    }

    /// A model as this folder may use it: cloud models are locked where code stays on your devices.
    func allowing(_ m: ModelIdentity) -> ModelIdentity {
        guard m.place.isCloud, cloud == .deny, m.state.isReady else { return m }
        var m = m
        m.state = .notAllowed(project: policyName)
        return m
    }
    @ObservationIgnored private var filesLoaded = false

    func loadFiles() {
        guard !filesLoaded else { return }
        filesLoaded = true
        Task { files = await FileIndex.load(folder) }
    }

    /// `fresh` starts a new conversation instead of reopening the folder's last one; `resume`
    /// opens that session.
    init(folder: URL, fresh: Bool = false, resume: String? = nil) {
        self.folder = folder
        preferredModel = UserDefaults.standard.string(forKey: "defaultModel").flatMap { $0.isEmpty ? nil : $0 }
        // Pick up where you left off: the first window reopens this folder's last session.
        // Windows and tabs opened after that start a fresh conversation.
        let chat = Frog.isChat(folder)
        let last = resume ?? (Self.restored || fresh || chat ? nil : UserDefaults.standard.string(forKey: Self.lastSessionKey(folder)))
        Self.restored = true
        let replay = Replay.arguments
        isReplay = replay != nil
        start(arguments: replay ?? last.map { ["-r", $0] } ?? [])
        // A remembered session that won't open (deleted, or from another engine version) starts
        // a fresh conversation instead of leaving a dead one.
        if replay == nil, resume == nil, last != nil, let c = conversation {
            c.onExit = { [weak self, weak c] in
                guard let self, let c, c.turns.isEmpty else { return }
                UserDefaults.standard.removeObject(forKey: Self.lastSessionKey(self.folder))
                self.newSession()
            }
        }
        Task { await refresh() }
    }

    var name: String { isChat ? "Chat" : folder.lastPathComponent }

    /// A plain chat: no project folder, no file or shell tools.
    var isChat: Bool { Frog.isChat(folder) }

    /// Set once the first window has restored its folder's last session.
    private static var restored = false

    /// Showing a recorded session (`-FrogReplay`): don't remember it as this folder's last one.
    @ObservationIgnored private var isReplay = false

    private static func lastSessionKey(_ folder: URL) -> String {
        "lastSession:" + folder.standardizedFileURL.path
    }

    func refresh() async {
        Library.shared.refresh()
        if !isChat { git = await Git.status(folder) }
        if skills.isEmpty, let k = try? await Frog.json([SkillInfo].self, args: ["--skills", "--json"], cwd: folder) {
            skills = k
        }
        if let s = try? await Frog.json([SessionInfo].self, args: ["--sessions", "--json"], cwd: folder) {
            sessions = s
        }
        if models.isEmpty, let m = try? await Frog.json([ModelEntry].self, args: ["--models", "--json"], cwd: folder) {
            models = m
        }
        struct Answer: Decodable { var cloud: CloudPolicy }
        if let a = try? await Frog.json(Answer.self, args: ["--cloud-policy", "--json"], cwd: folder) {
            cloud = a.cloud
        }
    }

    /// Reload the model list (after providers or enabled models change).
    func reloadModels() async {
        if let m = try? await Frog.json([ModelEntry].self, args: ["--models", "--json"], cwd: folder) {
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

    /// Restore files edited in `turn` and later, and continue on a branch from just before it.
    func rewind(toBefore turn: UInt64) async {
        guard let id = conversation?.sessionID else { return }
        do {
            let r = try await Frog.json(Rewound.self, args: ["--rewind", "\(id)@\(turn)", "--json"], cwd: folder)
            start(arguments: ["-r", r.session])
            let files = r.restored.count
            conversation?.flash(files == 0
                ? "Rewound to before turn \(turn). No files needed restoring."
                : "Rewound to before turn \(turn) and restored \(files) file\(files == 1 ? "" : "s").")
            await refresh()
        } catch {
            conversation?.flash("Rewind failed: \(error.localizedDescription)", warning: true)
        }
    }

    func stop() {
        race?.discard()
        conversation?.stop()
    }

    private func start(arguments: [String]) {
        conversation?.stop()
        cloudForThisConversation = false
        // The permission mode new sessions start in (Settings > Permissions).
        let mode = UserDefaults.standard.string(forKey: "defaultMode").flatMap(Mode.init(rawValue:))
        let modeFlag: [String] = switch mode {
        case .yolo: ["--yolo"]
        case .auto: ["--auto"]
        case .acceptEdits: ["--accept-edits"]
        default: []
        }
        let computerUse = UserDefaults.standard.bool(forKey: "computerUse") ? ["--computer-use"] : []
        let chat = isChat ? ["--chat"] : []
        let sandbox = UserDefaults.standard.object(forKey: "sandboxShell") as? Bool ?? true
        let noSandbox = sandbox ? [] : ["--no-shell-sandbox"]
        let c = Conversation(folder: folder, arguments: arguments + modeFlag + computerUse + chat + noSandbox, model: preferredModel)
        c.onSessionChange = { [weak self, weak c] in
            guard let self else { return }
            self.selection = c?.sessionID
            // Only once it has a turn: the engine doesn't write a session before its first
            // message, so an empty one can't be reopened.
            if !self.isReplay, let c, let id = c.sessionID, !c.turns.isEmpty {
                UserDefaults.standard.set(id, forKey: Self.lastSessionKey(self.folder))
            }
            Task { await self.refresh() }
        }
        conversation = c
    }
}

/// `-FrogReplay <session or .jsonl>` (with optional `-FrogReplaySpeed 4` and `-FrogReplayAsk YES`)
/// plays a recorded session in the first window instead of starting a live engine.
@MainActor
enum Replay {
    private static var used = false

    static var arguments: [String]? {
        guard !used, let spec = UserDefaults.standard.string(forKey: "FrogReplay") else { return nil }
        used = true
        let speed = UserDefaults.standard.double(forKey: "FrogReplaySpeed")
        var args = ["--replay", spec, "--speed", String(speed > 0 ? speed : 2)]
        if UserDefaults.standard.bool(forKey: "FrogReplayAsk") { args.append("--replay-ask") }
        return args
    }
}
