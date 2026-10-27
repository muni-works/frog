import XCTest
@testable import Frog

/// The red line when an engine the app didn't stop is gone (`EngineProcess.endDescription`).
final class EngineEndTests: XCTestCase {
    /// The premium-shell report: another session `kill`ed the engine, and the line read
    /// "call 2 done in 12.6s · first token 11.7s · … · ToolUse", timing traces, as if it crashed.
    func testAKilledEngineSaysSoNotItsTimingTraces() {
        let stderr = """
        call 1 done in 6.3s · first token 5.7s · 117395 in, 48 out · ToolUse
        call 2 thinking → vercel/zai/glm-5.3-flash · ~123386 tokens in · 50 tools · reply up to 16384
        call 2 done in 12.6s · first token 11.7s · 117509 in, 73 out · ToolUse
        """
        let line = EngineProcess.endDescription(stderr: stderr, signal: 15, exit: "signal 15")
        XCTAssertEqual(line, "The frog engine was stopped from outside frog (SIGTERM).")
    }

    /// A real failure keeps its words: the error lines, with the traces around them dropped.
    func testARealErrorKeepsItsLines() {
        let stderr = """
        call 1 done in 2.0s · first token 1.0s · 10 in, 5 out · ToolUse
        thread 'main' panicked at src/engine/turn.rs:12:5:
        index out of bounds
        call 2 thinking → m · ~10 tokens in · 1 tools · reply up to 100
        """
        let line = EngineProcess.endDescription(stderr: stderr, signal: 6, exit: "signal 6")
        XCTAssertEqual(line, "thread 'main' panicked at src/engine/turn.rs:12:5:\nindex out of bounds")
    }

    func testNothingSaidFallsBackToTheExit() {
        XCTAssertEqual(EngineProcess.endDescription(stderr: "", signal: nil, exit: "status 1"),
                       "The frog engine exited (status 1).")
    }
}
