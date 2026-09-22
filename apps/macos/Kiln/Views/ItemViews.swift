import SwiftUI

struct ItemView: View {
    let item: ItemState
    let conversation: Conversation

    var body: some View {
        switch item.kind {
        case .message:
            MarkdownView(text: item.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .reasoning:
            ReasoningView(text: item.text, done: item.done)
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
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .symbolEffect(.pulse, isActive: !done)
                Text(done ? "Thought" : "Thinking…")
                if !expanded, let first = text.split(separator: "\n").first {
                    Text(first)
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
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

enum ToolIcon {
    static func symbol(_ name: String) -> String {
        switch name {
        case "Bash", "!": "terminal"
        case "Read": "doc.text"
        case "Write": "doc.badge.plus"
        case "Edit": "pencil.line"
        case "Glob": "folder.badge.questionmark"
        case "Grep": "text.magnifyingglass"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }
}

struct ToolCallView: View {
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
                    Text(name == "!" ? "Shell" : name)
                        .fontWeight(.medium)
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

            if expanded, let result {
                if let diff = result.diff {
                    DiffView(diff: diff)
                } else {
                    OutputView(text: result.display ?? result.output, failed: failed)
                }
            } else if !expanded, let diff = result?.diff, result?.outcome == .ok {
                DiffView(diff: diff, maxLines: 12)
            }

            if item.needsPermission, let p = conversation.permission, p.item == item.id {
                PermissionCard(request: p, conversation: conversation)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(expanded ? 0.3 : 0), in: .rect(cornerRadius: 10))
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

struct OutputView: View {
    let text: String
    let failed: Bool

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "(no output)" : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 280)
        .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
    }
}

struct DiffView: View {
    let diff: FileDiff
    var maxLines: Int = .max

    private var lines: [(hunk: Int, line: DiffLine)] {
        diff.hunks.enumerated().flatMap { h, hunk in hunk.lines.map { (h, $0) } }
    }

    var body: some View {
        let all = lines
        let shown = all.prefix(maxLines)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: diff.created ? "doc.badge.plus" : "doc")
                Text(diff.path).font(.caption.weight(.medium))
                Spacer()
                Text("+\(diff.added)").foregroundStyle(.green)
                Text("−\(diff.removed)").foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, entry in
                        if i > 0, shown[shown.startIndex + i - 1].hunk != entry.hunk {
                            Text("⋯").font(.caption).foregroundStyle(.tertiary).padding(.leading, 60).padding(.vertical, 2)
                        }
                        DiffLineView(line: entry.line)
                    }
                    if all.count > shown.count {
                        Text("\(all.count - shown.count) more lines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 0.5))
    }
}

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(line.old.map(String.init) ?? "")
                .frame(width: 32, alignment: .trailing)
            Text(line.new.map(String.init) ?? "")
                .frame(width: 32, alignment: .trailing)
            Text(sign)
                .frame(width: 20)
                .foregroundStyle(tint)
            Text(line.text)
                .foregroundStyle(.primary)
                .fixedSize()
                .padding(.trailing, 12)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(line.kind == .context ? 0 : 0.12))
    }

    private var sign: String {
        switch line.kind {
        case .add: "+"
        case .remove: "−"
        case .context: ""
        }
    }

    private var tint: Color {
        switch line.kind {
        case .add: .green
        case .remove: .red
        case .context: .clear
        }
    }
}

struct PermissionCard: View {
    let request: PermissionRequest
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Allow \(request.name)?").fontWeight(.semibold)
            }
            Text(request.arg)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(6)
            HStack(spacing: 8) {
                Button("Allow") { conversation.answer(.allow) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                Button(alwaysLabel) { conversation.answer(.allowAlways) }
                    .buttonStyle(.glass)
                Spacer()
                Button("Deny") { conversation.answer(.deny) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .rect(cornerRadius: 14))
    }

    private var alwaysLabel: String {
        request.always.prefix(1).uppercased() + request.always.dropFirst()
    }
}
