import SwiftUI

/// The composer's parts that mean the same on every screen: when you can send, stop or queue,
/// what's waiting to go, how frog asks, and how full its context is.

/// Send while there's something to send (queued while a turn runs); stop while a turn runs and
/// the field is empty. A return key on the Mac, an arrow in a bubble for a thumb.
struct SendButton: View {
    let conversation: Conversation
    let canSend: Bool
    let send: () -> Void
    /// The bubble's color on a phone: where the model runs.
    var tint: Color = .accentColor

    var body: some View {
        if conversation.busy, !canSend {
            Button { conversation.interrupt() } label: {
                #if os(macOS)
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .hoverPlate(h: 3, v: 3)
                #else
                Image(systemName: "stop.fill").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                #endif
            }
            #if os(macOS)
            .buttonStyle(.plain)
            #else
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            #endif
            .help("Interrupt (Esc or ⌘.)")
            .accessibilityLabel("Stop")
        } else {
            Button(action: send) {
                #if os(macOS)
                Image(systemName: "return")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 22, height: 22)
                    .hoverPlate(h: 3, v: 3)
                #else
                Image(systemName: conversation.busy ? "text.append" : "arrow.up")
                    .font(.body.weight(.bold))
                    .frame(width: 30, height: 30)
                #endif
            }
            #if os(macOS)
            .buttonStyle(.plain)
            #else
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(tint)
            .opacity(canSend ? 1 : 0)
            #endif
            .disabled(!canSend)
            .help(conversation.busy ? "Queue (Return)" : "Send (Return)")
            .accessibilityLabel(conversation.busy ? "Queue" : "Send")
        }
    }
}

struct QueuedMessages: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(conversation.queue.map(\.text).enumerated()), id: \.offset) { i, text in
                HStack(spacing: 6) {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text(text).lineLimit(1)
                    Spacer()
                    Button("Remove", systemImage: "xmark.circle.fill") { conversation.unqueue(at: i) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 4)
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
            HStack(spacing: 4) {
                Text(mode.label)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(mode == .yolo ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .hoverPlate()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permission mode")
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
