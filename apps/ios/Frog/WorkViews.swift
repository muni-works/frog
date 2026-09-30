import SwiftUI

/// A run of frog's work (tool calls and thinking) as one line. While it runs, the line is the
/// step in hand, shimmering; once done, a summary. Tap to fan the steps out, with any changes
/// as cards you can swipe through.
struct WorkGroupView: View {
    let entries: [SessionModel.Entry]
    /// The turn's current work, still going.
    let live: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.4, bounce: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: live ? symbol : (failures > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                        .foregroundStyle(live ? Color.frog : (failures > 0 ? .orange : .secondary))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 18)
                    if live {
                        Text(activity).shimmer()
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.2), value: activity)
                    } else {
                        Text(summary)
                    }
                    Spacer(minLength: 0)
                    if !diffs.isEmpty, !live {
                        Text("+\(added)").foregroundStyle(.green).monospacedDigit()
                        Text("−\(removed)").foregroundStyle(.red).monospacedDigit()
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the steps" : "Shows the steps")

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entries) { e in
                        StepRow(entry: e)
                            .transition(.asymmetric(insertion: .push(from: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(.leading, 26)
                if !diffs.isEmpty {
                    DiffCarousel(diffs: diffs)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var tools: [SessionModel.Entry] {
        entries.filter { if case .tool = $0.kind { true } else { false } }
    }

    private var diffs: [FileDiff] {
        // The latest change per file.
        var seen = Set<String>()
        return tools.reversed().compactMap(\.result?.diff).filter { seen.insert($0.path).inserted }.reversed()
    }

    private var added: UInt32 { diffs.reduce(0) { $0 + $1.added } }
    private var removed: UInt32 { diffs.reduce(0) { $0 + $1.removed } }
    private var failures: Int { tools.filter { $0.result?.outcome == .error }.count }

    private var seconds: Int? {
        guard let a = entries.compactMap(\.startedAt).min(), let b = entries.compactMap(\.endedAt).max() else { return nil }
        return max(1, Int(b.timeIntervalSince(a).rounded()))
    }

    private var summary: String {
        let steps = tools.count
        let took = seconds.map { $0 < 60 ? "\($0)s" : "\($0 / 60)m \($0 % 60)s" }
        if steps == 0 { return took.map { "Thought for \($0)" } ?? "Thought" }
        var parts = [took.map { "Worked for \($0)" } ?? "Worked"]
        parts.append("\(steps) step\(steps == 1 ? "" : "s")")
        if !diffs.isEmpty { parts.append("\(diffs.count) file\(diffs.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var current: SessionModel.Entry? { entries.last }

    private var symbol: String {
        guard let e = current else { return "sparkle" }
        if case .tool(let name, _) = e.kind, !e.done { return StepRow.symbol(name) }
        return "sparkle"
    }

    /// The step in hand, in words.
    private var activity: String {
        guard let e = current else { return "Starting" }
        switch e.kind {
        case .tool(let name, let arg) where !e.done:
            let target = StepRow.short(arg)
            switch name {
            case "Read": return "Reading \(target)"
            case "Grep": return "Searching for \(target)"
            case "Glob": return "Finding \(target)"
            case "Bash": return "Running \(target)"
            case "Edit": return "Editing \(target)"
            case "Write": return "Writing \(target)"
            case "WebFetch": return "Reading a web page"
            case "WebSearch": return "Searching the web"
            case "CodeMap": return "Mapping the project"
            case "TodoWrite": return "Planning"
            case "Task": return "Asking a helper"
            default: return "Using \(name)"
            }
        case .tool:
            return "Thinking · step \(tools.count + 1)"
        default:
            return tools.isEmpty ? "Thinking" : "Thinking · step \(tools.count + 1)"
        }
    }
}

/// One step, fanned out: the tool, its target and how it went. Opens to its output.
struct StepRow: View {
    let entry: SessionModel.Entry
    @State private var open = false

    var body: some View {
        switch entry.kind {
        case .reasoning:
            // Thinking stays quiet: a whisper of a row, its text a tap away.
            VStack(alignment: .leading, spacing: 4) {
                Button { withAnimation(.snappy) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain").frame(width: 16)
                        Text(open ? "Thought" : Self.gist(entry.text)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if open {
                    Text(entry.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.leading, 22)
                }
            }
        case .tool(let name, let arg):
            VStack(alignment: .leading, spacing: 4) {
                Button { withAnimation(.snappy) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Self.symbol(name)).frame(width: 16).foregroundStyle(.secondary)
                        Text(name).fontWeight(.medium).foregroundStyle(.primary.opacity(0.8))
                        Text(Self.short(arg)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        status
                    }
                    .font(.footnote)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if open, entry.result?.diff == nil {
                    let out = entry.result?.display ?? entry.result?.output ?? entry.output
                    if !out.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(String(out.prefix(4000))).font(.caption2.monospaced()).padding(8)
                        }
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
                    }
                }
            }
        default:
            EmptyView()
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
                    Image(systemName: "checkmark").foregroundStyle(.tertiary)
                }
            }
        }
    }

    static func symbol(_ name: String) -> String {
        [
            "Bash": "terminal", "Read": "doc.text", "Write": "square.and.pencil", "Edit": "pencil",
            "Glob": "folder", "Grep": "magnifyingglass", "TodoWrite": "checklist", "Diagram": "point.3.connected.trianglepath.dotted",
            "CodeMap": "map", "Docs": "book", "WebFetch": "globe", "WebSearch": "globe", "Task": "person.2",
        ][name] ?? "wrench.and.screwdriver"
    }

    /// A thought's first sentence, for its folded row.
    static func gist(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = t.firstIndex { ".!?\n".contains($0) } ?? t.endIndex
        let s = t[..<end]
        return s.isEmpty ? "Thought" : String(s)
    }

    /// Paths shortened to the file name; commands to their first line.
    static func short(_ arg: String) -> String {
        let first = arg.split(separator: "\n").first.map(String.init) ?? arg
        return first.hasPrefix("/") ? (first as NSString).lastPathComponent : first
    }
}

// MARK: - Diffs

/// Changed files as cards, side by side; swipe through them, tap one to read it all.
struct DiffCarousel: View {
    let diffs: [FileDiff]
    @State private var reading: FileDiff?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(diffs, id: \.path) { d in
                    Button { reading = d } label: {
                        DiffCard(diff: d, limit: 10)
                            .frame(width: 300, alignment: .topLeading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .sheet(item: $reading) { d in
            NavigationStack {
                ScrollView([.vertical, .horizontal]) {
                    DiffCard(diff: d, limit: .max, framed: false).padding()
                }
                .navigationTitle((d.path as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { reading = nil } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

extension FileDiff: Identifiable {
    public var id: String { path }
}

/// A file's change: its name and counts, then the lines with a gutter of line numbers.
struct DiffCard: View {
    let diff: FileDiff
    let limit: Int
    var framed = true

    var body: some View {
        let lines = diff.hunks.flatMap(\.lines)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: diff.created ? "doc.badge.plus" : "doc.text")
                    .foregroundStyle(diff.created ? .green : .secondary)
                Text((diff.path as NSString).lastPathComponent).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text("+\(diff.added)").foregroundStyle(.green)
                Text("−\(diff.removed)").foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            ForEach(Array(lines.prefix(limit).enumerated()), id: \.offset) { _, l in
                HStack(spacing: 0) {
                    Text(l.new.map(String.init) ?? l.old.map(String.init) ?? "")
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .trailing)
                        .padding(.trailing, 6)
                    Text(Self.mark(l)).foregroundStyle(Self.markColor(l)).frame(width: 12)
                    Text(l.text).lineLimit(framed ? 1 : nil).fixedSize(horizontal: !framed, vertical: false)
                    Spacer(minLength: 0)
                }
                .font(.caption2.monospaced())
                .padding(.vertical, 1)
                .background(Self.tint(l))
            }
            if lines.count > limit {
                Text("\(lines.count - limit) more lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                Spacer().frame(height: 6)
            }
        }
        .background(framed ? Color(.secondarySystemBackground) : .clear, in: .rect(cornerRadius: 14))
        .overlay {
            if framed { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 0.5) }
        }
    }

    private static func mark(_ l: DiffLine) -> String {
        switch l.kind {
        case .add: "+"
        case .remove: "−"
        default: " "
        }
    }

    private static func markColor(_ l: DiffLine) -> Color {
        switch l.kind {
        case .add: .green
        case .remove: .red
        default: .clear
        }
    }

    private static func tint(_ l: DiffLine) -> Color {
        switch l.kind {
        case .add: .green.opacity(0.13)
        case .remove: .red.opacity(0.13)
        default: .clear
        }
    }
}

// MARK: - Shimmer

extension View {
    /// A soft light passing over the text, like Siri thinking: something's happening here.
    func shimmer() -> some View { modifier(Shimmer()) }
}

private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            // The text in its own color, with a band of full-strength ink passing across it.
            content.overlay {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.0) / 2.0
                    content
                        .foregroundStyle(.primary)
                        .mask {
                            GeometryReader { g in
                                LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: g.size.width * 0.45)
                                    .offset(x: (t * 1.9 - 0.45) * g.size.width)
                            }
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}
