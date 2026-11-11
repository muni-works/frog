import XCTest
@testable import Frog

/// Failure paths that used to be silent or raw: sign-in's copy and timeout, Frog Cloud's
/// errors, and sidecars outliving the app.
@MainActor
final class SilentFailureTests: XCTestCase {
    // MARK: sign-in copy: one set of words, never the system's

    func testSignInCopy() {
        XCTAssertNil(CloudAccount.signInFailure(CancellationError()), "a cancel is no error")
        XCTAssertNil(CloudAccount.signInFailure(URLError(.cancelled)))
        XCTAssertEqual(CloudAccount.signInFailure(URLError(.timedOut)), "Sign-in timed out. Try again.")
        XCTAssertEqual(CloudAccount.signInFailure(URLError(.notConnectedToInternet)), CloudFailure.offlineText)
        XCTAssertEqual(CloudAccount.signInFailure(URLError(.cannotConnectToHost)), CloudFailure.offlineText)
        XCTAssertEqual(CloudAccount.signInFailure(SignInError.notSaved),
                       "Signed in, but Frog couldn't save your key. Try again.")
        XCTAssertEqual(CloudAccount.signInFailure(CloudAccount.CloudError.rejected), "Sign-in didn't finish. Try again.")
        XCTAssertEqual(CloudAccount.signInFailure(NSError(domain: "x", code: 1)), "Sign-in didn't finish. Try again.")
    }

    func testCloudCopyHidesServerText() {
        let raw = CloudGateway.GatewayError(status: 500, message: "panic at gateway/src/lib.rs:42")
        XCTAssertEqual(CloudFailure.text(raw, doing: "start a Frog Cloud session"),
                       "Couldn't start a Frog Cloud session. Try again.")
        XCTAssertEqual(CloudFailure.text(CloudGateway.GatewayError(status: 401, message: "bad token"), doing: "x"),
                       "Your Frog Cloud sign-in has expired. Sign in again.")
        XCTAssertEqual(CloudFailure.text(CloudGateway.GatewayError(status: 402, message: "no credit"), doing: "x"),
                       "You're out of Frog Cloud credit. Add credit in Settings › Billing.")
        XCTAssertEqual(CloudFailure.text(URLError(.notConnectedToInternet), doing: "x"), CloudFailure.offlineText)
        XCTAssertEqual(CloudFailure.text(NSError(domain: NSCocoaErrorDomain, code: 4), doing: "load your Frog Cloud sessions"),
                       "Couldn't load your Frog Cloud sessions. Try again.")
    }

    // MARK: sign-in gives up when the browser never comes back

    func testAbandonedSignInTimesOut() async {
        XCTAssertEqual(CloudSignIn.timeout, 60, "a minute, not ten")
        let (timeout, open) = (CloudSignIn.timeout, CloudSignIn.openBrowser)
        defer { CloudSignIn.timeout = timeout; CloudSignIn.openBrowser = open }
        CloudSignIn.timeout = 0.3
        var opened: URL?
        CloudSignIn.openBrowser = { opened = $0 } // the tab "closed": nothing comes back
        let start = Date.now
        do {
            _ = try await CloudSignIn.run(provider: "github")
            XCTFail("an abandoned sign-in must not succeed")
        } catch {
            XCTAssertEqual(CloudAccount.signInFailure(error), "Sign-in timed out. Try again.")
        }
        XCTAssertLessThan(Date.now.timeIntervalSince(start), 5)
        XCTAssertEqual(opened?.path, "/auth/web")
    }

    func testCancelledSignInEndsWithoutError() async {
        let open = CloudSignIn.openBrowser
        defer { CloudSignIn.openBrowser = open }
        CloudSignIn.openBrowser = { _ in }
        let task = Task { try await CloudSignIn.run(provider: "github") }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled")
        } catch {
            XCTAssertNil(CloudAccount.signInFailure(error))
        }
    }

    // MARK: sidecars end with the app

    /// A stand-in "app" and "sidecar": once the app's pid is gone, the watch ends the sidecar.
    func testParentWatchEndsTheChildWhenTheParentDies() throws {
        let app = try sleeper(), child = try sleeper()
        let watch = try XCTUnwrap(ParentWatch.watch(child: child.processIdentifier, parent: app.processIdentifier))
        usleep(300_000)
        XCTAssertTrue(child.isRunning, "alive while the parent is")
        kill(app.processIdentifier, SIGKILL)
        let deadline = Date.now + 6
        while child.isRunning, Date.now < deadline { usleep(100_000) }
        XCTAssertFalse(child.isRunning, "the child outlived its parent")
        watch.waitUntilExit()
    }

    func testParentWatchEndsWhenTheChildDoes() throws {
        let child = try sleeper()
        let watch = try XCTUnwrap(ParentWatch.watch(child: child.processIdentifier))
        child.terminate()
        let deadline = Date.now + 5
        while watch.isRunning, Date.now < deadline { usleep(100_000) }
        XCTAssertFalse(watch.isRunning, "the watch outlived the child")
    }

    private func sleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        addTeardownBlock { if p.isRunning { p.terminate() } }
        return p
    }
}
