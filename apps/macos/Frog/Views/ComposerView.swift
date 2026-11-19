import AppKit
import SwiftUI

/// The composer (docs/design/composer/spec.md): one card, two rows at rest — the field and its
/// controls (attach, where before a session, then mode, model and the action) — with a status
/// line on top when there is something to say. What it does is `ComposerModel` (shared with the
/// web through docs/design/composer/cases.json); this view feeds it the live state and runs its
/// effects. Frog-drawn from the tokens: no glass, no system menus.
struct ComposerView: View {
    @Environment(\.paneWidth) var paneWidth
    let workspace: Workspace
    let conversation: Conversation
    var window: WindowState?
    /// Opens the changes card (the git line's +a −d).
    var openDiff: () -> Void = {}
    @State var text = ""
    @State var height: CGFloat = 16
    @State var controller = ComposerController()
    @State var mention: String?
    @State var picked = 0
    @State var racing = false
    /// Images to send with the message.
    @State var attachments: [ToolImage] = []
    @State var dictation = Dictation()
    @State var downloads = ModelDownloads.shared
    /// Restores the draft when this conversation appears; saves it as it's typed.
    @State var drafts = DraftStore.shared
    @State var draftSave: Task<Void, Never>?
    /// The draft the last warm-up carried (`.some(nil)`: the conversation alone; nil: none yet).
    @State var warmed: String?? = nil
    /// The reducer's own state: what the live objects don't hold (error, confirmations, memory).
    @State var local = TrayLocal()
    /// The session's GitHub slug and commits ahead, read off the main thread.
    @State var slug: String?
    @State var ahead = 0
    @State var cloudRepos: [String] = []
    /// The current place's branches, for the where menu's Branch level.
    @State var branches: [String] = []
    /// The one composer menu that's open.
    @State var menu: ComposerMenuID?
    /// The composer's own width: under 420 the controls go narrow.
    @State var width: CGFloat = ComposerMetrics.maxWidth
    /// The field has the keyboard: the card's stroke goes to muted.
    @State var focused = false
    @State var gitIndex = GitIndex.shared
    @Environment(\.switchFolder) var switchFolder
    @Environment(\.showSettings) var showSettings

    /// What `ComposerModel.State` keeps that nothing else here does.
    struct TrayLocal {
        var error: ComposerModel.Failure?
        var notice: String?
        var confirm: ComposerModel.Confirm?
        var stackOpen = false
        var lastSent = ""
        var memory = ComposerModel.Memory()
        var yoloConfirmed = UserDefaults.standard.bool(forKey: "yoloConfirmed")
    }

    /// Folders a send from the "where" line just moved to: their composer sends the draft it restores.
    @MainActor static var sendOnAppear: Set<String> = []

    static func hasWords(_ s: String) -> Bool {
        s.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    var waitingForModel: Bool {
        guard let model = workspace.pendingDownloadModel else { return false }
        return switch model.state {
        case .notDownloaded, .downloading, .downloadFailed: true
        default: false
        }
    }

    @State var suggestions: [String] = []

    var skillSuggestions: [SkillInfo] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let q = text.dropFirst().lowercased()
        let all = workspace.skills
        let prefix = all.filter { $0.name.hasPrefix(q) }
        let rest = q.isEmpty ? [] : all.filter { !$0.name.hasPrefix(q) && ($0.name.contains(q) || $0.description.lowercased().contains(q)) }
        return Array((prefix + rest).prefix(8))
    }

    // MARK: The reducer's view of things

    var isNew: Bool { !conversation.started && !conversation.replaying }

