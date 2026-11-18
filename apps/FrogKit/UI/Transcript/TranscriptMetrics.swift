import SwiftUI

/// The transcript's rows as numbers, for parity with the web (`-FrogMetrics <path>`; format
/// `frog-transcript-metrics/1`, docs/design/parity/README.md, "Metrics"). Each row the transcript
/// draws reports its kind, its words, its box and where its first word starts, in the transcript
/// column's coordinates (x 0 is the column's text edge). Off unless the launch argument is set:
/// the modifiers below then do nothing.
@MainActor
final class TranscriptMetrics {
    static let shared = TranscriptMetrics()

    /// `-FrogMetrics <path>` was given.
    nonisolated static let enabled: Bool = !(UserDefaults.standard.string(forKey: "FrogMetrics") ?? "").isEmpty

    enum Kind: String { case prompt, thought, fold, line, prose, code, card, footer, live, stats }

    struct Row {
        var kind: Kind
        var text: String
        /// The row's box, in the column's coordinates.
        var box: CGRect
        /// Where its first visible character starts, in the column's coordinates.
        var firstX: CGFloat?
        var fontSize: CGFloat
    }

    private(set) var rows: [String: Row] = [:]
    /// The layout: pane and column widths, the gutter, and where the first line's mark is.
    var pane: CGFloat = 0
    var column: CGFloat = 0
    var gutter: CGFloat = 0
    var indent: CGFloat = 0

    func set(_ key: String, kind: Kind, text: String, box: CGRect, fontSize: CGFloat) {
        var row = rows[key] ?? Row(kind: kind, text: text, box: box, fontSize: fontSize)
        row.kind = kind
        row.text = kind == .stats ? Self.ticking(Self.collapse(text)) : Self.collapse(text)
        row.box = box
        row.fontSize = fontSize
        rows[key] = row
    }

    func setFirst(_ key: String, x: CGFloat) {
        rows[key]?.firstX = x
        pendingFirst[key] = x
    }

    /// A first word measured before its row's box (children lay out first).
    private var pendingFirst: [String: CGFloat] = [:]

    func remove(_ key: String) { rows[key] = nil }

    /// The stats' figures tick, so the dump writes every duration `#s` and every other run of
    /// digits `#` (docs/design/parity/README.md; metrics.mjs's own two replacements).
    static func ticking(_ s: String) -> String {
        let durations = s.replacingOccurrences(of: #"(\d+m )?\d+s\b"#, with: "#s", options: .regularExpression)
        return durations.replacingOccurrences(of: #"\d[\d,.]*"#, with: "#", options: .regularExpression)
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The dump, rows top to bottom, tops relative to the first row's, lengths rounded to 0.1.
    func json(width: CGFloat, height: CGFloat, look: String) -> Data {
        func r(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
        struct Entry { let key: String; let row: Row }
        let entries: [Entry] = rows.map { Entry(key: $0.key, row: $0.value) }.filter { !$0.row.text.isEmpty }
        let sorted = entries.sorted { (a: Entry, b: Entry) -> Bool in
            a.row.box.minY != b.row.box.minY ? a.row.box.minY < b.row.box.minY : a.row.box.minX < b.row.box.minX
        }
        let first: CGFloat = sorted.first?.row.box.minY ?? 0
        // A line's mark box: hung `hang` into the gutter, or at the column's edge when text is inset.
        let mark: CGFloat = indent - Tokens.Transcript.Layout.hang
        let out: [String: Any] = [
            "format": "frog-transcript-metrics/1",
            "app": "mac",
            "width": r(width), "height": r(height), "look": look,
            "column": r(column), "gutter": r(gutter), "pane": r(pane),
            "mark": r(mark), "markOnScreen": gutter + mark >= 0,
            "rows": sorted.map { e -> [String: Any] in
                let x = e.row.firstX ?? pendingFirst[e.key] ?? e.row.box.minX
                return ["kind": e.row.kind.rawValue, "text": e.row.text, "x": r(x), "top": r(e.row.box.minY - first),
                        "height": r(e.row.box.height), "fontSize": r(e.row.fontSize)]
            },
        ]
        return (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}

extension EnvironmentValues {
    /// Rows inside an opened line or fold don't count as rows of their own.
    @Entry var metricsHidden = false
    /// The row whose first word a `metricsFirstWord()` below reports.
    @Entry var metricsKey: String?
}

/// The coordinate space rows report in: the transcript column (`TranscriptView.content`).
private var metricsSpace: CoordinateSpace { .named("transcript-content") }

private struct MetricsRow: ViewModifier {
    let kind: TranscriptMetrics.Kind
    let text: String
    let key: String
    let fontSize: CGFloat
    @Environment(\.metricsHidden) private var hidden

    func body(content: Content) -> some View {
        content
            .environment(\.metricsKey, key)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: metricsSpace) }) { box in
                guard !hidden else { return TranscriptMetrics.shared.remove(key) }
                TranscriptMetrics.shared.set(key, kind: kind, text: text, box: box, fontSize: fontSize)
            }
            // A row that's gone (lines folding as the replay streams) isn't a row any more.
            .onDisappear { TranscriptMetrics.shared.remove(key) }
    }
}

private struct MetricsFirstWord: ViewModifier {
    var offset: CGFloat = 0
    @Environment(\.metricsKey) private var key
    @Environment(\.metricsHidden) private var hidden

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: metricsSpace).minX }) { x in
            guard !hidden, let key else { return }
            TranscriptMetrics.shared.setFirst(key, x: x + offset)
        }
    }
}

extension View {
    /// This view is a row of the transcript, for the parity metrics.
    @ViewBuilder
    func metricsRow(_ kind: TranscriptMetrics.Kind, _ text: String, key: String, fontSize: CGFloat) -> some View {
        if TranscriptMetrics.enabled {
            modifier(MetricsRow(kind: kind, text: text, key: key, fontSize: fontSize))
        } else {
            self
        }
    }

    /// This view's leading edge is its row's first visible character (`offset` further in).
    @ViewBuilder
    func metricsFirstWord(offset: CGFloat = 0) -> some View {
        if TranscriptMetrics.enabled {
            modifier(MetricsFirstWord(offset: offset))
        } else {
            self
        }
    }
}
