import SwiftUI

#if DEBUG
import os
#endif

struct TranscriptView: View {
    let conversation: Conversation
    let actions: TurnActions
    /// Set to a turn's id to scroll it into view (the timeline rail does this).
    var jump: Binding<TurnState.ID?> = .constant(nil)
    /// Told which turns are on screen.
    var onVisibleTurns: ([TurnState.ID]) -> Void = { _ in }
    @AppStorage("density") private var density = Density.comfortable.rawValue
    private var space: TurnSpace.Scale { TurnSpace.scale(density) }
    /// The toolbar's height over the transcript, for the fade under it.
    @State private var topInset: CGFloat = 0
    /// The view keeps to the bottom as content grows (see `onScrollGeometryChange`).
    @State private var following = true
    @State private var userScrolling = false
    /// A follow scroll is queued for the next run-loop turn; coalesces bursts of growth.
    @State private var followPending = false
    /// Where the last turn starts, in the content: a long answer stops following once its
    /// prompt would pass the top of the view, so you read it from the beginning.
    @State private var lastTurnTop: CGFloat = .infinity
    /// Stopped short of the end, with more below (stopped at a long answer's start, or you
    /// scrolled up while it wrote): the pill offers the way down.
    @State private var parked = false
    /// Content below the view, in points.
    @State private var below: CGFloat = 0
    /// How tall the content was when the view stopped following: the pill only shows once
    /// something new has come in past it, not for what was already there.
    @State private var parkedHeight: CGFloat?
    @State private var height: CGFloat = 0
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
                    parked = false
                    proxy.scrollTo(Self.end, anchor: .bottom)
                }
                // Follow the answer as it streams: while following, content that grows takes the
                // view back to the bottom. The size-change anchor alone loses the bottom once the
                // lazy stack re-estimates rows it hasn't laid out.
                .onScrollGeometryChange(for: ScrollEnd.self, of: ScrollEnd.init) { old, new in
                    below = new.below
                    height = new.contentHeight
                    let growth = new.contentHeight - old.contentHeight
                    if userScrolling {
                        // Only your own scrolling ends a stop: back at the end, it follows again.
                        following = new.atBottom
                        if !new.atBottom, parked || conversation.busy {
                            park(at: new.contentHeight)
                        } else {
                            parked = false
                        }
                        return
                    }
                    if following, conversation.busy, growth > 0,
                       lastTurnTop < new.visibleTop + growth + topInset + 4,
                       let id = conversation.turns.last?.id {
                        // Keeping to the bottom would push the answer's start above the top:
                        // stop with the prompt at the top instead, and read from there.
                        following = false
                        park(at: old.contentHeight)
                        withAnimation(Motion.quick(reduced: reduceMotion)) { proxy.scrollTo(id, anchor: .top) }
                        return
                    }
                    // Only growth needs chasing (shrinking clamps to the bottom anyway), and the
                    // scroll waits for the next turn of the run loop: scrolling inside the scroll
                    // view's own update re-estimates the lazy rows, which changes the geometry
                    // again, and AppKit aborts on the constraint loop.
                    guard following, !new.atBottom, new.contentHeight > old.contentHeight, !followPending else { return }
                    followPending = true
                    DispatchQueue.main.async {
                        followPending = false
                        guard following, !userScrolling else { return }
                        #if DEBUG
                        // Perf task: the follow fires at most once per run-loop turn.
                        os_signpost(.event, log: Self.followLog, name: "transcript.follow")
                        #endif
                        proxy.scrollTo(Self.end, anchor: .bottom)
                    }
                }
                // Only your own scrolling stops (or restarts) following: the lazy stack also
                // moves the offset as it measures rows, and that mustn't count.
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                }
                .overlay(alignment: .bottom) {
                    if unseen {
                        NewBelow(writing: conversation.busy) {
                            parked = false
                            following = true
                            withAnimation(Motion.panel(reduced: reduceMotion)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                        }
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
                    }
                }
                .animation(Motion.quick(reduced: reduceMotion), value: unseen)
        }
    }

    private func park(at contentHeight: CGFloat) {
        if !parked { parkedHeight = contentHeight }
        parked = true
    }

    /// Something new came in below where you stopped (more than a line: the thinking row
    /// changing size doesn't count), and it's still out of view.
    private var unseen: Bool {
        guard parked, below > 30, let parkedHeight else { return false }
        return height - parkedHeight > 40
    }

    /// Where the view is against the end of the content.
    private struct ScrollEnd: Equatable {
        let contentHeight: CGFloat
        let atBottom: Bool
        /// Content below the view.
        let below: CGFloat
        /// The top of the visible area, in content coordinates.
        let visibleTop: CGFloat

        init(_ g: ScrollGeometry) {
            contentHeight = g.contentSize.height
            // Against what's actually visible above the composer. The offset alone misses the top
            // inset, which is large while the content is shorter than the view (it's anchored to
            // the bottom): the transcript never thought it was at the end, and following
            // scrolled to it over and over.
            below = max(0, g.contentSize.height - (g.visibleRect.maxY - g.contentInsets.bottom))
            visibleTop = g.visibleRect.minY
            atBottom = below <= 24
        }
    }

    /// The transcript's content, for measuring where a turn starts in it.
    private static let content = "transcript-content"

    #if DEBUG
    /// For the perf task: the deferred, coalesced follow-scroll signpost. Instruments' "Points
    /// of Interest" misses `OSLog.pointsOfInterest` under explicit modules, so a named one.
    static let followLog = OSLog(subsystem: "toys.frog", category: "transcript-follow")
    #endif

    /// A row at the very end of the transcript, below the last turn and its indicators.
    private static let end = "transcript-end"

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: space.betweenTurns) {
                let footers = TurnFooter.pinned(conversation.turns) { ModelStats.shared.cost(of: $0) }
                ForEach(conversation.turns) { turn in
                    TurnView(turn: turn, conversation: conversation, actions: actions, pinsFooter: footers.contains(turn.id))
                        .background {
                            if turn.id == conversation.turns.last?.id {
                                Color.clear.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(Self.content)).minY }) {
                                    lastTurnTop = $0
                                }
                            }
                        }
                }
                if let q = conversation.question {
                    QuestionCard(question: q, conversation: conversation)
                        .id(q.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let e = conversation.elicitation {
                    ElicitationCard(request: e, conversation: conversation)
                        .id(e.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                // The running turn's live line shows progress once there's something to show.
                // A busy state with no live engine behind it (the stream died mid-turn) doesn't:
                // it's a stale window until the watchdog reconciles from the log.
                if conversation.replaying {
                    LoadingIndicator(since: conversation.opened)
                } else if conversation.busy, conversation.engineAlive, conversation.permission == nil,
                   conversation.elicitation == nil, conversation.question == nil,
                   conversation.turns.last?.items.isEmpty ?? true {
                    WorkingIndicator(progress: conversation.progress, since: conversation.progressSince)
                }
                if let preview = conversation.presentPreview {
                    PresentCard(present: preview)
                        .opacity(0.85)
                        .transition(.opacity)
                }
                if let failure = conversation.failure {
                    Label(failure, systemImage: "exclamationmark.octagon")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Color.clear.frame(height: 0).id(Self.end)
            }
            .scrollTargetLayout()
            .coordinateSpace(.named(Self.content))
            .environment(\.turnSpace, space)
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
        // Start at the bottom, and keep short content there. While following (above), growth
        // keeps the view at the bottom too; once a long answer has stopped at its start, it
        // grows downward under a still view instead.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(following ? .bottom : .top, for: .sizeChanges)
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
        let (message, contexts) = PromptContext.split(text)
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                        if let ns = img.image {
                            Image(platformImage: ns)
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
            if !message.isEmpty {
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    // Solid, with white text, like iMessage (blue) and SMS (green).
                    .foregroundStyle(.white)
                    .background(tint, in: .rect(cornerRadius: 18))
            }
            ForEach(contexts) { ContextDisclosure(context: $0) }
        }
        .frame(maxWidth: 560, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Context sent with a message, folded under its bubble: "› GitHub · ecto/ipse#458". Open it
/// to read what the model was given.
private struct ContextDisclosure: View {
    let context: PromptContext
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                withAnimation(Motion.quick(reduced: reduceMotion)) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(context.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help(open ? "Hide what was sent with this message" : "Show what was sent with this message")
            if open {
                Text(context.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
            }
        }
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
                            Clipboard.copy(answer)
                        }
                        .opacity(hovering ? 1 : 0)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        case .cancelled:
            banner("Interrupted", symbol: "stop.circle", color: .secondary)
        case .suspended:
            banner("Suspended for app update", symbol: "pause.circle", color: .secondary)
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
    let progress: EngineProgress?
    let since: Date?

    init(progress: EngineProgress?, since: Date? = nil) {
        self.progress = progress
        self.since = since
    }

    init(label: String?) {
        self.progress = label.map { EngineProgress(label: $0, completed: nil, total: nil) }
        self.since = nil
    }

    var body: some View {
        if let progress, let completed = progress.completed, let total = progress.total, total > 0 {
            ProbeProgress(progress: progress, completed: completed, total: total, since: since ?? .now)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress.map { Self.title($0.label) } ?? "Working…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .animation(.default, value: progress)
        }
    }

    fileprivate static func title(_ label: String) -> String {
        label.prefix(1).uppercased() + label.dropFirst()
    }
}

/// Capability profiling has discrete requests. The solid portion is the exact number done;
/// the moving highlight stays inside the request currently in flight.
private struct ProbeProgress: View {
    let progress: EngineProgress
    let completed: Int
    let total: Int
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(since))
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.probeTitle(for: progress.label))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("Step \(min(completed + 1, total)) of \(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                ProbeProgressBar(completed: completed, total: total, elapsed: elapsed)
                Text("\(Self.phase(for: progress.label, elapsed: elapsed)) · \(Self.elapsed(elapsed))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Self.probeTitle(for: progress.label)), step \(min(completed + 1, total)) of \(total), \(Self.phase(for: progress.label, elapsed: Date.now.timeIntervalSince(since)))")
    }

    private static func probeTitle(for label: String) -> String {
        let normalized = label.lowercased()
        if normalized.contains("text tool") { return "Testing text tool calls" }
        if normalized.contains("native tool") { return "Testing native tool calls" }
        if normalized.contains("direct answer") { return "Testing direct answers" }
        if normalized.contains("json") { return "Testing structured output" }
        if normalized.contains("thinking") { return "Testing thinking controls" }
        return WorkingIndicator.title(label)
    }

    private static func phase(for label: String, elapsed: TimeInterval) -> String {
        if elapsed < 1 { return "Preparing a small compatibility request" }
        let normalized = label.lowercased()
        let operation: String
        if normalized.contains("tool") { operation = "Checking the model's tool-call format" }
        else if normalized.contains("json") { operation = "Checking the model's schema-constrained reply" }
        else if normalized.contains("thinking") { operation = "Checking the model's response controls" }
        else { operation = "Waiting for the model's reply" }
        return elapsed < 12 ? operation : "Still waiting for this request"
    }

    private static func elapsed(_ seconds: TimeInterval) -> String {
        let wholeSeconds = Int(seconds.rounded(.down))
        return wholeSeconds < 60 ? "\(wholeSeconds)s elapsed" : "\(wholeSeconds / 60)m \(wholeSeconds % 60)s elapsed"
    }
}

private struct ProbeProgressBar: View {
    let completed: Int
    let total: Int
    let elapsed: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let doneFraction = CGFloat(min(max(Double(completed) / Double(total), 0), 1))
            let doneWidth = width * doneFraction
            let slotWidth = width / CGFloat(total)
            let beamWidth = min(slotWidth, max(22, slotWidth * 0.42))
            let phase = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.25) / 1.25)
            let beamOffset = doneWidth + max(0, slotWidth - beamWidth) * phase

            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(.green).frame(width: doneWidth)
                Capsule()
                    .fill(LinearGradient(colors: [.green.opacity(0.35), .green, .green.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: beamWidth)
                    .offset(x: beamOffset)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityHidden(true)
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

    private var isChat: Bool { FrogPaths.isChat(conversation.folder) }

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
            #if os(macOS)
            if card {
                EmptyPageExtras(conversation: conversation)
                    .padding(.top, 6)
            }
            #endif
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

#if os(macOS)
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

#else
/// A SwiftUI `ScrollView` on iOS paints nothing of its own.
struct ScrollBackdropClear: View {
    var body: some View { EmptyView() }
}
#endif

/// The way down to a message that came in below where you're reading.
private struct NewBelow: View {
    let writing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down")
                    .symbolEffect(.pulse, options: .repeating, isActive: writing)
                Text("New message")
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Go to the end and follow the answer")
    }
}
