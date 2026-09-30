import AppIntents
import Foundation

/// Answer frog from the Dynamic Island or the lock screen. Allowing asks for Face ID first, so a
/// phone left on a desk can't approve a command; saying no never needs it. These run in the app
/// (it's woken for them), which carries the answer to the Mac.
struct AllowIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow"
    static let description = IntentDescription("Let frog go ahead with what it asked.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let isDiscoverable = false

    @Parameter(title: "Conversation") var session: String
    @Parameter(title: "Question") var permission: String

    init() {}
    init(session: String, permission: String) {
        self.session = session
        self.permission = permission
    }

    func perform() async throws -> some IntentResult {
        await Answer.send(session: session, permission: permission, decision: "allow")
        return .result()
    }
}

struct DenyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny"
    static let description = IntentDescription("Tell frog not to.")
    static let isDiscoverable = false

    @Parameter(title: "Conversation") var session: String
    @Parameter(title: "Question") var permission: String

    init() {}
    init(session: String, permission: String) {
        self.session = session
        self.permission = permission
    }

    func perform() async throws -> some IntentResult {
        await Answer.send(session: session, permission: permission, decision: "deny")
        return .result()
    }
}

enum Answer {
    static func send(session: String, permission: String, decision: String) async {
        #if FROG_APP
        if let player = await FixturePlayer.playing[session] {
            await player.send(op: ["op": "permission", "id": permission, "decision": decision], in: session)
            return
        }
        await Remote.shared.perform(op: ["op": "permission", "id": permission, "decision": decision], in: session)
        #endif
    }
}
