import SwiftUI

struct ItemView: View {
    let item: ItemState
    let conversation: Conversation
    /// False for an MCP App result that a later call in the turn superseded.
    var showsApp = true

    var body: some View {
        switch item.kind {
        case .message:
            MarkdownView(text: item.text, streaming: !item.done)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .reasoning:
            ReasoningView(text: item.text, done: item.done)
        case .tool("Diagram", _) where item.result?.diagram != nil:
            DiagramCard(diagram: item.result!.diagram!)
        case .tool("Diagram", let arg) where !item.done:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(arg.isEmpty ? "Drawing a diagram…" : "Drawing \(arg)…").font(.callout).foregroundStyle(.secondary)
            }
        case .tool("Present", _) where item.result?.present != nil:
            PresentCard(present: item.result!.present!, act: conversation.act)
        case .tool("Task", let arg):
            SubagentCard(arg: arg, item: item, conversation: conversation)
        case .tool(let name, _) where item.result?.app != nil && showsApp:
            McpAppCard(name: name, item: item, app: item.result!.app!, conversation: conversation)
        case .tool(let name, let arg) where !item.displayImages.isEmpty:
            VStack(alignment: .leading, spacing: 8) {
                ToolCallView(name: name, arg: arg, item: item, conversation: conversation)
                ToolImages(images: item.displayImages, preview: !item.done)
                if !item.done { Text("Approximate step preview").font(.caption).foregroundStyle(.secondary) }
            }
        case .tool(let name, let arg):
            ToolCallView(name: name, arg: arg, item: item, conversation: conversation)
        case .notice(let warning):
            NoticeView(text: item.text, warning: warning)
        }
    }
}

struct ReasoningView: View {
    let text: String
    let done: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .frame(width: 18)
                        .symbolEffect(.pulse, isActive: !done)
                    Text(done ? "Thought" : "Thinking…")
                        .fontWeight(.medium)
                    if !expanded {
                        Text(preview)
                            .lineLimit(1)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 26)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    /// The latest line while streaming (what it's thinking now), the first line once done.
    private var preview: String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (done ? lines.first : lines.last) ?? ""
    }
}

struct NoticeView: View {
    let text: String
    let warning: Bool

    var body: some View {
        Label(text, systemImage: warning ? "exclamationmark.triangle" : "info.circle")
            .font(.caption)
            .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 2)
    }
}

