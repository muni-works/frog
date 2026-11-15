import AppKit
import Foundation
import Observation

/// One conversation open on screen, as saved for the next launch.
struct OpenSession: Codable, Equatable, Sendable {
    var id: String
    var cwd: String
    var model: String?
    /// Which window (in the order they opened) and which pane in it (reading order).
    var window: Int
    var pane: Int
    /// A turn was running (or a message was on its way to the engine).
    var turnRunning: Bool
    /// The user pressed stop on that turn: it ended because they wanted it to.
    var userStopped = false
    /// Messages typed while a turn ran, not yet sent; they're sent after the restore.
    var queued: [String] = []
    /// The turn was suspended by an app update's drain (`Op::Drain`), so it carries on at
    /// relaunch on this session's stored model — with the update notice, not the crash one.
    var suspendedByUpdate = false
}

/// Everything open, written on every change to
/// `~/Library/Application Support/Frog/open-sessions.json`.
struct OpenSessions: Codable, Equatable, Sendable {
    var sessions: [OpenSession] = []
    /// How the app last went away. `nil` while it runs: found that way at launch, it crashed
    /// (or was killed).
    var quit: Quit?
    /// Sessions the user said not to pick back up on their own after a restart.
    var noAutoContinue: [String] = []
    /// The relaunch was an update whose drains the app waited for: suspended turns resume
    /// with the update notice.
    var afterUpdate = false

    enum Quit: String, Codable, Sendable {
        /// Quit, keeping running turns to carry on next launch.
        case resume
        /// Quit and let running turns go.
        case discard
    }
}

/// What to do with a saved session at launch.
enum RestoreAction: Equatable {
    /// Open it as it was.
    case reopen
    /// Open it and have the engine carry on with the turn the restart cut off.
    case `continue`
}

extension OpenSessions {
    /// A turn cut off by a crash, or by a quit that chose to resume, carries on. A turn the user
    /// stopped, a quit that let turns go, a session opted out, and an idle one just reopen.
    func action(for s: OpenSession) -> RestoreAction {
        guard s.turnRunning, !s.userStopped, !noAutoContinue.contains(s.id) else { return .reopen }
        switch quit {
        case nil, .resume?: return .continue
        case .discard?: return .reopen
        }
    }
}

/// Keeps `open-sessions.json` current, and restores what it lists at launch.
@MainActor
final class SessionRegistry {
    static let shared = SessionRegistry()

