import AppKit
import XCTest
@testable import Frog

/// The Changes tab's Commit and Open PR, and a race: started, applied, discarded.
final class GitAndRaceFlowTests: FlowTestCase {
    /// A turn that changes a file, so the Changes tab has something.
    private func changeAFile() {
        engine.model.add(
            .reply(.tool("Write", ["file_path": "NOTES.md", "content": "frog notes\n"])),
            .after("", .text("Wrote notes."))
        )
        w.send("write some notes")
        expect("the turn ended") { self.c?.turns.last?.finished == true && self.engine.file("NOTES.md") != nil }
    }

    private func openChanges() {
        if !w.panes.focused.showChanges { w.press(.button("Inspector")) }
        w.element(.button("Commit"))
    }

    func test_commit_from_changes() throws {
        try open(mode: .acceptEdits)
        changeAFile()
        openChanges()
        engine.model.add(.after("Commit the current changes", .text("Committed.")))
        w.press(.button("Commit"))
        expect("Frog got a turn to commit") { self.engine.model.requests.contains { $0.contains("Commit the current changes") } }
        expect("that turn answered") { self.w.shows("Committed.") }
    }

    func test_open_pr_or_push() throws {
        try open(mode: .acceptEdits)
        changeAFile()
        openChanges()
        engine.model.add(.after("open a pull request", .text("Opened.")))
        w.press(.button("Open PR"))
        expect("Frog got a turn to open a PR") { self.engine.model.requests.contains { $0.contains("open a pull request") } }
    }

    // MARK: Race

    /// Session › Race… with a prompt typed: three attempts, each writing the file.
    private func startRace() {
        for _ in 0..<3 {
            engine.model.add(.after("race this", .tool("Write", ["file_path": "RACE.md", "content": "raced\n"])))
        }
        for _ in 0..<3 { engine.model.add(.after("", .text("Raced."))) }
        w.typeInComposer("race this")
        w.menuBar("Session", "Race…")
        w.press(.button("Start 3 Attempts"))
        expect("the race card shows its attempts") { self.w.shows("Racing 3 attempts") }
    }

    func test_start_race() throws {
        try open()
        startRace()
        XCTAssertNotNil(w.workspace.race)
        XCTAssertEqual(w.workspace.race?.attempts.count, 3)
    }

    func test_start_race__apply() throws {
        try open()
        startRace()
        let race = try XCTUnwrap(w.workspace.race)
        expect("every attempt finished", timeout: 60) { race.allFinished }
        XCTAssertNil(engine.file("RACE.md"), "nothing in the project before Apply")
        w.press(.button("Apply"))
        expect("the attempt's change is in the project", timeout: 30) { self.engine.file("RACE.md") == "raced\n" }
        expect("the card closed") { self.w.workspace.race == nil }
        expect("the worktrees went", timeout: 10) { race.attempts.allSatisfy { !FileManager.default.fileExists(atPath: $0.dir.path) } }
    }

    func test_discard_race() throws {
        try open()
        startRace()
        let race = try XCTUnwrap(w.workspace.race)
        w.press(.button("Discard All"))
        expect("the card closed") { self.w.workspace.race == nil }
        expect("every attempt stopped") { race.attempts.allSatisfy { !$0.conversation.isLive } }
        expect("the worktrees went", timeout: 15) { race.attempts.allSatisfy { !FileManager.default.fileExists(atPath: $0.dir.path) } }
        XCTAssertNil(engine.file("RACE.md"))
    }
}
