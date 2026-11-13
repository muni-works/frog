import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The compact row's rule of information (Cam, 2026-11-13): **information must not be
/// hover-only; actions may be.** The git badge is information — three straight reports that it
/// vanished under the cursor, so it must stay in the row for as long as the pointer is on it,
/// even once the title has unwrapped (`expandTitle`, after 450 ms). The ⋯ menu and the branch
/// suffix are actions and emphasis; they may come and go with the pointer.
///
/// The pointer can't be staged inside a unit test, so these render the row **frozen
/// mid-hover** (the `EndView(hovering:)` pattern, OpacityViewTests): `CompactRowContent` takes
/// `hovering` and `expandTitle` as plain values, and the row itself renders the same view —
/// what a resting row draws and what a hovered one draws come from one implementation. Written
/// to fail before the fix (the badge dropped from the layout once `expandTitle` was true); see
/// the PR body for the red proof.
@MainActor
final class CompactRowHoverTests: XCTestCase {
    /// Where the snapshots land ($TMPDIR/frog-snapshots, as the other snapshot tests').
    static var dir: URL {
        FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
    }

    override func setUp() {
        Library.shared.unstage()
        GitIndex.shared.unstage()
    }

    override func tearDown() {
        Library.shared.unstage()
        GitIndex.shared.unstage()
    }

    /// One settled row in a worktree of its own, as the listing carries times (ms).
    private static let now = Int64(Date().timeIntervalSince1970 * 1000)

    /// One settled row in a worktree of its own, with a badge worth reading: ahead, dirty,
    /// a card. The age it used to carry sits in the fixtures below.
    private func row(git: Bool = true, depth: Int = 0) -> CompactSessionRow<Text> {
        let s = SessionInfo(id: "grace", modified: Self.now - 14 * 60_000, created: Self.now - 60 * 60_000,
                            model: "cloud/deepseek-v4.1-flash", firstInput: nil,
                            title: "graceful restart implementation", end: .complete, forkedFrom: nil,
                            cwd: "/Users/cam/Developer/frog/.frog/worktrees/grace")
        Library.shared.stage(sessions: [s], live: [:], parents: [:], chief: nil, pinned: [], archived: [])
        if git {
            GitIndex.shared.stage(["grace": GitBadge(tree: "/Users/cam/Developer/frog/.frog/worktrees/grace",
                                                     branch: "frog/graceful-restart", base: "origin/main",
                                                     ahead: 3, behind: 0, dirty: 2, landed: .no, trouble: nil)],
                                  card: nil, stats: [:])
        } else {
            GitIndex.shared.stage([:], card: nil, stats: [:])
        }
        let badge = GitTreeBadges.leaf(s, members: [s], settled: true) { _ in }
        return CompactSessionRow(session: s, selected: false, live: nil, depth: depth, git: badge,
                                 folded: 0, counts: .init(), collapsed: false, onFold: nil, onCollapse: nil,
                                 open: {}, menu: { Text("menu") })
    }

    /// The one line, frozen at a moment of the hover: at rest, or after the title unwrapped.
    private func content(_ row: CompactSessionRow<Text>, expandTitle: Bool) -> some View {
        CompactRowContent(row: row, menu: { Text("menu") }, working: false, hovering: expandTitle, expandTitle: expandTitle)
            .frame(width: 288)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The bytes of a view drawn into a bitmap at a fixed size.
    private func pixels<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The purple branch glyph's pixels, if the row drew it. Scanning the whole bitmap keeps
    /// the test independent of where the badge sits; the badge is the only purple in it.
    private func badgePixels(_ rep: NSBitmapImageRep) throws -> CGRect {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var found = CGRect.null
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y), c.isBadgePurple else { continue }
                found = found.union(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1))
            }
        }
        return found
    }

    /// The badge must still be in the row once the title has unwrapped. The regression: the
    /// row dropped it from the layout on `expandTitle`, so the badge vanished under the
    /// pointer 450 ms after it arrived.
    func testTheBadgeStaysInTheRowAfterTheTitleUnwraps() throws {
        let rest = try badgePixels(pixels(content(row(), expandTitle: false), size: CGSize(width: 288, height: 32)))
        XCTAssertFalse(rest.isNull, "the row drew no badge even at rest; the fixture is broken")
        let unwrapped = try badgePixels(pixels(content(row(), expandTitle: true), size: CGSize(width: 288, height: 48)))
        XCTAssertFalse(unwrapped.isNull,
                       "the badge left the row once the title unwrapped: information vanished under the pointer")
    }

    /// A row without a badge draws none, at any moment of the hover — the fixture can't pass
    /// by accident.
    func testARowWithoutABadgeDrawsNoBadge() throws {
        let rest = try badgePixels(pixels(content(row(git: false), expandTitle: false), size: CGSize(width: 288, height: 32)))
        XCTAssertTrue(rest.isNull)
        let unwrapped = try badgePixels(pixels(content(row(git: false), expandTitle: true), size: CGSize(width: 288, height: 48)))
        XCTAssertTrue(unwrapped.isNull)
    }

    /// The badge's width doesn't change as the title unwraps. (Where it sits may: the age
    /// that used to trail it is gone in the same change, so the badge slides into that slot.)
    func testTheBadgeKeepsItsWidthAsTheTitleUnwraps() throws {
        let rest = try badgePixels(pixels(content(row(), expandTitle: false), size: CGSize(width: 288, height: 32)))
        let unwrapped = try badgePixels(pixels(content(row(), expandTitle: true), size: CGSize(width: 288, height: 48)))
        XCTAssertEqual(rest.width, unwrapped.width, accuracy: 1.5,
                       "the badge changed size between rest and hover")
    }

    /// The hover's three moments as snapshots (sidebar-row-hover-{rest,300,600}.png): the
    /// badge present in all three, the row's width unchanged (the renders compared to each
    /// other, in device pixels — whatever the screen's scale), the title unwrapped only by
    /// 600 ms.
    func testRowAtRestBeforeAndAfterTheTitleUnwraps() throws {
        let row = self.row()
        var widths: [Int] = []
        for (expand, name) in [(false, "rest"), (false, "300"), (true, "600")] {
            let height: CGFloat = expand ? 48 : 32
            let view = content(row, expandTitle: expand)
            let host = NSHostingView(rootView: view.frame(width: 288, height: height))
            host.frame = CGRect(origin: .zero, size: CGSize(width: 288, height: height))
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: Self.dir.appending(path: "sidebar-row-hover-\(name).png"))
            XCTAssertFalse(try badgePixels(rep).isNull, "sidebar-row-hover-\(name): no badge in the row")
            widths.append(rep.pixelsWide)
        }
        XCTAssertEqual(widths.first, widths.last, "the row's width changed over the hover")
    }

    /// The age the row used to carry — the timestamp is gone from it (Cam, 2026-11-13); the
    /// tooltip keeps "active 14m ago" for the nested rows that never showed a visible age.
    func testTheRowLeavesItsAgeToTheTooltip() {
        XCTAssertTrue(row(depth: 1).helpText.contains("active 14m ago"), "the tooltip lost the age")
        XCTAssertFalse(row().helpText.contains("active"), "a top-level row's tooltip grew an age")
    }
}

private extension NSColor {
    /// The branch glyph's purple (`.purple`, GitBadgeView.branchTint), the badge's only hue.
    var isBadgePurple: Bool {
        guard let rgb = usingColorSpace(.deviceRGB) else { return false }
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        return b > 0.35 && b > g + 0.1 && r > g + 0.05
    }
}
