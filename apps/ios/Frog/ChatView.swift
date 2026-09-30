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
    @State private var draft = ""
    @State private var opening = false
    @State private var openError: String?

    private var identity: ModelIdentity? {
        conversation.status.map { ModelIdentity.of($0.model, in: models) }
    }
    private var canSend: Bool { link?.isOpenOnMac ?? true }

    var body: some View {
        TranscriptView(conversation: conversation, actions: TurnActions())
            .environment(\.pinsQuestions, true)
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
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        FrogFace(mood: conversation.mood, size: 24).tint(Color.frog)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(conversation.title ?? title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let identity { ModelLabel(model: identity, size: .caption).font(.caption2) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
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
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message frog", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                        .disabled(!canSend)
                        .onSubmit(send)
                    if conversation.busy {
                        Button { conversation.interrupt() } label: {
                            Image(systemName: "stop.fill").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Stop")
                        .transition(.scale.combined(with: .opacity))
                    } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(action: send) {
                            Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 30, height: 30)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .tint(Color.place(cloud: identity?.place.isCloud ?? false))
                        .accessibilityLabel("Send")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.3, bounce: 0.3), value: conversation.busy)
                .animation(.spring(duration: 0.3, bounce: 0.3), value: draft.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func send() {
        guard canSend else { return }
        FrogSounds.shared.play(.plip)
        conversation.submit(draft)
        draft = ""
    }
}
