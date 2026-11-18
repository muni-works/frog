import XCTest
@testable import Frog

/// The Mac's funnel events (`Funnel`): nothing at all without the opt-in, an install id only
/// while opted in, joined to the account once, and never a model name.
@MainActor
final class FunnelTests: XCTestCase {
    private var suite: String!
    private var sent: [URLRequest] = []
    private var key: String?

    override func setUp() async throws {
        suite = "FunnelTests-\(UUID().uuidString)"
        Funnel.defaults = UserDefaults(suiteName: suite)!
        sent = []
        key = nil
        Funnel.send = { [unowned self] in sent.append($0) }
        Funnel.key = { [unowned self] in key }
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        Funnel.defaults = .standard
        Funnel.send = { _ in }
        Funnel.key = { CloudAccount.shared.key }
    }

    private func body(_ r: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: Any])
    }

    func testSendsNothingWithoutTheOptIn() {
        Funnel.track("local_answer", ["model": "apple"])
        Funnel.turnEnded(model: "apple/on-device", cloud: false, end: .complete)
        Funnel.decided(tool: "Edit", .allow)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(Funnel.defaults.string(forKey: Funnel.installKey), "no id is made before the opt-in")
    }

    func testSignedOutSendsTheInstallIdToTheGatewayOnly() throws {
        Funnel.defaults.set(true, forKey: Funnel.optInKey)
        Funnel.track("model_download_started")
        Funnel.track("model_download_finished", ["ok": true])
        XCTAssertEqual(sent.count, 2)
        let r = sent[0]
        XCTAssertEqual(r.url?.path, "/v1/events")
        XCTAssertEqual(r.url?.host, CloudGateway.origin.host)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
        let a = try body(sent[0]), b = try body(sent[1])
        XCTAssertEqual(a["event"] as? String, "model_download_started")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(a["anon"] as? String)))
        XCTAssertEqual(a["anon"] as? String, b["anon"] as? String, "one install id")
    }

    func testFirstSignedInEventJoinsTheInstallThenStops() throws {
        Funnel.defaults.set(true, forKey: Funnel.optInKey)
        Funnel.track("edit_accepted")
        let anon = try body(sent[0])["anon"] as? String
        key = "frog_test"
        Funnel.track("edit_accepted")
        Funnel.track("edit_accepted")
        XCTAssertEqual(sent[1].value(forHTTPHeaderField: "Authorization"), "Bearer frog_test")
        XCTAssertEqual(try body(sent[1])["anon"] as? String, anon)
        XCTAssertNil(try body(sent[2])["anon"])
    }

    func testTurningItOffForgetsTheInstall() throws {
        Funnel.defaults.set(true, forKey: Funnel.optInKey)
        Funnel.track("edit_accepted")
        let first = try body(sent[0])["anon"] as? String
        Funnel.defaults.set(false, forKey: Funnel.optInKey)
        Funnel.forget()
        Funnel.defaults.set(true, forKey: Funnel.optInKey)
        Funnel.track("edit_accepted")
        XCTAssertNotEqual(try body(sent[1])["anon"] as? String, first)
    }

    func testLocalAnswersSayTheKindOfModelNeverItsName() throws {
        Funnel.defaults.set(true, forKey: Funnel.optInKey)
        Funnel.turnEnded(model: "apple/on-device", cloud: false, end: .complete)
        Funnel.turnEnded(model: "local/Qwen3-8B-4bit", cloud: false, end: .complete)
        Funnel.turnEnded(model: "cloud/glm-5.3-flash", cloud: false, end: .complete)
        Funnel.turnEnded(model: "local/Qwen3-8B-4bit", cloud: true, end: .complete)
        Funnel.turnEnded(model: "local/Qwen3-8B-4bit", cloud: false, end: .cancelled)
        XCTAssertEqual(try sent.map { try body($0)["props"] as? [String: String] }, [["model": "apple"], ["model": "local"]])
        for r in sent { XCTAssertFalse(String(decoding: r.httpBody!, as: UTF8.self).contains("Qwen")) }
    }

    func testOnlyAllowedEditsCount() {
        Funnel.defaults.set(true, forKey: Funnel.optInKey)
        Funnel.decided(tool: "Edit", .allow)
        Funnel.decided(tool: "Write", .allowAlways)
        Funnel.decided(tool: "Edit", .deny)
        Funnel.decided(tool: "Bash", .allow)
        XCTAssertEqual(sent.count, 2)
    }
}
