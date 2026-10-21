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
    private(set) var pinned: Set<String>
    private(set) var archived: Set<String>
    private(set) var live: [String: Live] = [:]
    /// Sessions started by another session (`StartSession`): child id → parent id.
    private(set) var parents: [String: String]
    /// The session shown in the key window: finishing there doesn't count as unread.
    @ObservationIgnored var focused: String?
    @ObservationIgnored private var windows: [ObjectIdentifier: WeakWindow] = [:]
    @ObservationIgnored private var conversations: [String: WeakConversation] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    private init() {
        pinned = Set(UserDefaults.standard.stringArray(forKey: "pinnedSessions") ?? [])
        archived = Set(UserDefaults.standard.stringArray(forKey: "archivedSessions") ?? [])
        parents = UserDefaults.standard.dictionary(forKey: "sessionParents") as? [String: String] ?? [:]
        refresh()
    }

    /// Reload the list (coalesced: a burst of calls makes one `frog --sessions --all`).
    func refresh() {
        refreshing?.cancel()
        refreshing = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser
            if let all = try? await Frog.json([SessionInfo].self, args: ["--sessions", "--all", "--json"], cwd: home) {
                // A conversation whose folder is gone can't be reopened.
                // Race attempts live in their own worktrees and are shown in the race, not here;
                // agents' scratch worktrees aren't projects. Worktrees a session started for
                // another (`<repo>/.frog/worktrees/`) are shown, under their parent.
                sessions = all.filter { s in
                    guard let cwd = s.cwd, !cwd.contains("/.local/share/frog/attempts/"),
                          !cwd.contains("/.claude/worktrees/") else { return false }
                    return FileManager.default.fileExists(atPath: cwd)
                }
                archiveQuietChats()
                RemoteBridge.shared.listChanged()
            }
        }
    }

    // MARK: Pins and archive

    func togglePin(_ id: String) {
        if pinned.remove(id) == nil { pinned.insert(id) }
        UserDefaults.standard.set(Array(pinned), forKey: "pinnedSessions")
    }

    func setArchived(_ id: String, _ on: Bool) {
        if on { archived.insert(id); pinned.remove(id) } else { archived.remove(id) }
        UserDefaults.standard.set(Array(archived), forKey: "archivedSessions")
        UserDefaults.standard.set(Array(pinned), forKey: "pinnedSessions")
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

    /// Part of a group of sessions: started by one, or started one.
    func isAgentSession(_ id: String) -> Bool {
        parents[id] != nil || parents.values.contains(id)
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

    /// An open conversation's state; called as its events arrive.
    func report(_ id: String, conversation: Conversation, running: Bool, waiting: Bool) {
        conversations[id] = WeakConversation(value: conversation)
        SessionBroker.shared.observe(id, running: running, waiting: waiting)
        let now: Live? = waiting ? .waiting : running ? .running : (live[id] == .unread ? .unread : nil)
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
