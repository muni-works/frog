import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The inline diagram: the engine's fit pass decides the form, and the transcript draws it at no
/// less than the readable scale. Renders land in `$FROG_SNAPSHOT_DIR` like `SnapshotTests`.
@MainActor
final class DiagramInlineTests: XCTestCase {
    private var outDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FROG_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
    }

    /// A real folded sequence from the engine (4 group lanes, bundles with the numbers hoisted).
    private func folded() throws -> Diagram {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "diagram-folded", withExtension: "json"))
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Diagram.self, from: Data(contentsOf: url))
    }

    private func render<V: View>(_ view: V, size: CGSize, to name: String, appearance: NSAppearance.Name = .darkAqua) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appending(path: "\(name).png"))
    }

    /// The engine's compact form is what the column draws, and it fits at the floor.
    func testTheInlineFormIsDrawnAtTheColumnAndFits() throws {
        let d = try folded()
        let inline = try XCTUnwrap(d.inline, "the engine folds this sequence")
        XCTAssertEqual(d.inlineLayout?.width, inline.width, "the column draws the inline form")
        XCTAssertEqual(inline.nodes.count, 4, "four group lanes")
        // At the column width, the floor still fits it: no crop, no expand button.
        XCTAssertLessThanOrEqual(inline.width * FittedDiagram.minScale, 704)
        // The numbers survive the fold, in bundles and on kept arrows.
        let text = inline.edges.map { $0.bundle?.label ?? d.edge(of: $0)?.label ?? "" }.joined(separator: "|")
        XCTAssertTrue(text.contains("40 ms"), text)
        XCTAssertTrue(text.contains("1.3 GB"), text)
        XCTAssertTrue(text.contains("1000+ tok/s"), text)
        XCTAssertGreaterThanOrEqual(inline.edges.filter { $0.bundle != nil }.count, 2, "runs fold into bundles")
        XCTAssertTrue(inline.edges.contains { $0.bundle == nil }, "between-lane messages stay")
    }

    /// The full layout is one click away and keeps every participant.
    func testExpandingDrawsTheFullLayout() throws {
        let d = try folded()
        let full = try XCTUnwrap(d.layout)
        XCTAssertEqual(d.layout(expanded: true)?.width, full.width)
        XCTAssertGreaterThan(full.nodes.count, d.inline?.nodes.count ?? 0)
        XCTAssertEqual(d.layout(expanded: false)?.width, d.inline?.width)
    }

    /// A bundle row has no single source edge, so lookups must not fall through to edges[0].
    func testBundleRowsHaveNoSourceEdge() throws {
        let d = try folded()
        let bundle = try XCTUnwrap(d.inline?.edges.first { $0.bundle != nil })
        XCTAssertNil(d.edge(of: bundle))
        let kept = try XCTUnwrap(d.inline?.edges.first { $0.bundle == nil })
        XCTAssertNotNil(d.edge(of: kept))
    }

    /// An old transcript with no `inline` key still decodes and draws the full layout.
    func testOldTranscriptWithoutInlineDecodes() throws {
        let json = #"{"kind":"sequence","title":"t","nodes":[{"id":"a","label":"A"},{"id":"b","label":"B"}],"edges":[{"from":"a","to":"b","label":"hi"}],"layout":{"width":400,"height":200,"nodes":[],"edges":[]}}"#
        let d = try JSONDecoder().decode(Diagram.self, from: Data(json.utf8))
        XCTAssertNil(d.inline)
        XCTAssertEqual(d.inlineLayout?.width, 400, "falls back to the full layout")
    }

    /// The floor: a too-wide full layout is cropped with an expand affordance, never shrunk past
    /// the readable scale. Rendered so the look can be reviewed.
    func testATooWideDiagramCropsAndOffersExpand() throws {
        let d = try folded()
        for (dark, name) in [(NSAppearance.Name.darkAqua, "inline-folded"), (.aqua, "inline-folded-light")] {
            let view = DiagramCard(diagram: d)
                .environment(\.diagramStatic, true)
                .padding(20)
                .frame(width: 720)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark == .aqua ? .light : .dark)
            try render(view, size: CGSize(width: 760, height: 560), to: name, appearance: dark)
        }
    }
}
