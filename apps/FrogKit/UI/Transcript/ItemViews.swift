import SwiftUI

struct ItemView: View {
    let item: ItemState
    let conversation: Conversation
    /// False for an MCP App result that a later call in the turn superseded.
    var showsApp = true
    /// The answer still being written, shown as a typing bubble (see `TypingBubble`).
    var typing = false

    var body: some View {
        #if DEBUG
        let _ = TranscriptProbe.row()
        #endif
        switch item.kind {
        case .message:
            // One view for a message from first word to history, so the handoff from the
            // typing bubble to the plain row is a fade inside it, not a swap of two (a swap
            // would rebuild the text view and replay the ink).
            TypingBubble(text: item.streamedText, conversation: conversation, writing: typing && !item.done)
        case .reasoning:
            ReasoningView(text: item.text, done: item.done)
        case .tool("Diagram", _) where item.result?.diagram != nil:
            DiagramCard(diagram: item.result!.diagram!)
        case .tool("Diagram", let arg) where !item.done:
            HStack(spacing: TurnSpace.Inset.row) {
                ProgressView().controlSize(.small)
                Text(arg.isEmpty ? "Drawing a diagram…" : "Drawing \(arg)…").font(.callout).foregroundStyle(.secondary)
            }
        case .tool("Visualize", _) where item.result?.widget != nil && item.result?.outcome == .ok:
            WidgetCard(widget: item.result!.widget!, conversation: conversation)
        case .tool("Visualize", let arg) where !item.done:
            HStack(spacing: TurnSpace.Inset.row) {
                ProgressView().controlSize(.small)
                Text(arg.isEmpty ? "Making a visual…" : "Making \(VisualWidget(title: arg, code: "", html: "").displayTitle)…").font(.callout).foregroundStyle(.secondary)
            }
        case .tool("Present", _) where item.result?.present != nil:
            PresentCard(present: item.result!.present!, act: conversation.act)
        case .tool("Task", let arg):
            AgentStepRow(arg: arg, item: item, conversation: conversation)
        case .tool(let name, _) where item.result?.app != nil && showsApp:
            McpAppCard(name: name, item: item, app: item.result!.app!, conversation: conversation)
        case .tool(let name, let arg) where !item.displayImages.isEmpty:
            VStack(alignment: .leading, spacing: TurnSpace.Inset.row) {
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
        VStack(alignment: .leading, spacing: TurnSpace.Inset.snug) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: TurnSpace.Inset.row) {
                    // One quiet line: a breathing dot while it thinks.
                    BreathingDot(live: !done)
                        .opacity(done ? 0 : 1)
                        .frame(width: TurnSpace.Inset.icon)
                    Text(done ? "Thought" : "Thinking…")
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
                .foregroundStyle(Tokens.textTertiary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                CappedThought(text: text)
                    .padding(.leading, TurnSpace.Inset.iconColumn)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, TurnSpace.Inset.tight)
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

    /// Collapsed to its first line, like the other system rows; a longer one expands.
    var body: some View {
        EventLineView(event: EventLine(notice: text, warning: warning))
            .padding(.vertical, TurnSpace.Inset.hair)
    }
}

/// Compaction failed and the history can't fit the window (the engine's `compaction_failed`):
/// one line and a way out. The raw provider payload is in the engine log, never the
/// transcript. Styled like the degraded-mode badge: small, warm, lowercase.
struct OverflowRescueView: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: TurnSpace.Inset.row) {
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
        .padding(.horizontal, TurnSpace.Inset.snug)
        .padding(.vertical, TurnSpace.Inset.tight)
        .background(.orange.opacity(0.14), in: .capsule)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// A successful compaction, at the transcript's top: "carried forward · everything important
/// was saved", with what was kept one expander away — the receipt (files with +/−, turns
/// with their requests and outcomes, tests run and whether each passed). Replayed sessions
/// keep it; ones compacted before the receipt existed show nothing.
struct CarriedForwardBanner: View {
    let kept: KeptSummary
    /// Tests open the receipt without clicking (an injected initial state).
    var opened: Bool? = nil
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isOpen = opened ?? open
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.forward").imageScale(.small)
                Text("carried forward · everything important was saved")
                    .fontWeight(.medium)
                Spacer(minLength: 0)
                Button {
                    withAnimation(Motion.quick(reduced: reduceMotion)) { open.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("what was kept")
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
            if isOpen {
                KeptSummaryReceipt(kept: kept)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .font(.caption)
        .foregroundStyle(.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.green.opacity(0.10), in: .rect(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The receipt itself: files with +/−, turns with requests and outcomes, tests with pass/fail.
struct KeptSummaryReceipt: View {
    let kept: KeptSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !kept.files.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Files")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(kept.files, id: \.path) { f in
                        HStack(spacing: 6) {
                            Text((f.path as NSString).lastPathComponent)
                            Text("+\(f.added)").foregroundStyle(.green)
                            Text("−\(f.removed)").foregroundStyle(.red)
                            Spacer(minLength: 0)
                        }
                        .monospacedDigit()
                    }
                }
            }
            if !kept.turns.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Turns")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(kept.turns.enumerated()), id: \.offset) { i, t in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text("\(i + 1).").foregroundStyle(.tertiary)
                                Text(t.request).lineLimit(1)
                                if !t.outcome.isEmpty && t.outcome != "complete" {
                                    Text("(\(t.outcome))").foregroundStyle(.secondary)
                                }
                            }
                            if !t.tests.isEmpty {
                                ForEach(Array(t.tests.enumerated()), id: \.offset) { _, test in
                                    HStack(spacing: 5) {
                                        Image(systemName: test.passed ? "checkmark.circle" : "xmark.circle")
                                            .foregroundStyle(test.passed ? .green : .red)
                                        Text(test.command).lineLimit(1).truncationMode(.middle)
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10, style: .continuous))
        .textSelection(.enabled)
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
    /// The row's words: the gist when the engine's side-model sent one, else the argument
    /// (a shell command elided against the session root, so a worktree path can't eat the
    /// line). The argument stays the truth; the gist only reads better.
    private var isShell: Bool { name == "Bash" || name == "!" }
    private var root: String { conversation.folder.path }
    private var elided: String { CommandElision.elide(arg, from: root) }
    private var gist: String? { item.gist }

    var body: some View {
        VStack(alignment: .leading, spacing: TurnSpace.Inset.row) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: TurnSpace.Inset.row) {
                    Image(systemName: ToolIcon.symbol(name))
                        .frame(width: TurnSpace.Inset.icon)
                        .foregroundStyle(failed ? .red : .secondary)
                    Text(ToolIcon.title(name))
                        .fontWeight(.medium)
                        .font(.callout)
                    if let gist {
                        // The gist reads like a sentence: plain, not monospaced.
                        Text(gist)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(isShell ? elided : arg)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
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
                ToolDetail(name: name, item: item, expanded: expanded, root: root)
            }

            if let why = item.autoReason {
                Label("Auto: \(why)", systemImage: "wand.and.sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, TurnSpace.Inset.iconColumn)
                    .help("Auto mode's classifier let this run without asking")
            }
            if !pinsQuestions, item.needsPermission, let p = conversation.permission, p.item == item.id {
                PermissionCard(request: p, conversation: conversation)
            }
        }
        .padding(.vertical, TurnSpace.Inset.tight)
        // Open, it sits on a plate that bleeds into the gutter: the icon stays on the column's edge.
        .linePlate(expanded ? 0.3 : 0)
    }

    @ViewBuilder
    private var summary: some View {
        if let r = result {
            switch r.outcome {
            case .denied: Text("Denied").font(.caption).foregroundStyle(.orange)
            case .skipped: Text("Skipped").font(.caption).foregroundStyle(.secondary)
            case .error: Text(ToolResultWords.errorLabel(r.display)).font(.caption).foregroundStyle(.red)
            case .ok:
                if let d = r.diff {
                    HStack(spacing: TurnSpace.Inset.tight) {
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
    /// The session root, for eliding paths in a shell row's command block.
    var root = "/"

    var body: some View {
        if expanded, let result = item.result {
            if let diff = result.diff {
                DiffView(diff: diff)
            } else if name == "Task", result.outcome == .ok {
                // A subagent's report reads like an answer.
                MarkdownView(text: result.display ?? result.output)
                    .padding(TurnSpace.Inset.card)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: TurnSpace.Card.nestedRadius))
            } else if name == "Bash" || name == "!" {
                CommandDetail(command: item.arg, output: result.display ?? result.output,
                              outcome: result.outcome, root: root)
            } else {
                TerminalView(text: result.display ?? result.output)
            }
        } else if !item.done, let p = item.progress {
            VStack(alignment: .leading, spacing: TurnSpace.Inset.tight) {
                if let total = p.total, total > 0 {
                    ProgressView(value: min(p.progress, total), total: total)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let m = p.message, !m.isEmpty {
                    Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, TurnSpace.Inset.iconColumn)
            .transition(.opacity)
        } else if !item.done, !item.output.isEmpty {
            // Live tail of a running command.
            TerminalView(text: String(item.output.suffix(6000)), live: true, maxHeight: 150)
                .transition(.opacity)
        }
    }
}

/// A shell command opened: the full command in a monospace block with paths elided
/// root-relative ("cd worktrees/foo"), and its output styled like `DiffView` (the same
/// chrome), collapsed past `collapsedLines` with the same "N more lines" treatment.
struct CommandDetail: View {
    let command: String
    let output: String
    var outcome: ToolOutcome = .ok
    var root = "/"
    /// How many output lines show before the fold. DiffView's default cut for a long diff.
    @State private var showingAll = false

    private static let collapsedLines = 24

    private var lines: [String] {
        output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The command, verbatim but with paths elided against the session root.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CommandElision.elide(command, from: root))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, TurnSpace.Inset.card)
                    .padding(.vertical, TurnSpace.Inset.snug)
            }
            if !output.isEmpty {
                Divider().opacity(0.5)
                outputBlock
            }
        }
        .background(.background.opacity(0.6))
        .clipShape(.rect(cornerRadius: TurnSpace.Card.nestedRadius))
        
    }

    @ViewBuilder
    private var outputBlock: some View {
        let all = lines
        let shown = showingAll ? all : Array(all.prefix(Self.collapsedLines))
        VStack(alignment: .leading, spacing: 0) {
            // The output, ANSI-styled like any terminal, without its own chrome: this
            // block's frame is the chrome.
            ScrollView {
                Text(ANSI.attributed(output.isEmpty ? "(no output)" : shown.joined(separator: "\n")))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(TurnSpace.Inset.card)
            }
            .frame(maxHeight: 280)
            if all.count > shown.count {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showingAll.toggle() }
                } label: {
                    Text(showingAll ? "Collapse" : "\(all.count - shown.count) more lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.vertical, TurnSpace.Inset.tight)
            }
        }
    }
}

struct PermissionCard: View {
    let request: PermissionRequest
    let conversation: Conversation
    @State private var noting = false
    @State private var note = ""

    var body: some View {
        #if os(macOS)
        macCard
        #else
        iosCard
        #endif
    }

    private var iosCard: some View {
        VStack(alignment: .leading, spacing: TurnSpace.Inset.card) {
            QuestionBody(request: request)
            if let card = request.card { ApprovalDetails(card: card) }
            #if os(iOS)
            // For a thumb: two big answers side by side, the standing one as a line below.
            HStack(spacing: TurnSpace.Inset.card) {
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
            EmptyView()
            #endif
        }
        #if os(iOS)
        .padding(TurnSpace.Card.padding)
        .glassEffect(.regular.tint(.orange.opacity(0.10)), in: .rect(cornerRadius: TurnSpace.Card.radius))
        #endif
    }

    #if os(macOS)
    /// One look with the web: the title, the command in a well, where it runs, then the answers.
    /// Allow is the green primary (⌘↩), Deny keeps ⌘., the rest are secondary.
    private var macCard: some View {
        // One inset (16) all round, one rhythm (12) between parts, the command in a rounded
        // well inside the margins, the answers on the last line.
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.question)
                    .font(.frog(size: Tokens.Size.body, weight: .semibold))
                if let reason = request.reason {
                    Text(reason).font(.frog(size: Tokens.Size.secondary)).foregroundStyle(Tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let diff = request.preview {
                DiffView(diff: diff, maxLines: 40)
                    .clipShape(.rect(cornerRadius: 8))
            } else if !request.arg.isEmpty {
                Text(request.arg)
                    .font(.frog(size: Tokens.Size.secondary, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.well, in: .rect(cornerRadius: 8))
            }
            if let card = request.card { ApprovalDetails(card: card) }
            if noting {
                HStack(spacing: 8) {
                    TextField("Tell the agent why, or what to do instead", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { conversation.answer(.deny, note: note) }
                    Button("Deny") { conversation.answer(.deny, note: note) }
                        .buttonStyle(CardButtonStyle())
                        .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            // Two answers, as a Mac alert has: Deny and the default, Allow. The rest of the
            // choices wait behind ⋯; the shortcuts work without being printed on the buttons.
            HStack(spacing: 8) {
                Menu {
                    // Some requests (moving to a folder) are decided every time.
                    if !request.always.isEmpty {
                        Button(alwaysLabel) { conversation.answer(request.card == nil ? .allowAlways : .allowPrefix) }
                    }
                    Button("Deny with a Note…") { noting = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.frog(size: Tokens.Size.secondary, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Tokens.hover, in: .circle)
                        .contentShape(.circle)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(Tokens.textSecondary)
                .help("More choices")
                Text("Runs on this Mac · sandboxed")
                    .font(.frog(size: Tokens.Size.meta))
                    .foregroundStyle(Tokens.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button("Deny") { conversation.answer(.deny) }
                    .buttonStyle(CardButtonStyle())
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Deny (⌘.)")
                Button(request.card == nil ? "Allow" : "Allow Once") { conversation.answer(.allow) }
                    .buttonStyle(CardButtonStyle(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Allow (⌘↩)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.raised, in: .rect(cornerRadius: Tokens.Radius.card))
        .clipShape(.rect(cornerRadius: Tokens.Radius.card))
    }
    #endif

    private var alwaysLabel: String {
        request.always.prefix(1).uppercased() + request.always.dropFirst()
    }
}

/// The ask card's buttons, as on the web: secondary on the hover fill, the primary green.
struct CardButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.frog(size: Tokens.Size.secondary, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? Color.black : Tokens.text)
            .padding(.horizontal, 14)
            .frame(minWidth: 72)
            .frame(height: 28)
            .background(primary ? Tokens.accent : Tokens.hover, in: .capsule)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(.capsule)
    }
}

/// A shell command's approval card: why the agent wants it, what made frog ask,
/// what it touches (size, and whether this session made it), the risk and advice.
struct ApprovalDetails: View {
    let card: ApprovalCard

    var body: some View {
        VStack(alignment: .leading, spacing: TurnSpace.Inset.tight) {
            if let why = card.agentReason {
                Label(why, systemImage: "text.bubble").lineLimit(3)
            }
            Label(card.trigger, systemImage: "exclamationmark.shield")
            ForEach(card.touches ?? [], id: \.path) { t in
                HStack(spacing: TurnSpace.Inset.snug) {
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

/// The answer as it writes itself, in a quiet bubble while it streams: the words arriving
/// inside and the model's speed at its edge (no frog: the mascot is retired from the live flow
/// and keeps the empty page). The status line ("Thinking… 4s") stays for the work before and
/// between answers; this is for the answer.
///
/// This is the message row's only view, from the first word to history: at the handoff the
/// words are already in place, and the bubble's chrome and insets ease out to the plain row in
/// one animated settle — no swap, so the text view (and its ink) is never rebuilt.
struct TypingBubble: View {
    let text: String
    let conversation: Conversation
    /// Still streaming: the bubble shows; settling fades it out.
    var writing: Bool
    @State private var settled = false

    var body: some View {
        let live = writing && !settled
        // No gap beside a collapsed speed readout: a finished answer lines up with the
        // activity lines.
        HStack(alignment: .top, spacing: live ? TurnSpace.Inset.row : 0) {
            MarkdownView(text: text, streaming: live)
                .frame(maxWidth: .infinity, alignment: .leading)
            speed
                .opacity(live ? 1 : 0)
                .frame(width: live ? nil : 0, alignment: .trailing)
        }
        .padding(.vertical, live ? TurnSpace.Card.padding : 0)
        .padding(.leading, live ? TurnSpace.Inset.roomy : 0)
        .padding(.trailing, live ? TurnSpace.Inset.roomy : 0)
        .background(.quaternary.opacity(live ? 0.45 : 0), in: .rect(cornerRadius: 14))
        .animation(.easeOut(duration: 0.25), value: settled)
        .animation(.easeOut(duration: 0.25), value: writing)
        .onAppear { settled = !writing }
        .onChange(of: writing) { _, w in
            if !w { settled = true }
        }
        .accessibilityHidden(!live)
        .accessibilityLabel("Frog is writing")
    }

    /// The model's speed, at the bubble's edge, from the engine's status.
    @ViewBuilder
    private var speed: some View {
        if let s = conversation.status?.tokensPerSec, s > 0 {
            Text(ModelStats.speedText(s))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }
}

/// What a failed tool call's badge says. "refused: repeated identical call" is the loop guard;
/// "no folder: …" a chat with no folder asked for a file or shell tool; anything else failed.
enum ToolResultWords {
    static func errorLabel(_ display: String?) -> String {
        guard let display else { return "Failed" }
        if display.hasPrefix("refused: repeated") { return "Repeated call refused" }
        if display.hasPrefix("no folder") { return "No folder open" }
        if display.hasPrefix("not an available tool") || display.hasPrefix("refused: not an available") { return "Not available" }
        return "Failed"
    }
}
