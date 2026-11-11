import AppKit
import Foundation
import Observation

/// Every conversation frog has had, across folders and plain chats, for the sidebar. Pins and
/// the archive are UI state kept in the app's defaults (archiving hides, it never deletes). Open
/// conversations report whether they're running, waiting on the user, or finished unseen.
@MainActor
@Observable
final class Library {
    static let shared = Library()

    typealias Live = SessionLive

    private(set) var sessions: [SessionInfo] = []
    /// This Mac's sessions and Frog Cloud's, which `sessions` lists together: one list, as
    /// on the web, each opening through its own link (`isCloud`).
    private var local: [SessionInfo] = []
    private var cloud: [SessionInfo] = []
    private(set) var cloudIDs: Set<String> = []

    func isCloud(_ id: String) -> Bool { cloudIDs.contains(id) }

    /// Frog Cloud's list changed (`CloudSessions` polls it): its rows join this Mac's.
    func cloudChanged(_ rows: [CloudGateway.Session]) {
        let mapped = rows.filter { $0.archived != true }.map(Self.row)
        // A sandbox still starting reads as running.
        for r in rows where r.archived != true {
            let busy = r.state == "starting"  // as on the web; an open one says so itself
            if busy, live[r.id] == nil { live[r.id] = .running }
            if !busy, live[r.id] == .running { live[r.id] = nil }
        }
        guard mapped != cloud else { return }
        cloud = mapped
        cloudIDs = Set(mapped.map(\.id))
        sessions = local + mapped
    }

    /// A cloud session as a row: its repo stands where a folder would (`/Frog Cloud/owner/repo`,
    /// so the row's place reads as the repo), its times the gateway's.
    static func row(_ s: CloudGateway.Session) -> SessionInfo {
        let modified = Int64(s.last_turn ?? s.updated)
        return SessionInfo(id: s.id, modified: modified, created: Int64(s.created ?? s.updated), model: "",
                           firstInput: nil, title: s.title.isEmpty ? "New session" : s.title,
                           end: s.state == "error" ? .failed : nil, forkedFrom: nil,
                           cwd: s.repo.isEmpty ? "/Frog Cloud" : "/Frog Cloud/\(s.repo)")
    }
    private(set) var pinned: Set<String>
    private(set) var archived: Set<String>
    private(set) var live: [String: Live] = [:] {
        // The Dock frog wants you exactly when some session is waiting on you.
        didSet {
            DockActivity.shared.attention = live.values.contains(.waiting)
            // A session that stops running settles its tree: the git badge re-reads it.
            if live != oldValue { GitIndex.shared.liveChanged(from: oldValue, to: live) }
        }
    }
    /// The chief of staff: one session, as a tile above the pins. It keeps its pin.
    private(set) var chief: String?
    /// Sessions started by another session (`StartSession`): child id → parent id.
    private(set) var parents: [String: String]
    /// The session shown in the key window: finishing there doesn't count as unread.
    @ObservationIgnored var focused: String?
    @ObservationIgnored private var windows: [ObjectIdentifier: WeakWindow] = [:]
    @ObservationIgnored private var conversations: [String: WeakConversation] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// When the last `frog --sessions --all` started. A listing costs about a second of CPU
    /// with a thousand sessions, and a streaming session asks for one every second.
    @ObservationIgnored private var lastListed = ContinuousClock.now - .seconds(60)
    static let listInterval = Duration.seconds(3)
    /// The last full listing, kept so a watcher refresh only fetches what changed: the ids the
    /// watcher names go out as `--sessions --ids` and their rows merge in here. Refreshing one
    /// session costs ~5 ms instead of the full 1.5 MB listing's 0.05 s + 1,026 stat calls.
    @ObservationIgnored private var listed: [String: SessionInfo] = [:]
    /// cwd → whether it exists, cached (folders rarely appear or disappear): the listing filter
    /// used to stat one per session, 1,026 `fileExists` on the main actor per refresh.
    @ObservationIgnored private var existingFolders: [String: (exists: Bool, at: ContinuousClock.Instant)] = [:]
    static let folderCacheTTL: Duration = .seconds(60)

