import SwiftUI

/// The transcript's rows as numbers, for parity with the web (`-FrogMetrics <path>`; format
/// `frog-transcript-metrics/1`, docs/design/parity/README.md, "Metrics"). Each row the transcript
/// draws reports its kind, its words, its box and where its first word starts, in the transcript
/// column's coordinates (x 0 is the column's text edge). Off unless the launch argument is set:
/// the modifiers below then do nothing.
@MainActor
final class TranscriptMetrics {
    static let shared = TranscriptMetrics()

    /// `-FrogMetrics <path>` or `-FrogEdges <path>` was given (tests switch it on themselves,
    /// before the views they measure are built).
    nonisolated(unsafe) static var enabled: Bool = ["FrogMetrics", "FrogEdges"].contains { !(UserDefaults.standard.string(forKey: $0) ?? "").isEmpty }

    enum Kind: String { case prompt, thought, fold, line, prose, code, card, footer, live, stats, turnline }

    struct Row {
        var kind: Kind
        var text: String
        /// The row's box, in the column's coordinates.
        var box: CGRect
        /// Where its first visible character starts, in the column's coordinates.
        var firstX: CGFloat?
        var fontSize: CGFloat
        /// What kind of line, block or card it is, for the edges dump ("command", "list item").
        var sub: String?
    }

    /// One more measured part of a row for the edges dump (`-FrogEdges`): a line's mark or
    /// result, a card's box, the composer. `box` is in the column's coordinates, or the
    /// window's when `global` (the composer sits outside the transcript's scroll view).
    struct Edge {
        var row: String?
        var kind: String?
        var part: String
        var text: String
        var box: CGRect
        var claims: [String]
        var global: Bool
    }

    private(set) var edges: [String: Edge] = [:]
    /// The column's frame in the window, to bring `global` edges into the column's coordinates.
    var columnGlobal: CGRect = .zero

    func setEdge(_ key: String, _ edge: Edge) { edges[key] = edge }
    func removeEdge(_ key: String) { edges[key] = nil }

    private(set) var rows: [String: Row] = [:]
    /// The layout: pane and column widths, the gutter, and where the first line's mark is.
    var pane: CGFloat = 0
    var column: CGFloat = 0
    var gutter: CGFloat = 0
    var indent: CGFloat = 0

