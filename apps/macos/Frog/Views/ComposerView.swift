import AppKit
import SwiftUI

/// The composer: one tray (docs/plans/2026-11-12-composer-tray.md). A top line (the git line in
/// a session, the "where" line before the first message), the field, and a rail of ＋, mode,
/// model and one action button. What it does is `ComposerModel` (shared with the web through
/// docs/design/composer/cases.json); this view feeds it the live state and runs its effects.
struct ComposerView: View {
    @Environment(\.paneWidth) var paneWidth
    let workspace: Workspace
    let conversation: Conversation
    var window: WindowState?
    /// Opens the changes card (the git line's +a −d).
    var openDiff: () -> Void = {}
    @State var text = ""
    @State var height: CGFloat = 22
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
    @State var gitIndex = GitIndex.shared
    @Environment(\.switchFolder) var switchFolder

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
            repo: slug, branch: git.branch, worktree: inTree, worktreePath: inTree ? path : nil,
            diff: .init(add: git.added, del: git.removed, files: git.changed), dirty: git.changed > 0,
            ahead: ahead, prs: gitIndex.prs(conversation.prs)
        ))
    }

    var trayModel: ComposerModel.Model {
        let spec = conversation.status?.model ?? UserDefaults.standard.string(forKey: "lastModel") ?? ""
        let cloud = conversation.cloudSession != nil || spec.hasPrefix("cloud/") || workspace.cloudTarget != nil
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
        s.queued = conversation.queue.count
        s.error = local.error
        s.notice = local.notice
        s.confirm = local.confirm
        s.stackOpen = local.stackOpen
        s.memory = local.memory
        return s
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

    var body: some View {
        let s = tray
        return draftHooks(
            VStack(alignment: .leading, spacing: 8) {
                if conversation.cloudSession == nil { NodeOffer() }
                ComposerNotices(workspace: workspace, conversation: conversation, downloads: downloads)
                TraySurface(showTop: !workspace.isChat || isNew && workspace.cloudTarget != nil, error: s.error, notice: s.notice,
                            localModel: nil, send: dispatch) {
                    topLine(s)
                } field: {
                    field
                } rail: {
                    rail(s)
                }
                .contentShape(.rect)
                .onTapGesture { controller.focus() }
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
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { local.confirm != nil }, set: { if !$0 { dispatch(.cancelConfirm) } })) {
            Button(confirmButton, role: local.confirm == .archive ? .destructive : nil) { dispatch(.confirm) }
            Button("Cancel", role: .cancel) { dispatch(.cancelConfirm) }
        } message: {
            Text(confirmMessage)
        }
        .task(id: workspace.folder) { await readRepo() }
        .onChange(of: workspace.git) { Task { await readRepo() } }
        .task(id: conversation.prs) { await gitIndex.watchPrs(conversation.prs, in: workspace.folder.path) }
        .task { await loadCloudRepos() }
        .onChange(of: dictation.problem) { _, p in
            guard p != nil else { return }
            dictation.problem = nil
            dispatch(.micDenied)
        }
    }

    @ViewBuilder
    func topLine(_ s: ComposerModel.State) -> some View {
        switch s.where {
        case .session(let session):
            TrayGitLine(
                state: s, session: session, send: dispatch,
                openDiff: openDiff,
                reveal: reveal,
                copy: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }
            )
        case .folder, .cloud:
            TrayWhereLine(
                state: s, send: dispatch,
                recent: Recents.all.map(\.path).filter { $0 != workspace.folder.path },
                cloudRepos: cloudRepos,
                choose: { switchFolder?(nil) }
            )
        case .chat:
            EmptyView()
        }
    }

    var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                AttachmentStrip(images: $attachments, blind: conversation.status?.vision == false ? conversation.status?.model : nil)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Group {
                        if let ghost { Text(ghost) + Text("  ⇥").foregroundStyle(.quaternary) } else { Text(placeholder) }
                    }
                    .foregroundStyle(ghost == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                    .padding(.leading, 5)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
                }
                ComposerTextView(
                    text: $text, height: $height, controller: controller,
                    onPush: noteDraft, onSubmit: { dispatch(.send) },
                    onEscape: {
                        if dictation.isActive { dictation.stop(); return true }
                        let s = tray
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
                    onPasteImages: { attachments += $0 }
                )
                .frame(height: height)
            }
        }
        .onChange(of: window?.focusComposerRequest) { controller.focus() }
        .onChange(of: window?.dictationRequest) { toggleDictation() }
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
            .alignmentGuide(.top) { $0[.bottom] + 52 }
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

    func rail(_ s: ComposerModel.State) -> some View {
        HStack(spacing: 8) {
            plusMenu
            TrayModeMenu(mode: s.mode, send: dispatch)
            ModelPicker(workspace: workspace, conversation: conversation)
            if let status = conversation.status, paneWidth > .narrow {
                ContextButton(conversation: conversation, status: status)
            }
            if conversation.cloudSession == nil { SwitchNotice(conversation: conversation) }
            Spacer(minLength: 0)
            TrayActionButton(state: s, send: dispatch, listening: dictation.isActive)
        }
        .font(.frog(size: 12))
        .foregroundStyle(.secondary)
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

    var placeholder: String {
        if let model = workspace.pendingDownloadModel {
            return "Downloading \(model.name)… messages send when it’s ready"
        }
        if conversation.busy { return "Working… Esc interrupts · Return queues a follow-up" }
        if workspace.isChat { return "Reply to Frog" }
        return "Reply to Frog, @ a file, ! a command"
    }

    var plusMenu: some View {
        Menu {
            Button("Add Files…", systemImage: "doc") { attachFromPanel(images: false) }
            Button("Add Image…", systemImage: "photo") { attachFromPanel(images: true) }
            Button("Paste Screenshot", systemImage: "camera.viewfinder") { controller.focus(); NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
            if !workspace.isChat {
                Button("Mention a File", systemImage: "at") {
                    controller.focus()
                    controller.insert("@")
                }
            }
            if !workspace.skills.isEmpty {
                Button("Use a Skill", systemImage: "wand.and.stars") {
                    controller.focus()
                    controller.replaceAll("/")
                }
                .disabled(!text.isEmpty)
            }
            if !workspace.isChat {
                Divider()
                Button("Race Attempts…", systemImage: "square.stack.3d.up") { racing = true }
                    .disabled(!Self.hasWords(text) || conversation.busy)
            }
        } label: {
            Image(systemName: "plus")
                .font(.frog(size: 15, weight: .medium))
                .frame(width: 22, height: 22)
                .hoverPlate(h: 3, v: 3)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add files or images, mention a file, use a skill, or race attempts")
        .popover(isPresented: $racing, arrowEdge: .top) {
            RaceSetup(workspace: workspace, prompt: text) { models, check in
                racing = false
                dictation.cancel()
                workspace.startRace(prompt: text, models: models, check: check)
                text = ""
            }
        }
    }

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
