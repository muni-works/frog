import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// `frog://new?model=&prompt=&repo=`: the web's local-model rows open a new session on the Mac
/// with the model chosen and the message in the composer. Every part is untrusted, and nothing
/// is ever sent until the person presses send.
@MainActor
final class NewSessionLinkTests: XCTestCase {
    private func link(_ s: String) -> NewSessionLink? { NewSessionLink.parse(URL(string: s)!) }
    /// Where the request tests post: no window from another test hears (and takes) it.
    private let center = NotificationCenter()

    override func setUp() {
        super.setUp()
        NewSessionRequest.reset()
    }

    override func tearDown() {
        NewSessionRequest.reset()
        super.tearDown()
    }

    // MARK: - Parsing: good and partial

    func testAFullLink() {
        XCTAssertEqual(link("frog://new?model=qwen3-8b&prompt=fix%20the%20tests%0Athen%20push&repo=muni-works/frog"),
                       NewSessionLink(model: "qwen3-8b", prompt: "fix the tests\nthen push", repo: "muni-works/frog"))
        XCTAssertEqual(link("frog-dev://new?prompt=hi"), NewSessionLink(prompt: "hi"), "a Debug build's links")
        XCTAssertEqual(link("frog://new/?model=local/mlx-community/Qwen3-8B-4bit"),
                       NewSessionLink(model: "local/mlx-community/Qwen3-8B-4bit"))
    }

    func testEveryPartIsOptional() {
        XCTAssertEqual(link("frog://new"), NewSessionLink())
        XCTAssertEqual(link("frog://new?"), NewSessionLink())
        XCTAssertEqual(link("frog://new?model=qwen3-4b"), NewSessionLink(model: "qwen3-4b"))
        XCTAssertEqual(link("frog://new?repo=a/b"), NewSessionLink(repo: "a/b"))
        XCTAssertEqual(link("frog://new?unknown=1&prompt=x"), NewSessionLink(prompt: "x"), "an unknown part is ignored")
    }

    func testOtherLinksAreNotNewLinks() {
        XCTAssertNil(link("frog://settings/models"))
        XCTAssertNil(link("frog://new/session?prompt=x"), "a path is some other link")
        XCTAssertNil(link("https://new?prompt=x"))
        XCTAssertNil(link("frogx://new?prompt=x"))
        XCTAssertNil(link("frog://pair?code=1"))
    }

    /// Foundation doesn't turn `+` into a space; the web encodes with `encodeURIComponent`.
    func testPlusStaysAPlus() {
        XCTAssertEqual(link("frog://new?prompt=a+b")?.prompt, "a+b")
        XCTAssertEqual(link("frog://new?prompt=a%2Bb%20c")?.prompt, "a+b c")
        XCTAssertEqual(link("frog://new?prompt=%E2%9C%85%20done")?.prompt, "✅ done")
    }

    func testTheFirstOfARepeatedPartWins() {
        XCTAssertEqual(link("frog://new?prompt=mine&prompt=theirs")?.prompt, "mine")
        XCTAssertEqual(link("frog://new?model=qwen3-4b&model=evil")?.model, "qwen3-4b")
    }

    // MARK: - Parsing: hostile

    func testHiddenCharactersDropTheMessage() {
        for bad in ["%00", "%1B%5B2J", "%07", "%7F", "%C2%85", "%E2%80%AE", "%E2%80%8B", "%E2%81%A6", "%EF%BB%BF", "%E2%80%8F"] {
            let l = link("frog://new?prompt=hello\(bad)world&model=qwen3-4b")
            XCTAssertNil(l?.prompt, "\(bad) is dropped, never shown")
            XCTAssertEqual(l?.model, "qwen3-4b", "the rest of the link still opens")
        }
    }

    func testNewlinesAndTabsStay() {
        XCTAssertEqual(link("frog://new?prompt=a%0A%09b")?.prompt, "a\n\tb")
        XCTAssertEqual(link("frog://new?prompt=a%0D%0Ab%0Dc")?.prompt, "a\nb\nc", "CR becomes a newline")
        XCTAssertNil(link("frog://new?prompt=%20%0A%09")?.prompt, "only whitespace is nothing")
        XCTAssertNil(link("frog://new?prompt=")?.prompt)
    }

