import PhotosUI
import SwiftUI

/// One conversation: the Mac's own transcript (`TranscriptView`, shared), with frog's questions
/// pinned above the keyboard instead of in the turn, and a composer for the thumb.
struct ChatView: View {
    let conversation: Conversation
    /// How it reaches the Mac; nil for a recording.
    let link: RemoteLink?
    let title: String
    var onClose: () -> Void = {}
    @Environment(\.models) private var models
    @Environment(\.startNewChat) private var startNewChat
    @State private var draft = ""
    @State private var opening = false
    @State private var openError: String?
    @State private var energyHistory = false
    @State private var showActivity = false
    @State private var jump: TurnState.ID?
    @State private var pickingModel = false
    /// Images going with the next message.
    @State private var attachments: [ToolImage] = []
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showChanges = false
    @State private var renaming = false
    @State private var newTitle = ""

    /// This conversation as the Mac's list has it (pinned or not).
    private var row: RemoteSession? { link.flatMap { l in Remote.shared.sessions.first { $0.id == l.session } } }

    private var identity: ModelIdentity? {
        conversation.status.map { ModelIdentity.of($0.model, in: models) }
    }
    private var canSend: Bool { link?.isOpenOnMac ?? true }

    /// Fork and rewind happen on the Mac, in the pane showing this conversation; the phone
    /// follows to the session it continues in. Only while it's open there.
    private var turnActions: TurnActions {
        guard let link, link.isOpenOnMac else { return TurnActions() }
        let session = link.session
        return TurnActions(
            fork: { n in Task { await Remote.shared.turn("fork", n, in: session) } },
            rewind: { n in Task { await Remote.shared.turn("rewind", n, in: session) } }
        )
    }

