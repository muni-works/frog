import AppIntents
import FoundationModels
import SwiftUI
import UserNotifications

/// "Hey Siri, ask the house why the garage is cold." The request goes to frog on your home
/// server (`House`), which reasons over the house's tools and answers; Siri speaks the answer.
/// If the server can't be reached, Apple's on-device model answers instead, without the house's
/// tools, and says so. Never Private Cloud Compute.
struct AskHouseIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask the house"
    static let description = IntentDescription("Ask frog on your home server anything about the house, and hear the answer.")

    @Parameter(title: "Request", inputOptions: .init(multiline: true),
               requestValueDialog: IntentDialog("What do you want to ask the house?"))
    var request: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask the house \(\.$request)")
    }

    init() {}
    init(request: String) { self.request = request }

    /// Siri gives an intent about ten seconds; past this, answer with what's there.
    static let budget: Duration = .seconds(8)

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard House.configured else {
            return .result(value: "", dialog: "Set up the house in frog's settings first: your server's address and token.")
        }
        let asked = request
        do {
            let a = try await House.ask(asked, budget: Self.budget)
            if a.done {
                let text = a.failed.map { "frog couldn't finish: \($0)" } ?? a.text
                HouseLog.save(asked, text, session: a.session)
                return .result(value: text, dialog: IntentDialog(stringLiteral: text.isEmpty ? "frog had nothing to say." : text))
            }
            // Out of time: the turn carries on on the server. Keep listening for a little while
            // and send the answer as a notification when it lands.
            HouseLog.save(asked, a.text, session: a.session, pending: true)
            HouseLog.follow(asked)
            let said = a.text.isEmpty ? "Still working on it. I'll send you the answer." : "\(a.text)… still working. I'll send you the rest."
            return .result(value: a.text, dialog: IntentDialog(stringLiteral: said))
        } catch House.Failure.unreachable {
            let text = await OnDevice.answer(asked)
            HouseLog.save(asked, text, session: nil)
            return .result(value: text, dialog: IntentDialog(stringLiteral: text))
        } catch House.Failure.refused(let why) {
            return .result(value: "", dialog: IntentDialog(stringLiteral: why))
        }
    }
}

/// When the house is out of reach: Apple's on-device model, no tools, said plainly.
enum OnDevice {
    static func answer(_ request: String) async -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return "I can't reach the house, and the on-device model isn't available on this device."
        }
        let session = LanguageModelSession(model: model, instructions: """
            You answer questions spoken to a home assistant. You have no access to the house's \
            sensors, cameras or devices right now, so never claim to know their state. Answer in \
            two sentences at most, plainly, for reading aloud.
            """)
        do {
            let reply = try await session.respond(to: request)
            return "I can't reach the house, so this is from your phone alone: \(reply.content)"
        } catch {
            return "I can't reach the house, and the on-device model couldn't answer."
        }
    }
}

/// The last few things asked of the house, shown in the app (where a slow answer finishes).
enum HouseLog {
    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var request: String
        var answer: String
        var session: String?
        var pending = false
        var at = Date()
    }

    static var entries: [Entry] {
        (Snapshot.defaults.data(forKey: "houseLog").flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
    }

    static func save(_ request: String, _ answer: String, session: String?, pending: Bool = false) {
        var all = entries.filter { !($0.request == request && $0.pending) }
        all.insert(Entry(request: request, answer: answer, session: session, pending: pending), at: 0)
        Snapshot.defaults.set(try? JSONEncoder().encode(Array(all.prefix(20))), forKey: "houseLog")
    }

    /// Wait for a turn Siri gave up on to finish on the server, then post its answer. Runs as
    /// long as iOS keeps the app awake after the intent; if it's suspended first, the answer is
    /// still in the conversation on the server, and the app picks it up next time it's opened.
    static func follow(_ request: String) {
        guard let session = entries.first(where: { $0.request == request })?.session else { return }
        Task.detached { await finish(request, session: session, notify: true) }
    }

    /// Fetch the answers still pending (when the app opens).
    static func refresh() async {
        for e in entries where e.pending {
            if let s = e.session { await finish(e.request, session: s, notify: false, tries: 1) }
        }
    }

    private static func finish(_ request: String, session: String, notify: Bool, tries: Int = 30) async {
        for i in 0..<tries {
            if i > 0 { try? await Task.sleep(for: .seconds(2)) }
            guard let text = try? await House.answer(session: session) else { continue }
            save(request, text, session: session)
            guard notify else { return }
            let note = UNMutableNotificationContent()
            note.title = "The house"
            note.body = text
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "house-\(session)", content: note, trigger: nil))
            return
        }
    }
}