    func testABadModelIsDropped() {
        for bad in ["qwen%203", "a;rm%20-rf", "../../etc", "%24(id)", "a%0Ab", String(repeating: "m", count: 201)] {
            XCTAssertNil(link("frog://new?model=\(bad)")?.model, bad)
        }
        XCTAssertEqual(link("frog://new?model=node/mew:Qwen3-4B")?.model, "node/mew:Qwen3-4B", "a machine spec is well-formed")
    }

    func testABadRepoIsDropped() {
        for bad in ["a", "a/b/c", "../x", "x/..", "x/.", "-x/y", "x/-y", "/x", "x/", "a%20b/c", "a/b%0A", "a_b/c",
                    String(repeating: "o", count: 40) + "/x", "x/" + String(repeating: "n", count: 101)] {
            XCTAssertNil(link("frog://new?repo=\(bad)")?.repo, bad)
        }
        XCTAssertEqual(link("frog://new?repo=muni-works/frog.toys_v2")?.repo, "muni-works/frog.toys_v2")
    }

    // MARK: - Parsing: oversized

    func testTheMessageCapRejectsRatherThanCuts() {
        let at = String(repeating: "a", count: NewSessionLink.maxPrompt)
        XCTAssertEqual(link("frog://new?prompt=\(at)")?.prompt, at)
        XCTAssertNil(link("frog://new?prompt=\(at)b")?.prompt, "one over the cap: dropped, not cut")
        // Counted in characters: a multi-byte message at the cap still fits.
        let frogs = String(repeating: "🐸", count: NewSessionLink.maxPrompt)
        let encoded = frogs.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(link("frog://new?prompt=\(encoded)")?.prompt, frogs)
    }

    func testAnEnormousLinkOpensEmpty() {
        let huge = String(repeating: "a", count: NewSessionLink.maxURL)
        XCTAssertEqual(link("frog://new?model=qwen3-4b&prompt=\(huge)"), NewSessionLink(),
                       "a link over the size limit isn't read, but it's still a new session")
    }

    // MARK: - The model

