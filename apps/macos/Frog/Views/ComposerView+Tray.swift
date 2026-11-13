import AppKit
import SwiftUI

/// The tray's runner: intents through `ComposerModel`, and its effects on the live objects.
extension ComposerView {
    // MARK: Intents and effects

    /// Run an intent through the reducer, keep what it decided, and perform its effects.
    func dispatch(_ intent: ComposerModel.Intent) {
        let before = tray
        let (next, effects) = ComposerModel.reduce(before, intent)
        local.error = next.error
        local.notice = next.notice
        local.confirm = next.confirm
        local.stackOpen = next.stackOpen
        local.memory = next.memory
        if next.yoloConfirmed != local.yoloConfirmed {
            local.yoloConfirmed = next.yoloConfirmed
            UserDefaults.standard.set(next.yoloConfirmed, forKey: "yoloConfirmed")
        }
        // Suggestions and ↑ fill the field; nothing else here writes the draft.
        if next.draft.text != before.draft.text, case .recall = intent { text = next.draft.text }
        if next.draft.text != before.draft.text, case .suggestion = intent { text = next.draft.text }
        if next.where != before.where { moved(from: before.where, to: next.where) }
        for e in effects { run(e, next) }
    }

    /// The "where" line changed: a folder, a cloud repo, or chat. The draft goes along (saved
    /// under the new folder, restored by the composer that opens there).
    func moved(from old: ComposerModel.Where, to new: ComposerModel.Where) {
        switch new {
        case .folder(let folder, _, _, _, _) where folder != workspace.folder.path:
            workspace.cloudTarget = nil
            carryDraft(to: URL(fileURLWithPath: folder))
        case .folder:
            workspace.cloudTarget = nil
        case .cloud(let repo, _):
            workspace.cloudTarget = .some(repo == "No repo" ? nil : repo)
        case .chat:
            if case .chat = old { return }
            carryDraft(to: Frog.chatFolder)
        case .session:
            break
        }
    }

    func carryDraft(to folder: URL, send: Bool = false) {
        saveDraftNow()
        if !text.isEmpty || !attachments.isEmpty {
            drafts.save(ComposerDraft(text: text, images: attachments, cursor: text.utf16.count, saved: .now), id: nil, folder: folder)
        }
        if send { Self.sendOnAppear.insert(folder.path) }
        switchFolder?(folder)
    }

    /// The queued images: the effect names them (`Attachment`s), and the count matches the
    /// draft's own ones — the view passes those along (it holds the bytes; the reducer
    /// carries metadata only, like the web).
    static func images(_ json: JSON?, from attachments: [ToolImage]) -> [ToolImage] {
        guard case .array(let files) = json, files.count == attachments.count else { return [] }
        return attachments
    }

