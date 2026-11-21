import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Two lines down the conversation column (docs/design/transcript/spec.md, "One left line,
/// flush" and "Two lines"): every row starts on the column's left line (a line's mark, a list's
/// marker, prose), a marked line's words one mark column in and a list item's one marker column
/// in, and everything that reaches the right ends on its right edge. The edge fixture
/// (docs/design/parity/edges.jsonl, every kind of row, from edges-fixture.mjs) is fed to a hosted
/// pane laid out as `PaneView` lays it out (the transcript with the composer in its bottom inset),
/// the transcript's metrics hooks report each element (`TranscriptMetrics.edgesJSON`, the format
/// docs/design/parity/edges.mjs writes on the web), and anything more than 0.5 pt off its line,
/// or any kind of row missing, fails. The same rules as docs/design/parity/check-edges.mjs.
///
/// 2026-11-18: the composer sat 32 pt inside the column on both sides (the gutter applied twice),
/// an opening code chip pushed its paragraph 4 pt in, list items started 22 pt in behind their
/// bullets, and the footer's turn line stopped 3 pt short. 2026-11-21: marks and list markers
/// moved from the gutter onto the left line (Cam).

@MainActor
final class TranscriptEdgesTests: XCTestCase {
    /// The kinds the fixture draws: check-edges.mjs's REQUIRED.
    static let required = [
        "prompt", "thought", "fold", "line:command", "line:edit", "line:search", "line:web", "line:other",
        "prose", "prose (opens with code)", "heading", "list item", "list marker", "code", "table", "visual", "footer",
        "error", "question card", "card", "live", "stats", "composer",
    ]
    static let tolerance = 0.5

    struct Element: Decodable { let kind, part, text: String; let left, right: Double; let claims: [String] }
    struct Dump: Decodable { let format: String; let column, hang, marker: Double; let elements: [Element] }

    override func setUp() async throws {
        TranscriptMetrics.enabled = true
        TranscriptMetrics.shared.reset()
        InkReveal.off = true
    }

    override func tearDown() async throws {
        TranscriptMetrics.shared.reset()
        TranscriptMetrics.enabled = false
        InkReveal.off = false
    }

    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func fixture() throws -> [Envelope] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/design/parity/edges.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        return try lines.compactMap { line -> Envelope? in
            let v = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            guard v?["type"] as? String == "event", let env = v?["env"] else { return nil }
            return try JSONDecoder.frog.decode(Envelope.self, from: JSONSerialization.data(withJSONObject: env))
        }
    }

    /// The pane as `PaneView` builds it: the transcript, the composer in its bottom inset.
    private struct Pane: View {
        let workspace: Workspace
        let conversation: Conversation
        @State private var jump: TurnState.ID?

        var body: some View {
            TranscriptView(conversation: conversation, actions: TurnActions(fork: { _ in }, rewind: { _ in }),
                           jump: $jump, onVisibleTurns: { _ in })
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ComposerView(workspace: workspace, conversation: conversation)
                }
        }
    }

    private func measure(width: CGFloat, height: CGFloat = 3400) throws -> Dump {
        // A folder that isn't there: no engine starts, so the fed events are what the pane shows
        // (its "Couldn't start frog" row sits under the live row and isn't measured).
        let ws = Workspace(folder: URL(fileURLWithPath: "/tmp/frog-edges-tests"), fresh: true)
        let c = try XCTUnwrap(ws.conversation)
        // Only this pane reports (`TranscriptMetrics.scope`): an earlier test's transcript still
        // alive in the host wrote its rows into the dump on a full run (2026-11-19).
        let scope = UUID().uuidString
        TranscriptMetrics.shared.scope = scope
        let host = NSHostingView(rootView: Pane(workspace: ws, conversation: c).frame(width: width, height: height)
            .background(Tokens.canvas).environment(\.metricsScope, scope))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        // Borderless, so the window keeps its size off any screen's bounds.
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        w.orderInForTest()
        defer { w.close() }
        for env in try fixture() { c.ingest(env) }
        pump(2.5)
        host.layoutSubtreeIfNeeded()
        pump(0.5)
        let data = TranscriptMetrics.shared.edgesJSON(width: width, height: height, look: "dark")
        // `TEST_RUNNER_FROG_EDGES_OUT=<dir>`: the dump and a picture of the pane, for the PR and
        // for checking the hooks against the pixels (docs/design/transcript/edges/).
        if let out = ProcessInfo.processInfo.environment["FROG_EDGES_OUT"] {
            try? data.write(to: URL(fileURLWithPath: "\(out)/edges-mac-\(Int(width)).json"))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/edges-mac-\(Int(width)).png"))
            }
        }
        return try JSONDecoder().decode(Dump.self, from: data)
    }

    /// check-edges.mjs's rules: each claim on its line, and every kind present.
    static func problems(_ d: Dump) -> [String] {
        var out: [String] = d.format == "frog-transcript-edges/2" ? [] : ["unknown format \(d.format)"]
        for e in d.elements {
            for claim in e.claims {
                let off: Double = switch claim {
                case "text", "box": e.left
                case "after": e.left - d.hang
                case "item": e.left - d.marker
                case "before": max(0, e.right - d.hang)
                case "right": e.right - d.column
                default: .infinity
                }
                if abs(off) > tolerance { out.append("\(e.kind) \(e.part) \"\(e.text)\": \(claim) off by \((off * 10).rounded() / 10)") }
            }
        }
        let seen = Set(d.elements.map(\.kind))
        for k in required where !seen.contains(k) { out.append("no \(k) in the dump") }
        return out
    }

    /// For the PR (`FROG_EDGES_OUT` only): the fixture's first turn (a fold, the tool rows, a
    /// list) as a picture. Only that turn: `cacheDisplay` draws blank once a card is up.
    func testPictureOfTheFirstTurn() throws {
        guard let out = ProcessInfo.processInfo.environment["FROG_EDGES_OUT"] else { throw XCTSkip("FROG_EDGES_OUT not set") }
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/frog-edges-tests"), link: nil, replay: false, session: "edges")
        let size = CGSize(width: 1030, height: 2300)
        let host = NSHostingView(rootView: TranscriptView(conversation: c, actions: TurnActions(fork: { _ in }, rewind: { _ in }))
            .frame(width: size.width, height: size.height).background(Tokens.canvas))
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        w.orderInForTest()
        defer { w.close() }
        let all = try fixture()
        let end = try XCTUnwrap(all.firstIndex { if case .turnEnded = $0.event { true } else { false } })
        for env in all[...end] { c.ingest(env) }
        pump(2.5)
        host.layoutSubtreeIfNeeded()
        pump(0.5)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/turn1-mac-1030.png"))
    }

    /// The pane of a 1280-wide window with the sidebar open.
    func testEveryElementSitsOnTheColumnsTwoLines() throws {
        let d = try measure(width: 1030)
        let p = Self.problems(d)
        XCTAssertEqual(p, [], "\(p.count) off:\n" + p.joined(separator: "\n"))
    }

    /// A narrower pane (a split): the column is still 720 with its gutter, centred.
    func testAndInANarrowerPane() throws {
        let d = try measure(width: 800)
        let p = Self.problems(d)
        XCTAssertEqual(p, [], "\(p.count) off:\n" + p.joined(separator: "\n"))
    }

    /// Under 480 (`TranscriptEdge.insetBelow`): the narrow gutter, and nothing else moves.
    func testAndInAPaneUnder480() throws {
        let d = try measure(width: 440)
        let p = Self.problems(d)
        XCTAssertEqual(p, [], "\(p.count) off:\n" + p.joined(separator: "\n"))
    }
}
