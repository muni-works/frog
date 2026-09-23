import SwiftUI

struct TranscriptView: View {
    let conversation: Conversation
    let actions: TurnActions
    /// Set to a turn's id to scroll it into view (the timeline rail does this).
    var jump: Binding<TurnState.ID?> = .constant(nil)
    /// Told which turns are on screen.
    var onVisibleTurns: ([TurnState.ID]) -> Void = { _ in }
    @AppStorage("density") private var density = Density.comfortable.rawValue

    var body: some View {
        ScrollViewReader { proxy in
            transcript
                .onChange(of: jump.wrappedValue) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(id, anchor: .top) }
                    jump.wrappedValue = nil
                }
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: density == Density.compact.rawValue ? 12 : 22) {
                ForEach(conversation.turns) { turn in
                    TurnView(turn: turn, conversation: conversation, actions: actions)
                }
                if let e = conversation.elicitation {
                    ElicitationCard(request: e, conversation: conversation)
                        .id(e.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                // The running turn's work group shows progress once there's something to show.
                if conversation.busy, conversation.permission == nil, conversation.elicitation == nil,
                   conversation.replaying || (conversation.turns.last?.items.isEmpty ?? true) {
                    WorkingIndicator(label: conversation.replaying ? "Loading session…" : conversation.progress)
                }
                if let failure = conversation.failure {
                    Label(failure, systemImage: "exclamationmark.octagon")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: 820)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(ScrollBackdropClear())
        }
        .scrollContentBackground(.hidden)
        .onScrollTargetVisibilityChange(idType: TurnState.ID.self, threshold: 0.05) { onVisibleTurns($0) }
        // Start at the bottom, and stay pinned there as streamed content grows.
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay {
            if conversation.turns.isEmpty, !conversation.busy, conversation.failure == nil {
                EmptyTranscript(conversation: conversation)
            }
        }
    }
}

struct UserPrompt: View {
    let text: String

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.tint.opacity(0.14), in: .rect(cornerRadius: 16))
            .frame(maxWidth: 560, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct EndView: View {
    let reason: EndReason
    let usage: TurnUsage?

    var body: some View {
        switch reason {
        case .complete, .denied:
            if let usage, usage.modelCalls > 0 {
                HStack(spacing: 10) {
                    Text("\(usage.modelCalls) call\(usage.modelCalls == 1 ? "" : "s")")
                    Text("\((usage.inputTokens + usage.outputTokens).tokens) tokens")
                    if let tps = usage.tokensPerSec {
                        Text("\(Int(tps)) tok/s")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        case .cancelled:
            banner("Interrupted", symbol: "stop.circle", color: .secondary)
        case .maxTokens:
            banner("Hit the output token limit", symbol: "text.append", color: .orange)
        case .looping:
            banner("Stopped: the model kept repeating the same tool call", symbol: "arrow.trianglehead.2.clockwise", color: .orange)
        case .stepLimit:
            banner("Stopped at the step limit. Say “continue” to keep going.", symbol: "flag.checkered", color: .orange)
        case .error(let e):
            banner(e.description, symbol: "exclamationmark.octagon", color: .red)
        }
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .textSelection(.enabled)
    }
}

struct WorkingIndicator: View {
    let label: String?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Working…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .animation(.default, value: label)
    }
}

struct EmptyTranscript: View {
    let conversation: Conversation
    @Environment(\.canvasInsets) private var insets

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "flame")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.orange.gradient)
            Text(conversation.folder.lastPathComponent)
                .font(.title2.weight(.semibold))
            if let s = conversation.status {
                Text("\(s.model) · \(s.toolMode) tools · \(s.tier) tier")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Ask about the code, or describe a change.  Use @file to attach a file, !cmd to run a command.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding()
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
    }
}

/// Keeps the `NSScrollView` behind a SwiftUI `ScrollView` from painting anything of its own,
/// so the transcript stays one canvas with the window instead of a panel that lightens on hover.
struct ScrollBackdropClear: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.postsFrameChangedNotifications = true
        DispatchQueue.main.async { Self.clear(from: v) }
        // The content grows as the conversation streams; clear again whenever it does.
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: v, queue: .main
        ) { [weak v] _ in
            MainActor.assumeIsolated { if let v { Self.clear(from: v) } }
        }
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.clear(from: view) }
    }

    private static func clear(from view: NSView) {
        guard let scroll = view.enclosingScrollView else { return }
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = .clear
        // macOS 26 adds a backdrop behind the content and a scroll-edge "pocket" (a 5% white
        // fill) that light up while the pointer is over the scroll view: the lighter panel.
        // AppKit re-shows it, so zero its alpha (which it leaves alone) as well.
        let chrome: Set<String> = ["BackdropView", "NSScrollPocket"]
        for sub in scroll.subviews where chrome.contains(String(describing: type(of: sub))) {
            sub.isHidden = true
            sub.alphaValue = 0
        }
    }
}
