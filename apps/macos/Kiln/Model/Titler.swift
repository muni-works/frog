import Foundation
import FoundationModels

/// Session titles from Apple's on-device model: free, private, and fast enough to run after the
/// first turn without anyone noticing. Silently does nothing where the model isn't available.
enum Titler {
    static var available: Bool {
        SystemLanguageModel.default.availability == .available
    }

    static func title(for request: String, answer: String) async -> String? {
        guard available else { return nil }
        let session = LanguageModelSession(instructions: """
            You name coding sessions. Given the user's first request (and the start of the answer), \
            reply with a title of 2 to 6 words in sentence case. No quotes, no trailing period.
            """)
        let prompt = "Request: \(request.prefix(600))\nAnswer: \(answer.prefix(300))"
        guard let reply = try? await session.respond(to: prompt).content else { return nil }
        let title = reply
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.`*#"))
        return title.isEmpty || title.count > 80 ? nil : title
    }
}
