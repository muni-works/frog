import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit

/// frog on your wrist: what needs you, answered with a tap (or your voice), what's running, and
/// what frog said last. The phone keeps it current and carries answers to the Mac; when the phone
/// isn't around, the watch talks to the Mac itself (`WatchBridge`).
@main
struct FrogWatchApp: App {
    @State private var link = WristLink()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WristView(link: link)
        }
        .onChange(of: phase, initial: true) { _, p in link.active = p == .active }
    }
}

@MainActor
@Observable
final class WristLink: NSObject, WCSessionDelegate {
    typealias Row = Snapshot.Row

    /// How we're reaching the Mac right now.
    enum Route: Equatable {
        case phone
        case direct
        case offline(String)
    }

    private(set) var rows: [Row] = []
    private(set) var sending: Set<String> = []
    private(set) var route: Route = .phone

    /// On screen: talk to the Mac directly while the phone can't.
    var active = false {
        didSet { if active != oldValue { reconsider() } }
    }

    @ObservationIgnored private let bridge = WatchBridge()
    @ObservationIgnored private var direct: URL?

    override init() {
        super.init()
        direct = UserDefaults.standard.string(forKey: "direct").flatMap(URL.init(string:))
        // Development: a bridge (or a stand-in) named at launch, as the phone's FROG_REMOTE_HOST.
        let env = ProcessInfo.processInfo.environment
        if let url = env["FROG_DIRECT_URL"].flatMap(URL.init(string:)), let code = env["FROG_REMOTE_CODE"] {
            direct = url
            PairingCode.write(code)
        }
        if let saved = Snapshot.load()?.rows { rows = saved }
        bridge.onRows = { [weak self] rows in self?.adopt(rows) }
        bridge.onState = { [weak self] _ in self?.reconsider() }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Routes

    /// The phone, when it's in reach and has frog.
    private var phone: Bool {
        WCSession.isSupported() && WCSession.default.isReachable && WCSession.default.isCompanionAppInstalled
    }

    /// While on screen, also hold the Mac directly if we know where it is: reachability flickers,
    /// and a question shouldn't wait on the phone coming back. Answers still prefer the phone.
    private func reconsider() {
        if active, let direct, let code = PairingCode.read(), !code.isEmpty {
            bridge.connect(url: direct, code: code)
        } else {
            bridge.disconnect()
        }
        switch bridge.state {
        case .connected: route = .direct
        case _ where phone: route = .phone
        case .failed(let why): route = .offline(why)
        case .connecting: route = .offline("Reaching your Mac…")
        case .off: route = .offline("Your phone is out of reach")
        }
    }

    // MARK: Answers

    func allow(_ row: Row, _ allow: Bool) {
        guard let p = row.permission else { return }
        send(["op": "permission", "id": p, "decision": allow ? "allow" : "deny"], in: row)
    }

    /// An Ask answered: an option picked, or words of your own.
    func answer(_ row: Row, choice: String? = nil, other: String? = nil) {
        guard let ask = row.ask else { return }
        var op: [String: Any] = ["op": "answer", "id": ask.id, "choices": choice.map { [$0] } ?? []]
        if let other, !other.isEmpty { op["other"] = other }
        send(op, in: row)
    }

    /// A next-step button pressed: runs a turn on the Mac.
    func act(_ row: Row, _ action: Snapshot.Action) {
        var op: [String: Any] = ["op": "act", "label": action.label]
        if !action.send.isEmpty { op["send"] = action.send }
        send(op, in: row)
    }

    private func send(_ op: [String: Any], in row: Row) {
        sending.insert(row.id)
        Task {
            let ok = await deliver(op, in: row.id)
            sending.remove(row.id)
            Haptic.play(ok ? .click : .failure)
        }
    }

    /// Straight to the Mac when we hold it; else through the phone; else try the Mac anyway.
    private func deliver(_ op: [String: Any], in session: String) async -> Bool {
        if bridge.isConnected { return await bridge.perform(op: op, in: session) }
        if phone, await viaPhone(["session": session, "op": op]) { return true }
        return await bridge.perform(op: op, in: session)
    }

    /// A message to the phone, given up on after a few seconds (a reachable phone can still
    /// sit on it).
    private func viaPhone(_ message: [String: Any]) async -> Bool {
        nonisolated(unsafe) let message = message
        let once = Once()
        return await withCheckedContinuation { cont in
            WCSession.default.sendMessage(message, replyHandler: { reply in
                once.run { cont.resume(returning: reply["ok"] as? Bool ?? false) }
            }, errorHandler: { _ in
                once.run { cont.resume(returning: false) }
            })
            Task {
                try? await Task.sleep(for: .seconds(5))
                once.run { cont.resume(returning: false) }
            }
        }
    }

    /// Bring this conversation up on the phone (a long press on what frog said).
    func showOnPhone(_ row: Row) {
        guard phone else { return Haptic.play(.failure) }
        WCSession.default.sendMessage(["show": row.id], replyHandler: nil)
        Haptic.play(.directionUp)
    }

    // MARK: Rows

    private func adopt(_ new: [Row]) {
        // The tap means something: a question, a finished turn, each its own.
        let was = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let asked = new.contains { r in r.waiting && !(was[r.id]?.waiting ?? false) }
        let done = new.contains { r in r.live == "unread" && was[r.id]?.live == "running" }
        if asked { Haptic.play(.notification) } else if done { Haptic.play(.success) }
        rows = new
        // The complication reads the same snapshot the phone's widgets do.
        let snapshot = Snapshot(rows: new, host: nil, at: .now)
        if snapshot.rows != Snapshot.load()?.rows {
            snapshot.save()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func context(_ context: [String: Any]) {
        if let url = context["direct"] as? String, let code = context["code"] as? String {
            UserDefaults.standard.set(url, forKey: "direct")
            direct = URL(string: url)
            if PairingCode.read() != code { PairingCode.write(code) }
        } else if context["rows"] != nil {
            UserDefaults.standard.removeObject(forKey: "direct")
            direct = nil
        }
        if let data = context["rows"] as? Data, let rows = try? JSONDecoder().decode([Row].self, from: data) {
            adopt(rows)
        }
        reconsider()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        nonisolated(unsafe) let ctx = session.receivedApplicationContext
        Task { @MainActor in self.context(ctx) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        nonisolated(unsafe) let ctx = context
        Task { @MainActor in self.context(ctx) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.reconsider() }
    }
}

/// Runs its first caller only: a continuation resumed by whichever of reply, error or timeout
/// comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

/// Learned in a day: a question taps, a finished turn rises, a failure buzzes.
enum Haptic {
    @MainActor
    static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}

struct WristView: View {
    let link: WristLink

    var body: some View {
        NavigationStack {
            List {
                let waiting = link.rows.filter(\.waiting)
                let running = link.rows.filter { $0.live == "running" }
                let done = link.rows.filter { $0.live == "unread" }
                if waiting.isEmpty, running.isEmpty, done.isEmpty {
                    VStack(spacing: 8) {
                        FrogFace(mood: .idle, size: 44).tint(.frog)
                        Text("All quiet").font(.headline)
                        Text("frog will tap you when it needs you.")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                ForEach(waiting) { row in
                    WaitingCard(row: row, link: link)
                }
                ForEach(running) { row in
                    NavigationLink(value: row) {
                        HStack(spacing: 8) {
                            FrogFace(mood: .working, size: 22).tint(.frog)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).font(.caption).lineLimit(1)
                                Text(row.activity ?? "Working").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
                ForEach(done) { row in
                    NavigationLink(value: row) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text(row.last ?? "Done.").font(.caption).lineLimit(3)
                        }
                    }
                }
                if case .offline(let why) = link.route {
                    Label(why, systemImage: "iphone.slash")
                        .font(.caption2).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else if link.route == .direct {
                    Label("Straight to your Mac", systemImage: "network")
                        .font(.caption2).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("frog")
            .navigationDestination(for: Snapshot.Row.self) { row in
                ReplyView(row: link.rows.first { $0.id == row.id } ?? row, link: link)
            }
        }
    }
}

/// frog needs you: Allow or Deny for a permission; for an Ask, its options as buttons, and
/// anything else said aloud.
struct WaitingCard: View {
    let row: Snapshot.Row
    let link: WristLink

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FrogFace(mood: .waiting, size: 20).tint(.frog)
                Text(row.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(row.ask?.question ?? row.question ?? "frog needs you")
                .font(.headline).foregroundStyle(.orange).lineLimit(4)
            if link.sending.contains(row.id) {
                ProgressView().frame(maxWidth: .infinity)
            } else if let ask = row.ask {
                ForEach(ask.options, id: \.self) { option in
                    Button(option) { link.answer(row, choice: option) }
                        .buttonStyle(.bordered)
                        .lineLimit(2)
                }
                if ask.other || ask.options.isEmpty {
                    TextFieldLink(prompt: Text(ask.question)) {
                        Label("Say something else", systemImage: "mic")
                    } onSubmit: { text in
                        link.answer(row, other: text)
                    }
                    .buttonStyle(.bordered)
                }
            } else if row.permission != nil {
                HStack {
                    Button { link.allow(row, false) } label: { Image(systemName: "xmark") }
                        .tint(.gray)
                    Button { link.allow(row, true) } label: { Image(systemName: "checkmark") }
                        .tint(Color(red: 0.18, green: 0.62, blue: 0.31))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

/// What frog said last, to read with the Crown. Long-press to bring it up on the phone; it's
/// offered there for Handoff too.
struct ReplyView: View {
    let row: Snapshot.Row
    let link: WristLink

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    FrogFace(mood: row.live == "running" ? .working : .idle, size: 20).tint(.frog)
                    Text(row.live == "running" ? (row.activity ?? "Working") : "Done")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(row.last ?? (row.live == "running" ? "frog is still going." : "Nothing said yet."))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(row.stats ?? [], id: \.self) { s in
                    Text(s).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if row.live != "running" {
                    ForEach(row.actions ?? [], id: \.self) { a in
                        Button(a.label) { link.act(row, a) }
                    }
                }
            }
            .onLongPressGesture { link.showOnPhone(row) }
        }
        .navigationTitle(row.title)
        .userActivity(Handoff.conversation) { a in
            a.title = row.title
            a.userInfo = ["session": row.id]
            a.isEligibleForHandoff = true
        }
    }
}
