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
        let line = EngineProcess.endDescription(stderr: stderr, out: "", signal: 15, exit: "signal 15")
        XCTAssertEqual(line, "The frog engine was stopped from outside frog (SIGTERM).")
    }

    /// A real failure keeps its words: the error line, with the traces around it dropped.
    func testARealErrorKeepsItsLine() {
        let stderr = """
        call 1 done in 2.0s · first token 1.0s · 10 in, 5 out · ToolUse
        thread 'main' panicked at src/engine/turn.rs:12:5:
        index out of bounds
        call 2 thinking → m · ~10 tokens in · 1 tools · reply up to 100
        """
        let line = EngineProcess.endDescription(stderr: stderr, out: "", signal: 6, exit: "signal 6")
        XCTAssertEqual(line, "index out of bounds")
    }

    func testNothingSaidFallsBackToTheExit() {
        XCTAssertEqual(EngineProcess.endDescription(stderr: "", out: "", signal: nil, exit: "status 1"),
                       "The frog engine exited (status 1).")
    }

    /// The engine's fatal error is printed on stdout after the events stop (render::error),
    /// colored: "✗ this worktree (…) already has an engine: session …". That line, not the
    /// status fallback, is the banner.
    func testAFatalLineOnStdoutIsTheBanner() {
        let out = "\u{1b}[38;5;9m✗\u{1b}[39m \u{1b}[38;5;9mthis worktree (/repo/.frog/worktrees/w) already has an engine: "
            + "session eng-0002 (pid 60428) is running in it. One engine per worktree.\u{1b}[39m\n"
        let line = EngineProcess.endDescription(stderr: "", out: out, signal: nil, exit: "status 1")
        XCTAssertEqual(line,
            "this worktree (/repo/.frog/worktrees/w) already has an engine: session eng-0002 (pid 60428) is running in it. One engine per worktree.")
    }

    /// Protocol event lines on stdout are never the banner, even when they're last.
    func testAnEventLineOnStdoutIsNotTheBanner() {
        let out = #"{"seq":9,"session":"s","created":1,"event":"idle"}"#
            + "\n✗ the model isn't on this gateway"
        let line = EngineProcess.endDescription(stderr: "", out: out, signal: nil, exit: "status 1")
        XCTAssertEqual(line, "✗ the model isn't on this gateway")
    }

    /// Stderr's real error still wins over stdout's non-error chatter when both are kept.
    func testStderrErrorWinsOverStdoutChatter() {
        let out = "frog 0.1.0"
        let stderr = "error: no model configured"
        let line = EngineProcess.endDescription(stderr: stderr, out: out, signal: nil, exit: "status 1")
        XCTAssertEqual(line, "error: no model configured")
    }

    /// What the process itself keeps: event lines never land in `outLines`; the fatal line does,
    /// stripped of its color, and the store stays bounded.
    @MainActor
    func testKeepOutStoresNonEventLinesStrippedAndBounded() {
        let process = EngineProcess(
            binary: URL(fileURLWithPath: "/bin/true"), cwd: URL(fileURLWithPath: "/tmp"), arguments: [])
        process.keepOutForTesting(#"{"seq":1,"session":"s","created":1,"event":"idle"}"#)
        XCTAssertEqual(process.outLines, [])
        process.keepOutForTesting("\u{1b}[38;5;9m✗\u{1b}[39m \u{1b}[38;5;9mboom\u{1b}[39m")
        XCTAssertEqual(process.outLines, ["✗ boom"])
        for i in 0..<20 { process.keepOutForTesting("line \(i)") }
        XCTAssertEqual(process.outLines.count, 8)
        XCTAssertEqual(process.outText.split(separator: "\n").last, "line 19")
    }
}
