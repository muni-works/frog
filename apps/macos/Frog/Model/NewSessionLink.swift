import Foundation

/// `frog://new?model=<id>&prompt=<text>&repo=<owner/name>` (`frog-dev://new` for a Debug build):
/// a new session, a model chosen, the person's message waiting in the composer. The web's model
/// menu sends it when a local model is picked (a local model can't run in Frog Cloud).
///
/// Every part is optional and untrusted: any page can open a `frog://` link. A part that fails
/// its check is dropped, never repaired, and the link still opens a new session. Nothing is
/// ever sent: the text goes into the composer as untyped fill (`ComposerTyped`), so it counts as
/// the person's own words only once they edit it, and it goes only when they press send.
struct NewSessionLink: Equatable {
    /// The model as the link named it (a catalog id, a repo, or `local/<repo>`); see `localSpec`.
    var model: String?
    var prompt: String?
    var repo: String?

    /// Longest message a link may carry (characters). Longer is dropped, not cut: a cut message
    /// could say something its sender never wrote.
    static let maxPrompt = 8_000
    /// Longest link read at all, before any decoding (room for a capped message of emoji,
    /// twelve bytes each once encoded).
    static let maxURL = 128 * 1024

    /// The link's parts, or nil when it isn't a `new` link.
    static func parse(_ url: URL) -> NewSessionLink? {
        guard url.scheme == "frog" || url.scheme == "frog-dev", url.host() == "new" else { return nil }
        // `frog://new` and `frog://new/` only: a path is some other link.
        guard url.path().isEmpty || url.path() == "/" else { return nil }
        guard url.absoluteString.utf8.count <= maxURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return NewSessionLink() }
        // The first of each name; a repeated one can't override it.
        func first(_ name: String) -> String? {
            parts.queryItems?.first { $0.name == name }?.value
        }
        return NewSessionLink(
            model: first("model").flatMap(cleanModel),
            prompt: first("prompt").flatMap(cleanPrompt),
            repo: first("repo").flatMap(cleanRepo))
    }

    /// A catalog id, a Hugging Face repo, or a model spec: letters, digits and `._-/:`.
    static func cleanModel(_ s: String) -> String? {
        guard (1...200).contains(s.count), !s.contains(".."),
              s.unicodeScalars.allSatisfy({ modelChars.contains($0) }) else { return nil }
        return s
    }

    /// The message as it was written, or nil when it can't go in a composer as is: empty, over
    /// the cap, or holding a character the person couldn't see (controls other than newline and
    /// tab, DEL, the C1 range, bidi overrides, zero-width marks). `\r\n` and `\r` become `\n`.
    static func cleanPrompt(_ s: String) -> String? {
        let text = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= maxPrompt else { return nil }
        guard !text.unicodeScalars.contains(where: hidden) else { return nil }
        return text
    }

    /// `owner/name` as GitHub spells them.
    static func cleanRepo(_ s: String) -> String? {
        let p = s.split(separator: "/", omittingEmptySubsequences: false)
        guard p.count == 2 else { return nil }
        let owner = p[0], name = p[1]
        guard (1...39).contains(owner.count), !owner.hasPrefix("-"),
              owner.unicodeScalars.allSatisfy({ ownerChars.contains($0) }),
              (1...100).contains(name.count), name != ".", name != "..", !name.hasPrefix("-"),
              name.unicodeScalars.allSatisfy({ nameChars.contains($0) }) else { return nil }
        return s
    }

    private static let ownerChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
    private static let nameChars = ownerChars.union(CharacterSet(charactersIn: "._"))
    private static let modelChars = nameChars.union(CharacterSet(charactersIn: "/:"))

    private static func hidden(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x0A, 0x09: return false
        case 0x00...0x1F, 0x7F...0x9F: return true
        // Zero-width space/joiners, LRM/RLM, bidi embeddings and overrides, isolates, BOM.
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF: return true
        default: return false
        }
    }

    // MARK: Which model

    /// The picker's spec (`local/<repo>`) for a model this Mac's catalog offers, by its catalog id
    /// (`qwen3-8b`, what the web sends), its repo, or its spec. Nil for anything else: a link
    /// never hands the engine a model the catalog doesn't name.
    static func localSpec(for model: String, catalog: [LocalCatalogModel] = LocalCatalog.all) -> String? {
        let bare = model.hasPrefix("\(ProviderID.local)/") ? String(model.dropFirst(ProviderID.local.count + 1)) : model
        let m = catalog.first {
            $0.local && $0.runs_on.contains("metal")
                && ($0.id.caseInsensitiveCompare(model) == .orderedSame
                    || $0.source.repo.caseInsensitiveCompare(bare) == .orderedSame)
        }
        return m.map { "\(ProviderID.local)/\($0.source.repo)" }
    }

    /// What the link's model comes to on this Mac: a spec to use, or a note on why the session
    /// starts on the usual model instead. A model that isn't downloaded is never fetched by a
    /// link (it could be gigabytes); the note points at the picker.
    enum ModelChoice: Equatable {
        case none
        case use(String)
        case note(String)
    }

    @MainActor static func choice(for model: String?, catalog: [LocalCatalogModel] = LocalCatalog.all,
                                  installed: @MainActor (String) -> Bool = { ModelDownloads.isInstalled($0) }) -> ModelChoice {
        guard let model else { return .none }
        guard let spec = localSpec(for: model, catalog: catalog) else {
            return .note("Frog for Mac doesn't offer that model, so this session uses your usual one.")
        }
        let repo = String(spec.dropFirst(ProviderID.local.count + 1))
        let name = catalog.first { $0.source.repo == repo }?.name ?? LocalCatalog.displayName(repo)
        guard installed(repo) else {
            return .note("\(name) isn't on this Mac yet. Get it from the model menu; until then this session uses your usual model.")
        }
        return .use(spec)
    }

    // MARK: Where

    /// The known folder whose GitHub remote is `repo`, if any. `remotes` pairs each folder Frog
    /// already knows (recents, open windows) with its `origin` (`CloudSessions.githubRepo`); a
    /// path is never built from the link.
    static func checkout(of repo: String?, in remotes: [(folder: URL, repo: String?)]) -> URL? {
        guard let repo else { return nil }
        return remotes.first { $0.repo?.caseInsensitiveCompare(repo) == .orderedSame }?.folder
    }

    /// The folders to look in, with their remotes: git runs once per folder, so call it off the
    /// main thread.
    nonisolated static func knownRemotes(_ folders: [URL]) -> [(folder: URL, repo: String?)] {
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.path).inserted && !Frog.isChat($0) }
            .map { ($0, CloudSessions.githubRepo(of: $0)) }
    }

    // MARK: Into the composer

    /// The message into `c`'s composer as untyped fill, ahead of whatever is already there
    /// (`Conversation.Queued.restore`). Never a submit.
    @MainActor func fill(_ c: Conversation) {
        guard let prompt else { return }
        c.restored.append(Conversation.Queued(text: prompt, typed: false))
    }
}

