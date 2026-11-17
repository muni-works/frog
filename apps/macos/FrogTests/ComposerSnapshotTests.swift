import SwiftUI
import XCTest
@testable import Frog

/// The composer's states from docs/design/composer/spec.md, drawn offscreen (never ordered in)
/// from fixture states by the parts the live composer uses, light and dark. Writes
/// mac-<state>-<theme>.png to $FROG_COMPOSER_SHOTS when set (docs/design/composer/ for the
/// checked-in set), else a temp folder.
@MainActor
final class ComposerSnapshotTests: XCTestCase {
    private typealias M = ComposerModel
    private static let mac = M.Model(id: "local/qwen3-8b", name: "Qwen3 8B", place: .local, node: nil)
    private static let cloud = M.Model(id: "cloud/glm-5.3-flash", name: "GLM-5.3 Flash", place: .cloud, node: nil)
    private static let home = NSHomeDirectory() + "/Developer"

    private var outDir: URL {
        ProcessInfo.processInfo.environment["FROG_COMPOSER_SHOTS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "frog-composer-shots")
    }

    private func state(_ edit: (inout M.State) -> Void = { _ in }) -> M.State {
        var s = M.State(model: Self.mac, where: .folder(folder: Self.home + "/frog", branch: "main", worktree: true, git: true, dirty: false))
        s.signedIn = true
        s.defaults = .init(local: Self.mac, cloud: Self.cloud)
        edit(&s)
        return s
    }

    private func session(dirty: Bool = false, add: Int = 0, del: Int = 0, ahead: Int = 0, prs: [M.Pr] = []) -> M.Where {
        .session(.init(repo: "muni-works/frog", branch: "frog/sidebar-polish", worktree: true, worktreePath: nil,
                       diff: .init(add: add, del: del, files: 3), dirty: dirty, ahead: ahead, prs: prs))
    }

    private var lists: WhereLists {
        WhereLists(recents: [Self.home + "/frog", Self.home + "/zest"], cloudRepos: ["ecto/pond", "ecto/loon"], signedIn: true,
                   branches: ["main", "release/v0.6.2", "frog/sidebar-polish"])
    }

    private func render(_ name: String, width: CGFloat = 720, height: CGFloat = 170, menu: ComposerMenuID? = nil,
                        focused: Bool = false, _ s: M.State) throws {
        for (theme, look) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let view = TrayPreview(state: s, lists: lists, menu: menu, narrow: width < ComposerMetrics.narrow, focused: focused)
                .frame(width: width)
                .padding(24)
                .frame(width: width + 48, height: height, alignment: .bottom)
                .background(Tokens.canvas)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: width + 48, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: look)
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appending(path: "mac-\(name)-\(theme).png"))
        }
    }

    func testRenderComposerStates() throws {
        try render("new-folder", state())
        try render("new-cloud", state {
            $0.where = .cloud(repo: "ecto/pond", branch: "main")
            $0.model = Self.cloud
        })
        try render("typing", focused: true, state {
            $0.where = session()
            $0.model = Self.cloud
            $0.draft = .init(text: "Make the tests faster", attachments: [], caret: 21)
        })
        try render("working", state {
            $0.where = session()
            $0.busy = .working
        })
        try render("queued", state {
            $0.where = session()
            $0.busy = .working
            $0.queued = [.init(text: "Then update the changelog")]
            $0.draft = .init(text: "And bump the version", attachments: [], caret: 20)
        })
        try render("error", state {
            $0.where = session()
            $0.model = Self.cloud
            $0.draft = .init(text: "Make the tests faster", attachments: [], caret: 21)
            $0.error = M.failure($0, "no_credit")
        })
        try render("git-pr", state {
            $0.where = session(add: 48, del: 12, ahead: 1, prs: [.init(repo: "muni-works/frog", number: 412, title: "Flush sidebars",
                                                                       state: .checks, checks: .init(ok: 4, total: 9))])
        })
        try render("where-menu", height: 560, menu: .place, state())
        try render("narrow", width: 360, state {
            $0.where = .cloud(repo: "ecto/slamwich", branch: "main")
            $0.model = Self.cloud
        })
    }

    /// The card's resting height: two rows (field and controls), and a third with a status line.
    /// The board's CSS sums to 76 and 108: 1 + (12 + 16 + 4) + (6 + 28 + 8) + 1, plus 32.
    func testRestingHeights() {
        func height(_ s: M.State) -> CGFloat {
            let host = NSHostingView(rootView: TrayPreview(state: s).frame(width: 720))
            return host.fittingSize.height
        }
        XCTAssertEqual(height(state()), 76, accuracy: 0.5, "two rows at rest")
        XCTAssertEqual(height(state { $0.where = session(ahead: 1) }), 108, accuracy: 0.5, "a status line adds 32")
        XCTAssertEqual(height(state { $0.error = M.failure($0, "engine_stopped") }), 108, accuracy: 0.5, "an error is the same one row")
    }

    /// Nothing ever adds a fourth row: an error over git state replaces it, not stacks on it.
    func testNeverMoreThanThreeRows() {
        let s = state {
            $0.where = session(dirty: true, add: 3, prs: [.init(repo: "muni-works/frog", number: 1, title: "x", state: .checks, checks: .init(ok: 0, total: 1))])
            $0.error = M.failure($0, "hook_failed")
            $0.notice = "Switched to GLM-5.3 Flash in Frog Cloud"
        }
        let host = NSHostingView(rootView: TrayPreview(state: s).frame(width: 720))
        XCTAssertEqual(host.fittingSize.height, 108, accuracy: 0.5)
    }

    /// The where chip is the place's own: a folder shows its name and branch, a folder outside
    /// git shows no branch, "No repo" and "Just chat" show none.
    func testWhereChipWords() {
        XCTAssertEqual(M.Where.folder(folder: "/x/frog", branch: "main", worktree: true, git: true, dirty: false).name, "frog")
        XCTAssertEqual(M.Where.folder(folder: "/x/frog", branch: "main", worktree: true, git: true, dirty: false).branch, "main")
        XCTAssertNil(M.Where.folder(folder: "/x/notes", branch: "", worktree: false, git: false, dirty: false).branch)
        XCTAssertNil(M.Where.cloud(repo: "No repo", branch: "").branch)
        XCTAssertEqual(M.Where.chat.icon, "bubble.left")
        XCTAssertEqual(M.Where.cloud(repo: "ecto/pond", branch: "main").icon, "cloud")
        XCTAssertEqual(WhereMenu.githubRepo("https://github.com/ecto/pond/pull/3"), "ecto/pond")
        XCTAssertEqual(WhereMenu.githubRepo("git@github.com:ecto/pond.git"), "ecto/pond")
        XCTAssertNil(WhereMenu.githubRepo("pond"))
        XCTAssertEqual(WhereChipLabel.middle("ecto/slamwich", 12), "ecto/sl…wich")
        XCTAssertEqual(WhereChipLabel.middle("frog", 12), "frog")
    }

    /// The three placeholders.
    func testPlaceholders() {
        XCTAssertEqual(TrayWords.placeholder(state()), "What should we work on?")
        XCTAssertEqual(TrayWords.placeholder(state { $0.where = session() }), "Reply to Frog")
        XCTAssertEqual(TrayWords.placeholder(state { $0.where = session(); $0.busy = .working }), "Add a follow-up")
    }
}
