import XCTest
@testable import Frog

/// A push sealed for a pairing code opens with that code and no other, and what the Mac seals
/// is the whole alert (the phone's extension puts it back).
@MainActor
final class PushCryptoTests: XCTestCase {
    func testRoundTripsWithTheCodeOnly() throws {
        let plain = Data(#"{"aps":{"alert":{"title":"fix tests","body":"$ cargo test"}},"session":"s1"}"#.utf8)
        let sealed = try PushCrypto.seal(plain, code: "abcdefghjkmnpqrstuvw")
        XCTAssertEqual(PushCrypto.open(sealed, code: "abcdefghjkmnpqrstuvw"), plain)
        XCTAssertNil(PushCrypto.open(sealed, code: "abcdefghjkmnpqrstuvx"))
        XCTAssertNil(PushCrypto.open(String(sealed.dropLast(4)) + "AAAA", code: "abcdefghjkmnpqrstuvw"))
        XCTAssertNil(PushCrypto.open("not base64!", code: "abcdefghjkmnpqrstuvw"))
    }

    func testSealedPushKeepsOnlyWhatIOSNeedsInTheClear() throws {
        let payload: [String: Any] = [
            "aps": ["alert": ["title": "fix tests", "subtitle": "frog wants to run a command", "body": "$ rm -rf build"],
                    "category": "PERMISSION", "thread-id": "s1", "sound": "default", "interruption-level": "time-sensitive"],
            "session": "s1", "permission": "p1", "arg": "rm -rf build",
            "request": ["id": "p1", "name": "Bash", "arg": "rm -rf build", "preview": ["hunks": Array(repeating: ["lines": [["text": String(repeating: "x", count: 100)]]], count: 40)]],
        ]
        let outer = try XCTUnwrap(RemotePush.sealed(payload, code: "abcdefghjkmnpqrstuvw"))
        let text = String(decoding: try JSONSerialization.data(withJSONObject: outer), as: UTF8.self)
        XCTAssertFalse(text.contains("rm -rf"), "the command leaked")
        XCTAssertFalse(text.contains("fix tests"), "the title leaked")
        XCTAssertEqual((outer["aps"] as? [String: Any])?["category"] as? String, "PERMISSION")
        XCTAssertEqual((outer["aps"] as? [String: Any])?["mutable-content"] as? Int, 1)
        XCTAssertLessThanOrEqual(text.utf8.count, 4000, "over APNs' 4 KB")
        // The phone gets everything back but the diff, which was what had to go to fit.
        let inner = try XCTUnwrap(PushCrypto.open(try XCTUnwrap(outer["enc"] as? String), code: "abcdefghjkmnpqrstuvw"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: inner) as? [String: Any])
        XCTAssertEqual(obj["permission"] as? String, "p1")
        XCTAssertEqual(((obj["aps"] as? [String: Any])?["alert"] as? [String: Any])?["body"] as? String, "$ rm -rf build")
        XCTAssertNil((obj["request"] as? [String: Any])?["preview"])
    }
}
