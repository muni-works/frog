#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// Which container the Mac transcript uses. The lazy stack is the default; the table
/// (`TableTranscript`) is behind this switch until it has every behaviour the stack has (see
/// docs/plans/mac-transcript-table-2026-11-11.md for what's missing).
///
///     defaults write toys.frog.dev transcriptTable -bool YES     # or FROG_TRANSCRIPT_TABLE=1
enum TranscriptContainer {
    nonisolated(unsafe) static var table: Bool = {
        if let v = ProcessInfo.processInfo.environment["FROG_TRANSCRIPT_TABLE"] { return v != "0" }
        return UserDefaults.standard.bool(forKey: "transcriptTable")
    }()
}

/// Lets the SwiftUI around the table (the "new message" pill) drive it.
@MainActor
final class TableTranscriptHandle {
    weak var controller: TableTranscriptController?
    func toEnd() { controller?.toEnd() }
}

/// The transcript as an `NSTableView`: one row per `TranscriptRow` (a turn's head, each
/// segment of its flow, its tail), the same `TurnView`s the lazy stack shows, hosted per row.
///
/// What the table buys over the lazy stack: rows it isn't showing are a cached height, not a
/// view the stack must make to place. A jump lands on a row without building the ones it
/// passes; a live resize lays out only the rows on screen; a streamed answer growing a line
/// re-measures that one row (it reports its own height) instead of the stack re-placing
/// everything after an estimate.
struct TableTranscript: NSViewRepresentable {
    let conversation: Conversation
    let actions: TurnActions
    var jump: Binding<TurnState.ID?>
    var onVisibleTurns: ([TurnState.ID]) -> Void
    let track: ScrollTrack
    let space: TurnSpace.Scale
    let showThinking: Bool
    let handle: TableTranscriptHandle
    /// The toolbar above and the composer below, which the content scrolls under.
    var insets = EdgeInsets()

    func makeCoordinator() -> TableTranscriptController {
        TableTranscriptController(conversation: conversation, actions: actions, track: track)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        handle.controller = c
        c.environment = context.environment
        c.configure(space: space, showThinking: showThinking)
        return c.scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let c = context.coordinator
        handle.controller = c
        c.environment = context.environment
        c.onVisibleTurns = onVisibleTurns
        c.configure(space: space, showThinking: showThinking)
        c.setInsets(top: insets.top, bottom: insets.bottom)
        if let id = jump.wrappedValue {
            // Not inside SwiftUI's update: the binding, and the scroll (rows may still be coming).
            DispatchQueue.main.async {
                jump.wrappedValue = nil
                c.jump(to: id)
            }
        }
    }

    /// It fills what it's offered. Without this SwiftUI asks the scroll view for its fitting
    /// size, and AppKit answers by walking constraints through every row's hosting view: on
    /// each layout pass of the window, most of streaming's cost in the table.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: TableTranscriptController) {
        coordinator.stop()
    }
}

/// The scroll view, so your own scrolling (not the table's) is what stops following.
final class TranscriptScrollView: NSScrollView {
    var userScrolled: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        userScrolled?()
    }
}

final class TranscriptTableView: NSTableView {
    // Rows are content, not a list: no row selection, no type-select, no focus ring.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    /// Only the rows on screen: AppKit's responsive scrolling prepares rows well past the visible
    /// rect, and each of ours is a hosting view with a text view and its code blocks. Building
    /// them ahead put them in the frame that scrolled, not before it.
    override func prepareContent(in rect: NSRect) {
        super.prepareContent(in: visibleRect)
    }
}

/// One row: a hosting view for whatever the entry shows. Reused for any entry; the content's
/// identity (`.id`) is the entry's, so a reused cell never carries another row's state.
final class TranscriptRowCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("transcript-row")
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    var entryID: AnyHashable?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

@MainActor
final class TableTranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Entry {
        case top
        case banner
        case row(TranscriptRow)
        case trailer
        case end

