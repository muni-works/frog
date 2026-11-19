#if DEBUG
/// Counters for the streaming benchmark (`TranscriptStreamBenchmarkTests`): how often the
/// transcript rebuilds its rows and turns, and how often it chases the bottom. A row body that
/// runs once per inserted row is incremental; one that runs for every row on every insert is a
/// full-transcript relayout, and shows up as rows² here. Debug builds only.
@MainActor
enum TranscriptProbe {
    /// Row bodies built (`ActivityLine`, `ItemView`).
    static var rowBodies = 0
    /// `TurnView` bodies built.
    static var turnBodies = 0
    /// Follow scrolls issued while streaming.
    static var follows = 0
    /// InkReveal restyles, and the characters they touched.
    static var inkStyles = 0
    static var inkStyledChars = 0
    /// Rows on screen now (appeared and not yet disappeared), and the most there ever were:
    /// a virtualized transcript keeps these to the visible set, whatever the session's length.
    static var mountedRows: Int { mounted.count }
    static var peakMountedRows = 0
    /// Times the transcript built more rows above (`showEarlier`).
    static var earlier = 0
    /// Fills that have settled: the fill's last keep-scroll ran and its reentrancy guard
    /// released (see `showEarlier`), so its kept row is where it ends up. For the scroll-up
    /// benchmark, which must not sample a fill before this.
    static var fillSettles = 0
    /// The row kept in place the last time (its segment id, or "head"/"tail").
    static var kept = ""
    /// Why the last `showEarlier` did nothing (the guard it stopped at), or "" when it ran.
    static var fillBlocked = ""
    /// The stack has been at its end once since it opened (`ScrollTrack.openedAtEnd`): until
    /// then, nearing its top builds nothing above.
    static var openedAtEnd = false
    /// What the stack's fill trigger saw, newest last: the view nearing or leaving the top of
    /// what's built, each fill, each guard that stopped one. The scroll-up benchmark prints it
    /// when no fill came, so an intermittent failure says where it stopped. The last 32 only
    /// (the app's own debug build runs this too).
    private(set) static var fillLog: [String] = []
    static func noteFill(_ what: String) {
        fillLog.append(what)
        if fillLog.count > 32 { fillLog.removeFirst(fillLog.count - 32) }
    }
    private static var mounted: Set<String> = []
    /// While set, only this conversation's rows count (`ObjectIdentifier(conversation).hashValue`,
    /// the keys' prefix): a test host keeps earlier tests' transcripts alive, and their rows
    /// coming and going counted as this one's (the scroll-up benchmark's 108 rows "built" against
    /// 23 on a full run, 2026-11-19).
    static var only: Int?

    static func reset() {
        rowBodies = 0
        turnBodies = 0
        follows = 0
        inkStyles = 0
        inkStyledChars = 0
        mounted = []
        only = nil
        peakMountedRows = 0
        earlier = 0
        fillSettles = 0
        fillBlocked = ""
        openedAtEnd = false
        fillLog = []
        sidebarBodies = 0
    }

    static var mountedKeys: Set<String> { mounted }
    static func isMounted(suffix: String) -> Bool { mounted.contains { $0.hasSuffix(suffix) } }

    /// A row (by a key unique across conversations) appeared or disappeared.
    static func mounted(_ key: String, _ on: Bool) {
        if let only, !key.hasPrefix("\(only)-") { return }
        if on { mounted.insert(key) } else { mounted.remove(key) }
        peakMountedRows = max(peakMountedRows, mounted.count)
    }

    /// For `let _ = TranscriptProbe.row()` inside a view builder.
    @discardableResult static func row() -> Int { rowBodies += 1; return rowBodies }
    @discardableResult static func turn() -> Int { turnBodies += 1; return turnBodies }
    /// `SessionList` body evaluations (the perf-structural branch: does a streamed delta
    /// re-run the sidebar? The bar was: a delta must not dirty the sidebar's subtree).
    static var sidebarBodies = 0
    @discardableResult static func sidebar() -> Int { sidebarBodies += 1; return sidebarBodies }
}
#endif