    func run(_ e: ComposerModel.Effect, _ s: ComposerModel.State) {
        let dir = workspace.folder
        switch e.type {
        case "submit", "queue":
            // A git action's own turn carries text the field doesn't hold: the draft stays.
            // The draft itself goes through sendDraft, which clears it (on ack for a submit).
            if case .string(let t) = e.fields["text"], t != s.draft.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                conversation.submit(t)  // a git action's own turn: the draft stays
            } else {
                sendDraft()
            }
            if e.type == "submit" { dispatch(.ack) }
        case "queued":
            // The reducer cleared the draft state already; the view's own field follows it.
            // The images go with the text: Conversation.submit queues them behind the turn.
            if case .string(let t) = e.fields["text"] {
                conversation.submit(t, images: Self.images(e.fields["attachments"], from: attachments))
                FrogSounds.shared.play(.plip)
                text = ""
                attachments = []
                mention = nil
                suggestions = []
                draftSave?.cancel()
                draftSave = nil
                drafts.clear(id: conversation.sessionID, folder: workspace.folder)
            }
        case "start_session":
            if case .folder(_, _, true, true, _) = s.where {
                makeWorktreeAndSend()
            } else {
                sendDraft()
                dispatch(.ack)
            }
        case "interrupt": conversation.interrupt()
        case "cancel_load": if let repo = workspace.pendingDownloadModel?.repo { downloads.cancel(repo) }
        case "start_dictation": toggleDictation()
        case "set_mode": if case .string(let m) = e.fields["mode"], let mode = ComposerModel.Mode(rawValue: m) { conversation.setMode(Self.mode(mode)) }
        case "open_mic_settings":
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case "draft_commit":
            conversation.submit("Commit the current changes: review the diff, stage only files related to our work, and write a clear, concise commit message.")
        case "open_pr":
            conversation.submit("Push this branch and open a pull request with `gh pr create`: draft a clear title and body from our changes.")
        case "push": gitTask { await GitActions.push(in: dir) }
        case "pull_push": gitTask { await GitActions.pullAndPush(in: dir) }
        case "merge":
            if case .string(let repo) = e.fields["repo"], case .number(let n) = e.fields["number"] {
                gitTask { await GitActions.merge(repo, Int(n), in: dir) }
            }
        case "reopen":
            if case .string(let repo) = e.fields["repo"], case .number(let n) = e.fields["number"] {
                gitTask { await GitActions.reopen(repo, Int(n), in: dir) }
            }
        case "archive":
            if let id = conversation.sessionID { SessionBroker.shared.archive(id, true) }
        case "gh_auth_login": GitActions.ghAuthLogin()
        case "open_url": if case .string(let u) = e.fields["url"], let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case "copy":
            if case .string(let t) = e.fields["text"] {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
        case "bind_pr":
            guard case .string(let ref) = e.fields["ref"], let pr = Self.prRef(ref, repo: slug) else { return dispatch(.failed(code: "pr_not_found", detail: nil)) }
            conversation.send(.bindPr(pr))
        case "show_output":
            if case .string(let d) = e.fields["detail"] {
                let alert = NSAlert()
                alert.messageText = "Hook output"
                alert.informativeText = d
                alert.runModal()
            }
        default: break  // open_login, open_billing, set_model: the model picker and Settings own these
        }
    }

    /// A git action off the main thread; its failure lands in the error slot, success re-reads PRs.
    func gitTask(_ work: @escaping () async -> GitActions.Failure?) {
        Task {
            if let f = await work() { dispatch(.failed(code: f.code, detail: f.detail)) }
            gitIndex.refreshPrs(conversation.prs, in: workspace.folder.path, writeBack: gitIndexWriteBack)
        }
    }

    /// What gh saw, back to the engine. The sidebar reads the session listing, so unless the log
    /// holds the latest state the two disagree the moment this conversation closes.
    var gitIndexWriteBack: (PrBinding) -> Void {
        { pr in conversation.send(.bindPr(pr)) }
    }

