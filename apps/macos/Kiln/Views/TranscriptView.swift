import SwiftUI

struct TranscriptView: View {
    let conversation: Conversation
    let actions: TurnActions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(conversation.turns) { turn in
                    TurnView(turn: turn, conversation: conversation, actions: actions)
                }
                // The running turn's work group shows progress once there's something to show.
                if conversation.busy, conversation.permission == nil,
                   conversation.replaying || (conversation.turns.last?.items.isEmpty ?? true) {
                    WorkingIndicator(label: conversation.replaying ? "Loading session…" : conversation.progress)
                }
                if let failure = conversation.failure {
                    Label(failure, systemImage: "exclamationmark.octagon")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        // Start at the bottom, and stay pinned there as streamed content grows.
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay {
            if conversation.turns.isEmpty, !conversation.busy, conversation.failure == nil {
                EmptyTranscript(conversation: conversation)
            }
        }
    }
}

struct UserPrompt: View {
    let text: String

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.tint.opacity(0.14), in: .rect(cornerRadius: 16))
            .frame(maxWidth: 560, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct EndView: View {
    let reason: EndReason
    let usage: TurnUsage?

    var body: some View {
        switch reason {
        case .complete, .denied:
            if let usage, usage.modelCalls > 0 {
                HStack(spacing: 10) {
                    Text("\(usage.modelCalls) call\(usage.modelCalls == 1 ? "" : "s")")
                    Text("\((usage.inputTokens + usage.outputTokens).tokens) tokens")
                    if let tps = usage.tokensPerSec {
                        Text("\(Int(tps)) tok/s")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        case .cancelled:
            banner("Interrupted", symbol: "stop.circle", color: .secondary)
        case .maxTokens:
            banner("Hit the output token limit", symbol: "text.append", color: .orange)
        case .looping:
            banner("Stopped: the model kept repeating the same tool call", symbol: "arrow.trianglehead.2.clockwise", color: .orange)
        case .stepLimit:
            banner("Stopped at the step limit. Say “continue” to keep going.", symbol: "flag.checkered", color: .orange)
        case .error(let e):
            banner(e.description, symbol: "exclamationmark.octagon", color: .red)
        }
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .textSelection(.enabled)
    }
}

struct WorkingIndicator: View {
    let label: String?

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Working…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .animation(.default, value: label)
    }
}

struct EmptyTranscript: View {
    let conversation: Conversation

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "flame")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.orange.gradient)
            Text(conversation.folder.lastPathComponent)
                .font(.title2.weight(.semibold))
            if let s = conversation.status {
                Text("\(s.model) · \(s.toolMode) tools · \(s.tier) tier")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Ask about the code, or describe a change.  Use @file to attach a file, !cmd to run a command.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}
