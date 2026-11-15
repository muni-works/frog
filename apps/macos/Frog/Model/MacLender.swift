import AppKit
import Foundation
import IOKit.ps

/// "Lend this Mac": runs `tang-llm serve --host 0.0.0.0` as a child of the app so your other
/// Macs can pair with this one and run models on it (docs/node-protocol.md).
///
/// It runs only while the switch is on, the app is open, the Mac is on power (unless
/// `onBattery` is set) and the thermal state is below `.serious`. It never holds a sleep or
/// idle assertion: when the Mac sleeps, the node drops out like any other.
@MainActor
final class MacLender: ObservableObject {
    static let shared = MacLender()

    /// The lent server's port. Not the engine sidecar's 8911 (loopback-only) or RemoteBridge's 8913;
    /// the Mac app finds a node's port through Bonjour, so any fixed port works.
    static let port = 8920

    enum State: Equatable {
        case off
        case starting
        case running
        case paused(String)
        case failed(String)
    }

    @Published private(set) var state: State = .off
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "lendThisMac"); reconcile() }
    }
    @Published var onBattery: Bool {
        didSet { UserDefaults.standard.set(onBattery, forKey: "lendOnBattery"); reconcile() }
    }

    private var process: Process?
    private var powerTimer: Timer?
    private var restarts = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "lendThisMac")
        onBattery = UserDefaults.standard.bool(forKey: "lendOnBattery")
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in MacLender.shared.reconcile() }
        })
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MacLender.shared.stop() }
        })
        // Power source changes: a cheap poll is enough (the IOPS run-loop source needs a C callback).
        powerTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in MacLender.shared.reconcile() }
        }
    }

    /// Call once at launch so a switch left on resumes lending.
    func start() { reconcile() }

    /// Why lending should be paused right now, if it should.
    var pauseReason: String? {
        if !onBattery && Self.onBatteryPower { return "Paused on battery. Plug in to lend." }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return "Paused while this Mac is hot."
        }
        return nil
    }

    func reconcile() {
        guard enabled else { stop(); state = .off; return }
        if let reason = pauseReason { stop(); state = .paused(reason); return }
        if process?.isRunning == true { return }
        launch()
    }

    private func launch() {
        guard let bin = Self.binary else {
            state = .failed("tang-llm isn't installed. Set up a local model in Settings > Models first.")
            return
        }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["serve", "--host", "0.0.0.0", "--port", String(Self.port)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in MacLender.shared.exited(proc, code: code) }
        }
        do {
            try p.run()
            // Ends with the app, even on a crash: it was left serving, ppid 1, before.
            ParentWatch.watch(child: p.processIdentifier)
            process = p
            state = .starting
            Task { await waitHealthy(p) }
        } catch {
            state = .failed("Couldn't start tang-llm: \(error.localizedDescription)")
        }
    }

    private func waitHealthy(_ p: Process) async {
        for _ in 0..<60 {
            guard process === p, p.isRunning else { return }
            if await Self.healthy() { state = .running; restarts = 0; return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func exited(_ p: Process, code: Int32) {
        guard process === p else { return }
        process = nil
        guard enabled, pauseReason == nil else { return }
        // Crashed while it should be running: retry a few times, then give up and say so.
        restarts += 1
        if restarts > 3 {
            state = .failed("tang-llm keeps exiting (status \(code)).")
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(2 * restarts))
            reconcile()
        }
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        if p.isRunning { p.terminate() }
    }

    // MARK: - Pairing

    struct PairWindow: Decodable, Equatable {
        let code: String
        let expires_in: Int
        let fingerprint: String
    }

    /// Opens a 120 s pairing window on the lent server (`POST /pair/open`, loopback only).
    func openPairing() async throws -> PairWindow {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/pair/open")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(PairWindow.self, from: data)
    }

    // MARK: - Helpers

    static func healthy() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    static var onBatteryPower: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPSBatteryPowerValue
    }

    /// The bundled tang-llm first; then an override; then where `frog` installs it.
    static var binary: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "tang-llm", withExtension: nil) {
            candidates.append(bundled)
        }
        if let env = ProcessInfo.processInfo.environment["TANG_LLM_BIN"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        let home = fm.homeDirectoryForCurrentUser
        candidates += [
            home.appending(path: ".local/share/frog/bin/tang-llm"),
            URL(fileURLWithPath: "/opt/homebrew/bin/tang-llm"),
            URL(fileURLWithPath: "/usr/local/bin/tang-llm"),
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