    static let defaultURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Frog")
        return dir.appending(path: "open-sessions.json")
    }()

    let url: URL
    /// The file as last written (and, at launch, as last left).
    private(set) var current: OpenSessions
    /// What the previous run left, waiting to be restored by windows as they open.
    private var pending: [[OpenSession]] = []
    private var previous = OpenSessions()
    private var windows: [WeakPanes] = []
    /// The test host and the morning notice must never touch the user's registry.
    private let enabled: Bool
    private var frozen = false

    /// A replay (`-FrogReplay`, the parity harness and hero shots) shows its fixture and nothing
    /// else: it neither restores the last run's sessions nor writes over the user's list.
    init(url: URL = SessionRegistry.defaultURL,
         enabled: Bool = !SingleInstance.isTesting && UserDefaults.standard.string(forKey: "FrogReplay") == nil) {
        self.url = url
        self.enabled = enabled
        let loaded = Self.load(url) ?? OpenSessions()
        current = loaded
        previous = loaded
        guard enabled else { return }
        let byWindow = Dictionary(grouping: loaded.sessions, by: \.window)
        pending = byWindow.keys.sorted().map { byWindow[$0]!.sorted { $0.pane < $1.pane } }
        // Running now: if it isn't marked quit when we go, we crashed.
        current.quit = nil
        if !pending.isEmpty { EngineProcess.log("restore: \(loaded.sessions.count) session(s), last exit \(loaded.quit?.rawValue ?? "crash")") }
    }

    static func load(_ url: URL) -> OpenSessions? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OpenSessions.self, from: data)
    }

    /// Written whole to a temporary file and renamed into place, so a crash mid-write leaves the
    /// old file, never half of one.
    static func save(_ s: OpenSessions, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(s) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The resume manifest for an update: how every session stands right now, marked
    /// `quit = .resume` (so every restore action is `.continue`) and `afterUpdate` (so
    /// suspended turns get the update notice). Written after the drains finish, before
    /// Sparkle terminates the app; the new app reads it at launch.
    func manifestForUpdate() {
        var next = OpenSessions()
        next.sessions = snapshot()
        for i in next.sessions.indices {
            // The turn the drain suspended: its engine ended it `suspended` and closed its
            // turn, so `turnRunning` is false again — `suspendedByUpdate` is what says "carry
            // this one on".
            let c = Library.shared.conversation(next.sessions[i].id)
            next.sessions[i].suspendedByUpdate = c.map { $0.turns.last?.end == .suspended } ?? false
            next.sessions[i].turnRunning = next.sessions[i].suspendedByUpdate || next.sessions[i].turnRunning
        }
        next.quit = .resume
        next.afterUpdate = true
        guard enabled else { return }
        Self.save(next, to: url)
        frozen = true
    }

    /// Whether windows opening now will be handed sessions to restore.
    var hasPending: Bool { !pending.isEmpty }

    private func write(_ s: OpenSessions) {
        // Once quitting, windows closing must not empty the list the next launch restores.
        guard enabled, !frozen, s != current || !FileManager.default.fileExists(atPath: url.path) else { return }
        current = s
        Self.save(s, to: url)
    }

    // MARK: Tracking

    /// A window's panes: watched from now on, and given the next window's worth of sessions to
    /// restore if the last run left any.
    func track(_ panes: Panes, openWindow: @escaping (URL) -> Void) {
        guard enabled, !windows.contains(where: { $0.value === panes }) else { return }
        windows.removeAll { $0.value == nil }
        windows.append(WeakPanes(value: panes))
        if !pending.isEmpty {
            restore(pending.removeFirst(), into: panes)
            // More windows were open than macOS brought back: open them.
            if windows.count == 1, !pending.isEmpty {
                let rest = pending
                Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    for group in rest where self.pending.contains(group) {
                        if let first = group.first { openWindow(URL(fileURLWithPath: first.cwd)) }
                    }
                }
            }
        }
        observe()
    }

    /// Recompute the list whenever anything it's made of changes.
    private func observe() {
        let snapshot = withObservationTracking { self.snapshot() } onChange: {
            Task { @MainActor in self.observe() }
        }
        var next = current
        next.sessions = snapshot
        write(next)
    }

    private func snapshot() -> [OpenSession] {
        var out: [OpenSession] = []
        for (w, entry) in windows.compactMap(\.value).enumerated() {
            for (p, pane) in entry.items.enumerated() {
                // A chat nobody has typed in yet has no session on disk to come back to.
                guard let c = pane.workspace.conversation, let id = c.sessionID, !c.turns.isEmpty else { continue }
                let running = c.turns.last.map { !$0.finished } ?? false
                out.append(OpenSession(
                    id: id,
                    cwd: c.folder.path,
                    model: c.status?.model,
                    window: w,
                    pane: p,
                    turnRunning: running,
                    userStopped: c.userStopped,
                    queued: c.queue.map(\.text)
                ))
            }
        }
        return out
    }

    // MARK: Restoring

    /// Whether the engine has a log for this session (`-r` fails without one).
    /// Looked up where the engine looks: under `$HOME`, which a launch can set (the parity
    /// harness's throwaway home) apart from the account's home. Checking the account's home
    /// resumed ids the engine couldn't find ("no session …: No such file or directory").
    static func logExists(_ id: String) -> Bool {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return FileManager.default.fileExists(atPath: home.appending(path: ".local/share/frog/sessions/\(id).jsonl").path)
    }

    private func restore(_ group: [OpenSession], into panes: Panes) {
        for (i, s) in group.enumerated() {
            let folder = URL(fileURLWithPath: s.cwd)
            guard FileManager.default.fileExists(atPath: folder.path), Self.logExists(s.id) else { continue }
            let workspace: Workspace
            if i == 0 {
                workspace = Workspace(folder: folder, resume: s.id, waitLock: true)
                panes.setWorkspace(workspace, in: panes.items[0])
            } else {
                guard panes.canSplit else { break }
                workspace = Workspace(folder: folder, resume: s.id, waitLock: true)
                panes.add(workspace)
            }
            guard let c = workspace.conversation else { continue }
            switch (previous.afterUpdate, previous.action(for: s)) {
            case (true, true == s.suspendedByUpdate ? .continue : .reopen):
                // An update drained this session: carry it on with the update notice (the
                // engine runs on the session's stored model from the log header, never the
                // default or a sender's).
                if s.suspendedByUpdate { c.continueAfterUpdate() }
            case (_, .continue): c.continueInterrupted()
            case (_, .reopen): break
            }
            for text in s.queued { c.submit(text) }
        }
    }

    // MARK: Opting out

    func autoContinues(_ id: String) -> Bool { !current.noAutoContinue.contains(id) }

    func setAutoContinue(_ id: String, _ on: Bool) {
        var next = current
        next.noAutoContinue.removeAll { $0 == id }
        if !on { next.noAutoContinue.append(id) }
        write(next)
    }

    // MARK: Quitting

    /// Sessions with a turn running right now.
    var running: [OpenSession] { snapshot().filter(\.turnRunning) }

    /// Record how the app is going away, before its engines are stopped.
    func quitting(_ how: OpenSessions.Quit) {
        guard enabled else { return }
        var next = current
        next.sessions = snapshot()
        next.quit = how
        write(next)
        frozen = true
    }
}

