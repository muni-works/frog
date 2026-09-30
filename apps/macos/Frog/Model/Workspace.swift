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
    /// A conversation being opened: running, but kept off screen until its transcript is in (or
    /// it's slow to come), so opening one is a single cut rather than an empty pane filling in.
    @ObservationIgnored private var incoming: Conversation?
    /// The session being opened in this workspace's place (here, or another folder's), which
    /// the sidebar selects straight away.
    var opening: String?
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

    // MARK: Which model

    /// The model new conversations start with: the one fixed in Settings, else the one picked
    /// last, else Apple Intelligence where this Mac has it (nil: frog's own default).
    static var startingModel: String? { startingModel() }

    static func startingModel(_ d: UserDefaults = .standard, apple: Bool = AppleIntelligence.available) -> String? {
        if let s = d.string(forKey: "defaultModel"), !s.isEmpty { return s }
        return lastUsed(d, apple: apple)
    }

    /// The model picked last, or Apple Intelligence before anything has been.
    static var lastUsed: String? { lastUsed() }

    static func lastUsed(_ d: UserDefaults = .standard, apple: Bool = AppleIntelligence.available) -> String? {
        if let s = d.string(forKey: "lastModel"), !s.isEmpty { return s }
        return apple ? AppleIntelligence.spec : nil
    }

    /// Switch this conversation to a model, and remember it for the next one.
    func use(_ spec: String) {
        preferredModel = spec
        conversation?.setModel(spec)
        UserDefaults.standard.set(spec, forKey: "lastModel")
    }

    /// A model being downloaded to switch to once it's ready.
    @ObservationIgnored private var switching: Task<Void, Never>?

    /// Choose a model that isn't on this Mac yet: download it, and switch to it when it's done.
    func useWhenReady(_ m: ModelIdentity) {
        guard let repo = m.repo else { return }
        let downloads = ModelDownloads.shared
        switch downloads.states[repo] {
        case .downloading: break
        case .done: break
        default: downloads.download(repo)
        }
        conversation?.flash("Downloading \(m.name). frog switches to it when it's ready.")
        switching?.cancel()
        switching = Task { [weak self] in
            while !Task.isCancelled {
                switch ModelDownloads.shared.states[repo] {
                case .done:
                    guard let self else { return }
                    await self.reloadModels()
                    self.use(m.spec)
                    self.conversation?.flash("\(m.name) is ready.")
                    return
                case .downloading:
                    try? await Task.sleep(for: .seconds(1))
                case .failed, nil:
                    // Stopped or failed: the row says which.
                    return
                }
            }
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
        preferredModel = Self.startingModel
        // Name models the way the last list did until this folder's own loads (it's slow).
        models = Self.knownModels
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

    /// The model list as last loaded, by any folder.
    private static var knownModels: [ModelEntry] = []
    @ObservationIgnored private var modelsLoaded = false
    @ObservationIgnored private var gitChecked = false

    /// Returns once this folder shows as it will (its conversation's transcript and its git state
    /// are in), or after `limit` if that's slow.
    func settled(within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while !gitChecked || conversation?.replaying == true, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func lastSessionKey(_ folder: URL) -> String {
        "lastSession:" + folder.standardizedFileURL.path
    }

    func refresh() async {
        Library.shared.refresh()
        if !isChat { git = await Git.status(folder) }
        gitChecked = true
        if skills.isEmpty, let k = try? await Frog.json([SkillInfo].self, args: ["--skills", "--json"], cwd: folder) {
            skills = k
        }
        if let s = try? await Frog.json([SessionInfo].self, args: ["--sessions", "--json"], cwd: folder) {
            sessions = s
        }
        if !modelsLoaded, let m = try? await Frog.json([ModelEntry].self, args: ["--models", "--json"], cwd: folder) {
            modelsLoaded = true
            models = m
            Self.knownModels = m
            ModelStats.shared.learnPrices(m)
        }
        struct Answer: Decodable { var cloud: CloudPolicy }
        if let a = try? await Frog.json(Answer.self, args: ["--cloud-policy", "--json"], cwd: folder) {
            cloud = a.cloud
        }
    }

    /// Reload the model list (after providers or enabled models change).
    func reloadModels() async {
        if let m = try? await Frog.json([ModelEntry].self, args: ["--models", "--json"], cwd: folder) {
            modelsLoaded = true
            models = m
            Self.knownModels = m
            ModelStats.shared.learnPrices(m)
        }
    }

    func newSession() {
        start(arguments: [])
    }

    func open(_ id: String) {
        guard id != incoming?.sessionID else { return }
        guard id != conversation?.sessionID else {
            // Back to the one on screen before another finished opening.
            incoming?.stop()
            incoming = nil
            opening = nil
            return
        }
        opening = id
        start(arguments: ["-r", id])
    }

    /// Branch the current session right after `turn`, and switch to the branch.
    @discardableResult
    func fork(afterTurn turn: UInt64) -> Conversation? {
        guard let id = conversation?.sessionID else { return nil }
        return start(arguments: ["--fork", "\(id)@\(turn)"])
    }

    /// Restore files edited in `turn` and later, and continue on a branch from just before it.
    /// Returns the new branch's session, or nil if it failed (the transcript says why).
    @discardableResult
    func rewind(toBefore turn: UInt64) async -> String? {
        guard let id = conversation?.sessionID else { return nil }
        do {
            let r = try await Frog.json(Rewound.self, args: ["--rewind", "\(id)@\(turn)", "--json"], cwd: folder)
            let c = start(arguments: ["-r", r.session])
            let files = r.restored.count
            c.flash(files == 0
                ? "Rewound to before turn \(turn). No files needed restoring."
                : "Rewound to before turn \(turn) and restored \(files) file\(files == 1 ? "" : "s").")
            await refresh()
            return r.session
        } catch {
            conversation?.flash("Rewind failed: \(error.localizedDescription)", warning: true)
            return nil
        }
    }

    func stop() {
        race?.discard()
        incoming?.stop()
        conversation?.stop()
    }

    @discardableResult
    private func start(arguments: [String]) -> Conversation {
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
        incoming?.stop()
        incoming = c
        // Nothing to cut from, or nothing to wait for: straight on screen.
        guard conversation != nil, c.replaying else {
            show(c)
            return c
        }
        Task {
            await c.loaded(within: .milliseconds(300))
            show(c)
        }
        return c
    }

    /// Put `c` on screen in place of the conversation there, unless another was opened since.
    private func show(_ c: Conversation) {
        guard incoming === c else { return }
        incoming = nil
        opening = nil
        conversation?.stop()
        cloudForThisConversation = false
        Motion.cut { conversation = c }
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
