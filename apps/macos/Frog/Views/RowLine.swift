import SwiftUI

/// A sidebar row's second line and status, as the web shows them: what the session is doing
/// now or asking, else its last reply; idle with nothing loaded, the row falls back to
/// repo · turns · model. The status shows a pull request when nothing is live.
struct RowLine: Equatable {
    var text: String?
    var tint: Color = Tokens.textSecondary
    var turns: Int?
    var pr: Int?
}

@MainActor
extension Library {
    func rowLine(_ s: SessionInfo) -> RowLine {
        var line = RowLine()
        if case .pr(let n)? = GitIndex.shared.badge(s)?.landed { line.pr = n }
        guard let c = conversation(s.id) else {
            if live[s.id] == .waiting { line.text = "Waiting on you"; line.tint = Tokens.signal }
            return line
        }
        line.turns = c.turns.count
        if let q = c.question {
            line.text = q.question; line.tint = Tokens.signal
        } else if c.permission != nil || c.elicitation != nil {
            line.text = "Waiting on you"; line.tint = Tokens.signal
        } else if let now = c.liveActivity {
            line.text = now
        } else if let reply = Self.lastReply(c) {
            line.text = reply
        }
        return line
    }

    /// The first line of the last thing Frog said.
    static func lastReply(_ c: Conversation) -> String? {
        guard let last = c.turns.last, last.finished else { return nil }
        let text = last.items.last(where: { $0.kind == .message && !$0.text.isEmpty })?.text ?? ""
        let first = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") }
        return first.map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }
    }
}
