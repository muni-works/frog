import XCTest
@testable import Frog

/// Chapter derivation for the timeline rail (see `Chapter`): a chapter starts at each prompt,
/// at a compaction notice, and after a run of turns with no prompt.
@MainActor
final class ChapterTests: XCTestCase {
    private func turn(_ input: String = "", notice: String? = nil) -> TurnState {
        var t = TurnState(input: input)
        if let notice { t.items.append(ItemState(id: "n", kind: .notice(warning: false), text: notice)) }
        return t
    }

    func testPromptsStartChapters() {
        let turns = [turn("one"), turn(), turn(), turn("two"), turn()]
        let chapters = Chapter.of(turns)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].turn, turns[0].id)
        XCTAssertEqual(chapters[0].kind, .prompt)
        XCTAssertEqual(chapters[1].turn, turns[3].id)
        XCTAssertEqual(Chapter.starts(of: chapters, in: turns), [0, 3])
    }

    func testCompactionStartsAChapter() {
        let turns = [turn("one"), turn(), turn(),
                     turn(notice: "Summarized the conversation to save context (120000 → 40000 tokens)"),
                     turn(), turn("two")]
        let chapters = Chapter.of(turns)
        XCTAssertEqual(chapters.map(\.kind), [.prompt, .compacted, .prompt])
        XCTAssertEqual(Chapter.starts(of: chapters, in: turns), [0, 3, 5])
    }

    func testLongRunBreaksIntoChapters() {
        let turns = [turn("go")] + (0..<Chapter.runAfter).map { _ in turn() } + [turn()]
        let chapters = Chapter.of(turns)
        XCTAssertEqual(chapters.map(\.kind), [.prompt, .run])
        XCTAssertEqual(Chapter.starts(of: chapters, in: turns), [0, Chapter.runAfter + 1])
    }

    func testCurrentChapterIsTheLastStartAtOrBeforeTheTurn() {
        let turns = [turn("one"), turn(), turn("two"), turn()]
        let starts = Chapter.starts(of: Chapter.of(turns), in: turns)
        XCTAssertEqual(Chapter.index(of: 0, in: starts), 0)
        XCTAssertEqual(Chapter.index(of: 1, in: starts), 0)
        XCTAssertEqual(Chapter.index(of: 2, in: starts), 1)
        XCTAssertEqual(Chapter.index(of: 3, in: starts), 1)
    }

    func testWarningNoticesAreNotCompactions() {
        var warn = turn(notice: "Summarized the conversation to save context (1 → 1 tokens)")
        warn.items[0] = ItemState(id: "w", kind: .notice(warning: true), text: warn.items[0].text)
        let chapters = Chapter.of([turn("one"), warn, turn(), turn(), turn(), turn()])
        XCTAssertEqual(chapters.map(\.kind), [.prompt])
    }

    func testChapterTitlesAreTheFirstClauseInAFewWords() {
        XCTAssertEqual(Chapter.words("build named chapters on the rail: a short title per chapter"), "build named chapters")
        XCTAssertEqual(Chapter.words("let's go middle ground, and push"), "go middle ground")
        XCTAssertEqual(Chapter.words("can you please profile the frog.app and figure out"), "profile the frog.app")
        XCTAssertEqual(Chapter.words("nope. i feel like it's a frontend bug"), "nope")
        XCTAssertEqual(Chapter.words("Install the new build and restart frog"), "install the new build")
        XCTAssertEqual(Chapter.title(Chapter(turn: UUID(), number: 1, kind: .prompt), TurnState(input: "?"), turns: 1), "?")
        XCTAssertEqual(Chapter.title(Chapter(turn: UUID(), number: 1, kind: .prompt), TurnState(input: "<session-message from=\"x\">hi</session-message>"), turns: 3), "on its own · 3 turns")
    }

    // MARK: Model titles (`chapter_titled`)

    private var seq: UInt64 = 0

    private func ingest(_ c: Conversation, _ event: String) {
        seq += 1
        let line = #"{"seq":\#(seq),"session":"ch","created":1790113417019,"event":\#(event)}"#
        guard let env = try? JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)) else {
            return XCTFail("bad event: \(line)")
        }
        c.ingest(env)
    }

    func testHeuristicShowsUntilTheModelTitleArrivesThenTheModelWins() {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp"), link: nil, replay: false)
        ingest(c, #""turn_started","turn":1,"input":"can you fix the rail, it jumps""#)
        ingest(c, #""turn_started","turn":2,"input":"now draft the release notes""#)
        // Instantly: the heuristic titles, before any model title.
        XCTAssertEqual(Chapter.cached(c.turns).titles, ["fix the rail", "draft the release notes"])
        // The engine titled the closed chapter: it wins, the open one stays heuristic.
        ingest(c, #""chapter_titled","turn":1,"title":"timeline rail fix""#)
        XCTAssertEqual(c.turns[0].chapterTitle, "timeline rail fix")
        XCTAssertEqual(Chapter.cached(c.turns).titles, ["timeline rail fix", "draft the release notes"])
        // A title for a turn that isn't here (or an empty one) changes nothing.
        ingest(c, #""chapter_titled","turn":9,"title":"ghost""#)
        ingest(c, #""chapter_titled","turn":2,"title":"""#)
        XCTAssertEqual(Chapter.cached(c.turns).titles, ["timeline rail fix", "draft the release notes"])
    }

    func testModelTitleOverridesEveryKind() {
        var t = TurnState(input: "<session-message from=\"x\">hi</session-message>")
        XCTAssertEqual(Chapter.title(Chapter(turn: t.id, number: 1, kind: .run), t, turns: 7), "on its own · 7 turns")
        t.chapterTitle = "fleet drain"
        XCTAssertEqual(Chapter.title(Chapter(turn: t.id, number: 1, kind: .run), t, turns: 7), "fleet drain")
        XCTAssertEqual(Chapter.title(Chapter(turn: t.id, number: 1, kind: .compacted), t, turns: 2), "fleet drain")
    }
}
