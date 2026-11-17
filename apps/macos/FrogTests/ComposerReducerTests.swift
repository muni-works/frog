import XCTest
@testable import Frog

/// ComposerModel against the shared vectors (docs/design/composer/cases.json). The web's
/// apps/web/test/composer.test.ts runs the same file against composer.ts: a behaviour change is
/// a new case there, and both fail until they agree.
final class ComposerReducerTests: XCTestCase {

    private struct Doc: Decodable {
        struct Case: Decodable { let name: String; let given: JSON; let intent: JSON; let expect: JSON; let effects: JSON }
        let base: JSON
        let cases: [Case]
    }

    private func doc() throws -> Doc {
        // FROG_COMPOSER_DOCS: another docs/design folder (another branch's regenerated cases),
        // so a reducer can be run against them without touching the checked-in file.
        let design = ProcessInfo.processInfo.environment["FROG_COMPOSER_DOCS"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("docs/design")
        let url = design.appendingPathComponent("composer/cases.json")
        return try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
    }

    /// Objects merge, arrays and scalars replace.
    private func merge(_ a: JSON, _ b: JSON) -> JSON {
        guard case .object(var out) = a, case .object(let over) = b else { return b }
        for (k, v) in over { out[k] = out[k].map { merge($0, v) } ?? v }
        return .object(out)
    }

    /// Partial match: objects match the listed keys (missing is null), arrays match length and
    /// each element.
    private func match(_ actual: JSON, _ want: JSON, _ path: String) -> String? {
        switch want {
        case .object(let w):
            guard case .object(let a) = actual else { return "\(path): wanted an object, got \(actual)" }
            for (k, v) in w.sorted(by: { $0.key < $1.key }) {
                if let m = match(a[k] ?? .null, v, "\(path).\(k)") { return m }
            }
            return nil
        case .array(let w):
            guard case .array(let a) = actual, a.count == w.count else { return "\(path): wanted \(want), got \(actual)" }
            for (i, v) in w.enumerated() {
                if let m = match(a[i], v, "\(path)[\(i)]") { return m }
            }
            return nil
        default:
            return actual == want ? nil : "\(path): wanted \(want), got \(actual)"
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: JSON) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(json))
    }

    func testTheSharedCasesCoverThePlan() throws {
        let cases = try doc().cases
        XCTAssertGreaterThanOrEqual(cases.count, 60)
        XCTAssertEqual(Set(cases.map(\.name)).count, cases.count, "names are unique")
    }

    func testEverySharedCase() throws {
        let d = try doc()
        var failures: [String] = []
        for c in d.cases {
            let given = try decode(ComposerModel.State.self, merge(d.base, c.given))
            let intent = try decode(ComposerModel.Intent.self, c.intent)
            let (next, effects) = ComposerModel.reduce(given, intent)
            guard case .object(var got) = JSON(next) else { return XCTFail("state didn't encode") }
            got["derived"] = JSON(ComposerModel.derive(next))
            if let m = match(.object(got), c.expect, "state") ?? match(JSON(effects), c.effects, "effects") {
                failures.append("\(c.name): \(m)")
            }
        }
        XCTAssert(failures.isEmpty, failures.joined(separator: "\n"))
    }
}

/// The spec's logic changes (docs/design/composer/spec.md, "Changes to the shared logic"), from
/// Swift-built states, so they hold whatever the shared file says.
final class ComposerSpecTests: XCTestCase {
    private typealias M = ComposerModel
    private let model = M.Model(id: "local/qwen3-8b", name: "Qwen3 8B", place: .local, node: nil)

    private func state(_ edit: (inout M.State) -> Void = { _ in }) -> M.State {
        var s = M.State(model: model, where: .folder(folder: "/tmp/frog", branch: "main", worktree: true, git: true, dirty: false))
        edit(&s)
        return s
    }

    private func session(dirty: Bool = false, ahead: Int = 0, prs: [M.Pr] = [], repo: String? = "muni-works/frog") -> M.Where {
        .session(.init(repo: repo, branch: "frog/x", worktree: true, worktreePath: nil, diff: .init(add: 0, del: 0, files: 0),
                       dirty: dirty, ahead: ahead, prs: prs))
    }

    private func pr(_ state: M.PrState) -> M.Pr {
        .init(repo: "muni-works/frog", number: 412, title: "PR", state: state, checks: .init(ok: 1, total: 1))
    }

