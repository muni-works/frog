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
                    .font(.frog(size: 17))
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
                // A green circle with an up arrow, as on the web.
                Image(systemName: "arrow.up")
                    .font(.frog(size: 12, weight: .bold))
                    .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(Tokens.textTertiary))
                    .frame(width: 26, height: 26)
                    .background(canSend ? AnyShapeStyle(Tokens.accent) : AnyShapeStyle(Tokens.hover), in: .circle)
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

/// What's queued to send: one small-caps QUEUED · n label, then one quiet raised row per
/// message — the text on a line with an ✕ that takes it back to edit, and its images as small
/// chips (a queued image must be visible, not just counted). `streaming`: the row says when
/// they go in — at the next tool step of the running turn — instead of "when the turn ends".
struct QueuedMessages: View {
    let conversation: Conversation
    var streaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: TurnSpace.Inset.tight) {
            HStack(alignment: .firstTextBaseline, spacing: TurnSpace.Inset.row) {
                Text("QUEUED · \(conversation.queue.count)")
                    .font(.frog(size: Tokens.Size.label, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Tokens.textSecondary)
                if streaming {
                    Circle().fill(Tokens.accent).frame(width: 6, height: 6)
                        .help("The turn is working; the queued messages go in at its next tool step")
                    Text("goes in at the next tool step")
                        .font(.frog(size: Tokens.Size.label))
                        .foregroundStyle(Tokens.textTertiary)
                } else {
                    Text("sends when the turn ends")
                        .font(.frog(size: Tokens.Size.label))
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            ForEach(Array(conversation.queue.enumerated()), id: \.offset) { i, queued in
                HStack(alignment: .center, spacing: TurnSpace.Inset.snug) {
                    Image(systemName: "paperclip")
                        .font(.frog(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.textSecondary)
                        .help("Queued message")
                    Text(queued.text.isEmpty ? "\(queued.images.count) image\(queued.images.count == 1 ? "" : "s")" : queued.text)
                        .font(.frog(size: Tokens.Size.secondary))
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !queued.images.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(queued.images.prefix(3).enumerated()), id: \.offset) { _, img in
                                if let image = img.image {
                                    Image(platformImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 22, height: 22)
                                        .clipShape(.rect(cornerRadius: 6, style: .continuous))
                                }
                            }
                        }
                    }
                    Spacer(minLength: TurnSpace.Inset.row)
                    Button("Back to the Field", systemImage: "xmark") { conversation.unqueue(at: i) }
                        .help("Take it out of the queue and back into the field to edit")
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .font(.frog(size: Tokens.Size.label, weight: .semibold))
                        .foregroundStyle(Tokens.textTertiary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Tokens.raised, in: .rect(cornerRadius: 8, style: .continuous))
            }
        }
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
                Image(systemName: "chevron.down").font(.frog(size: 9, weight: .semibold))
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

/// Images waiting to be sent: thumbnails with a remove button, and a note when the model can't
/// see them.
struct AttachmentStrip: View {
    @Binding var images: [ToolImage]
    /// The model's name, when it can't see images.
    let blind: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                        if let image = img.image {
                            Image(platformImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                                .opensInLightbox(images, at: i)
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        images.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 5, y: -5)
                                    .help("Remove")
                                    .accessibilityLabel("Remove image")
                                }
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
            }
            .scrollIndicators(.never)
            if let blind {
                Label("\(blind) can't see images; pick a vision model (like gemma3 or qwen2.5vl) to include them.", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
