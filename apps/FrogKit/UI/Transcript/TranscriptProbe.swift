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
    /// The row kept in place the last time (its segment id, or "head"/"tail").
    static var kept = ""
    private static var mounted: Set<String> = []

    static func reset() {
        rowBodies = 0
        turnBodies = 0
        follows = 0
        inkStyles = 0
        inkStyledChars = 0
        mounted = []
        peakMountedRows = 0
        earlier = 0
    }

    static var mountedKeys: Set<String> { mounted }
    static func isMounted(suffix: String) -> Bool { mounted.contains { $0.hasSuffix(suffix) } }

    /// A row (by a key unique across conversations) appeared or disappeared.
    static func mounted(_ key: String, _ on: Bool) {
        if on { mounted.insert(key) } else { mounted.remove(key) }
        peakMountedRows = max(peakMountedRows, mounted.count)
    }

    /// For `let _ = TranscriptProbe.row()` inside a view builder.
    @discardableResult static func row() -> Int { rowBodies += 1; return rowBodies }
    @discardableResult static func turn() -> Int { turnBodies += 1; return turnBodies }
}
#endif
