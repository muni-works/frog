import AppKit
import Foundation
import Observation

/// Every conversation kiln has had, across folders and plain chats, for the sidebar. Pins and
/// the archive are UI state kept in the app's defaults (archiving hides, it never deletes). Open
/// conversations report whether they're running, waiting on the user, or finished unseen.
@MainActor
@Observable
final class Library {
    static let shared = Library()

    enum Live: Equatable {
        case running
        case waiting
        case unread
    }

    private(set) var sessions: [SessionInfo] = []
    private(set) var pinned: Set<String>
    private(set) var archived: Set<String>
    private(set) var live: [String: Live] = [:]
    /// The session shown in the key window: finishing there doesn't count as unread.
    @ObservationIgnored var focused: String?
    @ObservationIgnored private var windows: [String: WeakWindow] = [:]
    @ObservationIgnored private var conversations: [String: WeakConversation] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    private init() {
        pinned = Set(UserDefaults.standard.stringArray(forKey: "pinnedSessions") ?? [])
        archived = Set(UserDefaults.standard.stringArray(forKey: "archivedSessions") ?? [])
        refresh()
    }

    /// Reload the list (coalesced: a burst of calls makes one `kiln --sessions --all`).
    func refresh() {
        refreshing?.cancel()
        refreshing = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let home = FileManager.default.homeDirectoryForCurrentUser
            if let all = try? await Kiln.json([SessionInfo].self, args: ["--sessions", "--all", "--json"], cwd: home) {
                // A conversation whose folder is gone can't be reopened.
                // Race attempts live in their own worktrees and are shown in the race, not here.
                sessions = all.filter { s in
                    guard let cwd = s.cwd, !cwd.contains("/.local/share/kiln/attempts/") else { return false }
                    return FileManager.default.fileExists(atPath: cwd)
                }
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
            _ = try? await Kiln.run(args: ["--rename", id, title], cwd: home)
        }
        refresh()
    }

    // MARK: Live status

    /// An open conversation's state; called as its events arrive.
    func report(_ id: String, conversation: Conversation, running: Bool, waiting: Bool) {
        conversations[id] = WeakConversation(value: conversation)
        let now: Live? = waiting ? .waiting : running ? .running : (live[id] == .unread ? .unread : nil)
        if live[id] != now { live[id] = now }
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

    func register(window: NSWindow?, for id: String) {
        windows = windows.filter { $0.value.window != nil && $0.value.window !== window }
        if let window { windows[id] = WeakWindow(window: window) }
    }

    /// The window already showing this session, if any.
    func window(for id: String) -> NSWindow? {
        windows[id]?.window
    }
}

private struct WeakWindow {
    weak var window: NSWindow?
}

private struct WeakConversation {
    weak var value: Conversation?
}