    private init() {
        pinned = Set(UserDefaults.standard.stringArray(forKey: "pinnedSessions") ?? [])
        archived = Set(UserDefaults.standard.stringArray(forKey: "archivedSessions") ?? [])
        chief = UserDefaults.standard.string(forKey: "chiefSession")
        parents = UserDefaults.standard.dictionary(forKey: "sessionParents") as? [String: String] ?? [:]
        _ = SessionDirectoryWatcher.shared
        refresh()
    }

    /// Reload the list (coalesced: a burst of calls makes one `frog --sessions`). With `ids`
    /// (the watcher's changed set), only those sessions are re-listed (`--sessions --ids`) and
    /// merged into the cached full listing; without, the full `--sessions --all` runs.
    func refresh(ids: Set<String> = []) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))  // see Conversation.apply
        if staged { return }
        #endif
        refreshing?.cancel()
        refreshing = Task {
            let due = lastListed + Self.listInterval - .now
            try? await Task.sleep(for: max(.milliseconds(150), due))
            guard !Task.isCancelled else { return }
            lastListed = .now
            let home = FileManager.default.homeDirectoryForCurrentUser
            // A partial refresh with no cached listing has nothing to merge into: full then.
            let known = !ids.isEmpty && !listed.isEmpty
            let args = known ? ["--sessions", "--ids", ids.sorted().joined(separator: ","), "--all", "--json"]
                             : ["--sessions", "--all", "--json"]
            if let rows = try? await Frog.json([SessionInfo].self, args: args, cwd: home) {
                #if DEBUG
                if staged { return }  // a listing already in flight when a snapshot staged its own
                #endif
                // Unchanged ids stay as the full listing read them: a partial refresh's rows
                // replace only their own. Race attempts live in their own worktrees and are
                // shown in the race card, not here; worker worktrees are shown under their repo
                // (see `Sidebar.home`).
                if known {
                    var merged = listed
                    for id in ids { merged.removeValue(forKey: id) }  // keep only refreshed rows
                    for row in rows { merged[row.id] = row }
                    apply(merged.values.filter { present($0) })
                } else {
                    apply(rows.filter { present($0) })
                }
            }
        }
    }

    /// Write a listing: only when it changed (every view of the list would rebuild for nothing).
    private func apply(_ listed: [SessionInfo]) {
        guard listed != local else { return }
        local = listed
        sessions = listed + cloud
        self.listed = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        GitIndex.shared.listingChanged(listed)
        archiveQuietChats()
        RemoteBridge.shared.listChanged()
        onOrderInvalidated?()
    }

    /// Set by `SessionOrder` (the quick-switch shortcuts' cached sidebar order): the listing,
    /// pins, archive or parents moved, so the cache re-derives. Nothing a streamed turn does
    /// reaches it — its whole point is to leave the order alone per delta.
    @ObservationIgnored var onOrderInvalidated: (() -> Void)?

    /// Whether a session's folder exists, from the cache (fresh for `folderCacheTTL`): a
    /// Documents/Desktop/Downloads session can't be stat'd without a TCC prompt anyway.
    private func present(_ s: SessionInfo) -> Bool {
        guard let cwd = s.cwd, !cwd.contains("/.local/share/frog/attempts/") else { return false }
        if FrogPaths.isPrivacyProtected(cwd) { return true }
        let now = ContinuousClock.now
        if let cached = existingFolders[cwd], now < cached.at + Self.folderCacheTTL {
            return cached.exists
        }
        let exists = FileManager.default.fileExists(atPath: cwd)
        existingFolders[cwd] = (exists, now)
        return exists
    }

    // MARK: Pins and archive

    func togglePin(_ id: String) {
        // The chief keeps its pin (the folded strip and the phone show it as one); Remove
        // Chief first to unpin it. Flag off, it's a pin like any other.
        if FeatureFlags.chief, id == chief { return }
        if pinned.remove(id) == nil { pinned.insert(id) }
        UserDefaults.standard.set(Array(pinned), forKey: "pinnedSessions")
        onOrderInvalidated?()
    }

    // MARK: Chief

    /// The chief of staff's session, as the sidebar shows it.
    var chiefSession: SessionInfo? { chief.flatMap { id in sessions.first { $0.id == id } } }

    /// Make session `id` the chief: pinned if it isn't already, never archived.
    /// (Flag off, this stays reachable from the data layer but the UI never calls it.)
    func makeChief(_ id: String) {
        archived.remove(id)
        pinned.insert(id)
        UserDefaults.standard.set(Array(pinned), forKey: "pinnedSessions")
        UserDefaults.standard.set(Array(archived), forKey: "archivedSessions")
        let was = chief
        chief = id
        if was != id { UserDefaults.standard.set(id, forKey: "chiefSession") }
        onOrderInvalidated?()
    }

    /// No chief, until one is made again.
    func removeChief() {
        chief = nil
        UserDefaults.standard.removeObject(forKey: "chiefSession")
        onOrderInvalidated?()
    }

    func setArchived(_ id: String, _ on: Bool) {
        // However it's archived (sidebar, phone, a session's ArchiveSession), nothing queued
        // for it runs afterwards.
        if on { SessionBroker.shared.clearQueue(id) }
        if on { archived.insert(id); pinned.remove(id) } else { archived.remove(id) }
        if on, FeatureFlags.chief, chief == id { chief = nil; UserDefaults.standard.removeObject(forKey: "chiefSession") }
        UserDefaults.standard.set(Array(archived), forKey: "archivedSessions")
        UserDefaults.standard.set(Array(pinned), forKey: "pinnedSessions")
        onOrderInvalidated?()
    }

    /// Delete a session: its log goes to the Trash (recoverable from there) and its row leaves
    /// the list. Archiving first stops anything queued for it.
    func delete(_ id: String) {
        setArchived(id, true)
        let log = FrogPaths.sessions.appending(path: "\(id).jsonl")
        try? FileManager.default.trashItem(at: log, resultingItemURL: nil)
        archived.remove(id)
        UserDefaults.standard.set(Array(archived), forKey: "archivedSessions")
        onOrderInvalidated?()
    }

    /// Plain chats archive themselves after this long without activity, unless pinned, live or
    /// open in a window (the sidebar's "Chats" works like a browser's today tabs).
    static let chatLifetime: TimeInterval = 12 * 3600

    static var autoArchiveChats: Bool {
        UserDefaults.standard.object(forKey: "autoArchiveChats") as? Bool ?? true
    }

    private func archiveQuietChats() {
        guard Self.autoArchiveChats else { return }
        let cutoff = Date().addingTimeInterval(-Self.chatLifetime)
        let quiet = sessions.filter { s in
            s.isChat && s.modifiedDate < cutoff && !pinned.contains(s.id) && !archived.contains(s.id)
                && live[s.id] == nil && window(for: s.id) == nil
        }
        guard !quiet.isEmpty else { return }
        archived.formUnion(quiet.map(\.id))
        UserDefaults.standard.set(Array(archived), forKey: "archivedSessions")
    }

    // MARK: Sessions started by sessions

    func setParent(of child: String, to parent: String) {
        parents[child] = parent
        UserDefaults.standard.set(parents, forKey: "sessionParents")
    }

    /// Why a [`Library.move`] was refused; the message is the tool's error.
    enum MoveRefusal: Error, Equatable {
        /// The new parent sits under the session being moved (or is it).
        case nestsWithinItself

        var message: String {
            switch self {
            case .nestsWithinItself:
                "That would nest the session under itself or one of its descendants."
            }
        }
    }

    /// `MoveSession`: re-file `child` under `parent` (nil unparents; a top-level row
    /// again). Sidebar nesting only — the log, model, mode and history are the session's
    /// own. Refuses a move that would nest a session under itself or a descendant (the
    /// sidebar's tree walks tolerate a cycle, but one must never be recorded). Unparenting
    /// an unparented session is a successful no-op. `parents` is observed, so the sidebar's
    /// grouping re-derives on the change.
    @discardableResult
    func move(_ child: String, to parent: String?) -> Result<String?, MoveRefusal> {
        if let parent {
            guard !Self.wouldCycle(child, parent: parent, in: parents) else {
                return .failure(.nestsWithinItself)
            }
            parents[child] = parent
        } else {
            guard parents.removeValue(forKey: child) != nil else { return .success(nil) }
        }
        UserDefaults.standard.set(parents, forKey: "sessionParents")
        onOrderInvalidated?()
        return .success(parent)
    }

    /// Whether moving `child` under `parent` would close a loop: its own descendant. The
    /// walk is bounded by the recorded parents, so it terminates even on an existing cycle.
    static func wouldCycle(_ child: String, parent: String?, in parents: [String: String]) -> Bool {
        guard let parent else { return false }  // unparenting can't cycle
        // Walk up from the proposed parent: if the child is anywhere above it (or is it),
        // the move would nest the session under its own subtree.
        var seen: Set<String> = []
        var at: String? = parent
        while let current = at, seen.insert(current).inserted {
            if current == child { return true }
            at = parents[current]
        }
        return false
    }

    // MARK: Stored model and mode

    /// Durable per-session overrides, applied by the next engine start (SetSessionModel /
    /// SetSessionMode while no engine is running).
    func setStoredModel(_ id: String, _ spec: String) {
        var stored = UserDefaults.standard.dictionary(forKey: "sessionModels") as? [String: String] ?? [:]
        stored[id] = spec
        UserDefaults.standard.set(stored, forKey: "sessionModels")
    }

    func setStoredMode(_ id: String, _ mode: Mode) {
        var stored = UserDefaults.standard.dictionary(forKey: "sessionModes") as? [String: String] ?? [:]
        stored[id] = mode.rawValue
        UserDefaults.standard.set(stored, forKey: "sessionModes")
    }

    /// The stored model override for session `id`, if any.
    func storedModel(_ id: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: "sessionModels") as? [String: String])?[id]
    }

    /// The stored permission mode override for session `id`, if any.
    func storedMode(_ id: String) -> Mode? {
        (UserDefaults.standard.dictionary(forKey: "sessionModes") as? [String: String])?[id]
            .flatMap(Mode.init(rawValue:))
    }

    /// Session `id`'s stored overrides, cleared as they're taken: the engine starting now
    /// applies them, and after that its log remembers them (`model_changed`/`mode_changed`),
    /// so a later change made in the session isn't overridden at every restart.
    func takeStored(_ id: String) -> (model: String?, mode: Mode?) {
        let taken = (storedModel(id), storedMode(id))
        for key in ["sessionModels", "sessionModes"] {
            guard var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
                  stored.removeValue(forKey: id) != nil else { continue }
            UserDefaults.standard.set(stored, forKey: key)
        }
        return taken
    }

    // MARK: Renaming

    /// Rename through the open conversation if there is one (its engine holds the log), else
    /// directly.
    func rename(_ id: String, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let c = conversations[id]?.value {
            c.rename(title)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            _ = try? await Frog.run(args: ["--rename", id, title], cwd: home)
        }
        refresh()
    }

    // MARK: Live status

    /// The conversation open on this Mac for session `id`, if any.
    func conversation(_ id: String) -> Conversation? {
        conversations[id]?.value
    }

    /// Every conversation open on this Mac right now.
    var open: [Conversation] {
        conversations.values.compactMap(\.value)
    }

    /// What session `id` is waiting on you for, in a line: its question, the tool it wants
    /// to run, or the server's request. Nil when it isn't open here or isn't asking.
    func asking(_ id: String) -> String? {
        #if DEBUG
        if let staged = stagedAsks[id] { return staged }
        #endif
        guard let c = conversation(id) else { return nil }
        if let q = c.question { return q.question }
        if let p = c.permission { return Self.askLine(p) }
        if let e = c.elicitation { return e.message }
        return nil
    }

    #if DEBUG
    @ObservationIgnored private var stagedAsks: [String: String] = [:]
    @ObservationIgnored private var staged = false

    /// Snapshot tests: replace the listing with fixtures (nothing persisted, no refresh).
    func stage(sessions: [SessionInfo], live: [String: Live] = [:], parents: [String: String] = [:],
               chief: String? = nil, pinned: Set<String> = [], archived: Set<String> = [],
               asks: [String: String] = [:]) {
        if !staged { backup = (self.sessions, self.live, self.parents, self.chief, self.pinned, self.archived) }
        staged = true
        refreshing?.cancel()
        self.sessions = sessions
        self.live = live
        self.parents = parents
        self.chief = chief
        self.pinned = pinned
        self.archived = archived
        stagedAsks = asks
    }

    @ObservationIgnored private var backup: ([SessionInfo], [String: Live], [String: String], String?, Set<String>, Set<String>)?

    /// Back to the real listing after `stage`.
    func unstage() {
        guard staged, let b = backup else { return }
        (sessions, live, parents, chief, pinned, archived) = b
        stagedAsks = [:]
        staged = false
        backup = nil
    }
    #endif

    /// An open conversation's state; called as its events arrive. The one truth for the
    /// sidebar's dot and every list: a session is running when a turn is open OR messages
    /// are still queued in its engine's inbox (bug 2d — a queued-only session used to read
    /// as idle until its next turn boundary).
    func report(_ id: String, conversation: Conversation, running: Bool, waiting: Bool) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))  // see Conversation.apply
        #endif
        conversations[id] = WeakConversation(value: conversation)
        SessionBroker.shared.observe(id, running: running, waiting: waiting)
        let queued = SessionBroker.shared.pendingInbound(id) != 0
        let now: Live? = waiting ? .waiting : (running || queued) ? .running : (live[id] == .unread ? .unread : nil)
        if live[id] != now {
            live[id] = now
            RemoteBridge.shared.listChanged()
        }
    }

    /// A turn finished: unread unless it's what the user is looking at.
    func turnEnded(_ id: String) {
        let seen = focused == id && NSApp.isActive
        live[id] = seen ? nil : .unread
        refresh()
    }

    func markRead(_ id: String) {
        if live[id] == .unread { live[id] = nil }
    }

    /// A message landed in session `id`'s engine inbox while it was busy: the sidebar dot
    /// says running right away, not only at the next turn boundary.
    func reportQueued(_ id: String) {
        if live[id] != .waiting, live[id] != .running {
            live[id] = .running
            RemoteBridge.shared.listChanged()
        }
    }

    // MARK: Windows

    /// Register the window's pane owner once; session membership is read from its current panes.
    func register(window: NSWindow?, panes: Panes) {
        windows = windows.filter { $0.value.window != nil && $0.value.panes != nil }
        windows[ObjectIdentifier(panes)] = window.map { WeakWindow(window: $0, panes: panes) }
    }

    private func location(for id: String) -> (NSWindow, Panes)? {
        for entry in windows.values {
            if let window = entry.window, let panes = entry.panes, panes.paneShowing(id) != nil {
                return (window, panes)
            }
        }
        return nil
    }

    /// The window currently showing this session, if any.
    func window(for id: String) -> NSWindow? {
        location(for: id)?.0
    }

    /// Focus the actual pane as well as its window, including another tab in the same group.
    func focusSession(_ id: String, excluding window: NSWindow?) -> Bool {
        guard let (target, panes) = location(for: id), target !== window else { return false }
        guard panes.focusSession(id) else { return false }
        target.makeKeyAndOrderFront(nil)
        return true
    }
}

private struct WeakWindow {
    weak var window: NSWindow?
    weak var panes: Panes?
}

private struct WeakConversation {
    weak var value: Conversation?
}
