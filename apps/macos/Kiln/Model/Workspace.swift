import Foundation
import Observation

/// A project folder: its sessions, the available models, and the conversation in view.
@MainActor
@Observable
final class Workspace {
    let folder: URL
    private(set) var sessions: [SessionInfo] = []
    private(set) var models: [ModelEntry] = []
    private(set) var conversation: Conversation?
    var selection: String?
    var preferredModel: String?
    /// Parallel attempts in progress, shown instead of the transcript.
    var race: Race?
    private(set) var raceError: String?

    func startRace(prompt: String, models: [String], check: String?) {
        raceError = nil
        Task {
            do {
                race = try await Race.start(in: folder, prompt: prompt, models: models, check: check)
            } catch {
                raceError = "Couldn't start attempts: \(error.localizedDescription). Racing needs a git repository."
            }
        }
    }

    func endRace() {
        race = nil
        Task { await refresh() }
    }

    /// Project files for `@` mentions, loaded on first use.
    private(set) var files: [String] = []
    @ObservationIgnored private var filesLoaded = false

    func loadFiles() {
        guard !filesLoaded else { return }
        filesLoaded = true
        Task { files = await FileIndex.load(folder) }
    }

    init(folder: URL) {
        self.folder = folder
        start(arguments: Replay.arguments ?? [])
        Task { await refresh() }
    }

    var name: String { folder.lastPathComponent }

    func refresh() async {
        if let s = try? await Kiln.json([SessionInfo].self, args: ["--sessions", "--json"], cwd: folder) {
            sessions = s
        }
        if models.isEmpty, let m = try? await Kiln.json([ModelEntry].self, args: ["--models", "--json"], cwd: folder) {
            models = m
        }
    }

    func newSession() {
        start(arguments: [])
    }

    func open(_ id: String) {
        guard id != conversation?.sessionID else { return }
        start(arguments: ["-r", id])
    }

    /// Branch the current session right after `turn`, and switch to the branch.
    func fork(afterTurn turn: UInt64) {
        guard let id = conversation?.sessionID else { return }
        start(arguments: ["--fork", "\(id)@\(turn)"])
    }

    /// Restore files edited in `turn` and later, and continue on a branch from just before it.
    func rewind(toBefore turn: UInt64) async {
        guard let id = conversation?.sessionID else { return }
        do {
            let r = try await Kiln.json(Rewound.self, args: ["--rewind", "\(id)@\(turn)", "--json"], cwd: folder)
            start(arguments: ["-r", r.session])
            let files = r.restored.count
            conversation?.flash(files == 0
                ? "Rewound to before turn \(turn). No files needed restoring."
                : "Rewound to before turn \(turn) and restored \(files) file\(files == 1 ? "" : "s").")
            await refresh()
        } catch {
            conversation?.flash("Rewind failed: \(error.localizedDescription)", warning: true)
        }
    }

    func stop() {
        race?.discard()
        conversation?.stop()
    }

    private func start(arguments: [String]) {
        conversation?.stop()
        let c = Conversation(folder: folder, arguments: arguments, model: preferredModel)
        c.onSessionChange = { [weak self, weak c] in
            guard let self else { return }
            self.selection = c?.sessionID
            Task { await self.refresh() }
        }
        conversation = c
    }
}

/// `-KilnReplay <session or .jsonl>` (with optional `-KilnReplaySpeed 4` and `-KilnReplayAsk YES`)
/// plays a recorded session in the first window instead of starting a live engine.
@MainActor
enum Replay {
    private static var used = false

    static var arguments: [String]? {
        guard !used, let spec = UserDefaults.standard.string(forKey: "KilnReplay") else { return nil }
        used = true
        let speed = UserDefaults.standard.double(forKey: "KilnReplaySpeed")
        var args = ["--replay", spec, "--speed", String(speed > 0 ? speed : 2)]
        if UserDefaults.standard.bool(forKey: "KilnReplayAsk") { args.append("--replay-ask") }
        return args
    }
}
