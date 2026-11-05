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
    /// Where the view is and what's below it. Written on every scroll and every bit of growth,
    /// so it isn't view state: only the pill and the bottom fade read it, and the transcript's
    /// body (every turn in it) doesn't rebuild each time the content grows a line.
    @State private var track = ScrollTrack()
    /// The first turn the transcript builds: a few dozen rows from the end when it opens, and
    /// earlier as you scroll up to it (`showEarlier`) or jump to a turn before it. Turns above
    /// aren't in the stack at all: a lazy stack still does work for every row it holds (5,000
    /// rows took 300 ms more to open), and older history folding in
    /// (`Conversation.olderPending`) never moves what's on screen. Nil: the last rows.
    @State private var shownFrom: TurnState.ID?
    /// Rows are going in above the view (see `showEarlier`).
    @State private var growingAbove = false
    /// Finished turns' flows, so the rows aren't re-derived for every turn on every chunk.
    @State private var flows = FlowCache()
    @AppStorage(Verbosity.key) private var defaultVerbosity = Verbosity.standard.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Opening the session a line names (a worktree's owner, a message's sender).
    @Environment(\.openSessionID) private var openSessionID

    /// Rows built when the transcript opens, and added each time you reach its top.
    static var windowRows = 50
    static var earlierRows = 200
    /// How near the top of what's built (in points) builds more above it.
    static let nearTop: CGFloat = 60

    var body: some View {
        ScrollViewReader { proxy in
            transcript
                // Open at the end, whole: straight to the last row, laid out for real, rather
                // than an estimate of where the end is that settles into place as rows measure.
                .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
                // Until it's set, the window is the last rows; once a turn is added it's pinned
                // where it was, so the new turn doesn't push the top one out from above you.
                // (Set on appear, it left the stack over rows it hadn't laid out.)
                .onChange(of: conversation.turns.count) { old, new in
                    guard shownFrom == nil, new > old, old > 0 else { return }
                    shownFrom = Self.start(of: Array(conversation.turns.prefix(old)), rows: Self.windowRows)
                }
                .onChange(of: jump.wrappedValue) { _, id in
                    guard let id else { return }
                    following = false
                    jump.wrappedValue = nil
                    // A turn above what's built: build down from it first, then go there.
                    guard let target = conversation.turns.firstIndex(where: { $0.id == id }) else { return }
                    let row = firstRow(of: conversation.turns[target])
                    if target < firstShown {
                        shownFrom = id
                        DispatchQueue.main.async {
                            withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(row, anchor: .top) }
                        }
                        return
                    }
                    withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo(row, anchor: .top) }
                }
                // Older turns folded in while you were at the top: carry on up into them.
                .onChange(of: conversation.turns.first?.id) {
                    if track.atTop { showEarlier(proxy) }
                }
                // A new turn goes below one that may be taller than the window. The lazy stack
                // guesses that turn's height, and the bottom anchor alone can land past the real
                // content: a blank transcript until you scroll. Scrolling to a row at the end lays
                // the new rows out for real, and following keeps the view there as it grows.
                .onChange(of: conversation.turns.last?.id) { _, id in
                    guard id != nil else { return }
                    following = true
                    track.unpark()
                    proxy.scrollTo(Self.end, anchor: .bottom)
                }
                // Follow the answer as it streams: while following, content that grows takes the
                // view back to the bottom. The size-change anchor alone loses the bottom once the
                // lazy stack re-estimates rows it hasn't laid out.
                .onScrollGeometryChange(for: ScrollEnd.self, of: ScrollEnd.init) { old, new in
                    defer { track.measured(below: new.below, height: new.contentHeight) }
                    // Near the top of what's built, once it has opened at the end: build more
                    // above (and, when what's built is shorter than the view, until it isn't).
                    // A row in the lazy stack can't be the trigger: the stack estimates the rows
                    // it hasn't built from the ones it has, and a small one at the top made it
                    // land short of the end on open, over nothing.
                    if new.atBottom { track.openedAtEnd = true }
                    let atTop = track.openedAtEnd && new.contentHeight > 0 && new.visibleTop < Self.nearTop
                    if atTop != track.atTop {
                        track.atTop = atTop
                        if atTop { DispatchQueue.main.async { showEarlier(proxy) } }
                    }
                    let growth = new.contentHeight - old.contentHeight
                    if track.userScrolling {
                        // Only your own scrolling ends a stop: back at the end, it follows again.
                        following = new.atBottom
                        if !new.atBottom, track.parked || conversation.busy {
                            track.park(at: new.contentHeight)
                        } else {
                            track.unpark()
                        }
                        return
                    }
                    // Past the end of what's laid out: nothing to draw (the lazy stack's estimate
                    // of rows above shrank under a still offset). Back to the end, and follow.
                    if new.pastEnd {
                        following = true
                        track.unpark()
                        return follow(proxy)
                    }
                    if following, conversation.busy, growth > 0, let live = liveAnswer,
                       let top = live.first ? track.lastTurnTop : track.answerTop(live.item),
                       top < new.visibleTop + growth + topInset + 4 {
                        // Keeping to the bottom would push the answer's start above the top:
                        // stop at its start instead (the prompt, when it's the turn's first
                        // words), and read from there. Only for an answer: a turn of tool calls
                        // and short notes keeps following, however long it gets. Not animated, and
                        // after this update: an animated scroll on the lazy stack aims at where it
                        // estimated the row while the content keeps growing under it, and can
                        // stop past the laid-out end, a blank transcript until you scroll.
                        following = false
                        track.park(at: old.contentHeight)
                        let target = live.first ? firstRow(of: conversation.turns[conversation.turns.count - 1])
                            : TranscriptRow.ID(turn: live.turn, part: live.item)
                        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                        return
                    }
                    // Only growth needs chasing (shrinking clamps to the bottom anyway).
                    guard following, !new.atBottom, new.contentHeight > old.contentHeight else { return }
                    follow(proxy)
                }
                // Only your own scrolling stops (or restarts) following: the lazy stack also
                // moves the offset as it measures rows, and that mustn't count.
                .onScrollPhaseChange { _, phase in
                    track.userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                }
                .overlay(alignment: .bottom) {
                    NewBelowPill(track: track, writing: conversation.busy) {
                        track.unpark()
                        following = true
                        withAnimation(Motion.panel(reduced: reduceMotion)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                    }
                }
        }
        .environment(\.transcriptTrack, track)
    }

    /// Back to the end. The scroll waits for the next turn of the run loop, once per turn:
    /// scrolling inside the scroll view's own update re-estimates the lazy rows, which changes
    /// the geometry again, and AppKit aborts on the constraint loop.
    private func follow(_ proxy: ScrollViewProxy) {
        guard !track.followPending else { return }
        track.followPending = true
        DispatchQueue.main.async {
            track.followPending = false
            guard following, !track.userScrolling else { return }
            #if DEBUG
            // Perf task: the follow fires at most once per run-loop turn.
            os_signpost(.event, log: Self.followLog, name: "transcript.follow")
            TranscriptProbe.follows += 1
            #endif
            proxy.scrollTo(Self.end, anchor: .bottom)
        }
    }

    /// The rows of the turns built, in order (see `TranscriptRow`).
    private var rows: [TranscriptRow] {
        let turns = conversation.turns
        let first = firstShown
        let showThinking = verbosity.showsThinking
        var out: [TranscriptRow] = []
        for t in turns.indices where t >= first {
            let turn = turns[t]
            let start = out.count
            func add(_ part: TurnPart, _ key: String) {
                let leads = out.count == start
                out.append(TranscriptRow(turn: turn, part: part, first: leads,
                                         gap: space.gap(part, after: leads ? nil : out.last?.part, first: out.isEmpty),
                                         id: TranscriptRow.ID(turn: turn.id, part: key)))
            }
            if TurnView.hasHead(turn) { add(.head, "head") }
            for segment in flows.segments(of: turn, showThinking: showThinking) { add(.segment(segment), segment.id) }
            add(.tail, "tail")
        }
        return out
    }

    /// A turn's first row: where scrolling to the turn goes.
    private func firstRow(of turn: TurnState) -> TranscriptRow.ID {
        if TurnView.hasHead(turn) { return TranscriptRow.ID(turn: turn.id, part: "head") }
        let first = flows.segments(of: turn, showThinking: verbosity.showsThinking).first
        return TranscriptRow.ID(turn: turn.id, part: first?.id ?? "tail")
    }

    private var verbosity: Verbosity {
        VerbosityOverrides.shared.level(
            for: conversation.sessionID, default: Verbosity(rawValue: defaultVerbosity) ?? .normal)
    }

    /// Where the built turns start, in `conversation.turns`.
    private var firstShown: Int {
        let turns = conversation.turns
        guard let id = shownFrom ?? Self.start(of: turns, rows: Self.windowRows),
              let i = turns.firstIndex(where: { $0.id == id }) else { return 0 }
        return i
    }

    /// The turn that starts the last `rows` rows (items), counting back from the end.
    static func start(of turns: [TurnState], rows: Int, before end: Int? = nil) -> TurnState.ID? {
        var counted = 0
        var i = (end ?? turns.count) - 1
        while i > 0, counted + turns[i].items.count < rows {
            counted += max(1, turns[i].items.count)
            i -= 1
        }
        return turns.indices.contains(i) ? turns[i].id : turns.first?.id
    }

    /// You're at the top of what's built: build more above it, and keep the row that was at
    /// the top where it was. A lazy stack doesn't hold its place when rows go in above (it
    /// shows the new rows' estimated end instead), so it's put back by scrolling to that row,
    /// laid out for real; it was within `nearTop` of the top, so that's as far as it moves.
    private func showEarlier(_ proxy: ScrollViewProxy) {
        let first = firstShown
        guard first > 0, !growingAbove,
              let id = Self.start(of: conversation.turns, rows: Self.earlierRows, before: first) else {
            #if DEBUG
            TranscriptProbe.fillBlocked = first == 0 ? "at first turn" : (growingAbove ? "growing" : "no turns above")
            #endif
            return
        }
        let keep = firstRow(of: conversation.turns[first])
        #if DEBUG
        TranscriptProbe.earlier += 1
        // The row under it (prompts aren't counted as mounted, segments are).
        TranscriptProbe.kept = flows.segments(of: conversation.turns[first], showThinking: verbosity.showsThinking).first?.id ?? keep.part
        #endif
        growingAbove = true
        shownFrom = id
        // Again as the rows around it measure (each changes the estimate of the rest).
        DispatchQueue.main.async {
            proxy.scrollTo(keep, anchor: .top)
            DispatchQueue.main.async { proxy.scrollTo(keep, anchor: .top) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                proxy.scrollTo(keep, anchor: .top)
                growingAbove = false
                #if DEBUG
                // The fill is settled (its last keep-scroll ran): this is the signal the
                // scroll-up benchmark waits on before it samples what stayed on screen.
                TranscriptProbe.fillSettles += 1
                #endif
            }
        }
    }

    /// The answer being written now, when it's the last thing in the transcript: whether it's
    /// the turn's first words (nothing ran before it), for where a long one stops.
    private var liveAnswer: (turn: TurnState.ID, item: String, first: Bool)? {
        guard let turn = conversation.turns.last, let last = turn.items.last,
              last.kind == .message, !last.done else { return nil }
        let first = !turn.items.dropLast().contains { if case .tool = $0.kind { true } else { false } }
        return (turn.id, last.id, first)
    }

    /// Where the view is against the end of the content.
    private struct ScrollEnd: Equatable {
        let contentHeight: CGFloat
        let atBottom: Bool
        /// Content below the view.
        let below: CGFloat
        /// The top of the visible area, in content coordinates.
        let visibleTop: CGFloat
        /// The whole visible area is below the end of the content.
        let pastEnd: Bool

        init(_ g: ScrollGeometry) {
            pastEnd = g.contentSize.height > 0 && g.visibleRect.minY >= g.contentSize.height - 1
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

    /// The transcript's content, for measuring where a turn (or an answer) starts in it.
    static let content = "transcript-content"

    #if DEBUG
    /// For the perf task: the deferred, coalesced follow-scroll signpost. Instruments' "Points
    /// of Interest" misses `OSLog.pointsOfInterest` under explicit modules, so a named one.
    static let followLog = OSLog(subsystem: "toys.frog", category: "transcript-follow")
    #endif

    /// A row at the very end of the transcript, below the last turn and its indicators.
    private static let end = "transcript-end"

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                #if os(macOS)
                // On the Mac every turn's footer (model, cost, speed, energy) is hover-only,
                // the last one too: nothing pinned under the answer at rest.
                let footers = Set<TurnState.ID>()
                #else
                // No hover on a phone: the footers that matter stay pinned.
                let footers = TurnFooter.pinned(conversation.turns) { ModelStats.shared.cost(of: $0) }
                #endif
                let lastTurn = conversation.turns.last?.id
                // The transcript's first line: the last compaction's banner. Replay and
                // reopen keep it (a durable event); sessions compacted before receipts
                // existed show nothing.
                if let kept = conversation.carriedForward {
                    CarriedForwardBanner(kept: kept)
                }
                // A row per piece of each turn: only what's on screen is built (see `TurnPart`).
                ForEach(rows) { row in
                    TurnView(turn: row.turn, conversation: conversation, actions: actions, part: row.part,
                             gap: row.gap, pinsFooter: footers.contains(row.turn.id))
                        .equatable()
                        .id(row.id)
                        .background {
                            if row.first, row.turn.id == lastTurn {
                                Color.clear.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(Self.content)).minY }) {
                                    track.lastTurnTop = $0
                                }
                            }
                        }
                }
                if let q = conversation.question {
                    QuestionCard(question: q, conversation: conversation)
                        .padding(.top, space.turn)
                        .id(q.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let e = conversation.elicitation {
                    ElicitationCard(request: e, conversation: conversation)
                        .padding(.top, space.turn)
                        .id(e.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                // The running turn's live line shows progress once there's something to show.
                // A busy state with no live engine behind it (the stream died mid-turn) doesn't:
                // it's a stale window until the watchdog reconciles from the log.
                // (Not over the newest rows read from the log: they're the transcript already.)
                if conversation.replaying, conversation.turns.isEmpty {
                    LoadingIndicator(since: conversation.opened)
                        .padding(.top, space.turn)
                } else if conversation.busy, conversation.engineAlive, conversation.permission == nil,
                   conversation.elicitation == nil, conversation.question == nil,
                   conversation.turns.last?.items.isEmpty ?? true {
                    WorkingIndicator(progress: conversation.progress, since: conversation.progressSince)
                        .padding(.top, space.turn)
                }
                if let preview = conversation.presentPreview {
                    PresentCard(present: preview)
                        .opacity(0.85)
                        .padding(.top, space.turn)
                        .transition(.opacity)
                }
                if let failure = conversation.failure {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(failure, systemImage: "exclamationmark.octagon")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        // A worktree another engine holds: one press goes to the session that
                        // owns it (its window, or its transcript here) instead of leaving the
                        // user to hunt for the id in the line above.
                        if let owner = conversation.heldBy, openSessionID != nil {
                            Button { openSessionID?(owner) } label: {
                                Label("Open \(owner)", systemImage: "arrow.up.forward.square")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, space.turn)
                }
                if conversation.overflowRescue {
                    OverflowRescueView(conversation: conversation)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Color.clear.frame(height: space.turn).id(Self.end)
            }
            .scrollTargetLayout()
            .coordinateSpace(.named(Self.content))
            .environment(\.turnSpace, space)
            .frame(maxWidth: TurnSpace.measure)
            .padding(.horizontal, TurnSpace.gutter)
            .padding(.top, TurnSpace.top)
            .padding(.bottom, TurnSpace.bottom)
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
        .mask { TranscriptMask(topInset: topInset, track: track) }
        .onScrollTargetVisibilityChange(idType: TranscriptRow.ID.self, threshold: 0.05) { ids in
            var seen = Set<TurnState.ID>()
            onVisibleTurns(ids.map(\.turn).filter { seen.insert($0).inserted })
        }
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

    var body: some View {
        let (message, contexts) = PromptContext.split(text)
        VStack(alignment: .trailing, spacing: TurnSpace.Inset.snug) {
            if !images.isEmpty {
                HStack(spacing: TurnSpace.Inset.snug) {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                        if let ns = img.image {
                            Image(platformImage: ns)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: images.count == 1 ? 220 : 110, height: images.count == 1 ? 150 : 80)
                                .clipShape(.rect(cornerRadius: 12))
                                
                                .opensInLightbox(images, at: i)
                        }
                    }
                }
            }
            if !message.isEmpty {
                Text(message)
                    .font(.frog(size: TurnType.body))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, TurnSpace.Inset.roomy + TurnSpace.Inset.tight)
                    .padding(.vertical, TurnSpace.Inset.snug + TurnSpace.Inset.tight)
                    // Neutral raised gray: the prompt is you, not the place that served
                    // you. Where it ran shows in the model pill and the turn's footer.
                    // 14×10 padding: the bubble hugs closer than the web's `.me` (9×13 at
                    // 12px text) scaled up, so a short prompt doesn't float in a grey slab.
                    .foregroundStyle(Tokens.text)
                    .background(Tokens.bubble, in: .rect(cornerRadius: Tokens.Radius.bubble, style: .continuous))
            }
            ForEach(contexts) { ContextDisclosure(context: $0) }
        }
        .frame(maxWidth: TurnSpace.promptWidth, alignment: .trailing)
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
        VStack(alignment: .trailing, spacing: TurnSpace.Inset.snug) {
            Button {
                withAnimation(Motion.quick(reduced: reduceMotion)) { open.toggle() }
            } label: {
                HStack(spacing: TurnSpace.Inset.tight) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(context.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, TurnSpace.Inset.card)
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
                    .padding(TurnSpace.Inset.roomy)
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
                HStack(spacing: TurnSpace.Inset.card) {
                    // Where it ran, then what it cost (cloud) or how fast it wrote.
                    if let spec = usage.model {
                        // A Frog Cloud turn takes the color of who served it, not cloud green.
                        ModelLabel(model: ModelIdentity.of(spec, in: models), size: .caption, tint: usage.servedBy.map(Color.served))
                    }
                    if let s = usage.servedBy {
                        Text(s.name).foregroundStyle(Color.served(s))
                    }
                    // What it cost (cloud) or how fast it wrote; each opens its working.
                    if let c = ModelStats.shared.cost(of: usage) {
                        PriceHint(cost: c, usage: usage)
                    } else if let tps = usage.tokensPerSec, tps > 0 {
                        Text(ModelStats.speedText(tps))
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
        case .maxTokens(let autoContinued):
            banner(
                autoContinued == 0
                    ? "Hit the output token limit"
                    : "Hit the output token limit (auto-continued \(autoContinued)x)",
                symbol: "text.append",
                color: .orange
            )
        case .looping:
            banner("Stopped: the model kept repeating the same tool call", symbol: "arrow.trianglehead.2.clockwise", color: .orange)
        case .stepLimit:
            banner("Stopped at the step limit. Say “continue” to keep going.", symbol: "flag.checkered", color: .orange)
        case .blockedOnApproval(let denial):
            banner("Stopped: retried a call that was already denied (\(denial))", symbol: "hand.raised", color: .orange)
        case .billingLimit(let b):
            BillingEndView(limit: b)
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

/// Out of credit (`EndReason.billingLimit`): the one end that's about money, not a model
/// failure. Styled like the calm system rows (muted, not red), with the fix right there:
/// "add credit" opens the account page the settings use (BillingSettings' billing link).
struct BillingEndView: View {
    let limit: BillingLimit

    var body: some View {
        HStack(spacing: TurnSpace.Inset.row) {
            Label("out of credit", systemImage: "creditcard")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Link("add credit", destination: URL(string: "https://frog.toys/?settings=billing")!)
                .font(.callout)
        }
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
            HStack(spacing: TurnSpace.Inset.row) {
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
            VStack(alignment: .leading, spacing: TurnSpace.Inset.snug) {
                HStack(alignment: .firstTextBaseline, spacing: TurnSpace.Inset.card) {
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
    /// A hop is playing (it lasts one `FrogPose.hop` period).
    @State private var hopping = false

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
        VStack(spacing: TurnSpace.Inset.card) {
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
                    .padding(.top, TurnSpace.Inset.snug)
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
        VStack(spacing: TurnSpace.Inset.tight) {
            ZStack(alignment: .bottom) {
                LilyPad()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(width: 76, height: 26)
                    .offset(y: 4)
                // Still until hovered or hopping: its idle loop at 30 frames a second kept an
                // empty window at about 10% of a core.
                FrogFace(mood: .idle, size: 48, hop: hop, animating: hovering || hopping)
                    .anchorPreference(key: FrogAnchorKey.self, value: .bounds) { $0 }
            }
            .padding(.top, TurnSpace.Inset.tight)
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
        .task(id: hop) {
            guard hop > 0 else { return }
            hopping = true
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { hopping = false }
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

/// Where the transcript is against its end, kept off the view's own state: geometry callbacks
/// write it on every scroll and every line of growth, and only what reads `unseen` or
/// `moreBelow` (the pill and the bottom fade) updates when those flip.
@MainActor @Observable
final class ScrollTrack {
    /// Something new came in below where you stopped, and it's still out of view.
    private(set) var unseen = false
    /// The turn the pointer is over, any of its rows: its footer shows.
    var hoveredTurn: TurnState.ID?
    /// Text carries on below the view (the soft bottom edge).
    private(set) var moreBelow = false

    /// Stopped short of the end, with more below (stopped at a long answer's start, or you
    /// scrolled up while it wrote): the pill offers the way down.
    @ObservationIgnored private(set) var parked = false
    /// How tall the content was when the view stopped following: the pill only shows once
    /// something new has come in past it, not for what was already there.
    @ObservationIgnored private var parkedHeight: CGFloat?
    @ObservationIgnored private var below: CGFloat = 0
    @ObservationIgnored private var height: CGFloat = 0
    @ObservationIgnored var userScrolling = false
    /// A follow scroll is queued for the next run-loop turn; coalesces bursts of growth.
    @ObservationIgnored var followPending = false
    /// Where the last turn starts, in the content.
    @ObservationIgnored var lastTurnTop: CGFloat = .infinity
    /// Where the answer being written starts, in the content (reported by its row).
    @ObservationIgnored var answer: (item: String, top: CGFloat)?
    /// The view is near the top of what's built (see `TranscriptView.nearTop`).
    @ObservationIgnored var atTop = false
    /// It has been at the end once: it opened.
    @ObservationIgnored var openedAtEnd = false
    func answerTop(_ item: String) -> CGFloat? {
        answer?.item == item ? answer?.top : nil
    }

    func park(at contentHeight: CGFloat) {
        if !parked { parkedHeight = contentHeight }
        parked = true
        refresh()
    }

    func unpark() {
        parked = false
        refresh()
    }

    func measured(below: CGFloat, height: CGFloat) {
        self.below = below
        self.height = height
        refresh()
    }

    /// Observed values are written only when they change: each write would update their readers.
    private func refresh() {
        // More than a line: the thinking row changing size doesn't count.
        let unseen = parked && below > 30 && parkedHeight.map { height - $0 > 40 } == true
        if unseen != self.unseen { self.unseen = unseen }
        let more = below > 8
        if more != moreBelow { moreBelow = more }
    }
}

extension EnvironmentValues {
    /// The transcript's scroll tracking, for rows that report where they are (the live answer).
    @Entry var transcriptTrack: ScrollTrack? = nil
}

/// The toolbar fade at the top and, where the text carries on below the view, a soft edge.
private struct TranscriptMask: View {
    let topInset: CGFloat
    let track: ScrollTrack

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(0, topInset - 12))
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(track.moreBelow ? 0.05 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
        }
        .ignoresSafeArea()
    }
}

/// The pill, when something new came in below where you're reading.
private struct NewBelowPill: View {
    let track: ScrollTrack
    let writing: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if track.unseen {
                NewBelow(writing: writing, action: action)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
            }
        }
        .animation(Motion.quick(reduced: reduceMotion), value: track.unseen)
    }
}

/// The way down to a message that came in below where you're reading.
private struct NewBelow: View {
    let writing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: TurnSpace.Inset.snug) {
                Image(systemName: "arrow.down")
                    .symbolEffect(.pulse, options: .repeating, isActive: writing)
                Text("New message")
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, TurnSpace.Inset.row)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Go to the end and follow the answer")
    }
}

/// One row of the transcript's lazy stack: a piece of a turn (see `TurnPart`).
struct TranscriptRow: Identifiable {
    struct ID: Hashable {
        let turn: TurnState.ID
        /// "head", "tail", or the segment's id.
        let part: String
    }

    let turn: TurnState
    let part: TurnPart
    /// The turn's first row.
    let first: Bool
    let gap: CGFloat
    let id: ID
}

/// Finished turns' flows, by turn: a finished turn's rows only change when items are added
/// to it (a notice) or the thinking setting changes. The running turn's is cached too, keyed
/// by a signature of what the segmentation can depend on (identity, kinds, done, text
/// emptiness, the visual flags): re-deriving the segments (the activity groups, the visual
/// scan) on every streamed chunk was O(turn) per 30 Hz batch per mounted turn (see the
/// perf-structural notes). Never the streaming text itself.
@MainActor
final class FlowCache {
    private struct Entry {
        var count: Int
        var thinking: Bool
        var signature: String?
        var segments: [TurnFlow.Segment]
    }
    private var flows: [TurnState.ID: Entry] = [:]

    func segments(of turn: TurnState, showThinking: Bool) -> [TurnFlow.Segment] {
        if let hit = flows[turn.id], hit.count == turn.items.count, hit.thinking == showThinking {
            if turn.finished, hit.signature == nil { return hit.segments }
            if !turn.finished, hit.signature == Self.signature(of: turn) { return hit.segments }
        }
        let segments = TurnFlow(turn.items, showThinking: showThinking).segments
        flows[turn.id] = Entry(count: turn.items.count, thinking: showThinking,
                               signature: turn.finished ? nil : Self.signature(of: turn), segments: segments)
        return segments
    }

    /// What the segmentation can depend on, item by item: identity, kind, done, and the flags
    /// `TurnFlow` reads. Text *emptiness* (a message that hasn't said anything doesn't break
    /// the group) and a thought's `isShort` (a short one is dropped), not the text itself — so
    /// a streaming answer's growing text leaves the signature alone and the segments stay
    /// cached between item boundaries.
    private static func signature(of turn: TurnState) -> String {
        var out = ""
        out.reserveCapacity(turn.items.count * 16)
        for item in turn.items {
            let kind: String
            switch item.kind {
            case .message: kind = item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "me" : "M"
            case .reasoning: kind = ActivityGroup.isShort(item) ? "rs" : "RL"
            case .tool(let name, _): kind = "t:" + name
            case .notice(let warning): kind = warning ? "nw" : "n"
            }
            out += "\(item.id)|\(kind)|\(item.done ? "d" : "u")|"
            if item.imagePreview != nil { out += "v" }
            if let r = item.result {
                out += "\(r.present != nil ? "p" : "-")\(r.app != nil ? "a" : "-")\((r.images ?? []).isEmpty ? "-" : "i")\(r.diagram != nil ? "d" : "-")\(r.diff != nil ? "f" : "-")"
            }
            out += "|"
        }
        return out
    }
}