/// A `frog://new` link that arrived outside a window (the app delegate, a cold launch, a second
/// copy's hand-off): the front window takes it, or the first window to open takes the one left
/// waiting. Consumed once: the same link reaching both the delegate and a window's `onOpenURL`
/// opens one session, not two.
enum NewSessionRequest {
    static let name = Notification.Name("toys.frog.newSessionRequest")
    @MainActor static var pending: NewSessionLink?
    /// The last link posted and when: a repeat inside `window` is the same delivery twice.
    @MainActor private static var last: (url: String, at: Date)?
    static let window: TimeInterval = 2

    /// Post `url` if it's a `new` link. True when it was one (handled or a duplicate). `center`:
    /// tests post where no window listens.
    @MainActor @discardableResult
    static func post(_ url: URL, now: Date = .now, center: NotificationCenter = .default) -> Bool {
        guard let link = NewSessionLink.parse(url) else { return false }
        if let last, last.url == url.absoluteString, now.timeIntervalSince(last.at) < window { return true }
        last = (url.absoluteString, now)
        pending = link
        center.post(name: name, object: nil)
        return true
    }

    /// The waiting link, once.
    @MainActor static func take() -> NewSessionLink? {
        defer { pending = nil }
        return pending
    }

    /// Tests: forget what was posted.
    @MainActor static func reset() {
        pending = nil
        last = nil
    }
}
