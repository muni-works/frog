import SwiftUI

@main
struct FrogApp: App {
    /// Asks before quitting mid-turn, and records the quit for the next launch's restore.
    @NSApplicationDelegateAdaptor(QuitGuard.self) private var quitGuard

    init() {
        if MorningNotice.headless {
            // Woken by the brief's watcher to post the morning notice: no window, no Dock icon,
            // and never in the way of a frog that's already open (any build — it asks on its own).
            if SingleInstance.otherIsRunning { exit(0) }
            NSApplication.shared.setActivationPolicy(.accessory)
        } else {
            // One frog: a second copy hands its folder to the running one and quits; a different
            // build (debug vs the installed app) leaves quietly instead of opening on top.
            SingleInstance.handOff()
        }
        if SingleInstance.isTesting {
            // A test host: no Dock icon, no windows of its own (tests render offscreen).
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        LegacyKiln.migrate()
        // Keep frog's windows neutral gray: no wallpaper tint on window chrome, grouped settings
        // cards and materials (the per-app form of System Settings' "Allow wallpaper tinting").
        UserDefaults.standard.set(true, forKey: "AppleReduceDesktopTinting")
        Notifier.shared.setup()
        Conversation.effects = MacEffects.shared
        Conversation.logReader = { id, after in
            // The durable half of the session log (what a dead engine left behind), read the
            // same way the phone bridge reads it.
            let log = Frog.sessions.appending(path: "\(id).jsonl")
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder.frog
            return text.split(separator: "\n").compactMap { line -> Envelope? in
                guard line.contains(#""type":"event""#) else { return nil }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let env = obj["env"] else { return nil }
                guard let data = try? JSONSerialization.data(withJSONObject: env) else { return nil }
                guard let e = try? decoder.decode(Envelope.self, from: data), e.seq > after else { return nil }
                return e
            }
        }
        SessionBroker.shared.install()
        ModelContext.useMac()
        // Type-to-focus: printable keys reach the composer when no field holds them.
        TypeToFocus.begin()
        // A test host and the morning notice mustn't read or write the user's drafts.
        DraftStore.enabled = !SingleInstance.isTesting && !MorningNotice.headless
        DiagramLayout.mermaid = { source, cwd in
            await Diagram.fromMermaid(source, cwd: cwd ?? FileManager.default.homeDirectoryForCurrentUser)
        }
        MorningNotice.start()
        _ = Updates.shared
        RemoteBridge.shared.startIfEnabled()
        // `open Frog.app --args --test-notification`: fire one notification of every category,
        // so delivery can be proven rather than assumed (a dev build's notifications fail
        // silently when the system never authorized it). Logs what the system said.
        if CommandLine.arguments.contains("--test-notification") {
            Task { @MainActor in
                Notifier.shared.testDeliver { note in print(note) }
            }
        }
    }

    var body: some Scene {
        WindowGroup("Frog", for: URL.self) { $folder in
            RootView(folder: $folder)
                .font(.frog(size: 13))
                .containerBackground(FrogCanvas.color, for: .window)
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(SingleInstance.isTesting || MorningNotice.headless ? .suppressed : .presented)
        .restorationBehavior(SingleInstance.isTesting || MorningNotice.headless ? .disabled : .automatic)
        .commands { FrogCommands() }

        WindowGroup("Diagram", for: DiagramDocument.self) { $doc in
            if let doc {
                DiagramWindow(document: doc)
            }
        }
        .defaultSize(width: 960, height: 680)
        // Only ever opened from a diagram card, never at launch or by restoration.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .containerBackground(FrogCanvas.color, for: .window)
        }
    }
}

/// A window is one to three conversations side by side (panes), each in a project folder or (with
/// no folder) a plain chat. A new window starts as an empty chat; its composer's folder chip
/// points it at a folder before the first message. The first pane's folder is the window's
/// scene value, so relaunching reopens it.
struct RootView: View {
    @Binding var folder: URL?
    @Environment(\.openWindow) private var openWindow
    @State private var panes: Panes?

    var body: some View {
        Group {
            if let panes {
                WorkspaceView(panes: panes)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        // Drag the window from any empty space, not just the title bar. Text selection,
        // buttons and fields are children, so their own gestures win.
        .contentShape(.rect)
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .onAppear {
            if folder == nil { folder = LaunchFolder.take() ?? Frog.chatFolder }
        }
        // A second copy of frog handed over its folder: open it here, in a window of its own.
        .onReceive(DistributedNotificationCenter.default().publisher(for: SingleInstance.openFolder)) { note in
            guard let token = note.object as? String, SingleInstance.answered.insert(token).inserted,
                  let path = token.split(separator: "|", maxSplits: 1).last.map(String.init) else { return }
            openWindow(value: URL(fileURLWithPath: path))
        }
        .onChange(of: folder, initial: true) { _, url in
            guard let url else { return }
            if let panes {
                // Panes report their own folder changes; only an outside change lands here.
                let first = panes.items[0]
                if first.workspace.folder.standardizedFileURL != url.standardizedFileURL {
                    panes.setWorkspace(Workspace(folder: url, fresh: true), in: first)
                }
            } else {
                let p = Panes(Workspace(folder: url))
                p.onPrimaryFolder = { folder = $0 }
                panes = p
                Recents.add(url)
                SessionRegistry.shared.track(p) { openWindow(value: $0) }
            }
        }
        .onDisappear { panes?.stopAll() }
    }
}

/// There's one frog on a Mac, however many copies of it are built. A machine-wide lock (a file
/// plus `flock`, not a bundle id, so a debug build sees the installed one) decides at launch:
/// a second copy of the same build hands its `-FrogFolder` to the one that's running, brings
/// that forward, and quits; a copy with a different bundle id (the installed app vs a debug
/// build) just leaves, quietly — it mustn't open a window on top or steal focus. The lock also
/// stops `open -n` from stacking. Test hosts (XCTest launches the app to run its tests) are
/// left alone and kept out of sight.
enum SingleInstance {
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Per bundle id, so a debug frog and the installed one don't open each other's folders.
    static let openFolder = Notification.Name("\(Bundle.main.bundleIdentifier ?? "toys.frog").openFolder")

    /// The machine-wide lock. Held for the process's lifetime (the kernel drops `flock` when
    /// the holder exits, so the fd has to stay open past every initializer).
    private static let held = LockHolder()

    /// Another copy of frog is running — any build, checked by the machine-wide lock. Takes
    /// the lock when none is held, so the headless launch that asked is now the one frog.
    static var otherIsRunning: Bool {
        if isTesting { return false }
        if case .held = held.acquire(bundleIdentifier: Bundle.main.bundleIdentifier) { return true }
        return false
    }

    static func handOff() {
        guard !isTesting else { return }
        switch held.acquire(bundleIdentifier: Bundle.main.bundleIdentifier) {
        case .took: return
        // The lock couldn't even be opened (no Application Support?): run on, as before the
        // lock — QuitGuard still catches a same-build copy.
        case .free: return
        case .held(let holder):
            switch InstanceDecision.decide(
                holderPid: holder.pid, myBundleId: Bundle.main.bundleIdentifier,
                holderBundleId: holder.bundleIdentifier, isTesting: isTesting)
            {
            case .handOff: handOff(to: holder)
            case .exitQuietly:
                FileHandle.standardError.write(Data(
                    "another Frog is running (pid \(holder.pid)); not starting a second instance\n".utf8))
                exit(0)
            case .takeLock: return
            }
        }
    }

    /// The running copy has the lock (same bundle id): pass the folder over, bring it
    /// forward, and leave.
    private static func handOff(to holder: LockHolder.Held) {
        if let path = UserDefaults.standard.string(forKey: "FrogFolder") {
            // A token, so only one of the running copy's windows answers it.
            DistributedNotificationCenter.default().postNotificationName(
                openFolder, object: "\(UUID().uuidString)|\(path)", deliverImmediately: true)
        }
        // The holder's app object: activating by pid works across bundle ids and when the
        // running copy has no NSRunningApplication of its own visible to us yet.
        let running = NSRunningApplication(processIdentifier: holder.pid)
        running?.activate()
        exit(0)
    }

    /// Tokens already answered, across the running copy's windows.
    @MainActor static var answered: Set<String> = []
}

/// Whether this launch should take the lock, hand the folder over, or leave — everything
/// except the locking itself, so the rules can be tested without processes.
enum InstanceDecision {
    case takeLock, handOff, exitQuietly

    static func decide(holderPid: pid_t, myBundleId: String?, holderBundleId: String?,
                       isTesting: Bool) -> InstanceDecision {
        if isTesting { return .takeLock }
        // A holder that doesn't exist: the lock file outlived its holder (a crash can leave
        // the pid behind; flock itself is already gone). Take it. EPERM counts as alive — a
        // pid we can't signal is a process all the same.
        guard holderPid > 0 else { return .takeLock }
        if kill(holderPid, 0) != 0 && errno != EPERM { return .takeLock }
        if holderBundleId == nil || myBundleId == nil || holderBundleId == myBundleId {
            // Same build (or an older frog that wrote no bundle id): hand the folder over,
            // as one frog with many windows.
            return .handOff
        }
        // A different build is running: don't open a second frog on top of it.
        return .exitQuietly
    }
}

/// The lock itself: `flock` on one file in Application Support, with the holder's pid and
/// bundle id written in for the next launcher to read. `flock` is machine-wide, ignores bundle
/// ids, and is dropped by the kernel when the holder exits — so a dead holder never keeps a
/// live frog out. (Touched only at launch and in tests; `@unchecked` for the static let.)
final class LockHolder: @unchecked Sendable {
    struct Held: Equatable {
        let pid: pid_t
        let bundleIdentifier: String?
    }

    private var fd: Int32 = -1
    private var state: Outcome = .free

    private var isFree: Bool { if case .free = state { true } else { false } }

    enum Outcome: Equatable {
        case free, took, held(Held)
    }

    init() {}

    deinit { if fd >= 0 { close(fd) } }

    /// Try once to become the one frog. Idempotent: the first answer stands (a second call
    /// reports what the first did), so the headless path and `handOff` can both ask.
    func acquire(bundleIdentifier: String?) -> Outcome {
        if !isFree { return state }
        guard let lock = Self.path() else { return state }
        Self.ensureDirectory(of: lock)
        // The holder writes its pid right after it takes the lock, so a failed acquire can
        // briefly read a stale (dead) pid — retry while the file still names a dead one.
        for _ in 0..<5 {
            let f = open(lock.path, O_CREAT | O_RDWR, 0o644)
            guard f >= 0 else { return state }
            guard flock(f, LOCK_EX | LOCK_NB) != 0 else {
                // We hold it. Write who we are (pid first, for the dead-holder check) and keep
                // the fd open for the process's lifetime: closing it would drop the lock.
                ftruncate(f, 0)
                let text = "\(ProcessInfo.processInfo.processIdentifier)\n\(bundleIdentifier ?? "-")\n"
                text.utf8.withContiguousStorageIfAvailable { buf in
                    write(f, buf.baseAddress, buf.count) != -1
                } ?? false
                fd = f
                state = .took
                return state
            }
            close(f)
            let holder = Self.heldInfo(of: lock)
            guard holder.pid <= 0 || kill(holder.pid, 0) != 0 else {
                state = .held(holder)
                return state
            }
            usleep(20_000)
        }
        state = .held(Self.heldInfo(of: lock))
        return state
    }

    /// Who holds the lock now, as the file says it. The pid is trusted only as far as the
    /// live check in `InstanceDecision` goes.
    private static func heldInfo(of lock: URL) -> Held {
        var pid: pid_t = -1
        var bundle: String?
        if let text = try? String(contentsOf: lock, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            pid = lines.first.flatMap { line in Int(line).map { pid_t($0) } } ?? -1
            bundle = lines.count > 1 && lines[1] != "-" ? String(lines[1]) : nil
        }
        return Held(pid: pid, bundleIdentifier: bundle)
    }

    /// One lock per user, machine-wide — outside the bundle id's own container, so every
    /// build of frog (release, debug, a backup) locks the same file. Tests point this at a
    /// scratch file of their own.
    nonisolated(unsafe) static var pathForTesting: URL?

    private static func path() -> URL? {
        if let forced = pathForTesting { return forced }
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appending(path: "Frog/instance.lock")
    }

    private static func ensureDirectory(of lock: URL) {
        try? FileManager.default.createDirectory(
            at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}

/// `open Frog.app --args -FrogFolder <path>` opens that folder in the first window.
/// (AppKit reads `-Key value` launch arguments into UserDefaults; a bare path would be
/// treated as a document to open instead.)
@MainActor
enum LaunchFolder {
    private static var used = false

    static func take() -> URL? {
        guard !used else { return nil }
        used = true
        guard let path = UserDefaults.standard.string(forKey: "FrogFolder") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }
}

enum Recents {
    private static let key = "recentFolders"

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        guard !Frog.isChat(url) else { return }
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(8)), forKey: key)
    }
}

extension SuggestedModel {
    /// The model for this Mac: 32B at 48 GB, 8B at 16 GB, else 4B.
    static var forThisMac: SuggestedModel {
        let repo: String
        switch ModelIdentity.memoryGB {
        case 48...: repo = "mlx-community/Qwen3-32B-4bit"
        case 16...: repo = "mlx-community/Qwen3-8B-4bit"
        default: repo = "mlx-community/Qwen3-4B-4bit"
        }
        return all.first { $0.repo == repo } ?? all[0]
    }
}

/// One quiet line in an empty conversation, while there's no model on this Mac yet: "Using
/// Apple Intelligence. Get Qwen3 32B for bigger tasks · 18 GB". Get downloads the model that
/// suits this Mac and switches to it when it's ready, like picking it in the picker. Gone once
/// there's a model on this Mac or a cloud key, or once it's closed.
struct ModelSuggestion: View {
    let conversation: Conversation
    @AppStorage("modelSuggestionClosed") private var closed = false
    @State private var downloads = ModelDownloads.shared
    @State private var store = ProviderStore.shared

    private var recommended: SuggestedModel { .forThisMac }

    private var hasLocal: Bool {
        SuggestedModel.all.contains { ModelDownloads.isInstalled($0.repo) || downloads.states[$0.repo] == .done }
    }

    private var hasCloud: Bool { store.providers.contains { !$0.local && $0.connected } }

    private var onApple: Bool { conversation.status?.model == AppleIntelligence.spec }

    var body: some View {
        let m = ModelIdentity(recommended)
        Group {
            if !closed, !hasLocal, !hasCloud {
                HStack(spacing: 4) {
                    switch m.state {
                    case .downloading(let f):
                        ProgressView(value: f)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                        Text("Downloading \(m.name) · \(m.stateLine ?? "")")
                        Button("Stop") { downloads.cancel(recommended.repo) }
                            .buttonStyle(.link)
                            .foregroundStyle(.tint)
                    default:
                        if onApple { Text("Using Apple Intelligence.") }
                        Button("Get \(m.name)") { downloads.download(recommended.repo) }
                            .buttonStyle(.link)
                            .foregroundStyle(.tint)
                        Text("for bigger tasks · \(String(format: "%.1f GB", recommended.approxGB))")
                    }
                    Button {
                        closed = true
                    } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .help("Don't suggest this again")
                }
                .font(.frog(size: 12))
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .task { await store.load() }
        .onChange(of: downloads.states[recommended.repo]) { _, s in
            guard s == .done else { return }
            // Like picking it: remembered for new conversations, and this one moves over if it
            // hasn't started.
            UserDefaults.standard.set(recommended.spec, forKey: "lastModel")
            if conversation.turns.isEmpty {
                conversation.setModel(recommended.spec)
                conversation.flash("\(recommended.title) is ready on this Mac.")
            }
        }
    }
}

/// frog was called kiln. Before anything touches frog's folders or settings, move kiln's over:
/// config and data (the old paths become symlinks, so paths in old sessions still resolve) and
/// the app's preferences (pins, archive, settings) from frog's and kiln's old bundle ids.
enum LegacyKiln {
    static func migrate() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for (old, new) in [(".config/kiln", ".config/frog"), (".local/share/kiln", ".local/share/frog")] {
            let from = home.appending(path: old), to = home.appending(path: new)
            let isRealDir = (try? from.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]))
                .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
            guard isRealDir, !fm.fileExists(atPath: to.path) else { continue }
            try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: from, to: to)) != nil {
                try? fm.createSymbolicLink(at: from, withDestinationURL: to)
            }
        }
        // Then the preferences, newest bundle id first: frog was eco.frog before toys.frog,
        // com.campedersen.frog before that, and com.campedersen.kiln first.
        let defaults = UserDefaults.standard
        // eco.frog → toys.frog came later than the first import, so it has its own flag.
        if !defaults.bool(forKey: "importedEcoDefaults") {
            let dev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
            importDefaults(from: dev ? "eco.frog.dev" : "eco.frog", into: defaults)
            defaults.set(true, forKey: "importedEcoDefaults")
        }
        guard !defaults.bool(forKey: "importedLegacyDefaults") else { return }
        for oldID in ["com.campedersen.frog", "com.campedersen.kiln"] {
            let id = oldID as CFString
            let keys = CFPreferencesCopyKeyList(id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = CFPreferencesCopyAppValue(key as CFString, id) {
                    defaults.set(value, forKey: key)
                }
            }
        }
        defaults.set(true, forKey: "importedLegacyDefaults")
    }

    /// Copy what an old bundle id's preferences hold that these don't yet.
    private static func importDefaults(from oldID: String, into defaults: UserDefaults) {
        let id = oldID as CFString
        let keys = CFPreferencesCopyKeyList(id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = CFPreferencesCopyAppValue(key as CFString, id) { defaults.set(value, forKey: key) }
        }
    }
}
