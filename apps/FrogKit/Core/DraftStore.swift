import Foundation

/// What's typed in a session's composer, kept on disk so a tab switch or a relaunch keeps it.
///
/// One file per session, `~/.local/share/frog/drafts/<session id>.json`, beside the session
/// logs: a draft belongs to the session, so it lives with the session, out of git's view the
/// same way. A fresh conversation hasn't been sent yet — the engine only writes the log on the
/// first message — so its draft is keyed on the workspace's folder (`folder:<path>`) until a
/// session id arrives, then both keys read the same draft: the folder one from before the first
/// message, the session one after it, whichever was written last.
struct ComposerDraft: Codable, Equatable {
    var text: String
    /// Base64 images attached to the message.
    var images: [ToolImage]
    /// Where the cursor sat (UTF-16 offset), so it comes back where typing left it.
    var cursor: Int
    var saved: Date
}

@MainActor
final class DraftStore {
    /// Off in a test host or the headless morning notice, which must never touch the user's
    /// drafts (set at launch, as `SessionRegistry` does).
    static var enabled = true

    static let shared = DraftStore()

    /// Where drafts are kept; the session dir's `drafts/` folder. Settable for tests.
    static var dir: URL = FrogPaths.sessions.appending(path: "drafts")

    private var cache: [String: ComposerDraft] = [:]

    /// Read the draft for a session (`id`) in `folder`. A fresh conversation has no id yet:
    /// its draft is the one saved under its folder's key.
    func draft(for id: String?, folder: URL) -> ComposerDraft? {
        let keys = Self.keys(id: id, folder: folder)
        let best = keys.compactMap { cache[$0] ?? read($0) }.max { $0.saved < $1.saved }
        return best
    }

    /// Save the draft for a session (`id`) in `folder`. Written at once (cheap: a few bytes).
    func save(_ draft: ComposerDraft, id: String?, folder: URL) {
        guard Self.enabled else { return }
        let key = Self.keys(id: id, folder: folder)[0]
        cache[key] = draft
        write(draft, key: key)
    }

    /// The draft is gone (it was sent).
    func clear(id: String?, folder: URL) {
        for key in Self.keys(id: id, folder: folder) {
            cache[key] = nil
            try? FileManager.default.removeItem(at: Self.url(for: key))
        }
    }

    /// Forget what's cached (the file is the truth): after a relaunch, or in tests.
    func forget() {
        cache = [:]
    }

    /// The session got its id (the engine logged its first message): the draft typed under the
    /// folder key moves under the session key, so a later fresh conversation in the same folder
    /// doesn't resurrect it.
    func adopt(_ id: String, folder: URL) {
        guard let draft = draft(for: nil, folder: folder) else { return }
        clear(id: nil, folder: folder)
        save(draft, id: id, folder: folder)
    }

    // MARK: Files

    private static func keys(id: String?, folder: URL) -> [String] {
        [id.map { "session:\($0)" } ?? "folder:\(folder.standardizedFileURL.path)"]
    }

    static func url(for key: String) -> URL {
        // The key is a prefix and a path or id; make it one safe filename.
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return dir.appending(path: safe + ".json")
    }

    private func read(_ key: String) -> ComposerDraft? {
        guard let data = try? Data(contentsOf: Self.url(for: key)) else { return nil }
        return try? JSONDecoder.frog.decode(ComposerDraft.self, from: data)
    }

    private func write(_ draft: ComposerDraft, key: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        // The reader is `JSONDecoder.frog` (snake_case keys).
        enc.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? enc.encode(draft) else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? data.write(to: Self.url(for: key), options: .atomic)
    }
}
