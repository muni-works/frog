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

    static func reset() {
        rowBodies = 0
        turnBodies = 0
        follows = 0
        inkStyles = 0
        inkStyledChars = 0
    }

    /// For `let _ = TranscriptProbe.row()` inside a view builder.
    @discardableResult static func row() -> Int { rowBodies += 1; return rowBodies }
    @discardableResult static func turn() -> Int { turnBodies += 1; return turnBodies }
}
#endif
