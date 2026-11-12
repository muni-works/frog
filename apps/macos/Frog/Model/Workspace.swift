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
    /// The conversation's session id, mirrored (below) so views that only need WHICH session
    /// is showing — the sidebar's selected row, the window title — don't observe the
    /// conversation itself. A streamed turn rewrites `conversation` every 30 Hz batch; a view
    /// reading `conversation?.sessionID` re-evaluated per delta for a value that never moves.
    private(set) var currentSession: String?
    /// The conversation's title, mirrored like `currentSession` (the engine's `titled` sets
    /// both): the window title without the root body reading the streaming conversation.
    private(set) var currentTitle: String?
    var selection: String?
    var preferredModel: String?
    /// A choice made in this workspace's picker. Unlike the startup default, this must win
    /// over the "last model used" policy for the active conversation.
    private var explicitModelChoice: String?
    /// A local model selected in the picker while its files are still downloading. It is the
    /// visible choice, but the engine keeps its current runnable model until the snapshot is
    /// complete.
    private(set) var pendingDownload: String?
    /// Parallel attempts in progress, shown instead of the transcript.
    var race: Race?
    var raceError: String?

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
    /// The repo this folder belongs to: the checkout a worktree hangs off, or the folder
    /// itself when it's the main checkout. Nil for chats and non-repos. Asked once (a git
    /// subprocess — not on the composer's body pass).
    private(set) var repoRoot: URL?

    private func resolveRepoRoot() {
        guard !isChat else { return }
        // The sidebar's convention first: a worktree path names its repo with no git run.
        if SessionList.repoRoot(folder) != folder { repoRoot = SessionList.repoRoot(folder); return }
        guard let top = Git.run(folder, ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty else { return }
        repoRoot = URL(fileURLWithPath: top)
    }
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
        if d.string(forKey: "newMessageModelPolicy") == "fixed",
           let s = d.string(forKey: "defaultModel"), !s.isEmpty { return s }
        return lastUsed(d, apple: apple)
    }

    /// The model picked last, or Apple Intelligence before anything has been.
    static var lastUsed: String? { lastUsed() }

    static func lastUsed(_ d: UserDefaults = .standard, apple: Bool = AppleIntelligence.available) -> String? {
        // Saved before the rename, it may say "tang/…" or "frog-api/…".
        if let s = d.string(forKey: "lastModel"), !s.isEmpty { return ProviderID.canonicalSpec(s) }
        return apple ? AppleIntelligence.spec : nil
    }

    /// A remembered tang choice can outlive a partial or deleted Hugging Face snapshot. Start
    /// with another complete local suggestion so a new chat never reaches a sidecar that cannot
    /// load its tokenizer.
    private static func usableStartingModel(_ spec: String?) -> String? {
        guard let spec, ProviderID.of(spec: spec) == ProviderID.local else { return spec }
        let repo = String(spec.split(separator: "/", maxSplits: 1).last ?? "")
        guard !ModelDownloads.isInstalled(repo) else { return spec }
        return SuggestedModel.all.first(where: { ModelDownloads.isInstalled($0.repo) })?.spec
    }

    /// Switch this conversation to a model, and remember it for the next one.
    func use(_ spec: String) {
        pendingDownload = nil
        preferredModel = spec
        explicitModelChoice = spec
        conversation?.setModel(spec)
        UserDefaults.standard.set(spec, forKey: "lastModel")
    }

    /// The model the picker should show. A selected download takes precedence over the engine's
    /// last runnable model so the composer can explain why sending is paused.
    var selectedModel: String? {
        if let pendingDownload { return pendingDownload }
        // An explicit picker choice is an override for this workspace, regardless of the
        // new-conversation "last model" policy or the model used by the previous turn.
        if let explicitModelChoice { return explicitModelChoice }
        if let preferredModel,
           conversation?.turns.isEmpty != false { return preferredModel }
        // The model the last turn that actually ran used. A turn that never reached the model
        // (a provider error, a 401, an unreachable server) carries that model in its usage with
        // no calls behind it: inheriting it would hand the next message the same dead model.
        if UserDefaults.standard.string(forKey: "newMessageModelPolicy") != "fixed",
           let model = conversation?.turns.reversed()
            .compactMap({ $0.usage.flatMap { $0.modelCalls > 0 ? $0.model : nil } })
            .first { return model }
        return conversation?.status?.model ?? preferredModel
    }

    var pendingDownloadModel: ModelIdentity? {
        guard let spec = pendingDownload else { return nil }
        if let suggested = SuggestedModel.all.first(where: { $0.spec == spec }) {
            return ModelIdentity(suggested)
        }
        return identity(spec)
    }

    /// A model being downloaded to switch to once it's ready.
    @ObservationIgnored private var switching: Task<Void, Never>?

    /// Choose a model that isn't on this Mac yet: download it, and switch to it when it's done.
    func useWhenReady(_ m: ModelIdentity) {
        guard let repo = m.repo else { return }
        let downloads = ModelDownloads.shared
        pendingDownload = m.spec
        preferredModel = m.spec
        explicitModelChoice = m.spec
        UserDefaults.standard.set(m.spec, forKey: "lastModel")
        switch downloads.states[repo] {
        case .downloading: break
        case .done: break
        default: downloads.download(repo)
        }
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
    /// `waitLock`: the session's engine from before a relaunch may still be exiting; wait for it
    /// rather than fail.
    init(folder: URL, fresh: Bool = false, resume: String? = nil, waitLock: Bool = false) {
        self.folder = folder
        preferredModel = Self.usableStartingModel(Self.startingModel)
        // Name models the way the last list did until this folder's own loads (it's slow).
        models = Self.knownModels
        // Pick up where you left off: the first window reopens this folder's last session.
        // Windows and tabs opened after that start a fresh conversation.
        let chat = Frog.isChat(folder)
        // Restoring what was open (see `SessionRegistry`) decides what this window shows.
        let restoring = SessionRegistry.shared.hasPending
        // A replay shows its fixture, never the folder's last session.
        let replaying = Replay.pending
        let remembered = Self.restored || fresh || chat || restoring || replaying ? nil
            : UserDefaults.standard.string(forKey: Self.lastSessionKey(folder))
        // A remembered id whose log is gone (deleted, another home) would only fail to open.
        let last = resume ?? remembered.flatMap { SessionRegistry.logExists($0) ? $0 : nil }
        if let remembered, last == nil { UserDefaults.standard.removeObject(forKey: Self.lastSessionKey(folder)) }
        Self.restored = true
        resolveRepoRoot()
        let replay = Replay.arguments
        isReplay = replay != nil
        let wait = waitLock ? ["--wait-lock", "5"] : []
        start(arguments: replay ?? last.map { ["-r", $0] + wait } ?? [])
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
    static var knownModelList: [ModelEntry] { knownModels }
    @ObservationIgnored private var modelsLoaded = false
    @ObservationIgnored private var gitChecked = false

    /// Returns once this folder shows as it will (its conversation's transcript and its git state
    /// are in), or after `limit` if that's slow.
    func settled(within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while !gitChecked || conversation?.showable == false, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func lastSessionKey(_ folder: URL) -> String {
        "lastSession:" + folder.standardizedFileURL.path
    }

    func refresh() async {
        Library.shared.refresh()
        // Written only when it changed: every view of it would rebuild for nothing.
        if !isChat, case let g = await Git.status(folder), g != git { git = g }
        gitChecked = true
        if skills.isEmpty, let k = try? await Frog.json([SkillInfo].self, args: ["--skills", "--json"], cwd: folder) {
            skills = k
        }
        if let s = try? await Frog.json([SessionInfo].self, args: ["--sessions", "--json"], cwd: folder), s != sessions {
            sessions = s
        }
        if !modelsLoaded, let m = try? await Frog.json([ModelEntry].self, args: ["--models", "--json"], cwd: folder) {
            modelsLoaded = true
            models = m
            Self.knownModels = m
            ModelStats.shared.learnPrices(m)
            await ModelStats.shared.repriceSpend()
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

    /// A Frog Cloud session on screen: the same transcript and composer, its engine in a
    /// sandbox through the gateway instead of `frog --serve` here.
    func openCloud(_ id: String) {
        guard id != conversation?.cloudSession, let gateway = CloudSessions.shared.gateway else { return }
        let c = Conversation(folder: folder, link: CloudLink(gateway: gateway, session: id), replay: false, session: id)
        c.cloudSession = id
        incoming?.stop(reason: "open superseded")
        incoming = c
        selection = id
        show(c)
    }

    /// "Run in Frog Cloud": a new sandbox on this folder's GitHub repo (none: an empty one),
    /// opened here with `text` as its first message.
    /// Where the next new conversation runs, as the composer's location picker says: nil is
    /// this Mac; `.some(nil)` a Frog Cloud sandbox with no repo; `.some("owner/name")` one on
    /// that repo.
    var cloudTarget: String??

    func runInCloud(_ text: String, repo: String?? = nil) async {
        let folder = folder
        // Off the main thread: it runs git and waits, which spins the main run loop.
        let repo: String? = if let repo { repo } else {
            await Task.detached(priority: .userInitiated) { CloudSessions.githubRepo(of: folder) }.value
        }
        do {
            guard let s = try await CloudSessions.shared.create(repo: repo) else { return }
            cloudTarget = nil
            openCloud(s.id)
            if !text.isEmpty { conversation?.submit(text) }
        } catch {
            raceError = CloudFailure.text(error, doing: "start a Frog Cloud session")
        }
    }

    func open(_ id: String) {
        guard id != incoming?.sessionID else { return }
        guard id != conversation?.sessionID else {
            // Back to the one on screen before another finished opening.
            incoming?.stop(reason: "open cancelled")
            incoming = nil
            opening = nil
            return
        }
        // The click changes the screen now (the pane shows `opening`); the log is read off
        // the main thread, then the engine starts on a warm history.
        opening = id
        selection = id
        Task {
            await SessionHistory.prefetch(id, at: Frog.sessions.appending(path: "\(id).jsonl"))
            guard opening == id else { return }  // another click since
            start(arguments: ["-r", id])
        }
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

    func stop(reason: String = "workspace closed") {
        race?.discard()
        incoming?.stop(reason: "\(reason) (opening)")
        if let c = conversation, !SessionBroker.shared.keep(c) { c.stop(reason: reason) }
    }

    /// The engine flags every new conversation gets from Settings. `mode: false` for a
    /// resumed session, which keeps the permission mode it last used rather than whatever
    /// Settings says new ones start in.
    static func engineFlags(chat isChat: Bool, mode: Bool = true) -> [String] {
        // The permission mode new sessions start in (Settings > Permissions).
        let flag: [String] = switch mode ? UserDefaults.standard.string(forKey: "defaultMode").flatMap(Mode.init(rawValue:)) : nil {
        case .yolo: ["--yolo"]
        case .auto: ["--auto"]
        case .acceptEdits: ["--accept-edits"]
        // Asked for on purpose: the engine's own default for a new session is Auto.
        case .default: ["--mode", "default"]
        case nil: []
        }
        let computerUse = UserDefaults.standard.bool(forKey: "computerUse") ? ["--computer-use"] : []
        let chat = isChat ? ["--chat"] : []
        let sandbox = UserDefaults.standard.object(forKey: "sandboxShell") as? Bool ?? true
        let noSandbox = sandbox ? [] : ["--no-shell-sandbox"]
        return flag + computerUse + chat + noSandbox
    }

    /// The engine arguments and `-m` model a conversation starts with. A resume (`-r`) gets
    /// neither a model nor a mode flag: the engine keeps the model and mode the session last
    /// used. (Passing the picker's model there flipped every session opened from the sidebar,
    /// managers' workers included, to whatever the last chat used.)
    static func launch(_ arguments: [String], chat: Bool, model: String?) -> (arguments: [String], model: String?) {
        if arguments.first == "-r" { return (arguments + engineFlags(chat: chat, mode: false), nil) }
        return (arguments + engineFlags(chat: chat), model)
    }

    @discardableResult
    private func start(arguments: [String]) -> Conversation {
        // A newly opened session during a download must start on the still-runnable model.
        let startupModel = pendingDownload == nil ? preferredModel : conversation?.status?.model
        // A session already running in the background (another session messaged it) is
        // picked up as is; a second engine can't open its log.
        let resumed = arguments.first == "-r" && arguments.count > 1 ? arguments[1] : nil
        let adopted = resumed.flatMap { SessionBroker.shared.adopt($0) }
        // Another engine may already own this folder's worktree (its lock names the session):
        // showing the session means restarting its engine, which would die at birth. The
        // same session's engine (adopted above) is the reuse; a different one means no
        // engine starts here — the reason shows in place of a transcript, and the session
        // opens fine once the owner stops.
        if adopted == nil, let owner = Self.worktreeOwner(of: folder, resumed: resumed) {
            return refused(by: owner, session: resumed)
        }
        // A model or mode another session set while this one was stopped applies now, once.
        let stored = adopted == nil ? resumed.map { Library.shared.takeStored($0) } : nil
        let launch = Self.launch(arguments, chat: isChat, model: stored?.model ?? startupModel)
        let c = adopted ?? Conversation(folder: folder, arguments: launch.arguments, model: launch.model)
        if let stored, adopted == nil { SessionBroker.apply(stored, to: c) }
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
        incoming?.stop(reason: "open superseded")
        incoming = c
        // Straight on screen, as on the web: its newest turns are already folded in from the
        // log, and the rest fill in where you're looking.
        show(c)
        return c
    }

    /// The conversation shown in place of a session whose worktree another engine runs in:
    /// no engine, no history read (the owner's may change it), the reason where the
    /// transcript goes and the owner named so the transcript can offer it.
    private func refused(by owner: String, session: String?) -> Conversation {
        let why = SessionBroker.worktreeRefusal(top: folder, owner: owner)
        let c = Conversation(folder: folder, link: nil, replay: false, session: session, failure: why)
        c.heldBy = owner
        c.onSessionChange = { [weak self] in Task { await self?.refresh() } }
        incoming?.stop(reason: "open superseded")
        incoming = c
        show(c)
        return c
    }

    /// The session whose engine holds this folder's worktree, when it isn't the session
    /// being opened. Nil when the tree is free (or the folder isn't in one).
    nonisolated static func worktreeOwner(of folder: URL, resumed: String?) -> String? {
        guard case .worktree(_, let gitDir) = SessionBroker.checkout(of: folder),
              let owner = SessionBroker.worktreeOwner(gitDir: gitDir),
              owner != resumed else { return nil }
        return owner
    }

    /// The line the app shows instead of spawning: whose engine runs in this folder's
    /// worktree, and that the session is resumable once it stops. Nil when the folder's
    /// worktree is free (or no worktree at all).
    nonisolated static func worktreeHold(of folder: URL, resumed: String?) -> String? {
        guard let owner = worktreeOwner(of: folder, resumed: resumed) else { return nil }
        return SessionBroker.worktreeRefusal(top: folder, owner: owner)
    }

    /// Put `c` on screen in place of the conversation there, unless another was opened since.
    private func show(_ c: Conversation) {
        guard incoming === c else { return }
        incoming = nil
        opening = nil
        // A busy agent session keeps working off screen.
        if let old = conversation, !SessionBroker.shared.keep(old) { old.stop(reason: "replaced on screen") }
        cloudForThisConversation = false
        explicitModelChoice = nil
        Motion.cut {
            conversation = c
            currentSession = c.cloudSession ?? c.sessionID
            currentTitle = c.title
            // The id lands when the engine names the session (its first logged event); mirror
            // it here. `onSessionChange` stays the workspace's own hook; this chains beside it
            // and only writes the id when it moved (the writes are on the id, not the turn).
            c.sessionChanged = { [weak self, weak c] in
                guard let self, let c else { return }
                if self.currentSession != (c.cloudSession ?? c.sessionID) {
                    self.currentSession = c.cloudSession ?? c.sessionID
                }
                if self.currentTitle != c.title {
                    self.currentTitle = c.title
                }
            }
        }
    }

    /// Show `c` without the open-wait dance (`incoming`), for tests that mount the workspace's
    /// views directly (the sidebar-boundary benchmark).
    func testShow(_ c: Conversation) {
        incoming = c
        show(c)
    }
}

/// `-FrogReplay <session or .jsonl>` (with optional `-FrogReplaySpeed 4` and `-FrogReplayAsk YES`)
/// plays a recorded session in the first window instead of starting a live engine.
@MainActor
enum Replay {
    private static var used = false

    /// A replay was asked for and no window has taken it yet.
    static var pending: Bool { !used && UserDefaults.standard.string(forKey: "FrogReplay") != nil }

    static var arguments: [String]? {
        guard !used, let spec = UserDefaults.standard.string(forKey: "FrogReplay") else { return nil }
        used = true
        let speed = UserDefaults.standard.double(forKey: "FrogReplaySpeed")
        var args = ["--replay", spec, "--speed", String(speed > 0 ? speed : 2)]
        if UserDefaults.standard.bool(forKey: "FrogReplayAsk") { args.append("--replay-ask") }
        return args
    }
}
