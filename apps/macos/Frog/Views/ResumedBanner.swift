import SwiftUI

/// "Resumed after restart": shown on a conversation whose interrupted turn frog picked back up
/// at launch, with a way to stop it and to opt this conversation out of doing that again.
struct ResumedBanner: View {
    let conversation: Conversation
    @State private var autoContinue = true
    @Environment(\.paneWidth) private var paneWidth

    var body: some View {
        if conversation.resumedAfterRestart, let id = conversation.sessionID {
            HStack(spacing: 8) {
                Image(systemName: conversation.suspendedByUpdate ? "arrow.down.circle" : "arrow.clockwise.circle")
                // Gives way in a narrow split pane: a line that couldn't shrink widened the whole
                // pane past its frame, pushing its rail into the next pane and text over text.
                if paneWidth > .narrow {
                    Text(conversation.suspendedByUpdate ? "Resumed after app update" : "Resumed after restart")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Toggle(paneWidth == .wide ? "Resume automatically" : "Auto", isOn: $autoContinue)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Pick this conversation's running turn back up after Frog restarts")
                .onChange(of: autoContinue) { _, on in SessionRegistry.shared.setAutoContinue(id, on) }
                if conversation.busy {
                    Button("Stop") { conversation.interrupt() }
                        .buttonStyle(.link)
                }
                Button {
                    conversation.resumedAfterRestart = false
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Dismiss")
            }
            .font(.frog(size: 12))
            .foregroundStyle(.secondary)
            // On the transcript's column, a line on its edge like the tool rows (see
            // `TurnSpace`): a plate of its own would read as a card for nothing wrong.
            .padding(.horizontal, TurnSpace.Inset.snug)
            .padding(.vertical, TurnSpace.Inset.snug)
            .turnColumn()
            .onAppear { autoContinue = SessionRegistry.shared.autoContinues(id) }
        }
    }
}