private struct WeakPanes {
    weak var value: Panes?
}

/// Asks before quitting while turns run: carry on with them next launch, or let them go.
@MainActor
final class QuitGuard: NSObject, NSApplicationDelegate {
    /// One Frog at a time: a second copy of the same build hands over and quits (the
    /// machine-wide lock already stopped the rest — this catches a same-build copy that raced
    /// past `handOff`'s lock check). Test hosts are left alone: XCTest launches the app to run
    /// its tests, and its runner exits "code 0 before establishing connection" if this quits
    /// while one is open.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Session rows name models as the picker does (see `ModelIdentity.rowName`).
        ModelIdentity.rowName = { Workspace.modelName($0) }
        guard !SingleInstance.isTesting, let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated })
        else { return }
        SingleInstance.passFolder()
        other.activate()
        exit(0)
    }

    /// Hand-offs from a second copy reach the app, not a window, so none is lost with every
    /// window closed.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !SingleInstance.isTesting else { return }
        Snapshot.scheduleIfAsked()
        SingleInstance.listen()
    }

    /// A folder opened from Finder or dropped on the Dock icon while Frog runs: its own window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            FolderOpener.open(url)
        }
    }

    /// frog came forward: the "something finished while you were away" badge has been looked
    /// at. (Pending permission requests keep their count — those are still blocked work.)
    func applicationDidBecomeActive(_ notification: Notification) {
        Notifier.shared.focus()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let registry = SessionRegistry.shared
        let running = registry.running
        guard !running.isEmpty else {
            registry.quitting(.resume)
            return .terminateNow
        }
        let alert = NSAlert()
        let n = running.count
        alert.messageText = n == 1 ? "A conversation is still working" : "\(n) conversations are still working"
        alert.informativeText = "Frog can pick them back up where they left off the next time it opens."
        alert.addButton(withTitle: "Quit and Resume Running Sessions")
        alert.addButton(withTitle: "Quit and Stop Them")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            registry.quitting(.resume)
            return .terminateNow
        case .alertSecondButtonReturn:
            registry.quitting(.discard)
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
