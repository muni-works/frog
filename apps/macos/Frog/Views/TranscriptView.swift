import SwiftUI

struct TranscriptView: View {
    let conversation: Conversation
    let actions: TurnActions
    /// Set to a turn's id to scroll it into view (the timeline rail does this).
    var jump: Binding<TurnState.ID?> = .constant(nil)
    /// Told which turns are on screen.
    var onVisibleTurns: ([TurnState.ID]) -> Void = { _ in }
    @AppStorage("density") private var density = Density.comfortable.rawValue
    /// The toolbar's height over the transcript, for the fade under it.
    @State private var topInset: CGFloat = 0

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
                let footers = TurnFooter.pinned(conversation.turns) { ModelStats.shared.cost(of: $0) }
                ForEach(conversation.turns) { turn in
                    TurnView(turn: turn, conversation: conversation, actions: actions, pinsFooter: footers.contains(turn.id))
                }
                if let e = conversation.elicitation {
                    ElicitationCard(request: e, conversation: conversation)
                        .id(e.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                // The running turn's live line shows progress once there's something to show.
                if conversation.replaying {
                    LoadingIndicator(since: conversation.opened)
                } else if conversation.busy, conversation.permission == nil, conversation.elicitation == nil,
                   conversation.turns.last?.items.isEmpty ?? true {
                    WorkingIndicator(label: conversation.progress)
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
            // The canvas's margins are for this scroll view, not for ones inside it (code
            // blocks) or popovers opened from it.
            .contentMargins(0, for: .scrollContent)
        }
        .scrollContentBackground(.hidden)
        // The system's scroll-edge blur is hidden (see ScrollBackdropClear), so fade the
        // content out under the toolbar instead of letting it run into the title.
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }) { topInset = $0 }
        .mask {
            VStack(spacing: 0) {
                Color.clear.frame(height: max(0, topInset - 12))
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                Color.black
            }
            .ignoresSafeArea()
        }
        .onScrollTargetVisibilityChange(idType: TurnState.ID.self, threshold: 0.05) { onVisibleTurns($0) }
        // Start at the bottom, and stay pinned there as streamed content grows.
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay {
            if conversation.turns.isEmpty, !conversation.busy, !conversation.replaying, conversation.failure == nil {
                EmptyTranscript(conversation: conversation)
            }
        }
    }
}

struct UserPrompt: View {
    let text: String
    var images: [ToolImage] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                        if let ns = img.nsImage {
                            Image(nsImage: ns)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: images.count == 1 ? 220 : 110, height: images.count == 1 ? 150 : 80)
                                .clipShape(.rect(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                                .opensInLightbox(images, at: i)
                        }
                    }
                }
            }
            if !text.isEmpty {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.tint.opacity(0.14), in: .rect(cornerRadius: 16))
            }
        }
        .frame(maxWidth: 560, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct EndView: View {
    let reason: EndReason
    let usage: TurnUsage?
    /// The turn's answer: a copy button at the row's end, shown on hover.
    var answer: String = ""
    var hovering = false
    @Environment(\.models) private var models

    var body: some View {
        switch reason {
        case .complete, .denied:
            if let usage, usage.modelCalls > 0 {
                HStack(spacing: 10) {
                    // Where it ran, then what it cost (cloud) or how fast it wrote.
                    if let spec = usage.model {
                        ModelLabel(model: ModelIdentity.of(spec, in: models), size: .caption)
                    }
                    Group {
                        if let c = ModelStats.shared.cost(of: usage) {
                            Text(ModelStats.money(c))
                        } else if let tps = usage.tokensPerSec, tps > 0 {
                            Text(ModelStats.speedText(tps * ModelStats.wordsPerToken))
                        }
                    }
                    .help("\(usage.modelCalls) call\(usage.modelCalls == 1 ? "" : "s") · \(usage.inputTokens.tokens) in, \(usage.outputTokens.tokens) out") // advanced
                    Spacer(minLength: 8)
                    if !answer.isEmpty {
                        MessageAction(title: "Copy answer", symbol: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(answer, forType: .string)
                        }
                        .opacity(hovering ? 1 : 0)
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

/// "Loading session…", once opening a conversation has taken long enough to notice: a quick
/// open shows nothing between one conversation and the next.
struct LoadingIndicator: View {
    let since: Date
    @State private var shown = false

    var body: some View {
        WorkingIndicator(label: "Loading session…")
            .opacity(shown ? 1 : 0)
            .task {
                let wait = 0.3 - Date.now.timeIntervalSince(since)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                withAnimation(.easeIn(duration: 0.2)) { shown = true }
            }
    }
}

struct EmptyTranscript: View {
    let conversation: Conversation
    @Environment(\.canvasInsets) private var insets
    @AppStorage("playfulFrog") private var playful = true
    @State private var hovering = false
    @State private var line = 0
    @State private var hop = 0

    private var isChat: Bool { Frog.isChat(conversation.folder) }

    var body: some View {
        // Short panes (a split stacked in a column) drop the suggestion, then the frog.
        ViewThatFits(in: .vertical) {
            content(details: true, card: true)
            content(details: true, card: false)
            content(details: false, card: false)
        }
        .padding(.top, insets.top)
    }

    private func content(details: Bool, card: Bool) -> some View {
        VStack(spacing: 10) {
            if !details {
                EmptyView()
            } else if playful {
                mascot
            } else {
                Image("FrogMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .foregroundStyle(Color.accentColor.gradient)
            }
            // The frog and a question; the composer (and its model pill) does the rest.
            Text(isChat ? "What should we work on?" : conversation.folder.lastPathComponent)
                .font(.title2.weight(.semibold))
            if card {
                EmptyPageExtras(conversation: conversation)
                    .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .padding()
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
    }

    /// The frog on its lily pad. Hover and it says something; drop a file and it hops.
    private var mascot: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                LilyPad()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(width: 76, height: 26)
                    .offset(y: 4)
                FrogFace(mood: .idle, size: 48, hop: hop)
                    .anchorPreference(key: FrogAnchorKey.self, value: .bounds) { $0 }
            }
            .padding(.top, 4)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            Text(FrogCopy.hovers[line % FrogCopy.hovers.count])
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: hovering)
                .animation(.easeInOut(duration: 0.2), value: line)
                .contentTransition(.opacity)
        }
        .task(id: hovering) {
            guard hovering else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                guard !Task.isCancelled else { return }
                line += 1
            }
        }
        .onChange(of: conversation.dropped) { _, urls in
            if !urls.isEmpty { hop += 1 }
        }
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
