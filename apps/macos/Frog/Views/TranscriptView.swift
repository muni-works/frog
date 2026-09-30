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
    /// The view keeps to the bottom as content grows (see `onScrollGeometryChange`).
    @State private var following = true
    @State private var userScrolling = false
    /// Where the last turn starts, from the top of the view: a long answer stops following
    /// once its prompt reaches the top, so you read it from the beginning.
    @State private var lastTurnTop: CGFloat = .infinity
    /// Stopped short of the end, with more below (stopped at a long answer's start, or you
    /// scrolled up while it wrote): the pill offers the way down.
    @State private var parked = false
    /// Content below the view, in points.
    @State private var below: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            transcript
                // Open at the end, whole: straight to the last row, laid out for real, rather
                // than an estimate of where the end is that settles into place as rows measure.
                .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
                .onChange(of: jump.wrappedValue) { _, id in
                    guard let id else { return }
                    following = false
                    withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(id, anchor: .top) }
                    jump.wrappedValue = nil
                }
                // A new turn goes below one that may be taller than the window. The lazy stack
                // guesses that turn's height, and the bottom anchor alone can land past the real
                // content: a blank transcript until you scroll. Scrolling to a row at the end lays
                // the new rows out for real, and following keeps the view there as it grows.
                .onChange(of: conversation.turns.last?.id) { _, id in
                    guard let id else { return }
                    following = true
                    proxy.scrollTo(Self.end, anchor: .bottom)
                }
                // Follow the answer as it streams: while following, content that grows takes the
                // view back to the bottom. The size-change anchor alone loses the bottom once the
                // lazy stack re-estimates rows it hasn't laid out.
                .onScrollGeometryChange(for: ScrollEnd.self, of: ScrollEnd.init) { old, new in
                    below = new.below
                    if new.atBottom { parked = false }
                    if userScrolling {
                        following = new.atBottom
                        if !new.atBottom, conversation.busy { parked = true }
                    } else if following, !new.atBottom {
                        // Keeping to the bottom would push the answer's start above the top:
                        // stop with the prompt at the top instead, and read from there.
                        let growth = new.contentHeight - old.contentHeight
                        if conversation.busy, growth > 0, lastTurnTop - growth < topInset + 4,
                           let id = conversation.turns.last?.id {
                            following = false
                            parked = true
                            withAnimation(Motion.quick(reduced: reduceMotion)) { proxy.scrollTo(id, anchor: .top) }
                        } else {
                            proxy.scrollTo(Self.end, anchor: .bottom)
                        }
                    }
                }
                // Only your own scrolling stops (or restarts) following: the lazy stack also
                // moves the offset as it measures rows, and that mustn't count.
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                }
                .overlay(alignment: .bottom) {
                    if parked, below > 30 {
                        MoreBelow(lines: Int(below / 22), writing: conversation.busy) {
                            parked = false
                            following = true
                            withAnimation(Motion.panel(reduced: reduceMotion)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                        }
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                    }
                }
                .animation(Motion.quick(reduced: reduceMotion), value: parked && below > 30)
        }
    }

    /// Where the view is against the end of the content.
    private struct ScrollEnd: Equatable {
        let contentHeight: CGFloat
        let offset: CGFloat
        let atBottom: Bool
        /// Content below the view.
        let below: CGFloat

        init(_ g: ScrollGeometry) {
            contentHeight = g.contentSize.height
            offset = g.contentOffset.y
            below = max(0, g.contentSize.height + g.contentInsets.bottom - (g.contentOffset.y + g.containerSize.height))
            atBottom = below <= 24
        }
    }

    /// A row at the very end of the transcript, below the last turn and its indicators.
    private static let end = "transcript-end"

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: density == Density.compact.rawValue ? 12 : 22) {
                let footers = TurnFooter.pinned(conversation.turns) { ModelStats.shared.cost(of: $0) }
                ForEach(conversation.turns) { turn in
                    TurnView(turn: turn, conversation: conversation, actions: actions, pinsFooter: footers.contains(turn.id))
                        .background {
                            if turn.id == conversation.turns.last?.id {
                                Color.clear.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .scrollView).minY }) {
                                    lastTurnTop = $0
                                }
                            }
                        }
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
                Color.clear.frame(height: 0).id(Self.end)
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
                // A soft edge where the text carries on below the view.
                LinearGradient(colors: [.black, .black.opacity(below > 8 ? 0.05 : 1)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 44)
            }
            .ignoresSafeArea()
        }
        .onScrollTargetVisibilityChange(idType: TurnState.ID.self, threshold: 0.05) { onVisibleTurns($0) }
        // Start at the bottom; following (above) keeps it there as streamed content grows.
        .defaultScrollAnchor(.bottom)
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
    /// Where the turn ran: iMessage blue on this Mac or your own server, green in the cloud,
    /// like the model's name in its footer.
    var tint: Color = .accentColor

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
                    // Solid, with white text, like iMessage (blue) and SMS (green).
                    .foregroundStyle(.white)
                    .background(tint, in: .rect(cornerRadius: 18))
            }
        }
        .frame(maxWidth: 560, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct EndView: View {
    let reason: EndReason
    let usage: TurnUsage?
    @AppStorage(ModelStats.energyKey) private var showEnergy = false
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
                    // What it cost (cloud) or how fast it wrote; each opens its working.
                    if let c = ModelStats.shared.cost(of: usage) {
                        PriceHint(cost: c, usage: usage)
                    } else if let tps = usage.tokensPerSec, tps > 0 {
                        Text(ModelStats.speedText(tps * ModelStats.wordsPerToken))
                            .help("\(usage.modelCalls) call\(usage.modelCalls == 1 ? "" : "s") · \(usage.inputTokens.tokens) in, \(usage.outputTokens.tokens) out") // advanced
                    }
                    if showEnergy, let e = usage.energy {
                        EnergyHint(energy: e, usage: usage)
                    }
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

/// The way down from a long answer: how much is left, and whether it's still being written.
private struct MoreBelow: View {
    let lines: Int
    let writing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: writing ? "pencil.line" : "arrow.down")
                    .symbolEffect(.pulse, options: .repeating, isActive: writing)
                Text(writing ? "Writing · \(lines) more line\(lines == 1 ? "" : "s")" : "\(lines) more line\(lines == 1 ? "" : "s")")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Follow the answer to the end")
    }
}
