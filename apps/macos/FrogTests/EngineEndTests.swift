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
    /// colored and marked ✗. The process keeps the line plain (see `keepOut`), and that line,
    /// not the status fallback, is the banner.
    @MainActor
    func testAFatalLineOnStdoutIsTheBanner() {
        let process = EngineProcess(
            binary: URL(fileURLWithPath: "/bin/true"), cwd: URL(fileURLWithPath: "/tmp"), arguments: [])
        process.keepOutForTesting(#"{"seq":1,"session":"s","created":1,"event":"idle"}"#)
        process.keepOutForTesting("\u{1b}[38;5;9m✗\u{1b}[39m \u{1b}[38;5;9mthis worktree (/repo/.frog/worktrees/w) already has an engine: "
            + "session eng-0002 (pid 60428) is running in it. One engine per worktree.\u{1b}[39m\n")
        let line = EngineProcess.endDescription(stderr: "", out: process.outText, signal: nil, exit: "status 1")
        XCTAssertEqual(line,
            "this worktree (/repo/.frog/worktrees/w) already has an engine: session eng-0002 (pid 60428) is running in it. One engine per worktree.")
    }

    /// Protocol event lines on stdout are never the banner, even when they're last.
    @MainActor
    func testAnEventLineOnStdoutIsNotTheBanner() {
        let process = EngineProcess(
            binary: URL(fileURLWithPath: "/bin/true"), cwd: URL(fileURLWithPath: "/tmp"), arguments: [])
        process.keepOutForTesting("half a line")  // a partial line before its rest arrives
        process.keepOutForTesting(#"{"seq":9,"session":"s","created":1,"event":"idle"}"#)
        process.keepOutForTesting("✗ the model isn't on this gateway")
        let line = EngineProcess.endDescription(stderr: "", out: process.outText, signal: nil, exit: "status 1")
        XCTAssertEqual(line, "the model isn't on this gateway")
    }

    /// Both streams carry words: stdout's line wins. In `--serve` stdout's non-event lines
    /// are only ever the dying engine's render::error, while stderr's non-trace content
    /// (a panic) means the run died before render::error — mutually exclusive in practice,
    /// and the freshest words are the cause.
    func testStdoutFatalLineWinsOverStderrWords() {
        let out = "this worktree is busy"
        let stderr = "thread 'main' panicked: no model configured"
        let line = EngineProcess.endDescription(stderr: stderr, out: out, signal: nil, exit: "status 1")
        XCTAssertEqual(line, "this worktree is busy")
    }

    /// What the process keeps: event lines never land in `outLines`; the fatal line does,
    /// stripped of its color and the ✗; the store stays bounded, newest last.
    @MainActor
    func testKeepOutStoresNonEventLinesStrippedAndBounded() {
        let process = EngineProcess(
            binary: URL(fileURLWithPath: "/bin/true"), cwd: URL(fileURLWithPath: "/tmp"), arguments: [])
        process.keepOutForTesting(#"{"seq":1,"session":"s","created":1,"event":"idle"}"#)
        XCTAssertEqual(process.outLines, [])
        process.keepOutForTesting("\u{1b}[38;5;9m✗\u{1b}[39m \u{1b}[38;5;9mboom\u{1b}[39m")
        XCTAssertEqual(process.outLines, ["boom"])
        for i in 0..<20 { process.keepOutForTesting("line \(i)") }
        XCTAssertEqual(process.outLines.count, 8)
        XCTAssertEqual(process.outText.split(separator: "\n").last, "line 19")
    }
}

/// Engine failures read as plain lines; OS error strings never reach the transcript.
final class PlainEngineErrorTests: XCTestCase {
    func testAMissingSessionSaysWhatToDo() {
        let line = EngineProcess.endDescription(
            stderr: "no session 20261111-101400-834f: No such file or directory (os error 2)", out: "", signal: nil, exit: "status 1")
        XCTAssertEqual(line, "This session's history isn't on this Mac anymore, so it couldn't reopen. Start a new session.")
    }

    func testNoOSErrorStringIsShown() {
        for raw in ["reading config: Permission denied (os error 13)", "write: No space left on device (os error 28)",
                    "open x: No such file or directory (os error 2)", "bind: Address in use (os error 48)"] {
            let line = EngineError.plain(raw)
            XCTAssertFalse(line.contains("os error"), line)
            XCTAssertFalse(line.contains("No such file"), line)
        }
    }

    func testAPlainLineIsKept() {
        XCTAssertEqual(EngineError.plain("the model isn't on this gateway"), "the model isn't on this gateway")
    }

    func testAnErrorEventMapsToo() {
        let e = EngineError(type: "engine", status: nil, message: "no session abc: No such file or directory (os error 2)")
        XCTAssertFalse(e.description.contains("os error"))
    }
}
