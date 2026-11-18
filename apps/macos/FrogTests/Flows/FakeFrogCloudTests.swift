import Foundation
import XCTest
@testable import Frog

/// The fake Frog Cloud through the app's own account and gateway code, no window: sign-in comes
/// back with a key that lands in the fake (never the Keychain), the account reads it, top-up
/// opens Checkout through the seam, and the gateway makes a session on a repo.
@MainActor
final class FakeFrogCloudTests: XCTestCase {
    private var cloud: FakeFrogCloud!

    override func setUp() async throws {
        cloud = try FakeFrogCloud()
        CloudAccount.noKeychain = true
        CloudAccount.shared.stage(nil)
        cloud.install()
    }

    override func tearDown() async throws {
        cloud.uninstall()
        CloudAccount.shared.unstage()
        CloudAccount.noKeychain = false
        Library.shared.cloudChanged([])
    }

    func testSignInAccountCheckoutAndASession() async throws {
        CloudSignIn.timeout = 10
        defer { CloudSignIn.timeout = 60 }
        try await CloudAccount.signInAndSave(provider: "github")
        XCTAssertNotNil(cloud.savedKey)
        XCTAssertEqual(CloudAccount.shared.me?.name, "Flow Tester")
        XCTAssertEqual(CloudAccount.shared.me?.credit_cents, 500)

        await CloudAccount.shared.topUp(10)
        XCTAssertEqual(cloud.opened.last?.host, "checkout.example.invalid", "Checkout opened through the seam")
        XCTAssertEqual(cloud.requested("POST /v1/billing/topup")?["amount"] as? Int, 10_000_000)

        let s = try await CloudSessions.shared.create(repo: "flowtester/demo")
        XCTAssertEqual(s?.repo, "flowtester/demo")
        XCTAssertEqual(cloud.requested("POST /v1/sessions")?["repo"] as? String, "flowtester/demo")
    }

    /// Nothing about the fake reaches the developer's Frog: the account origin is the fake's
    /// while installed and the real one after.
    func testInstallAndUninstallRestoreTheRealOrigins() {
        XCTAssertEqual(CloudAccount.origin, cloud.origin)
        XCTAssertEqual(CloudGateway.origin, cloud.origin)
        cloud.uninstall()
        XCTAssertEqual(CloudAccount.origin.host, "api.frog.toys")
        cloud.install()
    }
}
