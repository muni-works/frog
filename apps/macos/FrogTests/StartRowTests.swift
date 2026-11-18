import XCTest
@testable import Frog

/// A new Frog Cloud session's start on the live row (the web's #447): the words from verbs.json's
/// `start`, one stage at a time from real signals, held like the thought, and handed over to the
/// first turn's own row when the engine starts it.
final class StartRowTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func w(_ verb: String, _ object: String = "", failed: Bool = false) -> StartWords {
        StartWords(verb: verb, object: object, failed: failed)
    }

    @MainActor
    private func envelope(_ seq: UInt64, _ body: String) throws -> Envelope {
        try JSONDecoder.frog.decode(Envelope.self, from: Data(#"{"seq":\#(seq),"session":"s","created":0,\#(body)}"#.utf8))
    }

    /// The generator emits verbs.json's `start` into Verbs.swift, word for word.
    func testTheWordsAreVerbsJsonsStartSection() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "docs/design/transcript/verbs.json"))) as! [String: Any]
        let start = try XCTUnwrap(json["start"] as? [String: String])
        XCTAssertEqual(Verbs.Start.reserving, start["reserving"])
        XCTAssertEqual(Verbs.Start.booting, start["booting"])
        XCTAssertEqual(Verbs.Start.cloning, start["cloning"])
        XCTAssertEqual(Verbs.Start.engine, start["engine"])
        XCTAssertEqual(Verbs.Start.failed, start["failed"])
        XCTAssertEqual(Verbs.Start.stuck, start["stuck"])
        XCTAssertEqual(Verbs.Start.retry, start["retry"])
        XCTAssertEqual(Verbs.Start.cloning("muni-works/frog"), start["cloning"]!.replacingOccurrences(of: "{repo}", with: "muni-works/frog"))
    }

    func testEachStageSaysWhatTheGatewayReports() {
        XCTAssertEqual(StartWords.of(stage: .reserving, repo: nil, error: nil), w(Verbs.Start.reserving))
        XCTAssertEqual(StartWords.of(stage: .booting, repo: nil, error: nil), w(Verbs.Start.booting))
        XCTAssertEqual(StartWords.of(stage: .booting, repo: "a/b", error: nil), w("Booting it and cloning a/b"))
        XCTAssertEqual(StartWords.of(stage: .engine, repo: "a/b", error: nil), w(Verbs.Start.engine))
        XCTAssertEqual(StartWords.of(stage: .booting, repo: "a/b", error: "Can't reach Frog Cloud."),
                       w(Verbs.Start.failed, "Can't reach Frog Cloud.", failed: true))
    }

    /// Each value is held at least 1.2 s; then the newest known shows, skipping any in between.
    func testOneChangePerDwellAndTheNewestWins() {
        let said = [StartWords.Said(at: t0, words: w("A")),
                    StartWords.Said(at: t0 + 0.2, words: w("B")),
                    StartWords.Said(at: t0 + 0.5, words: w("C"))]
        XCTAssertEqual(StartWords.steady(said, now: t0 + 1.1).now, w("A"))
        let at = StartWords.steady(said, now: t0 + 1.2)
        XCTAssertEqual(at.now, w("C"), "B was superseded before its turn")
        XCTAssertEqual(at.n, 1)
        XCTAssertEqual(at.since, t0 + 1.2)
        // A later change waits a full dwell after the last one shown.
        let more = said + [StartWords.Said(at: t0 + 1.5, words: w("D"))]
        XCTAssertEqual(StartWords.steady(more, now: t0 + 2.3).now, w("C"))
        XCTAssertEqual(StartWords.steady(more, now: t0 + 2.4).now, w("D"))
        XCTAssertEqual(StartWords.steady(more, now: t0 + 2.4).n, 2)
    }

    func testReducedMotionSwapsAtOnce() {
        let said = [StartWords.Said(at: t0, words: w("A")), StartWords.Said(at: t0 + 0.2, words: w("B"))]
        XCTAssertEqual(StartWords.steady(said, now: t0 + 0.2, steady: false).now, w("B"))
        XCTAssertEqual(StartWords.steady(said, now: t0 + 0.1, steady: false).now, w("A"))
    }

    func testTheRowWaitsSixHundredMillisecondsAndNeverOutpacesTheThought() {
        XCTAssertEqual(StartWords.quiet, LiveState.quietStart)
        XCTAssertEqual(StartWords.dwell, 1.2)
    }

    /// Up 30 s with no turn: Failed, "Frog didn't pick this up.", unless the turn started.
    func testUpThirtySecondsWithNoTurnIsStuck() {
        let said = [StartWords.Said(at: t0, words: w(Verbs.Start.engine))]
        XCTAssertEqual(StartWords.at(said, upSince: t0, handed: false, now: t0 + 29), said)
        let stuck = StartWords.at(said, upSince: t0, handed: false, now: t0 + 30)
        XCTAssertEqual(stuck.last, StartWords.Said(at: t0 + 30, words: w(Verbs.Start.failed, Verbs.Start.stuck, failed: true)))
        XCTAssertEqual(StartWords.at(said, upSince: t0, handed: true, now: t0 + 60), said)
    }

    @MainActor
    func testStagesAreRecordedOnlyWhenTheyChange() {
        let s = CloudStart(text: "hi", repo: "a/b", since: t0)
        s.reached(.booting, at: t0 + 1)
        s.reached(.booting, at: t0 + 3)
        s.reached(.engine, at: t0 + 5)
        XCTAssertEqual(s.said.map(\.words.verb), [Verbs.Start.reserving, "Booting it and cloning a/b", Verbs.Start.engine])
        XCTAssertEqual(s.upSince, t0 + 5)
        XCTAssertFalse(s.stuck(at: t0 + 34))
        XCTAssertTrue(s.stuck(at: t0 + 35))
        s.fail("The sandbox couldn't start.", at: t0 + 6)
        s.reached(.booting, at: t0 + 7)
        XCTAssertEqual(s.said.last?.words, w(Verbs.Start.failed, "The sandbox couldn't start.", failed: true), "a failed start stays failed")
    }

    /// The first message is the first turn from Send. The link's idle (it comes once the socket is
    /// caught up, before the boot is done) leaves it busy; the engine's `turn_started` numbers the
    /// same turn and hands the row over, with no second bubble.
    @MainActor
    func testTheSentMessageIsTheFirstTurnAndTheEnginesTurnHandsOver() async throws {
        let link = PendingCloudLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false)
        let start = CloudStart(text: "fix the sidebar", repo: nil)
        c.open(start)
        XCTAssertEqual(c.turns.map(\.input), ["fix the sidebar"])
        XCTAssertTrue(c.startCovers(c.turns[0]))
        XCTAssertTrue(c.busy)

        let inner = LiveLink()
        link.attach(inner)
        inner.onEvent(try envelope(1, #""event":"idle""#))
        XCTAssertTrue(c.busy, "the link's first idle isn't the sandbox being up")
        XCTAssertTrue(c.startCovers(c.turns[0]))

        inner.onEvent(try envelope(2, #""event":"turn_started","turn":1,"input":"fix the sidebar""#))
        XCTAssertEqual(c.turns.count, 1, "the engine's turn is the one already drawn")
        XCTAssertEqual(c.turns[0].number, 1)
        XCTAssertNotNil(start.handedAt)
        XCTAssertEqual(start.said.last?.words.verb, Verbs.Live.thinking, "it hands over through the turn's own first words")
        XCTAssertTrue(c.startCovers(c.turns[0]), "the hand-over shows before the turn's row takes over")
        try await Task.sleep(for: .seconds(StartWords.dwell + StartWords.settle + 0.3))
        XCTAssertNil(c.start)
        XCTAssertFalse(c.startCovers(c.turns[0]))
    }

    /// A failed start says so on the row, and nothing runs: the composer is free to try again.
    @MainActor
    func testAFailedStartStopsBeingBusyAndKeepsItsRow() {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: PendingCloudLink(), replay: false)
        let start = CloudStart(text: "hi", repo: nil)
        c.open(start)
        c.startFailed("Couldn't start a Frog Cloud session. Try again.")
        XCTAssertFalse(c.busy)
        XCTAssertTrue(c.startCovers(c.turns[0]), "the row stays, saying Failed")
        XCTAssertTrue(start.failed)

        // Try again: the same turn, what was typed instead, a fresh start.
        let again = CloudStart(text: "hi there", repo: nil)
        c.restart(again)
        XCTAssertEqual(c.turns.map(\.input), ["hi there"])
        XCTAssertTrue(c.start === again)
        XCTAssertTrue(c.busy)
    }

    /// Stuck: the message goes again to the same session, as the same first turn.
    @MainActor
    func testAStuckStartSendsTheMessageAgainAsTheSameTurn() throws {
        let link = PendingCloudLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: link, replay: false)
        let inner = LiveLink()
        link.attach(inner)
        c.open(CloudStart(text: "hi", repo: nil))
        c.resendStart("hello")
        XCTAssertEqual(c.turns.map(\.input), ["hello"])
        inner.onEvent(try envelope(1, #""event":"turn_started","turn":1,"input":"hello""#))
        XCTAssertEqual(c.turns.count, 1)
        XCTAssertEqual(c.turns[0].number, 1)
    }

    /// What's sent before the session exists waits, and goes in order once it's attached.
    @MainActor
    func testThePendingLinkHoldsOpsUntilTheSessionsLink() {
        final class Recorder: ConversationLink {
            var onEvent: (Envelope?) -> Void = { _ in }
            var sent: [String] = []
            func send(_ op: Op) { sent.append(String(describing: op)) }
            func stop() {}
            var endDescription: String { "" }
        }
        let link = PendingCloudLink()
        link.send(.submit("one"))
        link.send(.interrupt)
        let r = Recorder()
        link.attach(r)
        XCTAssertEqual(r.sent.count, 2)
        XCTAssertTrue(r.sent[0].contains("one"))
        link.send(.submit("two"))
        XCTAssertEqual(r.sent.count, 3)

        // Starting again drops the failed session's link and anything still waiting.
        link.reset()
        link.send(.submit("three"))
        let r2 = Recorder()
        link.attach(r2)
        XCTAssertEqual(r2.sent.count, 1)
        XCTAssertTrue(r2.sent[0].contains("three"))
    }

    func testASessionErrorIsSaidInWords() {
        XCTAssertEqual(CloudFailure.session(nil), "The sandbox couldn't start.")
        XCTAssertEqual(CloudFailure.session("  "), "The sandbox couldn't start.")
        XCTAssertEqual(CloudFailure.session("No space left on device (os error 28)"), "The sandbox disk is full. Start a new session.")
        XCTAssertEqual(CloudFailure.session("clone failed: repository not found"), "clone failed: repository not found")
    }
}