    private let catalog: [LocalCatalogModel] = {
        let json = #"""
        [{"id":"qwen3-8b","name":"Qwen3 8B","source":{"host":"hf","repo":"mlx-community/Qwen3-8B-4bit"},"format":"mlx",
          "download_bytes":1,"memory_bytes":1,"capabilities":[],"runs_on":["metal","cuda"],"local":true},
         {"id":"big-cloud","name":"Big","source":{"host":"hf","repo":"org/Big"},"format":"gguf",
          "download_bytes":1,"memory_bytes":1,"capabilities":[],"runs_on":["cuda"],"local":false}]
        """#
        return try! JSONDecoder().decode([LocalCatalogModel].self, from: Data(json.utf8))
    }()

    func testTheModelResolvesThroughTheCatalog() {
        let spec = "local/mlx-community/Qwen3-8B-4bit"
        XCTAssertEqual(NewSessionLink.localSpec(for: "qwen3-8b", catalog: catalog), spec, "the web's catalog id")
        XCTAssertEqual(NewSessionLink.localSpec(for: "QWEN3-8B", catalog: catalog), spec)
        XCTAssertEqual(NewSessionLink.localSpec(for: "mlx-community/qwen3-8b-4bit", catalog: catalog), spec, "a repo")
        XCTAssertEqual(NewSessionLink.localSpec(for: spec, catalog: catalog), spec, "a spec")
        XCTAssertNil(NewSessionLink.localSpec(for: "openai/gpt-5", catalog: catalog), "not in the catalog")
        XCTAssertNil(NewSessionLink.localSpec(for: "big-cloud", catalog: catalog), "not a model this Mac runs")
        XCTAssertNil(NewSessionLink.localSpec(for: "local/org/Big", catalog: catalog))
    }

    func testAModelNotOnThisMacIsNeverDownloaded() {
        XCTAssertEqual(NewSessionLink.choice(for: nil, catalog: catalog), .none)
        XCTAssertEqual(NewSessionLink.choice(for: "qwen3-8b", catalog: catalog, installed: { _ in true }),
                       .use("local/mlx-community/Qwen3-8B-4bit"))
        guard case .note(let why) = NewSessionLink.choice(for: "qwen3-8b", catalog: catalog, installed: { _ in false }) else {
            return XCTFail("a model that isn't here: the usual one, with a note")
        }
        XCTAssertTrue(why.contains("Qwen3 8B"), why)
        XCTAssertFalse(why.contains(" · "))
        guard case .note = NewSessionLink.choice(for: "openai/gpt-5", catalog: catalog, installed: { _ in true }) else {
            return XCTFail("a model the catalog doesn't name: the usual one, with a note")
        }
    }

    // MARK: - Where

    func testTheRepoOpensInAKnownCheckout() {
        let a = URL(fileURLWithPath: "/Users/me/code/frog"), b = URL(fileURLWithPath: "/Users/me/code/other")
        let remotes: [(folder: URL, repo: String?)] = [(b, nil), (a, "muni-works/frog")]
        XCTAssertEqual(NewSessionLink.checkout(of: "Muni-Works/Frog", in: remotes), a)
        XCTAssertNil(NewSessionLink.checkout(of: "someone/else", in: remotes), "unknown: the default")
        XCTAssertNil(NewSessionLink.checkout(of: nil, in: remotes))
    }

    func testKnownRemotesReadsEachFolderOnce() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "frog-newlink-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let remotes = NewSessionLink.knownRemotes([dir, dir, Frog.chatFolder])
        XCTAssertEqual(remotes.map(\.folder), [dir], "duplicates and the chat folder are skipped")
        XCTAssertNil(remotes.first?.repo, "no git, no remote")
    }

    // MARK: - Delivery: running and cold launch

    /// Already running: a second copy forwards its launch URLs to the running one untouched.
    func testTheHandOffForwardsTheLink() {
        let url = "frog://new?model=qwen3-8b&prompt=fix%20it%2Bnow&repo=muni-works/frog"
        let urls = SingleInstance.launchURLs(["/Applications/Frog.app/Contents/MacOS/Frog", "-psn_0_1", url])
        XCTAssertEqual(urls, [URL(string: url)!])
        XCTAssertEqual(urls.first.flatMap(NewSessionLink.parse)?.prompt, "fix it+now")
    }

    /// Running: the post reaches the open window (a notification). Cold launch: no window yet,
    /// so the link waits, and the first window takes it once.
    func testARequestIsPostedWaitsAndIsTakenOnce() {
        var heard = 0
        let token = center.addObserver(forName: NewSessionRequest.name, object: nil, queue: nil) { _ in heard += 1 }
        defer { center.removeObserver(token) }

        XCTAssertFalse(NewSessionRequest.post(URL(string: "frog://settings/models")!, center: center))
        XCTAssertNil(NewSessionRequest.pending)
        XCTAssertEqual(heard, 0)

        XCTAssertTrue(NewSessionRequest.post(URL(string: "frog://new?prompt=hi")!, center: center))
        XCTAssertEqual(heard, 1, "an open window hears it")
        XCTAssertEqual(NewSessionRequest.take(), NewSessionLink(prompt: "hi"), "a window opening now takes it")
        XCTAssertNil(NewSessionRequest.take(), "once")
    }

    /// The delegate and a window's onOpenURL can both get the same link: one session.
    func testTheSameDeliveryTwiceOpensOnce() {
        var heard = 0
        let token = center.addObserver(forName: NewSessionRequest.name, object: nil, queue: nil) { _ in heard += 1 }
        defer { center.removeObserver(token) }
        let url = URL(string: "frog://new?prompt=once")!
        let t = Date()
        NewSessionRequest.post(url, now: t, center: center)
        NewSessionRequest.post(url, now: t.addingTimeInterval(0.5), center: center)
        XCTAssertEqual(heard, 1)
        NewSessionRequest.post(URL(string: "frog://new?prompt=another")!, now: t.addingTimeInterval(0.6), center: center)
        XCTAssertEqual(heard, 2, "a different link is its own")
        NewSessionRequest.post(url, now: t.addingTimeInterval(5), center: center)
        XCTAssertEqual(heard, 3, "the same link later is a new click")
    }

    // MARK: - Nothing is sent

    private func idle() throws -> (Conversation, QueueLink) {
        let link = QueueLink()
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/frog-newlink"), link: link, replay: false)
        try link.event(#""event":"idle""#)
        return (c, link)
    }

    private var submits: (QueueLink) -> [[String: Any]] { { $0.sent.filter { $0["op"] as? String == "submit" } } }

    func testFillingNeverSubmits() throws {
        let (c, link) = try idle()
        NewSessionLink(prompt: "fix the tests").fill(c)
        XCTAssertEqual(c.restored, [Conversation.Queued(text: "fix the tests", typed: false)])
        XCTAssertTrue(submits(link).isEmpty)
        XCTAssertTrue(c.turns.isEmpty)
        NewSessionLink().fill(c)
        XCTAssertEqual(c.restored.count, 1, "no message, nothing filled")
    }

    /// The composer that appears for the new session shows the message, sends nothing on its own,
    /// and sends it untyped only when the person presses Return with it unedited.
    func testTheComposerShowsItAndWaitsForSend() throws {
        let ws = Workspace(folder: URL(fileURLWithPath: "/tmp/frog-newlink"), fresh: true)
        let (c, link) = try idle()
        NewSessionLink(prompt: "fix the tests").fill(c)  // before the composer is on screen
        let (w, host) = host(ComposerView(workspace: ws, conversation: c))
        defer { w.close() }
        let tv = try XCTUnwrap(Self.textView(in: host))
        pump(1)
        XCTAssertEqual(tv.string, "fix the tests")
        XCTAssertTrue(c.restored.isEmpty, "taken into the field")
        XCTAssertTrue(submits(link).isEmpty, "never sent by the link")

        _ = tv.delegate?.textView?(tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        pump(0.3)
        let sent = try XCTUnwrap(submits(link).last)
        XCTAssertEqual(sent["text"] as? String, "fix the tests")
        XCTAssertNil(sent["typed"], "sent as filled: not the person's own words")
    }

    func testEditedItIsThePersonsOwn() throws {
        let ws = Workspace(folder: URL(fileURLWithPath: "/tmp/frog-newlink"), fresh: true)
        let (c, link) = try idle()
        NewSessionLink(prompt: "fix the tests").fill(c)
        let (w, host) = host(ComposerView(workspace: ws, conversation: c))
        defer { w.close() }
        let tv = try XCTUnwrap(Self.textView(in: host))
        pump(0.5)
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))
        tv.insertText(" please", replacementRange: tv.selectedRange())
        pump(0.3)
        _ = tv.delegate?.textView?(tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        pump(0.3)
        let sent = try XCTUnwrap(submits(link).last)
        XCTAssertEqual(sent["text"] as? String, "fix the tests please")
        XCTAssertEqual(sent["typed"] as? Bool, true)
    }

    /// Panes.open: a fresh conversation, the model for it alone (the remembered pick stays), the
    /// message waiting, no turn.
    func testOpeningPutsItAllInAFreshConversation() throws {
        let saved = UserDefaults.standard.string(forKey: "lastModel")
        defer { UserDefaults.standard.set(saved, forKey: "lastModel") }
        UserDefaults.standard.set("openai/gpt-5", forKey: "lastModel")
        let panes = Panes(Workspace(folder: URL(fileURLWithPath: "/tmp/frog-newlink"), fresh: true))
        let before = panes.focused.workspace

        let spec = "local/mlx-community/Qwen3-8B-4bit"
        let ws = panes.open(NewSessionLink(model: "qwen3-8b", prompt: "hello"), in: nil, choice: .use(spec))
        XCTAssertTrue(panes.focused.workspace === ws)
        XCTAssertFalse(ws === before)
        XCTAssertTrue(ws.isChat, "no repo: a plain chat")
        XCTAssertEqual(ws.selectedModel, spec)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "lastModel"), "openai/gpt-5", "a link doesn't change the default")
        let c = try XCTUnwrap(ws.conversation)
        XCTAssertEqual(c.restored.map(\.text), ["hello"])
        XCTAssertEqual(c.restored.map(\.typed), [false])
        XCTAssertTrue(c.turns.isEmpty, "nothing sent")

        let noted = panes.open(NewSessionLink(model: "qwen3-8b"), in: nil, choice: .note("Qwen3 8B isn't on this Mac yet."))
        XCTAssertEqual(noted.conversation?.toast, "Qwen3 8B isn't on this Mac yet.", "a quiet note")
        XCTAssertNotEqual(noted.selectedModel, spec)
        ws.stop(reason: "test"); noted.stop(reason: "test"); before.stop(reason: "test")
    }

    // MARK: - Hosting

    private func host(_ view: some View) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 820)))
        host.frame = CGRect(x: 0, y: 0, width: 820, height: host.fittingSize.height)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderInForTest()
        host.layoutSubtreeIfNeeded()
        pump(0.3)
        return (w, host)
    }

    private func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private static func textView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView, tv.isEditable { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }
}
