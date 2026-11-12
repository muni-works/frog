import SwiftUI
import XCTest
@testable import Frog

/// Parity shots for the composer tray (docs/design/parity/composer.html): every state in
/// docs/design/parity/composer-states.json, merged onto cases.json's base, drawn by the same
/// parts the live composer uses. The web's parity page draws the same file. Writes
/// composer-<state>-mac-<look>.png to $FROG_PARITY_OUT when set, else a temp folder.
@MainActor
final class ComposerParityTests: XCTestCase {
    private struct States: Decodable {
        struct Shot: Decodable { let name: String; let given: JSON }
        let states: [Shot]
    }
    private struct Cases: Decodable { let base: JSON }

    private var docs: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/design")
    }

    private func merge(_ a: JSON, _ b: JSON) -> JSON {
        guard case .object(var out) = a, case .object(let over) = b else { return b }
        for (k, v) in over { out[k] = out[k].map { merge($0, v) } ?? v }
        return .object(out)
    }

    func testComposerParityShots() throws {
        let base = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: docs.appendingPathComponent("composer/cases.json"))).base
        let shots = try JSONDecoder().decode(States.self, from: Data(contentsOf: docs.appendingPathComponent("parity/composer-states.json"))).states
        XCTAssertGreaterThanOrEqual(shots.count, 14)
        for shot in shots {
            let state = try JSONDecoder().decode(ComposerModel.State.self, from: JSONEncoder().encode(merge(base, shot.given)))
            try render("composer-\(shot.name)", width: 720, height: shot.name == "stack" ? 360 : 210) {
                TrayPreview(state: state).padding(16).frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, @ViewBuilder _ view: () -> V) throws {
        let dir = ProcessInfo.processInfo.environment["FROG_PARITY_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (suffix, look) in [("mac-dark", NSAppearance.Name.darkAqua), ("mac-light", .aqua)] {
            let host = NSHostingView(rootView: view().frame(width: width, height: height).background(FrogCanvas.color))
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: look)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appending(path: "\(name)-\(suffix).png"))
        }
    }
}
