import XCTest
@testable import Frog

/// A provider's failure reads as a plain line, never an HTTP status and a JSON body; the raw
/// reply stays in `detail` for the disclosure and the log.
final class EngineErrorTests: XCTestCase {
    private func provider(_ status: Int, _ message: String?) -> EngineError {
        EngineError(type: "provider", status: status, message: message)
    }

    func testFrogCloudNoCapacityIsAPlainLine() {
        let body = #"{"error":{"message":"no inference capacity right now, retry shortly","type":"service_unavailable","code":503}}"#
        let e = provider(503, body)
        XCTAssertEqual(e.description, "The model is busy right now (no capacity), even after retrying. Try again in a moment.")
        XCTAssertEqual(e.reason, "no inference capacity right now, retry shortly")
        XCTAssertFalse(e.description.contains("{"))
        XCTAssertFalse(e.description.contains("Provider error"))
        XCTAssertTrue(e.detail.contains(body), "the raw body is kept for the disclosure")
        XCTAssertTrue(e.detail.contains("HTTP 503"))
    }

    func testStatusesHaveTheirOwnWords() {
        XCTAssertTrue(provider(429, #"{"error":{"message":"rate limited"}}"#).description.hasPrefix("Too many requests"))
        XCTAssertTrue(provider(401, "bad key").description.contains("Sign in again"))
        XCTAssertTrue(provider(402, nil).description.contains("Add credit"))
        XCTAssertTrue(provider(502, "<html>bad gateway</html>").description.hasPrefix("The model's server had a problem (502)"))
        XCTAssertTrue(provider(500, nil).description.contains("even after retrying"))
    }

    func testBusyWordingWithoutA503StillReadsAsBusy() {
        XCTAssertTrue(provider(529, #"{"error":{"message":"Overloaded"}}"#).description.hasPrefix("The model is busy"))
    }

    func testOtherClientErrorsShowAShortReasonButNeverJSON() {
        XCTAssertEqual(
            provider(400, #"{"error":{"message":"max_tokens is too large"}}"#).description,
            "The model call failed (400): Max_tokens is too large."
        )
        XCTAssertEqual(provider(400, #"{"error":{"nested":{"x":1}}}"#).description, "The model call failed (400).")
        XCTAssertEqual(provider(422, "{not json").description, "The model call failed (422).")
    }

    func testConnectionErrorsDontDumpTheTransportMessage() {
        let e = EngineError(type: "connection", status: nil, message: "error sending request for url (https://x/v1/chat): connection refused")
        XCTAssertEqual(e.description, "Couldn't reach the model. Check your connection and try again.")
        XCTAssertTrue(e.detail.contains("connection refused"))
    }
}