    func testQueueingKeepsTheTextAndItsAttachments() {
        let shot = M.Attachment(name: "shot.png", size: 10, type: "image/png")
        let s = state {
            $0.where = session()
            $0.busy = .working
            $0.draft = .init(text: "look at this", attachments: [shot], caret: 12)
        }
        let (n, fx) = M.reduce(s, .send)
        XCTAssertEqual(n.queued, [M.Queued(text: "look at this", attachments: [shot])])
        XCTAssertEqual(fx.map(\.type), ["queued"])
        XCTAssertEqual(n.draft, M.Draft())
    }

    func testRemoveQueuedTakesThatOneAndSaysSo() {
        let a = M.Queued(text: "a"), b = M.Queued(text: "b")
        let s = state { $0.busy = .working; $0.queued = [a, b] }
        let (n, fx) = M.reduce(s, .removeQueued(0))
        XCTAssertEqual(n.queued, [b])
        XCTAssertEqual(fx, [M.Effect("remove_queued", ["index": .number(0)])])
        let (same, none) = M.reduce(s, .removeQueued(5))
        XCTAssertEqual(same, s)
        XCTAssertTrue(none.isEmpty)
    }

    func testTurnDoneEmptiesTheQueue() {
        let s = state { $0.busy = .working; $0.queued = [.init(text: "a")] }
        XCTAssertEqual(M.reduce(s, .turnDone).0.queued, [])
    }

    func testDictationShowsListeningOverEveryFace() {
        var s = M.reduce(state(), .dictationStarted).0
        XCTAssertTrue(s.dictating)
        XCTAssertEqual(M.derive(s).action, .listening)
        s.draft.text = "make it"
        s.busy = .working
        XCTAssertEqual(M.derive(s).action, .listening, "listening wins over queue")
        XCTAssertEqual(M.reduce(s, .action).1, [M.Effect("stop_dictation")])
        s = M.reduce(s, .dictationEnded).0
        XCTAssertFalse(s.dictating)
        XCTAssertEqual(M.derive(s).action, .queue)
    }

    func testMicDeniedEndsDictationWithTheNewWords() {
        let (n, _) = M.reduce(state { $0.dictating = true }, .micDenied)
        XCTAssertFalse(n.dictating)
        XCTAssertEqual(n.error?.message, "Needs mic access to take dictation")
        XCTAssertEqual(n.error?.actions, ["open_settings"])
        XCTAssertEqual(n.error?.control, "action")
    }

    func testStatusFollowsThePriority() {
        let err = M.Failure(code: "cloud_busy", message: "Frog Cloud is busy", actions: ["retry"])
        var s = state {
            $0.where = session(dirty: true, prs: [pr(.approved)])
            $0.error = err
            $0.confirm = .merge
            $0.notice = "Switched"
        }
        XCTAssertEqual(M.derive(s).status, .error)
        s.error = nil
        XCTAssertEqual(M.derive(s).status, .confirm)
        s.confirm = nil
        XCTAssertEqual(M.derive(s).status, .notice)
        s.notice = nil
        XCTAssertEqual(M.derive(s).status, .git)
    }

    func testGitStatusOnlyWithSomethingToReport() {
        XCTAssertEqual(M.derive(state()).status, .none, "a new session has no line")
        XCTAssertEqual(M.derive(state { $0.where = session() }).status, .none, "clean, nothing ahead, no PR")
        XCTAssertEqual(M.derive(state { $0.where = session(dirty: true, repo: nil) }).status, .none, "no repo")
        XCTAssertEqual(M.derive(state { $0.where = session(ahead: 1) }).status, .git)
        var diffOnly = session()
        if case .session(var w) = diffOnly { w.diff = .init(add: 3, del: 0, files: 1); diffOnly = .session(w) }
        XCTAssertEqual(M.derive(state { $0.where = diffOnly }).status, .git, "lines changed, as the web counts them")
        XCTAssertEqual(M.derive(state { $0.where = session(prs: [pr(.draft)]) }).status, .git, "a PR with no action still shows")
    }

    func testStateDecodesTheNewShape() throws {
        var s = state()
        s.queued = [.init(text: "a")]
        s.dictating = true
        let round = try JSONDecoder().decode(M.State.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(round, s)
        let intent = try JSONDecoder().decode(M.Intent.self, from: Data(#"{"type":"remove_queued","index":2}"#.utf8))
        XCTAssertEqual(intent, .removeQueued(2))
    }
}
