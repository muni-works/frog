import AppKit
import SwiftUI

struct ComposerView: View {
    @Environment(\.paneWidth) private var paneWidth
    let workspace: Workspace
    let conversation: Conversation
    var window: WindowState?
    @State private var text = ""
    @State private var height: CGFloat = 22
    @State private var controller = ComposerController()
    @State private var mention: String?
    @State private var picked = 0
    @State private var racing = false
    /// Images to send with the message.
    @State private var attachments: [ToolImage] = []
    @State private var dictation = Dictation()
    @State private var downloads = ModelDownloads.shared
    /// Restores the draft when this conversation appears; saves it as it's typed.
    @State private var drafts = DraftStore.shared
    /// The keystroke save, restarted on every change (about ⅓ s of quiet writes).
    @State private var draftSave: Task<Void, Never>?
    /// The draft the last warm-up carried (`.some(nil)`: the conversation alone; nil: none yet).
    @State private var warmed: String?? = nil
    @Environment(\.switchFolder) private var switchFolder

    private var canSend: Bool {
        !waitingForModel && (Self.hasWords(text) || !attachments.isEmpty)
    }

    /// Anything but whitespace, stopping at the first such character (trimming copies the draft,
    /// and this runs on every body pass).
    static func hasWords(_ s: String) -> Bool {
        s.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private var waitingForModel: Bool {
        guard let model = workspace.pendingDownloadModel else { return false }
        return switch model.state {
        case .notDownloaded, .downloading, .downloadFailed: true
        default: false
        }
    }

    /// The files matching the `@query` at the cursor, worked out when the query changes (see
    /// `onMention`) rather than read back from a body pass: fuzzy-matching every path in the
    /// project is the composer's most expensive step, and the body re-evaluates for a great many
    /// reasons that have nothing to do with what's typed.
    @State private var suggestions: [String] = []

    /// `/sk…` at the start of the message: matching skills.
    private var skillSuggestions: [SkillInfo] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let q = text.dropFirst().lowercased()
        let all = workspace.skills
        let prefix = all.filter { $0.name.hasPrefix(q) }
        let rest = q.isEmpty ? [] : all.filter { !$0.name.hasPrefix(q) && ($0.name.contains(q) || $0.description.lowercased().contains(q)) }
        return Array((prefix + rest).prefix(8))
    }