    var body: some View {
        TranscriptView(conversation: conversation, actions: turnActions, jump: $jump)
            .environment(\.pinsQuestions, true)
            .environment(\.showEnergyHistory) { energyHistory = true }
            .sheet(isPresented: $energyHistory) { EnergyHistorySheet() }
            .safeAreaInset(edge: .bottom) {
                ZStack {
                    if let p = conversation.permission {
                        PermissionCard(request: p, conversation: conversation)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        composer.transition(.opacity)
                    }
                }
                .animation(Motion.panel(reduced: false), value: conversation.permission?.id)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { header }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    let changes = conversation.sessionChanges
                    Menu {
                        if !changes.isEmpty {
                            Button { showChanges = true } label: {
                                Label("Changes", systemImage: "plusminus")
                                Text("\(changes.count) file\(changes.count == 1 ? "" : "s"), +\(changes.reduce(0) { $0 + $1.added }) −\(changes.reduce(0) { $0 + $1.removed })")
                            }
                            Divider()
                        }
                        if let link {
                            Button("Rename…", systemImage: "pencil") {
                                newTitle = conversation.title ?? title
                                renaming = true
                            }
                            if let row {
                                Button(row.pinned ? "Unpin" : "Pin", systemImage: row.pinned ? "pin.slash" : "pin") {
                                    Remote.shared.manage(link.session, row.pinned ? "unpin" : "pin")
                                }
                            }
                            Divider()
                            Button("Archive", systemImage: "archivebox") {
                                Remote.shared.manage(link.session, "archive")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    if link != nil {
                        Button("New Chat", systemImage: "square.and.pencil") { startNewChat() }
                    }
                }
            }
            .sheet(isPresented: $showChanges) {
                NavigationStack {
                    GeometryReader { g in
                        ChangesInspector(conversation: conversation, maxHeight: g.size.height)
                    }
                        .navigationTitle("Changes")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", systemImage: "checkmark") { showChanges = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .alert("Rename", isPresented: $renaming) {
                TextField("Title", text: $newTitle)
                Button("Rename") { if let link { Remote.shared.manage(link.session, "rename", title: newTitle) } }
                Button("Cancel", role: .cancel) {}
            }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: conversation.stepsDone)
            .sensoryFeedback(.success, trigger: conversation.turnsDone)
            .sensoryFeedback(.warning, trigger: conversation.permission?.id)
            .userActivity(Handoff.conversation, isActive: conversation.sessionID != nil) { a in
                a.title = conversation.title ?? title
                a.userInfo = ["session": conversation.sessionID ?? ""]
                a.isEligibleForHandoff = true
            }
            .onDisappear(perform: onClose)
            // Images anywhere in the conversation open large, as on the Mac.
            .modifier(LightboxHost())
            .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: 6, matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let img = Attachments.image(from: data) {
                            attachments.append(img)
                        }
                    }
                }
            }
    }

    /// The title, and what frog is doing under it (the Mac's activity viewer); tap for the
    /// turn's steps.
    private var header: some View {
        Button { showActivity = true } label: {
            HStack(spacing: 8) {
                FrogFace(mood: conversation.mood, size: 24).tint(Color.frog)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title ?? title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Group {
                        if let waiting = ActivityLabel.waiting(conversation) {
                            Label(waiting, systemImage: "hand.raised.fill").foregroundStyle(.orange).lineLimit(1)
                        } else if conversation.busy || identity == nil {
                            ActivityLabel(conversation: conversation, playful: false, maxWidth: 180)
                        } else if let identity {
                            HStack(spacing: 6) {
                                ActivityLabel(conversation: conversation, playful: false, maxWidth: 110)
                                ModelLabel(model: identity, size: .pill).layoutPriority(-1)
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            // UIKit drops a title that doesn't fit, rather than squeezing it.
            .frame(maxWidth: 250)
            .overlay(alignment: .bottom) {
                if conversation.busy { WorkingLine().offset(y: 5) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows this turn's steps")
        .popover(isPresented: $showActivity) {
            ActivityPanel(conversation: conversation) { id in
                showActivity = false
                jump = id
            }
            .presentationCompactAdaptation(.popover)
            .presentationBackground(Color.windowBackground)
        }
        .animation(.snappy(duration: 0.2), value: conversation.busy)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !canSend, let link {
                // Not in a window on the Mac, so nothing's there to take a message: open it there.
                Button {
                    Task {
                        opening = true
                        openError = nil
                        if case .failure(let e) = await Remote.shared.openOnMac(link.session) { openError = e.message }
                        opening = false
                    }
                } label: {
                    Label(opening ? "Opening on your Mac…" : "Open on Your Mac to Reply", systemImage: "desktopcomputer")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.glass)
                .disabled(opening)
                if let openError { Text(openError).font(.caption).foregroundStyle(.orange) }
            }
            if !conversation.queue.isEmpty {
                QueuedMessages(conversation: conversation)
            }
            if !attachments.isEmpty {
                AttachmentStrip(images: $attachments, blind: conversation.status?.vision == false ? identity?.name : nil)
                    .padding(.horizontal, 4)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    attachMenu
                    TextField(conversation.busy ? "Queue a follow-up" : "Message frog", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                        .disabled(!canSend)
                        .onSubmit(send)
                    SendButton(conversation: conversation, canSend: canSend && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty),
                               send: send, tint: Color.place(cloud: identity?.place.isCloud ?? false))
                        .transition(.scale.combined(with: .opacity))
                }
                .animation(.spring(duration: 0.3, bounce: 0.3), value: conversation.busy)
                .animation(.spring(duration: 0.3, bounce: 0.3), value: draft.isEmpty)
            }
            if let status = conversation.status {
                // How frog asks, and how full its context is, as under the Mac's composer.
                HStack(spacing: 12) {
                    ModePicker(conversation: conversation)
                    if let link, canSend, let identity {
                        ModelButton(identity: identity) { pickingModel = true }
                            .disabled(conversation.busy)
                            .sheet(isPresented: $pickingModel) {
                                ModelSheet(remote: Remote.shared, session: link.session, current: status.model) { note in
                                    conversation.flash(note)
                                }
                                .environment(\.models, models)
                            }
                    }
                    Spacer()
                    ContextButton(conversation: conversation, status: status)
                }
                .font(.caption)
                .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        // A queued message's "x" puts it back in the field to edit, ahead of what's typed.
        .onChange(of: conversation.restored) { _, back in
            guard !back.isEmpty else { return }
            (draft, attachments) = conversation.takeRestored(into: draft, attachments: attachments)
        }
    }

    /// Images for the next message: from Photos, or what's been copied.
    private var attachMenu: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { pickingPhotos = true }
            Button("Paste Image", systemImage: "doc.on.clipboard") {
                let found = (UIPasteboard.general.images ?? []).compactMap { $0.jpegData(compressionQuality: 1).flatMap(Attachments.image(from:)) }
                attachments.append(contentsOf: found)
            }
            .disabled(!UIPasteboard.general.hasImages)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!canSend)
        .accessibilityLabel("Attach images")
    }

    private func send() {
        guard canSend else { return }
        FrogSounds.shared.play(.plip)
        conversation.submit(draft, images: attachments)
        draft = ""
        attachments = []
    }
}
