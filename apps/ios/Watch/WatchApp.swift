import SwiftUI
import WatchConnectivity

/// frog on your wrist: what needs you, answered with a tap, and what's running. The phone keeps
/// it current and carries the answers to the Mac.
@main
struct FrogWatchApp: App {
    @State private var link = WristLink()

    var body: some Scene {
        WindowGroup {
            WristView(link: link)
        }
    }
}

@MainActor
@Observable
final class WristLink: NSObject, WCSessionDelegate {
    struct Row: Identifiable, Hashable {
        let id: String
        let title: String
        let live: String
        let activity: String?
        let question: String?
        let permission: String?
    }

    private(set) var rows: [Row] = []
    private(set) var sending: Set<String> = []

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func answer(_ row: Row, allow: Bool) {
        guard let permission = row.permission else { return }
        sending.insert(row.id)
        WCSession.default.sendMessage(["session": row.id, "permission": permission, "allow": allow], replyHandler: { _ in
            Task { @MainActor in self.sending.remove(row.id) }
        }, errorHandler: { _ in
            Task { @MainActor in self.sending.remove(row.id) }
        })
    }

    private func load(_ list: [[String: String]]) {
        rows = list.compactMap { r in
            guard let id = r["id"] else { return nil }
            return Row(id: id, title: r["title"] ?? "frog", live: r["live"] ?? "", activity: r["activity"],
                       question: r["question"], permission: r["permission"])
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let list = session.receivedApplicationContext["sessions"] as? [[String: String]] ?? []
        Task { @MainActor in self.load(list) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let list = context["sessions"] as? [[String: String]] ?? []
        Task { @MainActor in self.load(list) }
    }
}

struct WristView: View {
    let link: WristLink

    var body: some View {
        NavigationStack {
            List {
                let waiting = link.rows.filter { $0.live == "waiting" }
                let running = link.rows.filter { $0.live == "running" }
                if waiting.isEmpty, running.isEmpty {
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
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            FrogFace(mood: .waiting, size: 20).tint(.frog)
                            Text(row.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(row.question ?? "frog needs you").font(.headline).foregroundStyle(.orange).lineLimit(3)
                        if link.sending.contains(row.id) {
                            ProgressView().frame(maxWidth: .infinity)
                        } else if row.permission != nil {
                            HStack {
                                Button { link.answer(row, allow: false) } label: { Image(systemName: "xmark") }
                                    .tint(.gray)
                                Button { link.answer(row, allow: true) } label: { Image(systemName: "checkmark") }
                                    .tint(Color(red: 0.18, green: 0.62, blue: 0.31))
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 4)
                }
                ForEach(running) { row in
                    HStack(spacing: 8) {
                        FrogFace(mood: .working, size: 22).tint(.frog)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.caption).lineLimit(1)
                            Text(row.activity ?? "Working").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .navigationTitle("frog")
        }
    }
}
