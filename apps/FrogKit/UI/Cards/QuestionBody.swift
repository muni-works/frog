import SwiftUI

/// What frog is asking, shown the same wherever it's asked: in the transcript's card, pinned
/// above the phone's keyboard, and in a notification's long-press. The icon, the question,
/// why (when it leaves the sandbox), and the change or command itself.
struct QuestionBody: View {
    let request: PermissionRequest
    var maxLines = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: request.name == "UseFolder" ? "folder.fill" : request.reason == nil ? "hand.raised.fill" : "lock.open.fill")
                    .foregroundStyle(.orange)
                Text(request.question).fontWeight(.semibold)
                Spacer()
            }
            if let reason = request.reason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let diff = request.preview {
                DiffView(diff: diff, maxLines: maxLines)
            } else if !request.arg.isEmpty {
                Text(request.arg)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.3), in: .rect(cornerRadius: 8))
            }
        }
    }
}