    var trayWhere: ComposerModel.Where {
        if workspace.isChat { return .chat }
        if isNew {
            if let target = workspace.cloudTarget { return .cloud(repo: target ?? "No repo", branch: "main") }
            let repo = workspace.repoRoot?.path
            return .folder(
                folder: workspace.folder.path,
                branch: workspace.git?.branch ?? "",
                worktree: repo != nil && (local.memory.worktreeByRepo[workspace.folder.path] ?? true),
                git: repo != nil,
                dirty: (workspace.git?.changed ?? 0) > 0
            )
        }
        guard let git = workspace.git else { return .chat }
        let path = workspace.folder.path
        let inTree = path.contains("/worktrees/")
        return .session(.init(
            // A local-only repo still has git state to show: its folder stands in for the slug.
            repo: slug ?? workspace.repoRoot?.lastPathComponent ?? workspace.folder.lastPathComponent, branch: git.branch, worktree: inTree, worktreePath: inTree ? path : nil,
            diff: .init(add: git.added, del: git.removed, files: git.changed), dirty: git.changed > 0,
            ahead: ahead, prs: gitIndex.prs(boundPrs)
        ))
    }

    /// The PRs bound to this session (`Conversation.boundPrs`).
    var boundPrs: [PrBinding] { conversation.boundPrs }

    var trayModel: ComposerModel.Model {
        let spec = conversation.status?.model ?? UserDefaults.standard.string(forKey: "lastModel") ?? ""
        let cloud = conversation.cloudSession != nil || conversation.start != nil || spec.hasPrefix("cloud/") || workspace.cloudTarget != nil
        return .init(id: spec, name: spec, place: cloud ? .cloud : .local, node: nil)
    }

    var tray: ComposerModel.State {
        var s = ComposerModel.State(model: trayModel, where: trayWhere)
        s.draft = .init(text: text, attachments: attachments.map { _ in .init(name: "image", size: 0, type: "image/png") }, caret: text.utf16.count)
        s.lastSent = local.lastSent
        s.mode = Self.mode(conversation.status?.mode ?? Mode(rawValue: UserDefaults.standard.string(forKey: "defaultMode") ?? "") ?? .auto)
        s.yoloConfirmed = local.yoloConfirmed
        s.signedIn = CloudSessions.shared.available
        s.busy = waitingForModel ? .loading_model : conversation.busy ? .working : .idle
        s.queued = conversation.queue.map { .init(text: $0.text, attachments: $0.images.map { _ in .init(name: "image", size: 0, type: "image/png") }) }
        s.dictating = dictation.isActive
        s.error = local.error
        s.notice = local.notice
        s.confirm = local.confirm
        s.stackOpen = local.stackOpen
        s.memory = local.memory
        s.openPrWhenDone = conversation.status?.openPrWhenDone.flatMap(OpenPR.Setting.init(rawValue:))
        s.openPr = openPrInput
        return s
    }

    /// What `OpenPR.shouldOpenPR` decides on (FrogKit/Core/OpenPR.swift). Every fact comes from
    /// what the app already knows: the tree it was started in, the branch's commits, the PRs
    /// bound to it, where it sits in the started-by tree, and whether it only reads.
    var openPrInput: OpenPR.Input {
        let id = conversation.sessionID
        let library = Library.shared
        let row = id.flatMap { sid in library.sessions.first { $0.id == sid } }
        let worktree: Bool = if case .session(let s) = trayWhere { s.worktree } else { false }
        return .init(
            worktree: worktree,
            ahead: ahead,
            hasPR: !boundPrs.isEmpty,
            depth: id.map { library.depth(of: $0) } ?? 0,
            hasChildren: id.map { library.hasChildren($0) } ?? false,
            readOnly: conversation.status?.readOnly ?? false,
            optedOut: OpenPR.optedOut(in: row?.firstInput)
        )
    }

    static func mode(_ m: Mode) -> ComposerModel.Mode {
        switch m {
        case .default: .default
        case .acceptEdits: .accept_edits
        case .auto: .auto
        case .yolo: .yolo
        }
    }

    static func mode(_ m: ComposerModel.Mode) -> Mode {
        switch m {
        case .default: .default
        case .accept_edits: .acceptEdits
        case .auto: .auto
        case .yolo: .yolo
        }
    }

    // MARK: View

    var narrow: Bool { width < ComposerMetrics.narrow }