    func set(_ key: String, kind: Kind, text: String, box: CGRect, fontSize: CGFloat, sub: String? = nil) {
        var row = rows[key] ?? Row(kind: kind, text: text, box: box, fontSize: fontSize)
        row.kind = kind
        if let sub { row.sub = sub }
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

    /// Forget every row and edge (tests measure one hosted transcript after another).
    func reset() {
        rows = [:]
        edges = [:]
        pendingFirst = [:]
    }

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
        let entries: [Entry] = rows.map { Entry(key: $0.key, row: $0.value) }
            // A turn line has no words: it's measured on its box (README, "turnline").
            .filter { !$0.row.text.isEmpty || $0.row.kind == .turnline }
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

    /// The edges dump, `frog-transcript-edges/1` (docs/design/parity/edges.mjs has the format):
    /// every element of the column with its left and right edge and the line it claims.
    func edgesJSON(width: CGFloat, height: CGFloat, look: String) -> Data {
        func r(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
        struct El { let y: CGFloat; let order: Int; let v: [String: Any] }
        var out: [El] = []
        func add(_ y: CGFloat, _ kind: String, _ part: String, _ text: String, _ l: CGFloat, _ rt: CGFloat, _ claims: [String], order: Int = 0) {
            out.append(El(y: y, order: order, v: ["kind": kind, "part": part, "text": String(Self.collapse(text).prefix(60)),
                                                  "left": r(l), "right": r(rt), "claims": claims]))
        }
        func kindName(_ row: Row) -> String {
            switch row.kind {
            case .line: return "line:\(row.sub ?? "other")"
            case .prose, .code, .card: return row.sub ?? row.kind.rawValue
            default: return row.kind.rawValue
            }
        }
        for (key, row) in rows where !row.text.isEmpty || row.kind == .turnline {
            let x = row.firstX ?? pendingFirst[key] ?? row.box.minX
            let kind = kindName(row)
            switch row.kind {
            case .prompt: add(row.box.minY, kind, "bubble", row.text, row.box.minX, row.box.maxX, ["right"])
            case .code: add(row.box.minY, kind, "box", "", row.box.minX, row.box.maxX, kind == "table" ? ["box"] : ["box", "right"])
            case .card: add(row.box.minY, kind, "box", row.text, row.box.minX, row.box.maxX, ["box", "right"])
                add(row.box.minY, kind, "title (inside)", row.text, x, row.box.maxX, [], order: 1)
            case .turnline: add(row.box.minY, row.sub ?? "footer", "turn line (box)", "", row.box.minX, row.box.maxX, ["right"], order: 2)
            default: add(row.box.minY, kind, "words", row.text, x, row.box.maxX, ["text"])
            }
        }
        for e in edges.values {
            var box = e.box
            if e.global { box = box.offsetBy(dx: -columnGlobal.minX, dy: 100_000) }
            let row = e.row.flatMap { rows[$0] }
            let kind = e.kind ?? row.map(kindName) ?? "?"
            add(row?.box.minY ?? box.minY, kind, e.part, e.text, box.minX, box.maxX, e.claims, order: 1)
        }
        let sorted = out.sorted { $0.y != $1.y ? $0.y < $1.y : $0.order < $1.order }
        // A line's mark hangs `hang` into the gutter, or sits at the column's edge when text is inset.
        let doc: [String: Any] = [
            "format": "frog-transcript-edges/1", "app": "mac",
            "width": r(width), "height": r(height), "look": look,
            "column": r(column), "indent": r(indent),
            "elements": sorted.map(\.v),
        ]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])) ?? Data()
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
    var sub: String?
    @Environment(\.metricsHidden) private var hidden

    func body(content: Content) -> some View {
        content
            .environment(\.metricsKey, key)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: metricsSpace) }) { box in
                guard !hidden else { return TranscriptMetrics.shared.remove(key) }
                TranscriptMetrics.shared.set(key, kind: kind, text: text, box: box, fontSize: fontSize, sub: sub)
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
    func metricsRow(_ kind: TranscriptMetrics.Kind, _ text: String, key: String, fontSize: CGFloat, sub: String? = nil) -> some View {
        if TranscriptMetrics.enabled {
            modifier(MetricsRow(kind: kind, text: text, key: key, fontSize: fontSize, sub: sub))
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

private struct MetricsEdge: ViewModifier {
    let part: String
    let claims: [String]
    var kind: String?
    var text = ""
    var global = false
    @Environment(\.metricsKey) private var row
    @Environment(\.metricsHidden) private var hidden
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: global ? .global : metricsSpace) }) { box in
                guard !hidden, kind != nil || row != nil else { return TranscriptMetrics.shared.removeEdge(id.uuidString) }
                TranscriptMetrics.shared.setEdge(id.uuidString, .init(row: row, kind: kind, part: part, text: text, box: box, claims: claims, global: global))
            }
            .onDisappear { TranscriptMetrics.shared.removeEdge(id.uuidString) }
    }
}

extension View {
    /// This view is a measured part of its row (or, with `kind`, an element of its own) for the
    /// edges dump: `claims` name the lines it must sit on ("text", "box", "right", "hung").
    /// `global`: it sits outside the transcript's scroll view (the composer).
    @ViewBuilder
    func metricsEdge(_ part: String, claims: [String], kind: String? = nil, text: String = "", global: Bool = false) -> some View {
        if TranscriptMetrics.enabled {
            modifier(MetricsEdge(part: part, claims: claims, kind: kind, text: text, global: global))
        } else {
            self
        }
    }
}
