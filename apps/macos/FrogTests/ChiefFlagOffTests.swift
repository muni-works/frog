import SwiftUI
import XCTest
@testable import Frog

/// The chief off (`FeatureFlags.chief == false`): a saved chief stays saved but nothing renders
/// or special-cases it — the sidebar is the pre-chief tree, and a pinned session is the home
/// base. The chief-on coverage is `ChiefTests`.
@MainActor
final class ChiefFlagOffTests: XCTestCase {
    /// `Library.shared` persists to the host app's defaults (toys.frog.dev), so put back
    /// whatever a real chief and real pins were.
    private static let keys = ["chiefSession", "pinnedSessions", "archivedSessions", "sidebarGroup", "sidebarScope"]
    private var saved: [String: Any] = [:]

    override func setUpWithError() throws {
        try XCTSkipIf(FeatureFlags.chief, "the off-state only holds with the flag off")
        saved = Self.keys.reduce(into: [:]) { d, k in d[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set("org", forKey: "sidebarGroup")
    }

    override func tearDown() {
        Library.shared.unstage()
        for k in Self.keys {
            if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    private static func session(_ id: String, title: String? = nil, ago: Int64 = 0) -> SessionInfo {
        SessionInfo(id: id, modified: 1_000_000_000_000 - ago, created: 1_000_000_000_000 - ago - 60_000,
                    model: "m", firstInput: nil, title: title ?? id, end: nil, forkedFrom: nil, cwd: "/tmp")
    }

    /// An org with a stale chief still saved from the flag-on era: manager + workers under it,
    /// the chief itself pinned (as `makeChief` left it).
    private func stageOrg() {
        Library.shared.stage(
            sessions: [Self.session("boss"), Self.session("mgr"), Self.session("w1"), Self.session("w2"), Self.session("mine")],
            live: ["boss": .running, "mgr": .running, "w1": .running],
            parents: ["mgr": "boss", "w1": "mgr", "w2": "mgr"],
            chief: "boss", pinned: ["boss"])
    }

    // MARK: no chief tile, no chief node

    func testNoChiefTileWhenFlagOff() {
        stageOrg()
        let built = SessionList.attention(Library.shared, sort: .activity, scope: .live, current: nil)
        // The tree renders sessions like any other: the chief is a top-level row, its finished
        // leaves fold into yours (or their parents'), never a chief node or its fold.
        let rows = (built.layout.org + built.layout.yours).compactMap { e -> String? in
            if case .row(let s, _, _, _) = e { return s.id } else { return nil }
        }
        XCTAssertTrue(rows.contains("boss"), "a saved chief renders as its own top-level row")
        XCTAssertFalse(built.layout.org.contains { e in
            if case .done(let parent, _, _, _, _) = e { return parent == AttentionTree.chiefFold }
            return false
        }, "no \"N done by chief\" fold")
        // ⌘1…9 count it like any other row: nothing prepended before the tree.
        let order = WorkspaceViewSidebarProbe.quickSwitchOrder()
        XCTAssertEqual(order.first?.id, "boss")
        XCTAssertEqual(order.count, built.layout.topLevels.count, "the chief adds no row of its own")
    }

    // MARK: pins are the home base

    func testTheChiefUnpinsLikeAnyPin() {
        stageOrg()
        let lib = Library.shared
        lib.togglePin("boss")
        XCTAssertFalse(lib.pinned.contains("boss"), "flag off, the pin-keep is off with it")
        lib.togglePin("boss")
        XCTAssertTrue(lib.pinned.contains("boss"))
    }

    // MARK: the org tree works with no chief at all

    func testOrgTreeWithoutAnyChief() {
        Library.shared.stage(
            sessions: [Self.session("a", ago: 100), Self.session("b", ago: 50), Self.session("kid")],
            live: ["a": .waiting, "b": .running],
            parents: ["kid": "b"], chief: nil, pinned: [])
        let built = SessionList.attention(Library.shared, sort: .activity, scope: .live, current: nil)
        XCTAssertEqual(built.layout.needsYou.map(\.id), ["a"], "needs-you still roots the view")
        // The started-by tree is the org: b with kid nested (kid is idle, folded into its
        // parent's done row or nested — b is live, so it shows).
        let top = built.layout.topLevels.map(\.id)
        XCTAssertTrue(top.contains("b"))
        XCTAssertFalse(top.contains("kid"), "kid nests under the session that started it")
    }
}

/// `WorkspaceView.sidebarOrder` is private; the quick-switch order is what the ⌘1…9 tests read.
@MainActor
enum WorkspaceViewSidebarProbe {
    static func quickSwitchOrder() -> [SessionInfo] {
        let library = Library.shared
        let tree = SessionList.attention(library, sort: .activity, scope: .live, current: nil)
        return (FeatureFlags.chief ? [library.chiefSession].compactMap(\.self) : []) + tree.layout.topLevels
    }
}
