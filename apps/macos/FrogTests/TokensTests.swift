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
        "line": Tokens.line, "text": Tokens.text, "textSecondary": Tokens.textSecondary, "textTertiary": Tokens.textTertiary,
        "textQuaternary": Tokens.textQuaternary, "accent": Tokens.accent, "signal": Tokens.signal, "fail": Tokens.fail,
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
}
