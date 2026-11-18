import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Tokens.swift is generated from design/tokens.json (design/generate.mjs), the source the web's
/// tokens.css comes from too. This fails when the compiled values drift from the JSON.
final class TokensTests: XCTestCase {

    private struct Spec: Decodable {
        struct Shade: Decodable { let swift: String?; let light: String; let dark: String }
        struct Length: Decodable { let swift: String?; let value: Double }
        let color: [Shade]
        let size: [Length]
        let radius: [Length]
        let space: [Length]
    }

    private func spec() throws -> Spec {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("design/tokens.json")
        return try JSONDecoder().decode(Spec.self, from: Data(contentsOf: url))
    }

    /// "#rrggbb" or "rgba(r, g, b, a)" → components 0...1.
    private func parse(_ s: String) -> [Double] {
        if s.hasPrefix("#") {
            let v = Int(s.dropFirst(), radix: 16)!
            return [Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255, 1]
        }
        let n = s.dropFirst(5).dropLast().split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces))! }
        return [n[0] / 255, n[1] / 255, n[2] / 255, n[3]]
    }

    private func resolve(_ c: Color, dark: Bool) -> [Double] {
        var out: [Double] = []
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let n = NSColor(c).usingColorSpace(.sRGB)!
            out = [n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent].map(Double.init)
        }
        return out
    }

    private let colors: [String: Color] = [
        "canvas": Tokens.canvas, "sidebar": Tokens.sidebar, "raised": Tokens.raised, "bubble": Tokens.bubble,
        "well": Tokens.well, "hover": Tokens.hover, "hairline": Tokens.hairline, "hairlineStrong": Tokens.hairlineStrong,
        // Rails that nest content (quotes, tool output, the started-by tree): `ed91d93a` added
        // the token and its JSON entry but not this line, so the set comparison below failed
        // for everyone who ran the suite after it landed on main.
        "line": Tokens.line, "lineStrong": Tokens.lineStrong, "edge": Tokens.edge, "notice": Tokens.notice,
        "text": Tokens.text, "textSecondary": Tokens.textSecondary, "textTertiary": Tokens.textTertiary,
        "textQuaternary": Tokens.textQuaternary, "accent": Tokens.accent, "onAccent": Tokens.onAccent, "signal": Tokens.signal, "fail": Tokens.fail,
        "warn": Tokens.warn, "placeLocal": Tokens.placeLocal, "placeCloud": Tokens.placeCloud,
        "prFailing": Tokens.prFailing, "prChecks": Tokens.prChecks, "prDraft": Tokens.prDraft,
        "prApproved": Tokens.prApproved, "prClosed": Tokens.prClosed, "prMerged": Tokens.prMerged,
    ]

    func testColorsMatchTheJSON() throws {
        let shades = try spec().color.filter { $0.swift != nil }
        XCTAssertEqual(Set(shades.map { $0.swift! }), Set(colors.keys), "Tokens' colors and the JSON's swift names differ")
        for s in shades {
            let c = try XCTUnwrap(colors[s.swift!])
            for dark in [false, true] {
                let want = parse(dark ? s.dark : s.light), got = resolve(c, dark: dark)
                for (w, g) in zip(want, got) {
                    XCTAssertEqual(g, w, accuracy: 0.003, "Tokens.\(s.swift!) (\(dark ? "dark" : "light")) is \(got), the JSON says \(want)")
                }
            }
        }
    }

    func testLengthsMatchTheJSON() throws {
        let s = try spec()
        let sizes: [String: CGFloat] = ["body": Tokens.Size.body, "secondary": Tokens.Size.secondary, "status": Tokens.Size.status,
                                        "meta": Tokens.Size.meta, "label": Tokens.Size.label]
        let radii: [String: CGFloat] = ["control": Tokens.Radius.control, "card": Tokens.Radius.card, "chrome": Tokens.Radius.chrome,
                                        "field": Tokens.Radius.field, "bubble": Tokens.Radius.bubble]
        let space: [String: CGFloat] = ["row": Tokens.Space.row]
        for (list, table) in [(s.size, sizes), (s.radius, radii), (s.space, space)] {
            let named = list.filter { $0.swift != nil }
            XCTAssertEqual(Set(named.map { $0.swift! }), Set(table.keys))
            for l in named { XCTAssertEqual(Double(table[l.swift!] ?? -1), l.value, l.swift!) }
        }
    }

    /// The transcript reads `Tokens.Transcript` (spec: "neither app hard-codes a size or a gap");
    /// `TurnSpace` keeps its literals (the web's transcript-tokens test reads them) and they must
    /// equal the generated tokens, at both densities.
    func testTurnSpaceIsTheTranscriptTokens() {
        for (scale, gaps) in [(TurnSpace.Scale.comfortable, Tokens.Transcript.Gaps.comfortable), (.compact, .compact)] {
            XCTAssertEqual(scale.gaps, gaps)
            XCTAssertEqual(scale.turn, gaps.turn)
            XCTAssertEqual(scale.paragraph, gaps.paragraph)
            XCTAssertEqual(scale.block, gaps.block)
            XCTAssertEqual(scale.activity, gaps.activity)
            XCTAssertEqual(scale.list, gaps.list)
            XCTAssertEqual(scale.section, gaps.section)
            XCTAssertEqual(scale.heading, gaps.heading)
            XCTAssertEqual(scale.block + scale.footer, gaps.footer, "the footer gap is block + Scale.footer")
        }
        XCTAssertEqual(TurnSpace.measure, Tokens.Transcript.Layout.column)
        XCTAssertEqual(TurnSpace.gutter, Tokens.Transcript.Layout.gutter)
        XCTAssertEqual(TurnSpace.promptWidth, Tokens.Transcript.Layout.prompt)
        XCTAssertEqual(TurnType.body, Tokens.Transcript.body.size)
        XCTAssertEqual(MessageStyle.lineBox, Tokens.Transcript.body.line)
        XCTAssertEqual(MessageStyle.measure, Tokens.Transcript.Layout.prose)
    }

    /// The gaps between a turn's rows (spec, "Gaps"): lines in a run touch, prose and lines are
    /// `activity` apart either way round, the prompt and a box `block`, paragraphs `paragraph`.
    func testTheGapsBetweenRows() {
        let s = TurnSpace.Scale.comfortable
        let text = TurnPart.segment(.text(ItemState(id: "m", kind: .message)))
        let lines = TurnPart.segment(.activity(ActivityGroup(steps: [])))
        XCTAssertEqual(s.gap(lines, after: .head, first: false), s.block)
        XCTAssertEqual(s.gap(lines, after: lines, first: false), 0)
        XCTAssertEqual(s.gap(lines, after: text, first: false), s.activity)
        XCTAssertEqual(s.gap(text, after: lines, first: false), s.activity)
        XCTAssertEqual(s.gap(text, after: text, first: false), s.paragraph)
        XCTAssertEqual(s.gap(.tail, after: text, first: false), s.block)
        XCTAssertEqual(s.gap(.head, after: nil, first: false), s.turn)
    }
}