/// Compaction failed and the history can't fit the window (the engine's `compaction_failed`):
/// one line and a way out. The raw provider payload is in the engine log, never the
/// transcript. Styled like the degraded-mode badge: small, warm, lowercase.
struct OverflowRescueView: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
            Text("compaction failed")
                .fontWeight(.medium)
            Button {
                conversation.startCarriedForward()
            } label: {
                Text("start a carried-forward session")
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.orange.opacity(0.14), in: .capsule)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ToolCallView: View {
    @Environment(\.pinsQuestions) private var pinsQuestions
    let name: String
    let arg: String
    let item: ItemState
    let conversation: Conversation
    @State private var expanded = false

    private var result: Item.ToolResult? { item.result }
    private var failed: Bool { result.map { $0.outcome != .ok } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: ToolIcon.symbol(name))
                        .frame(width: 18)
                        .foregroundStyle(failed ? .red : .secondary)
                    Text(ToolIcon.title(name))
                        .fontWeight(.medium)
                        .font(.callout)
                    Text(arg)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    summary
                    status
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded || !item.done {
                ToolDetail(name: name, item: item, expanded: expanded)
            }

            if let why = item.autoReason {
                Label("Auto: \(why)", systemImage: "wand.and.sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 26)
                    .help("Auto mode's classifier let this run without asking")
            }
            if !pinsQuestions, item.needsPermission, let p = conversation.permission, p.item == item.id {
                PermissionCard(request: p, conversation: conversation)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.quaternary.opacity(expanded ? 0.3 : 0), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var summary: some View {
        if let r = result {
            switch r.outcome {
            case .denied: Text("Denied").font(.caption).foregroundStyle(.orange)
            case .skipped: Text("Skipped").font(.caption).foregroundStyle(.secondary)
            case .error: Text(r.display?.hasPrefix("refused") == true ? "Repeated call refused" : "Failed").font(.caption).foregroundStyle(.red)
            case .ok:
                if let d = r.diff {
                    HStack(spacing: 4) {
                        Text("+\(d.added)").foregroundStyle(.green)
                        Text("−\(d.removed)").foregroundStyle(.red)
                    }
                    .font(.caption.monospacedDigit())
                } else if let display = r.display, !display.contains("\n") {
                    Text(display).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if item.needsPermission {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        } else if !item.done {
            ProgressView().controlSize(.small)
        } else if result?.outcome == .ok {
            Image(systemName: "checkmark").foregroundStyle(.green).font(.caption.weight(.bold))
        }
    }
}

/// What a tool call did: its diff, report, or output once it's opened, and its progress or
/// live output while it runs. Shared by `ToolCallView` and the activity list's rows.
struct ToolDetail: View {
    let name: String
    let item: ItemState
    /// Opened: show the finished result.
    var expanded = true

    var body: some View {
        if expanded, let result = item.result {
            if let diff = result.diff {
                DiffView(diff: diff)
            } else if name == "Task", result.outcome == .ok {
                // A subagent's report reads like an answer.
                MarkdownView(text: result.display ?? result.output)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            } else {
                TerminalView(text: result.display ?? result.output)
            }
        } else if !item.done, let p = item.progress {
            VStack(alignment: .leading, spacing: 4) {
                if let total = p.total, total > 0 {
                    ProgressView(value: min(p.progress, total), total: total)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let m = p.message, !m.isEmpty {
                    Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, 26)
            .transition(.opacity)
        } else if !item.done, !item.output.isEmpty {
            // Live tail of a running command.
            TerminalView(text: String(item.output.suffix(6000)), live: true, maxHeight: 150)
                .transition(.opacity)
        }
    }
}

struct PermissionCard: View {
    let request: PermissionRequest
    let conversation: Conversation
    @State private var noting = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuestionBody(request: request)
            if let card = request.card { ApprovalDetails(card: card) }
            #if os(iOS)
            // For a thumb: two big answers side by side, the standing one as a line below.
            HStack(spacing: 10) {
                Button { conversation.answer(.deny) } label: { Text("Deny").frame(maxWidth: .infinity) }
                    .buttonStyle(.glass)
                Button { conversation.answer(.allow) } label: {
                    Text("Allow").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
            if !request.always.isEmpty {
                Button(alwaysLabel) { conversation.answer(.allowAlways) }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
            }
            #else
            if noting {
                HStack(spacing: 8) {
                    TextField("Tell the agent why, or what to do instead", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { conversation.answer(.deny, note: note) }
                    Button("Deny") { conversation.answer(.deny, note: note) }
                        .buttonStyle(.glass)
                        .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack(spacing: 8) {
                Button {
                    conversation.answer(.allow)
                } label: {
                    Text(request.card == nil ? "Allow" : "Allow once").frame(minWidth: 56)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Allow (⌘↩)")
                // Some requests (moving to a folder) are decided every time.
                if !request.always.isEmpty {
                    Button(alwaysLabel) { conversation.answer(request.card == nil ? .allowAlways : .allowPrefix) }
                        .buttonStyle(.glass)
                }
                Spacer()
                Button("Deny with note…") { noting = true }
                    .buttonStyle(.borderless)
                Button("Deny") { conversation.answer(.deny) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Deny (⌘.)")
            }
            #endif
        }
        .padding(14)
        .glassEffect(.regular.tint(.orange.opacity(0.10)), in: .rect(cornerRadius: 14))
    }


    private var alwaysLabel: String {
        request.always.prefix(1).uppercased() + request.always.dropFirst()
    }
}

/// A shell command's approval card: why the agent wants it, what made frog ask,
/// what it touches (size, and whether this session made it), the risk and advice.
struct ApprovalDetails: View {
    let card: ApprovalCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let why = card.agentReason {
                Label(why, systemImage: "text.bubble").lineLimit(3)
            }
            Label(card.trigger, systemImage: "exclamationmark.shield")
            ForEach(card.touches ?? [], id: \.path) { t in
                HStack(spacing: 6) {
                    Image(systemName: t.dir == true ? "folder" : "doc")
                    Text(t.path).lineLimit(1).truncationMode(.middle)
                    if let b = t.bytes {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    if t.createdHere == true {
                        Text("made by this session").foregroundStyle(.green)
                    } else if t.exists != true {
                        Text("doesn't exist").foregroundStyle(.secondary)
                    }
                }
            }
            Label(card.risk, systemImage: "bolt.trianglebadge.exclamationmark")
            Label(card.recommendation, systemImage: card.recommendation.hasPrefix("allow") ? "hand.thumbsup" : "hand.thumbsdown")
                .fontWeight(.medium)
        }
        .font(.callout)
        .foregroundStyle(.primary)
    }
}