        var id: AnyHashable {
            switch self {
            case .top: "top"
            case .banner: "banner"
            case .row(let r): r.id
            case .trailer: "trailer"
            case .end: "end"
            }
        }
    }

    let scroll = TranscriptScrollView()
    let table = TranscriptTableView()
    let conversation: Conversation
    let actions: TurnActions
    let track: ScrollTrack
    var environment = EnvironmentValues()
    var onVisibleTurns: ([TurnState.ID]) -> Void = { _ in }

    private var entries: [Entry] = []
    private var index: [AnyHashable: Int] = [:]
    private let flows = FlowCache()
    private var space = TurnSpace.scale(Density.comfortable.rawValue)
    private var showThinking = true
    private var configured = false
    /// Each row's own height (reported by its content), at the width it was laid out at.
    /// Rows not on screen keep the last height they had, at any width: a good guess until
    /// they're shown again, and what makes a live resize cost only the rows on screen.
    private var heights: [AnyHashable: CGFloat] = [:]
    private var pendingHeights: Set<Int> = []
    private var flushPending = false
    private var refreshPending = false
    private var stopped = false
    /// Keeping to the end as content grows.
    private(set) var following = true
    private var programmatic = false
    private var liveScrolling = false
    private var lastVisible: [TurnState.ID] = []
    private var insetTop: CGFloat = 0
    private var insetBottom: CGFloat = 0
    private var opened = false

    init(conversation: Conversation, actions: TurnActions, track: ScrollTrack) {
        self.conversation = conversation
        self.actions = actions
        self.track = track
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsTypeSelect = false
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.userScrolled = { [weak self] in self?.userScrolled() }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        nc.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        nc.addObserver(self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    }

    func stop() {
        stopped = true
        NotificationCenter.default.removeObserver(self)
    }

    func configure(space: TurnSpace.Scale, showThinking: Bool) {
        guard !configured || space != self.space || showThinking != self.showThinking else { return }
        let first = !configured
        configured = true
        self.space = space
        self.showThinking = showThinking
        if first { refresh() } else { heights.removeAll(); reload() }
    }

    func setInsets(top: CGFloat, bottom: CGFloat) {
        guard top != insetTop || bottom != insetBottom else { return }
        insetTop = top
        insetBottom = bottom
        scroll.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if following { followSoon() }
    }

    // MARK: Rows

    /// Re-derive the rows, observing what they read: a change to the conversation's turns
    /// schedules another pass, at most one per turn of the run loop (a burst of events, or of
    /// 30 Hz delta batches, is one update). The streaming answer's words aren't in `turns`
    /// (see `LiveText`): its row updates itself and reports its new height.
    private func refresh() {
        refreshPending = false
        guard !stopped else { return }
        let next = withObservationTracking {
            computeEntries()
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }
        apply(next)
    }

    private func scheduleRefresh() {
        guard !refreshPending, !stopped else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func computeEntries() -> [Entry] {
        var out: [Entry] = [.top]
        if conversation.carriedForward != nil { out.append(.banner) }
        for r in TranscriptView.rows(of: conversation.turns, from: 0, flows: flows, showThinking: showThinking, space: space) {
            out.append(.row(r))
        }
        out.append(.trailer)
        out.append(.end)
        return out
    }

    private func turnView(_ r: TranscriptRow) -> TurnView {
        TurnView(turn: r.turn, conversation: conversation, actions: actions, part: r.part, gap: r.gap, pinsFooter: false)
    }

    /// Whether a row shows something different now.
    private func changed(_ a: Entry, _ b: Entry) -> Bool {
        switch (a, b) {
        case (.row(let x), .row(let y)): !(turnView(x) == turnView(y))
        case (.banner, .banner): true
        default: false
        }
    }

    private func apply(_ next: [Entry]) {
        let old = entries
        let oldIDs = old.map(\.id), newIDs = next.map(\.id)
        defer { if !opened, !entries.isEmpty { opened = true; scrollToEnd() } }
        if oldIDs == newIDs {
            entries = next
            for i in next.indices where changed(old[i], next[i]) { updateCell(at: i) }
            return
        }
        // Common prefix and suffix by id; one run inserted or removed between them is the usual
        // case (a new row at the end of the last turn, ahead of the trailer).
        var p = 0
        while p < old.count, p < next.count, oldIDs[p] == newIDs[p] { p += 1 }
        var q = 0
        while q < old.count - p, q < next.count - p, oldIDs[old.count - 1 - q] == newIDs[next.count - 1 - q] { q += 1 }
        let removed = old.count - p - q, inserted = next.count - p - q
        // Where the view is, to put it back in the same pass: rows going in above it (older
        // history folding in) must not show for a frame at the old offset.
        let anchor = opened ? anchorRow() : nil
        entries = next
        rebuildIndex()
        if removed == 0 || inserted == 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                if removed > 0 { table.removeRows(at: IndexSet(p..<(p + removed)), withAnimation: []) }
                if inserted > 0 { table.insertRows(at: IndexSet(p..<(p + inserted)), withAnimation: []) }
            }
            if following { scrollToEnd() } else if let anchor { restore(anchor) }
            for i in 0..<p where changed(old[i], next[i]) { updateCell(at: i) }
            for k in 0..<q where changed(old[old.count - 1 - k], next[next.count - 1 - k]) { updateCell(at: next.count - 1 - k) }
        } else {
            reload(anchor: anchor)
        }
        if following { followSoon() }
    }

    private func rebuildIndex() {
        index.removeAll(keepingCapacity: true)
        for (i, e) in entries.enumerated() { index[e.id] = i }
    }

    /// Everything again, keeping the row at the top of the view where it was.
    private func reload(anchor given: (id: AnyHashable, offset: CGFloat)?? = nil) {
        let anchor = given ?? anchorRow()
        rebuildIndex()
        table.reloadData()
        if following { scrollToEnd() } else if let anchor { restore(anchor) }
    }

    private func anchorRow() -> (id: AnyHashable, offset: CGFloat)? {
        let visible = scroll.documentVisibleRect
        let row = table.row(at: NSPoint(x: 1, y: visible.minY + insetTop))
        guard row >= 0, row < entries.count else { return nil }
        return (entries[row].id, table.rect(ofRow: row).minY - visible.minY)
    }

    private func restore(_ anchor: (id: AnyHashable, offset: CGFloat)) {
        guard let row = index[anchor.id] else { return }
        scrollTo(y: table.rect(ofRow: row).minY - anchor.offset)
    }

    private func updateCell(at row: Int) {
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptRowCell else { return }
        fill(cell, row: row)
    }

    // MARK: Content

    private func fill(_ cell: TranscriptRowCell, row: Int) {
        let entry = entries[row]
        cell.entryID = entry.id
        let id = entry.id
        let content = AnyView(view(for: entry)
            .environment(\.self, environment)
            .environment(\.turnSpace, space)
            .environment(\.transcriptTrack, track)
            .frame(maxWidth: TurnSpace.measure, alignment: .leading)
            .padding(.horizontal, TurnSpace.gutter)
            .frame(maxWidth: .infinity)
            // Its own height, whatever the row's is now: reported, and the row follows.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] h in
                self?.reported(id, h)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(id))
        cell.host.rootView = content
    }

    @ViewBuilder
    private func view(for entry: Entry) -> some View {
        switch entry {
        case .top:
            Color.clear.frame(height: TurnSpace.top)
        case .banner:
            if let kept = conversation.carriedForward { CarriedForwardBanner(kept: kept) }
        case .row(let r):
            turnView(r).equatable()
        case .trailer:
            VStack(alignment: .leading, spacing: 0) { TranscriptTrailer(conversation: conversation) }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .end:
            Color.clear.frame(height: space.turn + TurnSpace.bottom)
        }
    }

    /// A row's content laid out at a new height.
    private func reported(_ id: AnyHashable, _ height: CGFloat) {
        let h = max(1, ceil(height))
        guard heights[id] != h else { return }
        if heights[id] == nil { learn(id, h) }
        heights[id] = h
        guard let row = index[id] else { return }
        pendingHeights.insert(row)
        // Not from inside the hosting view's layout: once, after it.
        guard !flushPending else { return }
        flushPending = true
        DispatchQueue.main.async { [weak self] in self?.flushHeights() }
    }

    private func flushHeights() {
        flushPending = false
        guard !pendingHeights.isEmpty else { return }
        let rows = pendingHeights.filter { $0 < entries.count }
        pendingHeights.removeAll()
        let visible = scroll.documentVisibleRect
        // Rows above the view that changed height move what you're reading: put it back.
        var above: CGFloat = 0
        if !following {
            for r in rows {
                let rect = table.rect(ofRow: r)
                if rect.maxY <= visible.minY + insetTop + 1 { above += (heights[entries[r].id] ?? rect.height) - rect.height }
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(rows))
        }
        if above != 0 { scrollTo(y: visible.minY + above) }
        if following {
            if !parkAtLongAnswer() { scrollToEnd() }
        }
        report()
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let entry = entries[row]
        if let h = heights[entry.id] { return h }
        return estimate(entry)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: TranscriptRowCell.identifier, owner: self) as? TranscriptRowCell)
            ?? TranscriptRowCell(frame: .zero)
        fill(cell, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// A row's height before it has ever been shown: what rows of its kind have measured so
    /// far (a text row by its line count). It's corrected the first time the row is on screen,
    /// keeping the view still if it's above; the closer the guess, the fewer rows a scroll
    /// builds only to find they didn't fit.
    private func estimate(_ entry: Entry) -> CGFloat {
        switch entry {
        case .top: return TurnSpace.top
        case .end: return space.turn + TurnSpace.bottom
        case .banner: return 40
        case .trailer: return 1
        case .row(let r):
            let (kind, units) = Self.shape(r)
            let per = learned[kind].map { $0.sum / max(1, $0.count) } ?? Self.fallback(kind)
            return r.gap + per * units
        }
    }

    /// A row's kind for estimating, and how many of that kind's unit it is (lines, for text).
    private static func shape(_ r: TranscriptRow) -> (String, CGFloat) {
        switch r.part {
        case .head: return ("head", 1)
        case .tail: return ("tail", 1)
        case .segment(let s):
            switch s {
            case .text(let item):
                let text = item.text
                let breaks = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
                return ("text-line", CGFloat(max(1, text.utf8.count / 90 + breaks + 1)))
            case .activity: return ("activity", 1)
            case .visual: return ("visual", 1)
            case .notice: return ("notice", 1)
            }
        }
    }

    private static func fallback(_ kind: String) -> CGFloat {
        ["head": 48, "tail": 24, "text-line": 21, "activity": 24, "visual": 220, "notice": 28][kind] ?? 30
    }

    /// Measured heights per unit, by kind (see `estimate`).
    private var learned: [String: (sum: CGFloat, count: CGFloat)] = [:]

    private func learn(_ id: AnyHashable, _ height: CGFloat) {
        guard let row = index[id], case .row(let r) = entries[row] else { return }
        let (kind, units) = Self.shape(r)
        var l = learned[kind] ?? (0, 0)
        // Recent rows weigh most: a long session's early rows may be a different shape.
        if l.count >= 64 { l = (l.sum * 0.5, l.count * 0.5) }
        l.sum += max(0, height - r.gap) / units
        l.count += 1
        learned[kind] = l
    }

    // MARK: Scrolling

    private var maxY: CGFloat {
        max(-insetTop, table.frame.height - scroll.contentView.bounds.height + insetBottom)
    }

    private var atBottom: Bool { scroll.contentView.bounds.minY >= maxY - 24 }

    private func scrollTo(y: CGFloat) {
        programmatic = true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(-insetTop, y), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        programmatic = false
    }

    func scrollToEnd() {
        // The document's height, not a layout: laying the rows out first would build the
        // ones at the old offset (rows that just went in above, say) only to scroll past them.
        table.tile()
        scrollTo(y: maxY)
        #if DEBUG
        TranscriptProbe.follows += 1
        #endif
    }

    private var followQueued = false
    private func followSoon() {
        guard !followQueued else { return }
        followQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            followQueued = false
            if following, !liveScrolling { scrollToEnd() }
        }
    }

    func toEnd() {
        following = true
        track.unpark()
        scrollToEnd()
    }

    func jump(to id: TurnState.ID) {
        guard let row = entries.firstIndex(where: { if case .row(let r) = $0 { r.turn.id == id } else { false } }) else { return }
        following = false
        scrollTo(y: table.rect(ofRow: row).minY - insetTop)
        report()
    }

    /// Keeping to the end would push the answer being written above the top of the view: stop
    /// at its start instead, and read from there (as the lazy stack does).
    private func parkAtLongAnswer() -> Bool {
        guard conversation.busy, let turn = conversation.turns.last, let last = turn.items.last,
              last.kind == .message, !last.done else { return false }
        let first = !turn.items.dropLast().contains { if case .tool = $0.kind { true } else { false } }
        let rowID = first ? (TurnView.hasHead(turn) ? TranscriptRow.ID(turn: turn.id, part: "head") : TranscriptRow.ID(turn: turn.id, part: last.id))
            : TranscriptRow.ID(turn: turn.id, part: last.id)
        guard let row = index[rowID] else { return false }
        let top = table.rect(ofRow: row).minY
        let clip = scroll.contentView.bounds.height - insetTop - insetBottom
        guard table.frame.height - top > clip + 4 else { return false }
        following = false
        track.park(at: table.frame.height)
        scrollTo(y: top - insetTop)
        return true
    }

    private func userScrolled() {
        following = atBottom
        if following { track.unpark() } else if conversation.busy || track.parked { track.park(at: table.frame.height) }
    }

    @objc private func liveScrollStarted() { liveScrolling = true; track.userScrolling = true }
    @objc private func liveScrollEnded() {
        liveScrolling = false
        track.userScrolling = false
        userScrolled()
    }

    @objc private func boundsChanged() {
        if !programmatic, liveScrolling { following = atBottom }
        report()
    }

    /// Where the view is: for the pill, the soft bottom edge and the timeline rail.
    private func report() {
        let visible = scroll.contentView.bounds
        let below = max(0, table.frame.height - (visible.maxY - insetBottom))
        track.measured(below: below, height: table.frame.height)
        let range = table.rows(in: visible)
        var seen = Set<TurnState.ID>()
        var turns: [TurnState.ID] = []
        for i in range.location..<(range.location + range.length) where i < entries.count {
            if case .row(let r) = entries[i], seen.insert(r.turn.id).inserted { turns.append(r.turn.id) }
        }
        guard turns != lastVisible else { return }
        lastVisible = turns
        onVisibleTurns(turns)
    }
}
#endif