    var body: some View {
        draftHooks(
            VStack(alignment: .leading, spacing: 8) {
                if conversation.cloudSession == nil { NodeOffer() }
                topRow
                    .opacity(suggestions.isEmpty && skillSuggestions.isEmpty ? 1 : 0)
                field
                controls
            }
            .padding(.horizontal, TurnSpace.gutter)
            .padding(.top, TurnSpace.top)
            .padding(.bottom, TurnSpace.Inset.snug)
            .turnColumn()
        )
        // The canvas's margins keep the transcript clear of the cards; popovers opened from
        // here (the model picker, suggestions) mustn't inherit them.
        .contentMargins(0, for: .scrollContent)
        // The transcript scrolls under the composer; the canvas fades in behind it.
        .background {
            LinearGradient(
                stops: [.init(color: FrogCanvas.color.opacity(0), location: 0), .init(color: FrogCanvas.color, location: 0.25)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    /// What's typed stays with the conversation, applied to the body (not `field`, whose long
    /// modifier chain doesn't have room): restored when it appears — a switch back, a reopen, a
    /// relaunch (a session id persists; a fresh conversation's draft rides its folder) — saved
    /// as it's typed, and adopted by the session once the engine has named one.
    private func draftHooks(_ view: some View) -> some View {
        view
            .onAppear { restoreDraft() }
            // Noted from the text view as it hands the draft over (`onPush`), not here: a rebuild
            // right after a keystroke drops this view before its onChange would run.
            .onChange(of: text) { saveDraftSoon() }
            .onChange(of: attachments) { saveDraftSoon() }
            // Out for good: saved (the willTerminate read comes before the write below it).
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                saveDraftNow()
            }
            // The engine named the session (its first message logged): the draft typed before
            // it moves under the session key, so a later fresh conversation here starts clean.
            .onChange(of: conversation.sessionID) { _, id in
                if let id { drafts.adopt(id, folder: workspace.folder) }
            }
    }

    /// Before the first message: where the conversation works (a folder, or none for a plain
    /// chat). After it: the repository's branch and changes, for a folder in git.
    @ViewBuilder
    private var topRow: some View {
        if !conversation.started, !conversation.replaying {
            ContextBar {
                // Its hover plate's margin, so the text lines up with the git bar's.
                FolderChip(folder: workspace.folder, choose: switchFolder)
                    .padding(.leading, -7)
                // Work on a branch without disturbing the checkout the folder is in: pick an
                // existing worktree or make one; the conversation starts there.
                if let repo = workspace.repoRoot {
                    WorktreeChip(repo: repo) { url in switchFolder?(url) }
                        .padding(.leading, -6)
                }
                Spacer(minLength: 0)
            }
        } else if !workspace.isChat, let git = workspace.git {
            GitBar(folder: workspace.folder, git: git, busy: conversation.busy) {
                conversation.submit("Commit the current changes: review the diff, stage only files related to our work, and write a clear, concise commit message.")
            }
        }
    }

    private static let fieldShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let toast = conversation.toast {
                Label(toast, systemImage: "info.circle")
                    .font(.frog(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // One toast at a time: a new one replaces the last instead of crossfading
                    // its text over it.
                    .id(toast)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let fallback = conversation.fallbackNotice {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Frog cloud is unavailable")
                            .font(.callout.weight(.semibold))
                        Text(fallback)
                            .font(.frog(size: 10))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    Button { conversation.dismissFallbackNotice() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
                .padding(10)
                .background(.orange.opacity(0.09), in: .rect(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.orange.opacity(0.22), lineWidth: 1)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let model = workspace.pendingDownloadModel {
                ModelDownloadStatus(model: model, downloads: downloads) {
                    workspace.useWhenReady(model)
                }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let problem = dictation.problem {
                DictationProblemView(problem: problem) { dictation.problem = nil }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // What flushes at the next boundary (parked wakes, queued session messages).
            let pending = PendingEvents(queued: conversation.queuedEvents, messages: conversation.pendingMessages, jobs: conversation.jobs)
            if !pending.isEmpty {
                PendingEventsStrip(pending: pending, busy: conversation.busy) { conversation.dismissWakes() }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !conversation.queue.isEmpty {
                QueuedMessages(conversation: conversation)
            }
            if let next = conversation.next, next.act, !conversation.busy {
                // An outward step (push, send, deploy) takes a deliberate click, never a Tab.
                Button {
                    conversation.act(Present.Choice(label: next.text, send: nil))
                } label: {
                    Label(next.text, systemImage: "arrow.up.forward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
            if !attachments.isEmpty {
                AttachmentStrip(images: $attachments, blind: conversation.status?.vision == false ? conversation.status?.model : nil)
            }
            HStack(alignment: .bottom, spacing: 8) {
                plusMenu
                ZStack(alignment: .topLeading) {
                    if text.isEmpty, let ghost {
                        (Text(ghost) + Text("  ⇥").foregroundStyle(.quaternary))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 5)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    } else if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.leading, 5)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                    ComposerTextView(
                        text: $text,
                        height: $height,
                        controller: controller,
                        onPush: noteDraft,
                        onSubmit: send,
                        onEscape: {
                            if dictation.isActive {
                                dictation.stop()
                                return true
                            }
                            guard conversation.busy else { return false }
                            conversation.interrupt()
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
                .padding(.bottom, 2)
                // An open ask is its own card right above: the composer doesn't repeat it.
                if paneWidth > .narrow {
                    DictationButton(dictation: dictation, toggle: toggleDictation)
                }
                sendButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(FrogCanvas.color, in: Self.fieldShape)
        .overlay(Self.fieldShape.fill(Color.primary.opacity(0.045)).allowsHitTesting(false))
        .overlay(Self.fieldShape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .contentShape(Self.fieldShape)
        .onTapGesture { controller.focus() }
        .animation(.snappy, value: conversation.toast)
        .animation(.snappy, value: dictation.problem)
        .onChange(of: window?.focusComposerRequest) { controller.focus() }
        .onChange(of: window?.dictationRequest) { toggleDictation() }
        // Nothing listens once the conversation or window goes away, or Frog isn't in front.
        // Going away is also a save point: the draft is on disk before the next conversation
        // appears (its ⅓ s wait wouldn't survive the switch).
        .onDisappear {
            dictation.cancel()
            saveDraftNow()
        }
        // Type-to-focus targets the focused pane's composer while it exists.
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
        // Completions float above the composer, outside its glass (which would clip them).
        .overlay(alignment: .topLeading) {
            Group {
                if !suggestions.isEmpty {
                    MentionList(files: suggestions, picked: picked) { controller.insertMention($0) }
                } else if !skillSuggestions.isEmpty {
                    SkillList(skills: skillSuggestions, picked: picked) { controller.replaceAll("/\($0.name) ") }
                }
            }
            .fixedSize()
            .alignmentGuide(.top) { $0[.bottom] + 8 }
            .padding(.leading, 12)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        // Drops land on the whole conversation (see `ConversationDropZone`) and arrive here.
        .onChange(of: conversation.dropped) { _, urls in
            guard !urls.isEmpty else { return }
            conversation.dropped = []
            accept(urls)
        }
        // A queued message's "x" puts it back here to edit, ahead of what's typed.
        .onChange(of: conversation.restored) { _, back in
            guard !back.isEmpty else { return }
            (text, attachments) = conversation.takeRestored(into: text, attachments: attachments)
            controller.focus()
        }
        // An element picked in the preview's inspect mode lands here as an @mention.
        .onChange(of: conversation.panes.insert) { _, mention in
            guard let mention else { return }
            conversation.panes.insert = nil
            controller.insert(mention)
        }
        // The preview's chip asks whether its mention is still typed (only that answer is
        // observed; see `PaneHub.noteDraft`).
        .onChange(of: text, initial: true) { conversation.panes.noteDraft(text) }
        // Keep the model warm for what's about to be sent: when the conversation is shown, and
        // after each pause in typing (`.task(id:)` restarts on every keystroke).
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            warm()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in warm(again: true) }
    }

    /// Ask the engine to prefill the conversation and the draft. `/skill` and `!command` are
    /// rewritten before they're sent, so they warm the conversation alone.
    ///
    /// The engine prefills the draft as the start of the next message, so only a prefix of it can
    /// ever be reused: a long draft warms its first `warmLimit` characters, which typing at the
    /// end leaves unchanged, and an unchanged draft isn't sent again after a pause. Coming back to
    /// Frog (`again`) re-sends it, since the server's cache may have let it go.
    private func warm(again: Bool = false) {
        guard !conversation.busy else { return }
        let first = text.first { !$0.isWhitespace }
        let usable = first != nil && first != "/" && first != "!"
        let draft = usable ? String(text.prefix(Self.warmLimit)) : nil
        guard again || warmed != .some(draft) else { return }
        warmed = .some(draft)
        conversation.send(.warm(draft: draft))
    }

    /// The most of a draft a warm-up carries (about 8K tokens).
    static let warmLimit = 32_768

    /// The model's suggested next prompt, as ghost text Tab accepts; outward ones are a button.
    private var ghost: String? {
        guard let next = conversation.next, !next.act, !conversation.busy else { return nil }
        return next.text
    }

    private var placeholder: String {
        if let model = workspace.pendingDownloadModel {
            return "Downloading \(model.name)… messages send when it’s ready"
        }
        if conversation.busy { return "Working… Esc interrupts · Return queues a follow-up" }
        // One vocabulary everywhere (Settings › Shortcuts): @ mentions a file, ! runs a command.
        if workspace.isChat { return "Reply to Frog" }
        return "Reply to Frog, @ a file, ! a command"
    }

    private var sendButton: some View {
        SendButton(conversation: conversation, canSend: canSend, send: send)
    }

    /// Under the box, without chrome: mode and where it runs on the left, model and context
    /// ring on the right.
    private var controls: some View {
        HStack(spacing: 8) {
            ModePicker(conversation: conversation)
            if !conversation.started, conversation.cloudSession == nil, CloudSessions.shared.available {
                LocationPicker(workspace: workspace)
            } else if conversation.cloudSession != nil {
                Label("Frog Cloud", systemImage: "cloud").foregroundStyle(Tokens.accent)
            }
            if paneWidth > .narrow, conversation.cloudSession == nil {
                DeviceChip(conversation: conversation)
            }
            Spacer()
            if let e = workspace.raceError {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Tokens.signal).help(e)
            }
            ModelPicker(workspace: workspace, conversation: conversation)
            if let status = conversation.status, paneWidth > .narrow {
                ContextButton(conversation: conversation, status: status)
            }
        }
        .font(.frog(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
    }

    private var plusMenu: some View {
        Menu {
            Button("Attach Images…", systemImage: "photo") { attachFromPanel() }
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
                    .disabled(!canSend || conversation.busy)
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
        .help("Attach images, mention a file, use a skill, or race attempts")
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
    private func accept(_ urls: [URL]) {
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

    private func send() {
        controller.flush()
        guard canSend else { return }
        // A new conversation set to run in Frog Cloud starts its sandbox with this message.
        if !conversation.started, conversation.cloudSession == nil, let target = workspace.cloudTarget {
            let message = text
            text = ""
            attachments = []
            Task { await workspace.runInCloud(message, repo: .some(target)) }
            return
        }
        // What's in the field is what goes, words still settling included.
        dictation.cancel()
        conversation.submit(text, images: attachments)
        FrogSounds.shared.play(.plip)
        text = ""
        attachments = []
        mention = nil
        suggestions = []
        // It went: the draft is gone (a pending keystroke save must not bring it back).
        draftSave?.cancel()
        draftSave = nil
        drafts.clear(id: conversation.sessionID, folder: workspace.folder)
    }

    // MARK: Drafts

    /// What's typed stays with the conversation: restored on appear (a switch back, a reopen,
    /// a relaunch), saved under its session (or, before the first message, its folder), cleared
    /// when it's sent.
    private func restoreDraft() {
        guard let draft = drafts.draft(for: conversation.sessionID, folder: workspace.folder),
              text.isEmpty, !draft.text.isEmpty else { return }
        text = draft.text
        attachments = draft.images
        // The selection is best-effort: the text view clamps it to its length.
        controller.focus()
        controller.select(NSRange(location: min(draft.cursor, draft.text.utf16.count), length: 0))
    }

    /// Where the caret was, for the draft. With no text view (saved on the way out, after the
    /// field is gone) it's the end: 0 put the composer that took over mid-typing at the start,
    /// and what was typed next landed ahead of what was already there.
    static func draftCursor(_ tv: NSTextView?, text: String) -> Int {
        guard let tv, tv.selectedRange().location != NSNotFound else { return text.utf16.count }
        return min(tv.selectedRange().location, text.utf16.count)
    }

    /// Every hand-over from the text view, in memory: a composer that replaces this one before its
    /// save on the way out (SwiftUI can run the new one's onAppear first) still restores
    /// everything typed.
    private func noteDraft(_ text: String) {
        guard !text.isEmpty || !attachments.isEmpty else { return }
        drafts.note(
            ComposerDraft(text: text, images: attachments, cursor: Self.draftCursor(controller.textView, text: text), saved: .now),
            id: conversation.sessionID,
            folder: workspace.folder
        )
    }

    /// Typing settles for ⅓ s before the draft is written; every keystroke restarts the wait.
    private func saveDraftSoon() {
        draftSave?.cancel()
        guard !text.isEmpty || !attachments.isEmpty else { return }
        draftSave = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            saveDraftNow()
        }
    }

    private func saveDraftNow() {
        controller.flush()
        draftSave?.cancel()
        draftSave = nil
        guard !text.isEmpty || !attachments.isEmpty else {
            drafts.clear(id: conversation.sessionID, folder: workspace.folder)
            return
        }
        drafts.save(
            ComposerDraft(text: text, images: attachments, cursor: Self.draftCursor(controller.textView, text: text), saved: .now),
            id: conversation.sessionID,
            folder: workspace.folder
        )
    }

    private func toggleDictation() {
        if dictation.isActive {
            dictation.stop()
            return
        }
        controller.focus()
        controller.beginDictation()
        dictation.start(show: { controller.showDictation($0) }, done: { controller.endDictation() })
    }

    private func attachFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Attach images to your message"
        guard panel.runModal() == .OK else { return }
        attachments += panel.urls.compactMap(Attachments.image(at:))
    }

    private func handleMentionKey(_ key: MentionKey) -> Bool {
        let skills = skillSuggestions
        if suggestions.isEmpty, !skills.isEmpty {
            switch key {
            case .up: picked = (picked - 1 + skills.count) % skills.count
            case .down: picked = (picked + 1) % skills.count
            case .accept: controller.replaceAll("/\(skills[min(picked, skills.count - 1)].name) ")
            case .cancel: controller.replaceAll("")
            }
            return true
        }
        let list = suggestions
        guard !list.isEmpty else { return false }
        switch key {
        case .up: picked = (picked - 1 + list.count) % list.count
        case .down: picked = (picked + 1) % list.count
        case .accept: controller.insertMention(list[min(picked, list.count - 1)])
        case .cancel: mention = nil; suggestions = []
        }
        return true
    }
}

/// The mic beside +: starts dictation; while listening, a live level meter that stops it.
struct DictationButton: View {
    let dictation: Dictation
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Group {
                switch dictation.phase {
                case .idle:
                    Image(systemName: "mic")
                        .font(.frog(size: 14, weight: .medium))
                        .frame(width: 22, height: 22)
                case .starting:
                    ProgressView().controlSize(.small).frame(width: 22, height: 22)
                case .downloading(let p):
                    HStack(spacing: 5) {
                        ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
                        Text("Getting speech model… \(Int(p * 100))%").monospacedDigit()
                    }
                    .frame(height: 22)
                case .listening, .finishing:
                    HStack(spacing: 5) {
                        LevelMeter(level: dictation.phase == .listening ? dictation.level : 0)
                        Image(systemName: "stop.fill").font(.frog(size: 8))
                    }
                    .foregroundStyle(.red)
                    .frame(height: 22)
                    .padding(.horizontal, 4)
                    .background(Color.red.opacity(0.12), in: .capsule)
                }
            }
            .hoverPlate(h: 3, v: 3)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
        .accessibilityLabel(dictation.isActive ? "Stop dictation" : "Dictate")
    }

    private var help: String {
        switch dictation.phase {
        case .idle: "Dictate (⌥⌘V). Transcribed on this Mac."
        case .downloading: "Downloading the on-device speech model"
        case .finishing: "Finishing…"
        default: "Stop dictation (⌥⌘V or Esc)"
        }
    }
}

/// A few bars that rise and fall with the microphone's level.
private struct LevelMeter: View {
    let level: Float
    private let weights: [CGFloat] = [0.55, 1, 0.75, 0.4]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .frame(width: 2.5, height: 4 + 12 * weights[i] * CGFloat(level))
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

/// Why dictation couldn't run, with a way to fix it when System Settings can.
private struct DictationProblemView: View {
    let problem: DictationProblem
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(problem.message, systemImage: "mic.slash")
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let url = problem.settings {
                Button("Open System Settings") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
            }
            Button("Dismiss", systemImage: "xmark.circle.fill", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.frog(size: 12))
    }
}




/// The repository a conversation works in: folder, branch, and a shortcut to commit what's
/// changed.
struct GitBar: View {
    let folder: URL
    let git: GitInfo
    let busy: Bool
    let commit: () -> Void

    var body: some View {
        ContextBar {
            Text(folder.lastPathComponent)
            Text(git.branch).foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if git.changed > 0 {
                HStack(spacing: 6) {
                    if git.added + git.removed > 0 {
                        Text("+\(git.added)").foregroundStyle(.green)
                        Text("−\(git.removed)").foregroundStyle(.red)
                    } else {
                        Text("\(git.changed) new").foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 7))
                .help("\(git.changed) file\(git.changed == 1 ? "" : "s") with uncommitted changes")
                Button(action: commit) {
                    Text("Commit changes")
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 7))
                        .hoverPlate(h: 0, v: 0)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .help("Ask Frog to commit the current changes")
            }
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }
}

/// The flat bar above the composer: where the conversation works, and what's changed there.
struct ContextBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .font(.frog(size: 12))
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
            .padding(.trailing, 7)
            .frame(height: 38)
            .background(FrogCanvas.color, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)).allowsHitTesting(false))
    }
}

/// `/skill` completions: name and what it's for.
struct SkillList: View {
    let skills: [SkillInfo]
    let picked: Int
    let choose: (SkillInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(skills.enumerated()), id: \.element) { i, skill in
                Button {
                    choose(skill)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles.rectangle.stack").foregroundStyle(.secondary)
                            Text("/" + skill.name).fontWeight(.medium)
                            if skill.project {
                                Text("project").font(.frog(size: 10)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary, in: .capsule)
                            }
                        }
                        Text(skill.description)
                            .font(.frog(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 22)
                    }
                    .font(.frog(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(i == picked ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
                    .hoverPlate(h: 0, v: 0)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 480, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

struct MentionList: View {
    let files: [String]
    let picked: Int
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.element) { i, path in
                Button {
                    choose(path)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text((path as NSString).lastPathComponent).fontWeight(.medium)
                        let dir = (path as NSString).deletingLastPathComponent
                        Text(dir).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .font(.frog(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(i == picked ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
                    .hoverPlate(h: 0, v: 0)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 420, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

/// The composer owns the pause between selecting a local model and its snapshot becoming usable.
/// Keeping this here makes the reason Send is disabled visible where someone is trying to send.
private struct ModelDownloadStatus: View {
    let model: ModelIdentity
    let downloads: ModelDownloads
    let retry: () -> Void

    var body: some View {
        // Reads the observable state so progress redraws even though `model` is rebuilt by
        // Workspace on each update.
        let state = model.repo.flatMap { downloads.states[$0] }
        switch state {
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(maxWidth: 150)
                Text("Downloading \(model.name) · \(Self.size(fraction, of: model.downloadGB))")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { if let repo = model.repo { downloads.cancel(repo) } } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop downloading")
            }
            .foregroundStyle(.secondary)
        case .failed(let error):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't download \(model.name): \(error)").lineLimit(1)
                Spacer(minLength: 0)
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
            .font(.frog(size: 12))
        case nil:
            HStack(spacing: 8) {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text("Download paused for \(model.name). Messages send when it’s ready.")
                Spacer(minLength: 0)
                Button("Resume", action: retry).controlSize(.small)
            }
            .font(.frog(size: 12))
        default:
            EmptyView()
        }
    }

    private static func size(_ fraction: Double, of total: Double?) -> String {
        guard let total else { return "\(Int((fraction * 100).rounded()))%" }
        return String(format: "%.1f GB of %.1f GB", fraction * total, total)
    }
}

/// Where a new conversation runs, beside the mode, as the web's repo picker: this Mac, or a
/// Frog Cloud sandbox on a repo the GitHub App reaches (or none).
private struct LocationPicker: View {
    @Bindable var workspace: Workspace
    @State private var repos: CloudGateway.Repos?
    @State private var fetched = false
    /// This folder's GitHub repo, read off the main thread. Never in `body`: `githubRepo(of:)`
    /// runs git and waits, and `waitUntilExit` spins the run loop, so AppKit re-entered its
    /// layout pass from inside SwiftUI's update and raised (the Open Folder crash).
    @State private var here: String?

    private var label: String {
        switch workspace.cloudTarget {
        case .none: "This Mac"
        case .some(.none): "Frog Cloud"
        case .some(.some(let r)): r.split(separator: "/").last.map(String.init) ?? r
        }
    }

    var body: some View {
        Menu {
            Button("This Mac", systemImage: "laptopcomputer") { workspace.cloudTarget = nil }
            Section("Frog Cloud") {
                if let here {
                    Button(here, systemImage: "cloud") { workspace.cloudTarget = .some(here) }
                }
                ForEach((repos?.repos ?? []).filter { $0.name != here }, id: \.self) { r in
                    Button(r.name, systemImage: r.private ? "lock" : "book.closed") { workspace.cloudTarget = .some(r.name) }
                }
                Button("No Repo", systemImage: "cloud") { workspace.cloudTarget = .some(nil) }
                // Signed in with Google: no GitHub login, so no repos until it's connected.
                if fetched, repos?.login == nil {
                    Button("Connect GitHub to See Your Repos…", systemImage: "link") { connect() }
                }
                if let install = repos?.install.flatMap(URL.init(string:)) {
                    Link("Give Frog Access to More Repos…", destination: install)
                }
            }
        } label: {
            Label(label, systemImage: workspace.cloudTarget == nil ? "laptopcomputer" : "cloud")
                .foregroundStyle(workspace.cloudTarget == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green.opacity(0.85)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where this conversation runs")
        .task { await load() }
        .task(id: workspace.folder) {
            let folder = workspace.folder
            here = await Task.detached(priority: .utility) { CloudSessions.githubRepo(of: folder) }.value
        }
    }

    private func load() async {
        let r = try? await CloudSessions.shared.gateway?.repos()
        fetched = r != nil
        repos = r ?? CloudGateway.Repos(repos: [], install: nil)
    }

    private func connect() {
        Task {
            do {
                try await CloudAccount.connectGitHub()
                await load()
            } catch {
                if let failure = CloudAccount.signInFailure(error) { workspace.raceError = failure }
            }
        }
    }
}
