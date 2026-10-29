import SwiftUI

/// A message another session sent this one (`SendMessage`), as the engine wraps it:
/// `<session-message from="id" name="Name">…</session-message>`.
struct SessionMessage: Equatable {
    var from: String
    var name: String
    var body: String

    var isSystem: Bool { from == "system" }

    static func parse(_ input: String) -> SessionMessage? {
        let open = "<session-message "
        let close = "</session-message>"
        guard input.hasPrefix(open), input.hasSuffix(close),
              let headEnd = input.firstIndex(of: ">") else { return nil }
        let head = String(input[input.index(input.startIndex, offsetBy: open.count)..<headEnd])
        let body = input[input.index(after: headEnd)..<input.index(input.endIndex, offsetBy: -close.count)]
        return SessionMessage(
            from: attribute("from", in: head) ?? "",
            name: attribute("name", in: head) ?? "",
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&lt;/session-message", with: "</session-message"))
    }

    private static func attribute(_ key: String, in head: String) -> String? {
        guard let start = head.range(of: "\(key)=\"") else { return nil }
        let rest = head[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension EnvironmentValues {
    /// Show another session by id (a session message's sender).
    @Entry var openSessionID: ((String) -> Void)?
}

/// A delivered message: on the left like something said to you, not by you, with who sent it
/// and a link to their session.
struct SessionMessageCard: View {
    let message: SessionMessage
    @Environment(\.openSessionID) private var openSessionID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: message.isSystem ? "bell" : "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
                if message.isSystem {
                    Text("System notice").fontWeight(.semibold)
                } else if let openSessionID {
                    Button { openSessionID(message.from) } label: {
                        Text("From \(message.name.isEmpty ? message.from : message.name)")
                            .fontWeight(.semibold)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help("Open the session that sent this")
                } else {
                    Text("From \(message.name.isEmpty ? message.from : message.name)").fontWeight(.semibold)
                }
            }
            .font(.caption)
            Text(message.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, TurnSpace.Card.padding)
        .padding(.vertical, TurnSpace.Inset.card)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: TurnSpace.Card.radius))
        
        // As wide as your own prompt at most: it's a message, mirrored to the left.
        .frame(maxWidth: TurnSpace.promptWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
