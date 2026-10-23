import XCTest
@testable import Frog

/// Composer drafts persist per session: switching away and back, a relaunch, and a send.
@MainActor
final class DraftStoreTests: XCTestCase {
    private var dir: URL!
    private var originalDir: URL!
    private var wasEnabled = true

    override func setUp() {
        super.setUp()
        // The test host runs the app's init, which turns drafts off; tests turn them back on.
        wasEnabled = DraftStore.enabled
        DraftStore.enabled = true
        dir = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString)")
        originalDir = DraftStore.dir
        DraftStore.dir = dir
    }

    override func tearDown() {
        DraftStore.enabled = wasEnabled
        DraftStore.dir = originalDir
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func store() -> DraftStore {
        // A fresh store reads from disk: what a relaunch would see.
        let s = DraftStore()
        return s
    }

    private let folder = URL(fileURLWithPath: "/tmp/frog-draft-tests/one")

    private func draft(_ text: String, images: [ToolImage] = [], cursor: Int = 0) -> ComposerDraft {
        ComposerDraft(text: text, images: images, cursor: cursor, saved: .now)
    }

    func testSwitchAwayAndBackRestoresTheDraft() {
        let id = "s1"
        let a = store()
        a.save(draft("half a thought", cursor: 5), id: id, folder: folder)
        // Another conversation is typed in meanwhile.
        let b = store()
        b.save(draft("the other one"), id: "s2", folder: folder)
        // Back to the first: its draft is what comes back.
        let c = store()
        XCTAssertEqual(c.draft(for: id, folder: folder)?.text, "half a thought")
        XCTAssertEqual(c.draft(for: id, folder: folder)?.cursor, 5)
        XCTAssertEqual(c.draft(for: "s2", folder: folder)?.text, "the other one")
    }

    func testDraftSurvivesARelaunch() {
        let id = "s-relaunch"
        store().save(draft("still here", cursor: 10), id: id, folder: folder)
        // The app restarted: a new store, nothing cached, the file is the truth.
        XCTAssertEqual(store().draft(for: id, folder: folder)?.text, "still here")
    }

    func testSendClearsTheDraft() {
        let id = "s-clear"
        let a = store()
        a.save(draft("about to go"), id: id, folder: folder)
        a.clear(id: id, folder: folder)
        XCTAssertNil(store().draft(for: id, folder: folder))
    }

    func testTwoSessionsHaveIndependentDrafts() {
        let a = store()
        a.save(draft("one"), id: "s-a", folder: folder)
        a.save(draft("two"), id: "s-b", folder: folder)
        let b = store()
        XCTAssertEqual(b.draft(for: "s-a", folder: folder)?.text, "one")
        XCTAssertEqual(b.draft(for: "s-b", folder: folder)?.text, "two")
    }

    func testAFreshConversationsDraftRidesItsFolderThenItsSession() {
        // Typed before the first message: keyed on the folder, no session id yet.
        let a = store()
        a.save(draft("not sent yet"), id: nil, folder: folder)
        XCTAssertEqual(store().draft(for: nil, folder: folder)?.text, "not sent yet")
        // The engine logged the first message: the session id arrives, the draft moves under it.
        a.adopt("s-adopted", folder: folder)
        XCTAssertEqual(store().draft(for: "s-adopted", folder: folder)?.text, "not sent yet")
        // A later fresh conversation in the same folder starts clean.
        XCTAssertNil(store().draft(for: nil, folder: folder))
    }

    func testAttachmentsPersistWithTheDraft() {
        let image = ToolImage(mime: "image/png", data: "aGFsbG8=")
        let id = "s-images"
        store().save(draft("look at this", images: [image]), id: id, folder: folder)
        let restored = store().draft(for: id, folder: folder)
        XCTAssertEqual(restored?.images, [image])
    }

    func testAdoptionTakesTheNewestDraft() {
        let a = store()
        a.save(ComposerDraft(text: "older", images: [], cursor: 0, saved: Date(timeIntervalSinceNow: -10)), id: "s-both", folder: folder)
        // A draft saved under the folder key later (a fresh conversation typed over it before
        // its first message) is the newest: adopting it wins over the stale session draft.
        let folderKeyed = ComposerDraft(text: "folder", images: [], cursor: 0, saved: Date())
        a.save(folderKeyed, id: nil, folder: folder)
        a.adopt("s-both", folder: folder)
        XCTAssertEqual(store().draft(for: "s-both", folder: folder)?.text, "folder")
        XCTAssertNil(store().draft(for: nil, folder: folder))
    }
}
