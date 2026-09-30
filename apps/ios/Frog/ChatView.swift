import SwiftUI

/// One conversation, like a Messages thread: your messages on the right, frog's work and answers
/// on the left, and frog's questions pinned above the keyboard until you answer them.
struct ChatView: View {
    let model: SessionModel
    let remote: Remote
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.turns) { turn in
                        TurnView(turn: turn, local: model.isLocal)
                    }
                    if model.busy, model.permission == nil {
                        TypingDots().padding(.leading, 4)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.turns.last?.entries.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.permission?.id) { proxy.scrollTo("end", anchor: .bottom) }
            .overlay {
                if model.loading, model.turns.isEmpty { ProgressView() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let p = model.permission {
                    PermissionCard(request: p) { model.answer($0) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    composer
                }
            }
            .animation(.spring(duration: 0.35), value: model.permission?.id)
        }
        .navigationTitle(model.session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(model.session.title).font(.headline).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(model.isLocal ? Color.imessageBlue : Color.imessageGreen).frame(width: 6, height: 6)
                        Text(Models.short(model.model)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onDisappear { remote.detach(model) }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !model.isOpenOnMac {
                Text("Open this conversation on your Mac to reply from here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message frog", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.background, in: .capsule)
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .disabled(!model.isOpenOnMac)
                if model.busy {
                    Button { model.interrupt() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 30))
                    }
                    .tint(.secondary)
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        model.submit(draft)
                        draft = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .tint(model.isLocal ? .imessageBlue : .imessageGreen)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isOpenOnMac)
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Turns

struct TurnView: View {
    let turn: SessionModel.Turn
    let local: Bool
    @State private var appeared = false
    @State private var showAll = false

    /// Pasted logs and long prompts start folded, so the thread stays readable.
    private var long: Bool { turn.input.count > 600 || turn.input.split(separator: "\n").count > 10 }

    private static func clip(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
        return String(lines.prefix(480)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !turn.input.isEmpty {
                HStack {
                    Spacer(minLength: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(long && !showAll ? Self.clip(turn.input) : turn.input)
                            .textSelection(.enabled)
                        if long {
                            Button(showAll ? "Show less" : "Show more") { showAll.toggle() }
                                .font(.footnote.weight(.semibold))
                                .buttonStyle(.plain)
                                .opacity(0.85)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(local ? Color.imessageBlue : Color.imessageGreen, in: .rect(cornerRadius: 18))
                }
                .scaleEffect(turn.sentHere && !appeared ? 0.6 : 1, anchor: .bottomTrailing)
                .opacity(turn.sentHere && !appeared ? 0 : 1)
                .onAppear { withAnimation(.spring(duration: 0.35, bounce: 0.3)) { appeared = true } }
            }
            ForEach(turn.entries) { e in
                EntryView(entry: e)
            }
            if case .error(let e)? = turn.end {
                Label(e.description, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            } else if let end = turn.end, let text = Self.stopped(end) {
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            if let u = turn.usage, turn.finished {
                Text(Self.usage(u))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static func stopped(_ end: EndReason) -> String? {
        switch end {
        case .cancelled: "Stopped"
        case .looping: "Stopped: frog kept repeating itself"
        case .stepLimit: "Stopped at the step limit"
        case .maxTokens: "Cut off at the length limit"
        case .denied: "Stopped: you said no"
        default: nil
        }
    }

    private static func usage(_ u: TurnUsage) -> String {
        var parts = ["\(u.modelCalls) step\(u.modelCalls == 1 ? "" : "s")"]
        if let t = u.tokensPerSec { parts.append(String(format: "%.0f tok/s", t)) }
        if let e = u.energy { parts.append(String(format: "%.2f Wh", e.totalWh)) }
        return parts.joined(separator: " · ")
    }
}

struct EntryView: View {
    let entry: SessionModel.Entry
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .message:
            if !entry.text.isEmpty {
                HStack {
                    MessageBody(text: entry.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
                    Spacer(minLength: 32)
                }
            }
        case .reasoning:
            if !entry.text.isEmpty {
                Button { expanded.toggle() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(entry.done ? "Thought" : "Thinking…", systemImage: "brain")
                            .font(.caption.weight(.medium))
                        if expanded {
                            Text(entry.text).font(.caption).multilineTextAlignment(.leading)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        case .notice:
            Label(entry.text, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .tool(let name, let arg):
            ToolRow(name: name, arg: arg, entry: entry, expanded: $expanded)
        }
    }
}

struct ToolRow: View {
    let name: String
    let arg: String
    let entry: SessionModel.Entry
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(name)).frame(width: 16)
                    Text(name).fontWeight(.medium)
                    Text(Self.short(arg)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    status
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: .capsule)
            }
            .buttonStyle(.plain)
            if expanded {
                if let diff = entry.result?.diff {
                    DiffPreview(diff: diff, limit: 60)
                } else {
                    let out = entry.result?.display ?? entry.result?.output ?? entry.output
                    if !out.isEmpty {
                        ScrollView(.horizontal) {
                            Text(String(out.prefix(4000)))
                                .font(.caption2.monospaced())
                                .padding(8)
                        }
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if entry.needsPermission {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        } else if !entry.done {
            ProgressView().controlSize(.mini)
        } else {
            switch entry.result?.outcome {
            case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .denied: Image(systemName: "hand.raised.slash").foregroundStyle(.secondary)
            case .skipped: Image(systemName: "forward.fill").foregroundStyle(.secondary)
            default:
                if let d = entry.result?.diff {
                    Text("+\(d.added) −\(d.removed)").foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                }
            }
        }
    }

    static func symbol(_ name: String) -> String {
        [
            "Bash": "terminal", "Read": "doc.text", "Write": "square.and.pencil", "Edit": "pencil",
            "Glob": "folder", "Grep": "magnifyingglass", "TodoWrite": "checklist", "Diagram": "flowchart",
            "CodeMap": "map", "Docs": "book", "WebFetch": "globe", "WebSearch": "globe", "Task": "person.2",
        ][name] ?? "wrench.and.screwdriver"
    }

    /// Paths shortened to the file name; commands to their first line.
    static func short(_ arg: String) -> String {
        let first = arg.split(separator: "\n").first.map(String.init) ?? arg
        return first.hasPrefix("/") ? (first as NSString).lastPathComponent : first
    }
}

// MARK: - Permission

/// Frog asking before it acts. Pinned above the keyboard, so it can't scroll away.
struct PermissionCard: View {
    let request: PermissionRequest
    let answer: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: ToolRow.symbol(request.name))
                .font(.headline)
            if let reason = request.reason, !reason.isEmpty {
                Text(reason).font(.subheadline).foregroundStyle(.secondary)
            }
            if let diff = request.preview {
                DiffPreview(diff: diff, limit: 14)
            } else if !request.arg.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(request.arg)
                        .font(.callout.monospaced())
                        .lineLimit(6)
                        .padding(10)
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                Button(role: .destructive) { answer(.deny) } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { answer(.allow) } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            if !request.always.isEmpty {
                Button { answer(.allowAlways) } label: {
                    Text("Always allow \(request.always)")
                        .font(.footnote)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .sensoryFeedback(.warning, trigger: request.id)
    }

    private var title: String {
        switch request.name {
        case "Bash": "Run this command?"
        case "Edit": "Edit \((request.arg as NSString).lastPathComponent)?"
        case "Write": "Write \((request.arg as NSString).lastPathComponent)?"
        default: "Use \(request.name)?"
        }
    }
}

struct DiffPreview: View {
    let diff: FileDiff
    let limit: Int

    var body: some View {
        let lines = diff.hunks.flatMap(\.lines)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((diff.path as NSString).lastPathComponent).font(.caption.weight(.medium))
                Spacer()
                Text("+\(diff.added)").foregroundStyle(.green)
                Text("−\(diff.removed)").foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit())
            .padding(.bottom, 4)
            ForEach(Array(lines.prefix(limit).enumerated()), id: \.offset) { _, l in
                Text(Self.mark(l) + l.text)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Self.tint(l))
            }
            if lines.count > limit {
                Text("\(lines.count - limit) more lines").font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    }

    private static func mark(_ l: DiffLine) -> String {
        switch l.kind {
        case .add: "+ "
        case .remove: "− "
        default: "  "
        }
    }

    private static func tint(_ l: DiffLine) -> Color {
        switch l.kind {
        case .add: .green.opacity(0.15)
        case .remove: .red.opacity(0.15)
        default: .clear
        }
    }
}

// MARK: - Text

/// Markdown, simply: fenced code as monospaced blocks, the rest with inline styling.
struct MessageBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.pieces(text).enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .prose(let s):
                    Text(Self.inline(s)).textSelection(.enabled)
                case .code(let s):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(s).font(.caption.monospaced()).padding(8)
                    }
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
                }
            }
        }
    }

    enum Piece { case prose(String), code(String) }

    static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var prose: [Substring] = [], code: [Substring] = []
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { out.append(.code(code.joined(separator: "\n"))); code = [] }
                else if !prose.isEmpty { out.append(.prose(prose.joined(separator: "\n"))); prose = [] }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode, !code.isEmpty { out.append(.code(code.joined(separator: "\n"))) }
        let rest = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(.prose(rest)) }
        return out.map { p in
            if case .prose(let s) = p { return .prose(s.trimmingCharacters(in: .newlines)) }
            return p
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.3)) { ctx in
            let step = Int(ctx.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().frame(width: 7, height: 7).opacity(i == step ? 0.9 : 0.35)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(.secondarySystemBackground), in: .capsule)
        }
    }
}
