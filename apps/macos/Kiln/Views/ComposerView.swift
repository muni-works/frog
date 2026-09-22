import SwiftUI

struct ComposerView: View {
    let workspace: Workspace
    let conversation: Conversation
    @State private var text = ""
    @State private var height: CGFloat = 22
    @State private var controller = ComposerController()
    @State private var mention: String?
    @State private var picked = 0
    @State private var racing = false

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var suggestions: [String] {
        guard let mention else { return [] }
        return FileIndex.search(workspace.files, mention)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let toast = conversation.toast {
                Label(toast, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !conversation.queue.isEmpty {
                QueuedMessages(conversation: conversation)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(conversation.busy ? "Working… Esc interrupts · Return queues a follow-up" : "Ask kiln to do something · @ to mention a file")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                ComposerTextView(
                    text: $text,
                    height: $height,
                    controller: controller,
                    onSubmit: send,
                    onEscape: {
                        guard conversation.busy else { return false }
                        conversation.interrupt()
                        return true
                    },
                    onMention: { query in
                        if query != nil { workspace.loadFiles() }
                        if query != mention { picked = 0 }
                        mention = query
                    },
                    onMentionKey: handleMentionKey
                )
                .frame(height: height)
            }
            .overlay(alignment: .topLeading) {
                if !suggestions.isEmpty {
                    MentionList(files: suggestions, picked: picked) { controller.insertMention($0) }
                        .alignmentGuide(.top) { $0[.bottom] + 14 }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            HStack(spacing: 10) {
                ModePicker(conversation: conversation)
                ModelPicker(workspace: workspace, conversation: conversation)
                Spacer()
                if let e = workspace.raceError {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(e)
                }
                if let s = conversation.status {
                    ContextRing(status: s)
                }
                Button {
                    racing = true
                } label: {
                    Image(systemName: "square.stack.3d.up")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(!canSend || conversation.busy)
                .accessibilityLabel("Race")
                .help("Race: run this prompt as several parallel attempts")
                .popover(isPresented: $racing, arrowEdge: .top) {
                    RaceSetup(workspace: workspace, prompt: text) { models, check in
                        racing = false
                        workspace.startRace(prompt: text, models: models, check: check)
                        text = ""
                    }
                }
                if conversation.busy, !canSend {
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
                    .help(conversation.busy ? "Queue (Return)" : "Send (Return)")
                }
            }
        }
        .padding(12)
        .animation(.snappy, value: conversation.toast)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: 860)
    }

    private func send() {
        guard canSend else { return }
        conversation.submit(text)
        text = ""
        mention = nil
    }

    private func handleMentionKey(_ key: MentionKey) -> Bool {
        let list = suggestions
        guard !list.isEmpty else { return false }
        switch key {
        case .up: picked = (picked - 1 + list.count) % list.count
        case .down: picked = (picked + 1) % list.count
        case .accept: controller.insertMention(list[min(picked, list.count - 1)])
        case .cancel: mention = nil
        }
        return true
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

struct MentionList: View {
    let files: [String]
    let picked: Int
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.element) { i, path in
                Button {
                    choose(path)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text((path as NSString).lastPathComponent).fontWeight(.medium)
                        let dir = (path as NSString).deletingLastPathComponent
                        Text(dir).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(i == picked ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 420, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}

struct QueuedMessages: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(conversation.queue.enumerated()), id: \.offset) { i, text in
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
