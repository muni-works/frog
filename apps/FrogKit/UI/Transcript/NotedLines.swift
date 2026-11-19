import SwiftUI

/// A note Frog kept this turn, under the reply (docs/customize-events.md, "Noted"; canvas M2): a
/// green ring, "Noted for pond", the note, then Undo and Make it a rule as quiet underlined links.
/// Undo answered, the links give way to how it went. Same as the web's `NotedLine`.
struct NotedLineView: View {
    let noted: NotedState
    let conversation: Conversation

    static func lead(_ noted: NotedState) -> String {
        "\(noted.undone?.ok == true ? "Forgot for" : "Noted for") \(noted.note.place)"
    }

    var body: some View {
        let size = Tokens.Transcript.status.size
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle().strokeBorder(Tokens.accent, lineWidth: 1.5).frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(Self.lead(noted)).foregroundStyle(Tokens.textTertiary).fixedSize()
            Text(noted.note.text)
                .foregroundStyle(noted.undone?.ok == true ? Tokens.textTertiary : Tokens.text)
                .strikethrough(noted.undone?.ok == true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let undone = noted.undone {
                if !undone.ok {
                    Text(undone.message ?? "Couldn't undo").foregroundStyle(Tokens.warn).fixedSize()
                }
            } else {
                link("Undo", id: "noted.undo") { conversation.undo(noted.note.undo) }
                link("Make it a rule", id: "noted.rule") { conversation.noteToRule(noted.note) }
            }
        }
        .font(.frog(size: size))
        .lineSpacing(18 - size)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func link(_ title: String, id: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title).underline(color: Tokens.lineStrong).foregroundStyle(Tokens.textSecondary)
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityIdentifier(id)
    }
}

/// The notes that came back for a turn ("Used notes"; canvas M2): a filled ring and "Used 2 notes"
/// on a rule at the left, then each line.
struct UsedNotesView: View {
    let notes: [UsedNote]

    static func head(_ n: Int) -> String { "Used \(n) \(n == 1 ? "note" : "notes")" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Circle().fill(Tokens.accent).frame(width: 8, height: 8)
                Text(Self.head(notes.count)).foregroundStyle(Tokens.textTertiary)
            }
            .padding(.leading, -22)
            ForEach(notes, id: \.id) { note in
                Text(note.text).foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.frog(size: Tokens.Transcript.status.size))
        .padding(.leading, 18)
        .overlay(alignment: .leading) { Rectangle().fill(Tokens.line).frame(width: 1) }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