    var body: some View {
        let s = tray
        let d = ComposerModel.derive(s)
        return draftHooks(
            VStack(alignment: .leading, spacing: 8) {
                if conversation.cloudSession == nil, conversation.start == nil {
                    NodeOffer()
                    SwitchNotice(conversation: conversation).font(.frog(size: 12))
                }
                ComposerNotices(workspace: workspace, conversation: conversation, downloads: downloads)
                ComposerCard(
                    showStatus: d.status != .none,
                    showAbove: !s.queued.isEmpty || !attachments.isEmpty,
                    focused: focused
                ) {
                    ComposerStatusLine(state: s, send: dispatch, dismissNotice: { local.notice = nil }, openDiff: openDiff)
                } above: {
                    pending(s)
                } field: {
                    field
                } controls: {
                    controls(s)
                }
                .contentShape(.rect)
                .onTapGesture { controller.focus() }
                // After the card's content shape, so a menu above the card still takes clicks.
                .composerMenuHost()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .metricsEdge("box", claims: ["box", "right"], kind: "composer", global: true)
            }
            .padding(.horizontal, TurnSpace.gutter)
            .padding(.top, TurnSpace.top)
            .padding(.bottom, TurnSpace.Inset.snug)
            .turnColumn()
        )
        .contentMargins(0, for: .scrollContent)
        .background {
            LinearGradient(
                stops: [.init(color: FrogCanvas.color.opacity(0), location: 0), .init(color: FrogCanvas.color, location: 0.25)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .task(id: workspace.folder) { await readRepo() }
        .onChange(of: workspace.git) { Task { await readRepo() } }
        .task(id: conversation.prs) {
            await gitIndex.watchPrs(conversation.prs, in: workspace.folder.path, writeBack: gitIndexWriteBack)
        }
        .task { await loadCloudRepos() }
        .onChange(of: dictation.problem) { _, p in
            guard p != nil else { return }
            dictation.problem = nil
            dispatch(.micDenied)
        }
    }

    /// Queued follow-ups, then the images to send, above the field.
    func pending(_ s: ComposerModel.State) -> some View {
        let images = attachments.map { img in
            ComposerModel.Attachment(name: img.mime.hasSuffix("png") ? "Image.png" : "Image", size: img.data.utf8.count * 3 / 4, type: img.mime)
        }
        return ComposerPending(queued: s.queued, attachments: images) { intent in
            if case .removeAttachment(let i) = intent {
                if attachments.indices.contains(i) { attachments.remove(at: i) }
            } else {
                dispatch(intent)
            }
        }
        .help(conversation.status?.vision == false ? "\(conversation.status?.model ?? "This model") can't see images; pick a vision model to include them." : "")
    }

    /// Attach and where (before a session) at the left; mode, model and the action at the right.
    func controls(_ s: ComposerModel.State) -> some View {
        HStack(spacing: 2) {
            ComposerChip(open: menu == .attach, help: "Attach a file, mention a file or run a command", action: { toggle(.attach) }) {
                ComposerIcon("plus")
            }
            .accessibilityLabel("Attach")
            .composerMenu(menu == .attach, close: closeMenu) { attachMenu }
            .popover(isPresented: $racing, arrowEdge: .top) {
                RaceSetup(workspace: workspace, prompt: text) { models, check in
                    racing = false
                    dictation.cancel()
                    workspace.startRace(prompt: text, models: models, check: check)
                    text = ""
                }
            }
            if isNew {
                ComposerChip(open: menu == .place, marked: ["where", "worktree"].contains(s.error?.control ?? ""),
                             help: "Where this session works", action: { toggle(.place) }) {
                    WhereChipLabel(place: s.where, narrow: narrow)
                }
                .layoutPriority(-1)
                .accessibilityIdentifier("composer.where")
                .composerMenu(menu == .place, close: closeMenu) {
                    WhereMenu(
                        state: s, lists: whereLists, send: dispatch,
                        chooseFolder: { switchFolder?(nil) },
                        signIn: { run(.init("open_login"), s) },
                        close: closeMenu
                    )
                }
            }
            Spacer(minLength: 4)
            if let status = conversation.status, !narrow {
                ContextButton(conversation: conversation, status: status)
            }
            ComposerChip(open: menu == .mode, help: "When Frog asks (⌘.)", action: { toggle(.mode) }) {
                ModeChipLabel(mode: s.mode)
            }
            .fixedSize()
            .accessibilityIdentifier("composer.mode")
            .composerMenu(menu == .mode, trailing: true, close: closeMenu) {
                ModeMenu(mode: s.mode, send: dispatch, close: closeMenu)
            }
            ModelPicker(workspace: workspace, conversation: conversation, open: menu == .model, narrow: narrow,
                        loading: s.busy == .loading_model, toggle: { toggle(.model) }, close: closeMenu)
            ComposerAction(state: s, send: dispatch).padding(.leading, 4)
                .accessibilityIdentifier("composer.action")
        }
    }

    var whereLists: WhereLists {
        WhereLists(
            recents: Recents.all.map(\.path),
            cloudRepos: cloudRepos,
            signedIn: CloudSessions.shared.available,
            branches: branches
        )
    }

    var attachMenu: some View {
        AttachMenu(
            chat: workspace.isChat,
            attachFile: { attachFromPanel(images: false) },
            pasteScreenshot: {
                controller.focus()
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            },
            mention: {
                controller.focus()
                controller.insert("@")
            },
            command: {
                controller.focus()
                if text.isEmpty { controller.replaceAll("!") } else { controller.insert("!") }
            },
            skill: workspace.skills.isEmpty || !text.isEmpty ? nil : {
                controller.focus()
                controller.replaceAll("/")
            },
            race: workspace.isChat || !Self.hasWords(text) || conversation.busy ? nil : { racing = true },
            close: closeMenu
        )
    }

    /// Open a menu, or close it if it's the open one. A click outside that just closed this
    /// one doesn't reopen it.
    func toggle(_ m: ComposerMenuID) {
        if menu == m { return closeMenu() }
        guard !ComposerMenus.justClosed else { return }
        menu = m
        if m == .place { Task { await loadBranches() } }
    }

    /// Close the open menu; the field takes the keyboard back.
    func closeMenu() {
        guard menu != nil else { return }
        menu = nil
        controller.focus()
    }

    var field: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Group {
                    if let ghost { Text(ghost) + Text("  ⇥").foregroundStyle(.quaternary) } else { Text(placeholder) }
                }
                .font(.system(size: 13))
                .foregroundStyle(ghost == nil ? Tokens.textTertiary : Tokens.textSecondary)
                .lineLimit(1)
                .allowsHitTesting(false)
            }
            ComposerTextView(
                text: $text, height: $height, controller: controller,
                onPush: noteDraft, onSubmit: { dispatch(.send) },
                onEscape: {
                    if menu != nil { closeMenu(); return true }
                    if dictation.isActive { dictation.stop(); return true }
                    let s = tray
                    if s.busy == .idle, s.error == nil, s.confirm == nil, !s.stackOpen, local.notice != nil {
                        local.notice = nil
                        return true
                    }
                    guard s.busy != .idle || s.error != nil || s.stackOpen || s.confirm != nil else { return false }
                    dispatch(.esc)
                    return true
                },
                onMention: { query in
                    if query != nil { workspace.loadFiles() }
                    if query != mention { picked = 0 }
                    mention = query
                    suggestions = query.map { FileIndex.search(workspace.files, $0) } ?? []
                },
                onMentionKey: handleMentionKey,
                onTab: {
                    guard text.isEmpty, let ghost else { return false }
                    text = ghost
                    return true
                },
                onPasteImages: { attachments += $0 },
                minHeight: 16,
                maxHeight: 160,
                onFocus: { focused = $0 }
            )
            .frame(height: height)
        }
        .onChange(of: window?.focusComposerRequest) { controller.focus() }
        .onChange(of: window?.dictationRequest) { toggleDictation() }
        .onChange(of: window?.gitRequest) { _, r in if let r { run(.init(r.effect), tray) } }
        .onDisappear {
            dictation.cancel()
            saveDraftNow()
        }
        .onAppear { window?.composer = controller }
        .onDisappear { if window?.composer === controller { window?.composer = nil } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            dictation.stop()
            saveDraftNow()
        }
        .onChange(of: skillSuggestions.map(\.name)) { picked = 0 }
        .onChange(of: window?.raceRequest) {
            controller.flush()
            controller.focus()
            racing = true
        }
        .overlay(alignment: .topLeading) {
            Group {
                if !suggestions.isEmpty {
                    MentionList(files: suggestions, picked: picked) { controller.insertMention($0) }
                } else if !skillSuggestions.isEmpty {
                    SkillList(skills: skillSuggestions, picked: picked) { controller.replaceAll("/\($0.name) ") }
                }
            }
            .fixedSize()
            .alignmentGuide(.top) { $0[.bottom] + 22 }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        .onChange(of: conversation.dropped) { _, urls in
            guard !urls.isEmpty else { return }
            conversation.dropped = []
            accept(urls)
        }
        .onChange(of: conversation.restored) { _, back in
            guard !back.isEmpty else { return }
            (text, attachments) = conversation.takeRestored(into: text, attachments: attachments)
            controller.focus()
        }
        .onChange(of: conversation.panes.insert) { _, mention in
            guard let mention else { return }
            conversation.panes.insert = nil
            controller.insert(mention)
        }
        .onChange(of: text, initial: true) { conversation.panes.noteDraft(text) }
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            warm()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in warm(again: true) }
    }

