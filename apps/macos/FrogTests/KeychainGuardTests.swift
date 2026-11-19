import XCTest
@testable import Frog

/// No test reaches the login Keychain. The test host shares the developer's, and isn't signed
/// like the Frog that made its items, so a read raises the system's password prompt mid-run
/// (and a write or delete would change their real keys). Each store keeps its secrets in
/// memory under XCTest, and each real Keychain call traps if one gets that far.
@MainActor
final class KeychainGuardTests: XCTestCase {
    /// Frog Cloud's key: under test it's `keyProvider`'s or nothing, even with `noKeychain` off
    /// (the flow tests turn that off again in their teardown).
    func testCloudKeyNeverComesFromTheKeychain() throws {
        let (had, hadNo) = (CloudAccount.keyProvider, CloudAccount.noKeychain)
        defer { (CloudAccount.keyProvider, CloudAccount.noKeychain) = (had, hadNo) }
        CloudAccount.keyProvider = nil
        CloudAccount.noKeychain = false
        if ProcessInfo.processInfo.environment["FROG_API_KEY"]?.isEmpty == false {
            throw XCTSkip("FROG_API_KEY is set")
        }
        XCTAssertNil(CloudAccount.readKey())
        CloudAccount.keyProvider = { "kc-from-provider" }
        XCTAssertEqual(CloudAccount.readKey(), "kc-from-provider")
    }

    /// A paired node's key round-trips in memory: saved, read back, removed.
    func testPairedKeysStayInMemory() throws {
        XCTAssertTrue(PairedStore.inMemory)
        let store = PairedStore(file: FileManager.default.temporaryDirectory.appending(path: "kc-guard-\(UUID()).json"),
                                service: "frog")
        let id = "kcguard\(UUID().uuidString.prefix(8))"
        let n = PairedNode(node_id: id, fingerprint: "fp-\(id)", name: "mew", base_url: "http://mew.local:8911")
        try store.save(n, key: "tnk_guard")
        XCTAssertEqual(store.key(for: id), "tnk_guard")
        try store.remove(nodeID: id)
        XCTAssertNil(store.key(for: id))
    }

    /// Every `frog` the test host starts inherits FROG_KEYCHAIN=off, so no engine or
    /// `frog --set-key` reads, writes or deletes the real items either.
    func testEnginesInheritKeychainOff() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FROG_LIVE_NODE"] == nil else { throw XCTSkip("live node: the real home on purpose") }
        XCTAssertEqual(env["FROG_KEYCHAIN"], "off")
    }
}
