import SwiftUI

/// One conversation, like a Messages thread: your messages on the right, frog's work folded into
/// a line and its answers writing themselves in on the left, and its questions on glass above
/// the keyboard until you answer. The frog in the title shows what it's up to.
struct ChatView: View {
    let model: SessionModel
    var onClose: () -> Void = {}
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.turns) { turn in
                        TurnView(turn: turn, local: model.isLocal, current: turn.id == model.turns.last?.id && model.busy)
                    }
                    if model.busy, model.permission == nil, !answering {
                        TypingDots().transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .animation(.spring(duration: 0.35), value: model.busy)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.turns.last?.entries.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: model.turns.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .overlay {
                if model.loading, model.turns.isEmpty {
                    FrogFace(mood: .reading, size: 44).tint(.frog).opacity(0.6)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ZStack {
                if let p = model.permission {
                    PermissionCard(request: p) { model.answer($0) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    composer.transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.2), value: model.permission?.id)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    FrogFace(mood: model.mood, size: 24).tint(.frog)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.session.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            Circle().fill(model.isLocal ? Color.imessageBlue : Color.imessageGreen).frame(width: 6, height: 6)
                            Text(Models.short(model.model)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: model.stepsDone)
        .sensoryFeedback(.success, trigger: model.turnsDone)
        .userActivity(Handoff.conversation) { a in
            a.title = model.session.title
            a.userInfo = ["session": model.id]
            a.isEligibleForHandoff = true
            a.targetContentIdentifier = model.id
        }
        .onDisappear(perform: onClose)
    }

    /// Something is already showing progress: the live work line, or the answer's words. The
    /// dots are only for the moment before either.
    private var answering: Bool {
        !(model.turns.last?.entries.isEmpty ?? true)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !model.isOpenOnMac {
                Label("Open this conversation on your Mac to reply from here", systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message frog", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($typing)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                        .disabled(!model.isOpenOnMac)
                        .onSubmit(send)
                    if model.busy {
                        Button { model.interrupt() } label: {
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
                        .tint(model.isLocal ? .imessageBlue : .imessageGreen)
                        .accessibilityLabel("Send")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.3, bounce: 0.3), value: model.busy)
                .animation(.spring(duration: 0.3, bounce: 0.3), value: draft.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func send() {
        guard model.isOpenOnMac else { return }
        model.submit(draft)
        draft = ""
    }
}

// MARK: - Turns

struct TurnView: View {
    let turn: SessionModel.Turn
    let local: Bool
    /// The turn frog is working on now.
    let current: Bool
    @State private var appeared = false
    @State private var showAll = false

    /// Pasted logs and long prompts start folded, so the thread stays readable.
    private var long: Bool { turn.input.count > 600 || turn.input.split(separator: "\n").count > 10 }

    private static func clip(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
        return String(lines.prefix(480)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !turn.input.isEmpty { bubble }
            let blocks = turn.blocks
            ForEach(blocks) { block in
                switch block {
                case .work(let entries):
                    WorkGroupView(entries: entries, live: current && block.id == blocks.last?.id)
                case .message(let e):
                    HStack {
                        Group {
                            if e.live { InkMessage(text: e.text, streaming: !e.done) } else { MessageBody(text: e.text) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                        Spacer(minLength: 28)
                    }
                case .notice(let e):
                    Label(e.text, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            footer
        }
    }

    private var bubble: some View {
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(long && !showAll ? Self.clip(turn.input) : turn.input)
                    .textSelection(.enabled)
                if long {
                    Button(showAll ? "Show less" : "Show more") { withAnimation(.snappy) { showAll.toggle() } }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(local ? Color.imessageBlue : Color.imessageGreen, in: .rect(cornerRadius: 20))
        }
        .scaleEffect(turn.sentHere && !appeared ? 0.5 : 1, anchor: .bottomTrailing)
        .offset(y: turn.sentHere && !appeared ? 30 : 0)
        .opacity(turn.sentHere && !appeared ? 0 : 1)
        .onAppear { withAnimation(.spring(duration: 0.4, bounce: 0.35)) { appeared = true } }
    }

    @ViewBuilder
    private var footer: some View {
        if case .error(let e)? = turn.end {
            Label(e.description, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.orange)
        } else if let end = turn.end, let text = Self.stopped(end) {
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        if let u = turn.usage, turn.finished, u.modelCalls > 0 {
            Text(Self.usage(u))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    private static func stopped(_ end: EndReason) -> String? {
        switch end {
        case .cancelled: "Stopped"
        case .looping: "Stopped: frog kept repeating itself"
        case .stepLimit: "Stopped at the step limit"
        case .maxTokens: "Cut off at the length limit"
        case .denied: "Stopped: you said no"
        default: nil
        }
    }

    private static func usage(_ u: TurnUsage) -> String {
        var parts: [String] = []
        if let t = u.tokensPerSec { parts.append(String(format: "%.0f tok/s", t)) }
        if let e = u.energy { parts.append(String(format: "%.2f Wh", e.totalWh)) }
        parts.append("\(u.outputTokens.tokens) tokens out")
        return parts.joined(separator: " · ")
    }
}

extension UInt64 {
    /// 12345 → "12.3k"
    var tokens: String {
        self >= 1000 ? String(format: "%.1fk", Double(self) / 1000) : "\(self)"
    }
}

enum Handoff {
    /// The conversation you're reading, for the Mac to pick up (and back).
    static let conversation = "eco.frog.conversation"
}