    func warm(again: Bool = false) {
        guard !conversation.busy else { return }
        let first = text.first { !$0.isWhitespace }
        let usable = first != nil && first != "/" && first != "!"
        let draft = usable ? String(text.prefix(Self.warmLimit)) : nil
        guard again || warmed != .some(draft) else { return }
        warmed = .some(draft)
        conversation.send(.warm(draft: draft))
    }

    static let warmLimit = 32_768

    var ghost: String? {
        guard let next = conversation.next, !next.act, !conversation.busy else { return nil }
        return next.text
    }

    /// The three placeholders: a new session, a reply, a follow-up while Frog works.
    var placeholder: String { TrayWords.placeholder(tray) }

    /// Images attach; other files become `@` mentions, relative to the project when inside it.
    func accept(_ urls: [URL]) {
        attachments += urls.filter(Attachments.isImage).compactMap(Attachments.image(at:))
        let files = urls.filter { !Attachments.isImage($0) }
        guard !files.isEmpty else { return }
        let root = conversation.folder.standardizedFileURL.path + "/"
        let mentions = files.map { url in
            let p = url.standardizedFileURL.path
            return "@" + (p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p)
        }
        controller.insert(mentions.joined(separator: " ") + " ")
    }

    /// What's in the field goes: a new conversation set to run in Frog Cloud starts its sandbox.
    func sendDraft() {
        controller.flush()
        guard Self.hasWords(text) || !attachments.isEmpty, !waitingForModel else { return }
        local.lastSent = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = conversation.start, start.failed || start.stuck(at: .now) {
            // A start that failed: what's typed starts it again, in place (the web's retry).
            let message = text
            text = ""
            attachments = []
            let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
            workspace.retryStart(conversation, text: words.isEmpty ? nil : words)
            return
        }
        if !conversation.started, conversation.cloudSession == nil, let target = workspace.cloudTarget {
            let message = text
            text = ""
            attachments = []
            Task { await workspace.runInCloud(message, repo: .some(target)) }
            return
        }
        dictation.cancel()
        conversation.submit(text, images: attachments)
        FrogSounds.shared.play(.plip)
        text = ""
        attachments = []
        mention = nil
        suggestions = []
        draftSave?.cancel()
        draftSave = nil
        drafts.clear(id: conversation.sessionID, folder: workspace.folder)
    }
}

extension Conversation {
    /// The PRs bound to this session, from the listing the sidebar's rows read too: the engine
    /// keeps them in the log, so both surfaces derive from one list (an open conversation's copy
    /// is fresher by one event, so it wins when it has one). The tray and the inspector read it.
    var boundPrs: [PrBinding] {
        if !prs.isEmpty { return prs }
        return Library.shared.sessions.first { $0.id == sessionID }?.prs ?? []
    }
}
