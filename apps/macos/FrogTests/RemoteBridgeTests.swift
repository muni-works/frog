import Security
import XCTest
@testable import Frog

/// The bridge's session rows: a phone renders the org from them, so `parent` (the started-by
/// link in `Library.parents`) has to round-trip, and `welcome` has to name the protocol version.
@MainActor
final class RemoteBridgeTests: XCTestCase {
    override func tearDown() {
        Library.shared.unstage()
    }

    /// `sessionList` puts each session's recorded parent in its row, and leaves roots alone.
    func testSessionRowsCarryTheParent() {
        let sessions = [
            SessionInfo(id: "bridge-mgr", modified: 2, created: 2, model: "m",
                        firstInput: nil, title: "bridge manager", end: nil, forkedFrom: nil, cwd: "/tmp"),
            SessionInfo(id: "bridge-worker", modified: 1, created: 1, model: "m",
                        firstInput: nil, title: "bridge worker", end: nil, forkedFrom: nil, cwd: "/tmp"),
        ]
        Library.shared.stage(sessions: sessions, parents: ["bridge-worker": "bridge-mgr"])

        let rows = RemoteBridge.shared.sessionList().reduce(into: [:]) { d, r in
            d[r["id"] as? String ?? ""] = r["parent"]
        }
        XCTAssertEqual(rows["bridge-worker"] as? String, "bridge-mgr", "the child names its parent")
        XCTAssertNil(rows["bridge-mgr"], "the root has no parent field")
    }

    /// A test host never reads or writes the real Keychain item: it isn't the build that made
    /// it, so macOS would ask for the login password on every run. The code still behaves
    /// like a code: stable until a new one is asked for.
    func testTheCodeStaysOutOfTheKeychainUnderTest() {
        let first = RemoteBridge.token
        XCTAssertEqual(first.count, 20)
        XCTAssertEqual(RemoteBridge.token, first, "the same code until a new one is made")
        RemoteBridge.newToken()
        XCTAssertNotEqual(RemoteBridge.token, first, "a new code replaces it")

        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "toys.frog.remote",
                                kSecAttrAccount as String: "bridge-token",
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let attrs = out as? [String: Any], let made = attrs[kSecAttrModificationDate as String] as? Date {
            XCTAssertLessThan(made.timeIntervalSinceNow, -5, "this test run didn't write the Keychain item")
        }
    }
}
