import AppIntents
import SwiftUI

/// frog in Siri, Shortcuts and Spotlight: send a conversation something, ask what frog's up to,
/// open a conversation by name. Each talks to the Mac itself, connecting if it must.

struct ConversationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Conversation"
    static let defaultQuery = ConversationQuery()

    let id: String
    let title: String
    let open: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: open ? "Open on your Mac" : nil)
    }

    init(_ s: RemoteSession) {
        id = s.id
        title = s.title
        open = s.open
    }
}

struct ConversationQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
        await Remote.shared.listNow().filter { identifiers.contains($0.id) }.map(ConversationEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ConversationEntity] {
        await Remote.shared.listNow().filter { $0.title.localizedCaseInsensitiveContains(string) }.prefix(20).map(ConversationEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ConversationEntity] {
        let all = await Remote.shared.listNow()
        return (all.filter(\.open) + all.filter { !$0.open }).prefix(12).map(ConversationEntity.init)
    }
}

struct AskFrogIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask frog"
    static let description = IntentDescription("Send a message to a conversation that's open on your Mac.")

    @Parameter(title: "Message", inputOptions: .init(multiline: true))
    var message: String

    @Parameter(title: "Conversation", description: "Leave empty for the one you used last.")
    var conversation: ConversationEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask frog \(\.$message) in \(\.$conversation)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let sessions = await Remote.shared.listNow()
        let target = conversation.flatMap { c in sessions.first { $0.id == c.id } } ?? sessions.first(where: \.open)
        guard let target else {
            return .result(dialog: "Open a conversation on your Mac first, and I'll send it there.")
        }
        guard target.open else {
            return .result(dialog: "\(target.title) isn't open on your Mac right now.")
        }
        let sent = await Remote.shared.perform(op: ["op": "submit", "text": message], in: target.id)
        return .result(dialog: sent ? "Sent to \(target.title). I'll tell you when frog's done." : "I couldn't reach your Mac.")
    }
}

struct FrogStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "What's frog doing?"
    static let description = IntentDescription("What needs you and what's running on your Mac.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let sessions = await Remote.shared.listNow()
        let waiting = sessions.filter { $0.live == .waiting }
        let running = sessions.filter { $0.live == .running }
        let dialog: IntentDialog
        if let q = waiting.first {
            dialog = "\(q.title) needs you: \(q.question?.text ?? "frog has a question")."
        } else if let r = running.first {
            dialog = running.count == 1 ? "frog is on \(r.title): \(r.activity ?? "working")." : "frog is running \(running.count) conversations."
        } else if Remote.shared.isConnected {
            dialog = "All quiet. Nothing's running."
        } else {
            dialog = "I couldn't reach your Mac."
        }
        return .result(dialog: dialog, view: StatusSnippet(waiting: waiting, running: running))
    }
}

struct StatusSnippet: View {
    let waiting: [RemoteSession]
    let running: [RemoteSession]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FrogFace(mood: !waiting.isEmpty ? .waiting : !running.isEmpty ? .working : .idle, size: 40).tint(.frog)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(waiting + running) { s in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(s.question?.text ?? s.activity ?? "")
                            .font(.caption)
                            .foregroundStyle(s.question != nil ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }
                }
                if waiting.isEmpty, running.isEmpty {
                    Text("All quiet").font(.headline)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}

struct OpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open conversation"

    @Parameter(title: "Conversation")
    var target: ConversationEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        Remote.shared.requested = target.id
        return .result()
    }
}

struct FrogShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskFrogIntent(), phrases: ["Ask \(.applicationName)", "Tell \(.applicationName)", "Message \(.applicationName)"],
                    shortTitle: "Ask frog", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: FrogStatusIntent(), phrases: ["What's \(.applicationName) doing", "Check on \(.applicationName)", "Does \(.applicationName) need me"],
                    shortTitle: "What's frog doing?", systemImageName: "hand.raised")
        AppShortcut(intent: AskHouseIntent(), phrases: ["Ask \(.applicationName) about the house", "Ask the house with \(.applicationName)", "Check the house with \(.applicationName)"],
                    shortTitle: "Ask the house", systemImageName: "house")
        AppShortcut(intent: OpenConversationIntent(), phrases: ["Open \(\.$target) in \(.applicationName)"],
                    shortTitle: "Open conversation", systemImageName: "bubble.left")
    }
}
