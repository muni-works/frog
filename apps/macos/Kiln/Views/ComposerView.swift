import SwiftUI

struct ComposerView: View {
    let workspace: Workspace
    let conversation: Conversation
    @State private var text = ""
    @State private var height: CGFloat = 22

    private var canSend: Bool {
        !conversation.busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(conversation.busy ? "Working… press Esc to interrupt" : "Ask kiln to do something")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                ComposerTextView(
                    text: $text,
                    height: $height,
                    onSubmit: send,
                    onEscape: {
                        guard conversation.busy else { return false }
                        conversation.interrupt()
                        return true
                    }
                )
                .frame(height: height)
            }

            HStack(spacing: 10) {
                ModePicker(conversation: conversation)
                ModelPicker(workspace: workspace, conversation: conversation)
                Spacer()
                if let s = conversation.status {
                    ContextRing(status: s)
                }
                if conversation.busy {
                    Button {
                        conversation.interrupt()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Interrupt (Esc)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .disabled(!canSend)
                    .help("Send (Return)")
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: 860)
    }

    private func send() {
        guard canSend else { return }
        conversation.submit(text)
        text = ""
    }
}

struct ModePicker: View {
    let conversation: Conversation

    var body: some View {
        let mode = conversation.status?.mode ?? .default
        Menu {
            ForEach(Mode.allCases) { m in
                Button {
                    conversation.setMode(m)
                } label: {
                    Label(m.label, systemImage: m.symbol)
                }
            }
        } label: {
            Label(mode.label, systemImage: mode.symbol)
                .font(.callout)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .tint(mode == .yolo ? .orange : nil)
        .help("Permission mode")
    }
}

struct ModelPicker: View {
    let workspace: Workspace
    let conversation: Conversation

    var body: some View {
        Menu {
            ForEach(workspace.models) { m in
                Button {
                    workspace.preferredModel = m.spec
                    conversation.setModel(m.spec)
                } label: {
                    Text(m.spec)
                    Text(detail(m))
                }
            }
        } label: {
            Label(conversation.status?.model ?? "Model", systemImage: "cpu")
                .font(.callout)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help(conversation.status.map { "\($0.toolMode) tool calls · \($0.tier) tier" } ?? "Model")
    }

    private func detail(_ m: ModelEntry) -> String {
        var parts = ["\(m.toolMode) tools", "\(m.tier) tier"]
        if let b = m.caps?.paramsB { parts.insert(String(format: "%.1fB", b), at: 0) }
        if m.caps == nil, m.source == "ollama" { parts.append("not profiled yet") }
        return parts.joined(separator: " · ")
    }
}

struct ContextRing: View {
    let status: Status

    private var fraction: Double {
        guard let used = status.contextTokens, status.contextWindow > 0 else { return 0 }
        return min(1, Double(used) / Double(status.contextWindow))
    }

    private var color: Color {
        fraction > 0.8 ? .red : fraction > 0.6 ? .orange : .secondary
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .animation(.smooth, value: fraction)
        .help(helpText)
    }

    private var helpText: String {
        let window = status.contextWindow.tokens
        guard let used = status.contextTokens else { return "Context window: \(window) tokens" }
        return "\(used.tokens) of \(window) tokens (\(Int(fraction * 100))%)"
    }
}
