import Foundation
import FoundationModels

/// Session titles from Apple's on-device model: free, private, and fast enough to run after the
/// first turn without anyone noticing. Silently does nothing where the model isn't available.
enum Titler {
    /// Visual results may be the answer even when the final message is only an acknowledgment.
    static func answerContext(for turn: TurnState) -> String {
        let visuals = turn.items.compactMap { item -> String? in
            guard let result = item.result, result.outcome == .ok,
                  let images = result.images, !images.isEmpty else { return nil }
            return "Completed \(result.name): returned \(images.count) image(s)."
        }
        let answer = turn.items.last { $0.kind == .message }?.text ?? ""
        return (visuals + [answer]).joined(separator: "\n")
    }

    static var available: Bool {
        SystemLanguageModel.default.availability == .available
    }

    static func title(for request: String, answer: String) async -> String? {
        guard available else { return nil }
        let session = LanguageModelSession(instructions: """
            You name work sessions. Given the user's first request (and the start of the answer), \
            reply with a title of 2 to 6 words in sentence case. No quotes, no trailing period.
            Name the topic of the request. Completed tool results are facts about the work done.
            """)
        let prompt = "Request: \(request.prefix(600))\nAnswer: \(answer.prefix(300))"
        guard let reply = try? await session.respond(to: prompt).content else { return nil }
        let title = reply
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.`*#"))
        return title.isEmpty || title.count > 80 ? nil : title
    }
}
