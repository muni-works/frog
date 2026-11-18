import AppKit
import XCTest
@testable import Frog

/// Frog Cloud flows against `FakeFrogCloud`: sign-in from the sidebar's foot, giving up on it,
/// low credit, the out-of-credit turn, and starting a session on a cloud repo.
final class CloudFlowTests: FlowTestCase {
    private var cloud: FakeFrogCloud!

    /// Signed in: as at a launch with an account, so the window comes up with it.
    private func openCloud(signedIn: Bool, credit: Double = 500) throws {
        cloud = try FakeFrogCloud()
        cloud.account.creditCents = credit
        cloud.install(signedIn: signedIn)
        if signedIn {
            CloudAccount.noKeychain = true
            refreshAccountNow()
        }
        try open(signedOut: !signedIn)
    }

    private func refreshAccountNow() {
        let done = Box()
        Task { @MainActor in
            await CloudAccount.shared.reloadKey()
            await CloudAccount.shared.refresh()
            await CloudSessions.shared.refresh()
            done.value = true
        }
        let end = Date().addingTimeInterval(10)
        while !done.value, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    override func tearDown() {
        super.tearDown()
        cloud?.uninstall()
        cloud = nil
        Library.shared.cloudChanged([])
    }

    private final class Box { var value = false }

    func test_sign_in_from_footer() throws {
        try openCloud(signedIn: false)
        XCTAssertTrue(w.shows("Sign in to Frog Cloud"))
        let menu = try XCTUnwrap(w.menu(.text("Sign in to Frog Cloud")))
        XCTAssertEqual(menu.titles, ["Continue with GitHub", "Continue with Google"])
        menu.choose("Continue with GitHub")
        expect("the footer shows the account") { self.w.shows("Flow") && self.w.shows("$5.00 credit") }
        XCTAssertNotNil(cloud.savedKey, "the key was saved")
        let page = try XCTUnwrap(cloud.signInPages.first)
        XCTAssertEqual(page.path, "/auth/web")
        XCTAssertTrue(page.query?.contains("provider=github") ?? false, page.absoluteString)
        XCTAssertNotNil(cloud.requested("POST /v1/auth/exchange"), "the code was exchanged")
    }

    func test_cancel_sign_in() throws {
        try openCloud(signedIn: false)
        cloud.browserCompletes = false
        let menu = try XCTUnwrap(w.menu(.text("Sign in to Frog Cloud")))
        menu.choose("Continue with GitHub")
        expect("it waits on the browser") { self.w.shows("Signing in…") }
        w.press(.text("Signing in…"))
        expect("back to signing in") { self.w.shows("Sign in to Frog Cloud") }
        XCTAssertNil(cloud.savedKey)
    }

    func test_see_low_credit() throws {
        try openCloud(signedIn: true, credit: 0)
        expect("the footer shows no credit left") { self.w.shows("$0.00 credit") }
    }

    /// A turn the edge refuses for money ends "out of credit", with a way to add some.
    func test_out_of_credit() throws {
        try open()
        engine.model.add(.reply(.error(402, "out of credit")))
        w.send("one more thing")
        expect("the turn says it's out of credit") { self.w.shows("out of credit") }
        w.press(Query(label: "add credit"))
        XCTAssertEqual(w.openedURLs.last?.absoluteString, "https://frog.toys/?settings=billing")
    }

    /// The where chip: a repo of the account's, then the first message starts a cloud session.
    func test_start_cloud_session_on_repo() throws {
        try openCloud(signedIn: true)
        w.press(.id("composer.where"))
        w.press(.text("flowtester/demo"))
        w.send("fix the readme in the cloud")
        expect("the gateway was asked for a session on the repo") {
            (self.cloud.requested("POST /v1/sessions")?["repo"] as? String) == "flowtester/demo"
        }
    }

    /// Signing in from the sidebar's foot, then the where menu: the account's repos are there.
    /// Found by this harness (2026-11-18): the composer loads repos only when it appears (and
    /// after the where menu's own sign-in), so after the footer's sign-in the menu has none and
    /// the app never asks the gateway for them.
    func testWhereMenuOffersReposAfterSigningInFromTheFooter() throws {
        try openCloud(signedIn: false)
        let menu = try XCTUnwrap(w.menu(.text("Sign in to Frog Cloud")))
        menu.choose("Continue with GitHub")
        expect("signed in") { self.w.shows("$5.00 credit") }
        w.press(.id("composer.where"))
        w.pump(1)
        XCTExpectFailure("found 2026-11-18: after signing in from the footer the composer never loads the account's repos")
        XCTAssertNotNil(cloud.requested("GET /v1/repos"), "the composer asked for the account's repos")
        XCTAssertTrue(w.shows("flowtester/demo"), "the where menu lists the account's repos")
    }

    /// Reported at v0.7.0: the where menu's "Choose a folder…" makes the conversation a plain
    /// chat (`switchFolder(nil)`) instead of asking for a folder.
    func testWhereMenuChooseAFolderAsksForAFolder() throws {
        try open()
        XCTAssertFalse(w.workspace.isChat)
        w.press(.id("composer.where"))
        w.press(.text("Choose a folder"))
        w.pump(0.5)
        XCTExpectFailure("v0.7.0 bug: Choose a folder… calls switchFolder(nil), which makes a plain chat")
        XCTAssertFalse(w.workspace.isChat, "the conversation stays in its folder until one is chosen")
    }
}
