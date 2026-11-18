import XCTest
@testable import Frog

/// The line a turn shows while its model gets ready (Cam, 0.6.4: "Loading apple into memory"
/// under a second "Loading apple" row, for Apple Intelligence). The name is the one the model
/// menu uses, the words are true to the kind of model, and there is one loading line, not two.
@MainActor
final class ModelLoadTests: XCTestCase {
    /// Apple Intelligence is the system's model: it's started, not read into memory.
    func testAppleIntelligenceIsStarted() throws {
        let load = try XCTUnwrap(ModelLoad(label: "starting Apple Intelligence"))
        XCTAssertEqual(load.kind, .system)
        XCTAssertEqual(load.title, "Starting Apple Intelligence")
        XCTAssertNil(load.caption)
        // The label an older engine sent says the same, never "apple".
        XCTAssertEqual(ModelLoad(label: "loading apple")?.title, "Starting Apple Intelligence")
    }

    /// A downloaded model really is loaded into memory, by the name the menu gives it.
    func testDownloadedModelIsLoadedIntoMemoryByItsMenuName() throws {
        let load = try XCTUnwrap(ModelLoad(label: "loading mlx-community/Qwen3-32B-4bit"))
        XCTAssertEqual(load.kind, .downloaded)
        XCTAssertEqual(load.title, "Loading \(ModelIdentity.rowName("local/mlx-community/Qwen3-32B-4bit")) into memory")
        XCTAssertEqual(load.title, "Loading Qwen3 32B into memory")
        XCTAssertEqual(load.caption, "Starting the first response")
    }

    /// Other progress isn't a model load, and reads as it did.
    func testOtherProgressIsNotAModelLoad() {
        XCTAssertNil(ModelLoad(label: "thinking"))
        XCTAssertNil(ModelLoad(label: "compacting"))
        XCTAssertNil(ModelLoad(label: "starting the classifier"))
        XCTAssertEqual(ModelLoad.words("compacting"), "Compacting")
        XCTAssertEqual(ModelLoad.words("starting Apple Intelligence"), "Starting Apple Intelligence")
    }

    /// One loading line: while the turn's card shows a model getting ready, the transcript's
    /// working row steps aside; for anything else, and once the turn is over, it doesn't.
    func testOnlyOneLoadingIndication() {
        let running = TurnState(input: "test")
        let apple = EngineProgress(label: "starting Apple Intelligence", completed: nil, total: nil)
        let tang = EngineProgress(label: "loading mlx-community/Qwen3-32B-4bit", completed: nil, total: nil)
        XCTAssertTrue(WorkingIndicator.yields(to: apple, turn: running))
        XCTAssertTrue(WorkingIndicator.yields(to: tang, turn: running))
        XCTAssertFalse(WorkingIndicator.yields(to: EngineProgress(label: "compacting", completed: nil, total: nil), turn: running))
        XCTAssertFalse(WorkingIndicator.yields(to: nil, turn: running))
        // No running turn (the session starting, before any message): the row is the only line.
        XCTAssertFalse(WorkingIndicator.yields(to: apple, turn: nil))
        var done = running
        done.end = .complete
        XCTAssertFalse(WorkingIndicator.yields(to: apple, turn: done))
    }
}