    /// `#12`, `owner/name#12` or a PR URL.
    static func prRef(_ s: String, repo: String?) -> PrBinding? {
        let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)"#, options: .regularExpression) {
            let parts = s[r].split(separator: "/")
            if parts.count >= 5, let n = Int(parts[4]) { return PrBinding(repo: "\(parts[1])/\(parts[2])", number: n) }
        }
        if let hash = s.firstIndex(of: "#"), hash != s.startIndex, let n = Int(s[s.index(after: hash)...]) {
            return PrBinding(repo: String(s[..<hash]), number: n)
        }
        guard let repo, let n = Int(s.hasPrefix("#") ? String(s.dropFirst()) : s) else { return nil }
        return PrBinding(repo: repo, number: n)
    }

    /// New worktree on: make it off the main thread, then send from there with the draft.
    func makeWorktreeAndSend() {
        let folder = workspace.folder
        let name = String(text.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").prefix(3).joined(separator: "-")).nonEmpty ?? "session"
        Task {
            let made = await Task.detached { Result { try SessionBroker.makeWorktree(from: folder, name: name) } }.value
            switch made {
            case .success(let (url, _, _)):
                dispatch(.ack)
                carryDraft(to: url, send: true)
            case .failure(let error):
                dispatch(.failed(code: "worktree_failed", detail: error.localizedDescription))
            }
        }
    }

    func readRepo() async {
        guard !workspace.isChat, workspace.git != nil else { return }
        (slug, ahead) = await GitActions.slugAndAhead(workspace.folder)
    }

    func loadCloudRepos() async {
        guard CloudSessions.shared.available else { return }
        let r = try? await CloudSessions.shared.gateway?.repos()
        cloudRepos = r?.repos.map(\.name) ?? []
    }

    func reveal(_ s: String) {
        if s.hasPrefix("https://"), let url = URL(string: s) {
            NSWorkspace.shared.open(url)
            return
        }
        if s.contains("/"), !s.hasPrefix("/"), let url = URL(string: "https://github.com/\(s)") {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.hasPrefix("/") ? s : workspace.folder.path)])
    }

    var confirmTitle: String {
        switch local.confirm {
        case .yolo: "Turn on Yolo?"
        case .merge: "Merge this pull request?"
        case .archive: "Archive and delete the worktree?"
        case nil: ""
        }
    }

    var confirmButton: String {
        switch local.confirm {
        case .yolo: "Turn On Yolo"
        case .merge: "Merge"
        case .archive: "Archive Anyway"
        case nil: "OK"
        }
    }

    var confirmMessage: String {
        switch local.confirm {
        case .yolo: "Frog will never ask before acting. The sandbox still applies."
        case .merge: "Merges with the repository's default method."
        case .archive: "The worktree has uncommitted changes. They'll be deleted."
        case nil: ""
        }
    }

    // MARK: Drafts

    func draftHooks(_ view: some View) -> some View {
        view
            .onAppear { restoreDraft() }
            .onChange(of: text) { saveDraftSoon() }
            .onChange(of: attachments) { saveDraftSoon() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                saveDraftNow()
            }
            .onChange(of: conversation.sessionID) { _, id in
                if let id { drafts.adopt(id, folder: workspace.folder) }
            }
    }

    func restoreDraft() {
        guard let draft = drafts.draft(for: conversation.sessionID, folder: workspace.folder),
              text.isEmpty, !draft.text.isEmpty || !draft.images.isEmpty else { return }
        text = draft.text
        attachments = draft.images
        controller.focus()
        controller.select(NSRange(location: min(draft.cursor, draft.text.utf16.count), length: 0))
        // Moved here by a send from the "where" line (a new worktree): it goes now.
        if Self.sendOnAppear.remove(workspace.folder.path) != nil {
            Task { @MainActor in sendDraft() }
        }
    }

    static func draftCursor(_ tv: NSTextView?, text: String) -> Int {
        guard let tv, tv.selectedRange().location != NSNotFound else { return text.utf16.count }
        return min(tv.selectedRange().location, text.utf16.count)
    }

    func noteDraft(_ text: String) {
        guard !text.isEmpty || !attachments.isEmpty else { return }
        drafts.note(
            ComposerDraft(text: text, images: attachments, cursor: Self.draftCursor(controller.textView, text: text), saved: .now),
            id: conversation.sessionID,
            folder: workspace.folder
        )
    }

    func saveDraftSoon() {
        draftSave?.cancel()
        guard !text.isEmpty || !attachments.isEmpty else { return }
        draftSave = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            saveDraftNow()
        }
    }

    func saveDraftNow() {
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

    func toggleDictation() {
        if dictation.isActive {
            dictation.stop()
            return
        }
        controller.focus()
        controller.beginDictation()
        dictation.start(show: { controller.showDictation($0) }, done: { controller.endDictation() })
    }

    func attachFromPanel(images: Bool) {
        let panel = NSOpenPanel()
        if images { panel.allowedContentTypes = [.image] }
        panel.allowsMultipleSelection = true
        panel.message = images ? "Attach images to your message" : "Add files to your message"
        guard panel.runModal() == .OK else { return }
        accept(panel.urls)
    }

    func handleMentionKey(_ key: MentionKey) -> Bool {
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

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
