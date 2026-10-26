import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// The attention tree rendered from a staged org (the design's mockup data, roughly), into
/// `$TMPDIR/frog-snapshots/sidebar-<scope>-<look>.png`, for review against
/// docs/design/sidebar-shots/7-recommended-*.png.
@MainActor
final class SidebarSnapshotTests: XCTestCase {
    private var outDir: URL {
        FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
    }

    private let keys = ["sidebarGroup", "sidebarScope", "sidebarSort"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
    }

    override func tearDown() {
        Library.shared.unstage()
        for k in keys {
            if let v = saved[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, to name: String, appearance: NSAppearance.Name) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appending(path: "\(name).png"))
    }

    private static let now = Int64(Date().timeIntervalSince1970 * 1000)

    private static func s(_ id: String, _ title: String, ago minutes: Double, repo: String = "frog",
                          end: SessionInfo.End? = .complete) -> SessionInfo {
        let t = now - Int64(minutes * 60_000)
        return SessionInfo(id: id, modified: t, created: t - 600_000, model: "anthropic/claude-opus-5.5",
                           firstInput: nil, title: title, end: end, forkedFrom: nil,
                           cwd: "/Users/cam/Developer/\(repo)/.frog/worktrees/\(id)")
    }

    /// The org on Oct 25 (titles from the design's mockups), states staged for one moment.
    private func stage() {
        let chief = SessionInfo(id: "chief", modified: Self.now, created: Self.now - 86_400_000, model: "anthropic/claude-opus-5.5",
                                firstInput: nil, title: "chief", end: .complete, forkedFrom: nil, cwd: "/Users/cam/Developer")
        let sessions: [SessionInfo] = [
            chief,
            Self.s("fm", "frog manager", ago: 0.2),
            Self.s("grace", "graceful restart implementation", ago: 0.3),
            Self.s("drill", "restart drill tests", ago: 0.1),
            Self.s("gdesign", "graceful restart design", ago: 180),
            Self.s("deleg", "delegation pipeline v4", ago: 300),
            Self.s("orgrel", "org reliability fixes", ago: 310),
            Self.s("opus", "opus text-mode fix", ago: 320),
            Self.s("perf", "transcript perf batch", ago: 330),
            Self.s("ux", "accounts ux spec v3", ago: 340),
            Self.s("revert", "mode silently reverts", ago: 360, end: .failed),
            Self.s("old1", "sidebar status v2", ago: 2000),
            Self.s("old2", "compact sidebar", ago: 2100),
            Self.s("okc", "okc manager", ago: 12, repo: "okc"),
            Self.s("decode", "okc decode layer", ago: 1, repo: "okc"),
            Self.s("bf16", "okc bf16 proj", ago: 4, repo: "okc"),
            Self.s("prefill", "okc prefill layer", ago: 1, repo: "okc"),
            Self.s("attn", "okc attn decode", ago: 120, repo: "okc"),
            Self.s("serve", "okc serving patch", ago: 180, repo: "okc"),
            Self.s("cloud", "frog cloud manager", ago: 0.5, repo: "zest"),
            Self.s("keys", "frog api keys", ago: 0.5, repo: "zest"),
            Self.s("batch", "gateway batching", ago: 1, repo: "zest"),
            Self.s("tang", "tang manager", ago: 600, repo: "tang"),
            Self.s("t1", "kv ttl", ago: 1500, repo: "tang"),
            Self.s("t2", "kernel registry", ago: 1600, repo: "tang"),
            Self.s("rose", "rose head mvp setup", ago: 4300, repo: "rose"),
            Self.s("cd1", "renew daemon.so", ago: 200, repo: "home"),
            Self.s("cd2", "licensing audit", ago: 1300, repo: "home"),
            Self.s("blaze", "blaze distill", ago: 0.4, repo: "blaze"),
            Self.s("node", "Make the frog cloud node boot from a fresh image", ago: 4400, repo: "zest"),
            Self.s("mine-old", "kino stream eval", ago: 3000, repo: "kino"),
        ]
        let parents = [
            "fm": "chief", "okc": "chief", "cloud": "chief", "tang": "chief", "rose": "chief", "cd1": "chief", "cd2": "chief",
            "grace": "fm", "drill": "grace", "gdesign": "grace", "deleg": "fm", "orgrel": "fm", "opus": "fm", "perf": "fm",
            "ux": "fm", "revert": "fm", "old1": "fm", "old2": "fm",
            "decode": "okc", "bf16": "okc", "prefill": "okc", "attn": "okc", "serve": "okc",
            "keys": "cloud", "batch": "cloud", "t1": "tang", "t2": "tang",
        ]
        let live: [String: Library.Live] = [
            "chief": .running, "fm": .running, "grace": .running, "drill": .running, "decode": .running,
            "bf16": .waiting, "prefill": .running, "cloud": .running, "keys": .running, "batch": .waiting, "blaze": .running, "node": .unread,
        ]
        Library.shared.stage(sessions: sessions, live: live, parents: parents, chief: "chief",
                             archived: [], asks: ["bf16": "pod past its 2h cap · $3.50/hr · extend?",
                                                  "batch": "Bash git push origin gateway-batching"])
    }

    func testRenderAttentionTree() throws {
        stage()
        for scope in AttentionTree.Scope.allCases {
            UserDefaults.standard.set("org", forKey: "sidebarGroup")
            UserDefaults.standard.set(scope.rawValue, forKey: "sidebarScope")
            UserDefaults.standard.set("activity", forKey: "sidebarSort")
            for (look, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let ws = Workspace(folder: URL(fileURLWithPath: "/Users/cam/Developer/frog/.frog/worktrees/grace"), resume: "grace")
                try render(SessionList(workspace: ws, maxHeight: 900).background(.background),
                           size: CGSize(width: 288, height: 900), to: "sidebar-\(scope.rawValue)-\(name)", appearance: look)
            }
        }
        // Search filters the tree in place: "okc" keeps its manager, and the archive below.
        Library.shared.stage(sessions: Library.shared.sessions + [Self.s("okc-old", "okc dyno plan", ago: 9000, repo: "okc")],
                             live: Library.shared.live, parents: Library.shared.parents, chief: "chief",
                             archived: ["okc-old"])
        let ws = Workspace(folder: URL(fileURLWithPath: "/Users/cam/Developer/frog/.frog/worktrees/grace"), resume: "grace")
        try render(SessionList(workspace: ws, maxHeight: 900, query: "okc").background(.background),
                   size: CGSize(width: 288, height: 600), to: "sidebar-search-light", appearance: .aqua)
    }
}
