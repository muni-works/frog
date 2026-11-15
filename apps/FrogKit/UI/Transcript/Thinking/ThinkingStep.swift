import Foundation

/// One step of a thinking trace: a thinking block, or a run of tool calls that belong together
/// (a step = a thinking block or tool-call group, per the thinking-trace design). Derived from
/// the turn's items; nothing is stored, so it stays true while the turn streams.
///
/// Phase 1 is visual only: the steps come from what the model already did, so "future" steps
/// don't exist yet and the timeline's grey dots wait for engine support.
struct ThinkingStep: Identifiable {
    /// Where a step's chips point: a file in the repo, or a page on the web.
    enum Attention: Equatable, Hashable {
        case file(String)
        case url(String)

        /// The chip's label: the last path component, or the host.
        var label: String {
            switch self {
            case .file(let path): (path as NSString).lastPathComponent
            case .url(let url): URL(string: url)?.host() ?? url
            }
        }

        /// The chip's tooltip: the full path or URL.
        var detail: String {
            switch self {
            case .file(let path): path
            case .url(let url): url
            }
        }
    }

    enum Kind {
        /// The model's own words.
        case thought
        /// One or more tool calls that ran back to back.
        case tools
    }

    let id: String
    let kind: Kind
    /// The thought's text, or "" for a tool group.
    let text: String
    /// The step's items: the thought itself, or the tool calls.
    let items: [ItemState]
    /// When the step started and (once finished) ended.
    let startedAt: Date?
    let endedAt: Date?
    let done: Bool

    /// A one-line title for the collapsed row and the timeline's hover.
    var title: String {
        switch kind {
        case .thought:
            if let startedAt, let endedAt {
                let secs = endedAt.timeIntervalSince(startedAt)
                if secs >= 1 { return "Thought \(ThinkingTrace.duration(secs))" }
            }
            return "Thought"
        case .tools:
            let words = ActivityWords.plain(ActivityWords.summary(items.filter(\.done)))
            return words.isEmpty ? "Working" : words
        }
    }

    /// What this step read or fetched, as chips.
    var attention: [Attention] {
        var out: [Attention] = []
        var seen = Set<Attention>()
        for item in items {
            guard case .tool(let name, let arg) = item.kind, !arg.isEmpty else { continue }
            let chip: Attention?
            switch name {
            case "Read", "Grep", "Glob": chip = .file(arg)
            case "WebFetch": chip = .url(arg)
            default: chip = nil
            }
            if let chip, seen.insert(chip).inserted { out.append(chip) }
        }
        return out
    }

    /// The sentence the step is on, for the live one-line preview: the latest non-empty line
    /// while streaming, the first once done.
    var gist: String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String((done ? lines.first : lines.last) ?? "")
    }
}

/// The whole trace of a turn: its steps, and when the work began.
struct ThinkingTrace {
    let steps: [ThinkingStep]
    /// When the turn's work began, for the elapsed clock.
    let since: Date?

    /// Derives the trace from a turn's items. A step is a thinking block or a run of tool calls
    /// that came back to back; consecutive reasoning blocks are separate steps.
    init(items: [ItemState], since: Date? = nil) {
        var steps: [ThinkingStep] = []
        var run: [ItemState] = []   // tool calls pending grouping
        var thought: ItemState?     // the thought being written, or just finished

        func flushThought() {
            guard let t = thought else { return }
            thought = nil
            append(kind: .thought, group: [t], text: t.text)
        }
        func flushTools() {
            guard !run.isEmpty else { return }
            let group = run
            run = []
            append(kind: .tools, group: group, text: "")
        }
        func append(kind: ThinkingStep.Kind, group: [ItemState], text: String) {
            steps.append(ThinkingStep(
                id: group.map(\.id).joined(separator: "+"),
                kind: kind,
                text: text,
                items: group,
                startedAt: group.compactMap(\.startedAt).min(),
                endedAt: group.compactMap(\.endedAt).max(),
                done: group.allSatisfy(\.done)))
        }

        for item in items {
            switch item.kind {
            case .reasoning:
                flushThought()
                thought = item
            case .tool:
                flushThought()
                run.append(item)
            case .message, .notice:
                flushThought()
                flushTools()
            }
        }
        flushThought()
        flushTools()

        self.steps = steps
        self.since = since
            ?? steps.compactMap(\.startedAt).min()
            ?? items.compactMap(\.startedAt).min()
    }

    /// The step running now, if the trace is live.
    var current: ThinkingStep? { steps.last { !$0.done } }

    /// Every file or URL the turn has read, in first-read order, de-duplicated.
    var attention: [ThinkingStep.Attention] {
        var out: [ThinkingStep.Attention] = []
        var seen = Set<ThinkingStep.Attention>()
        for step in steps {
            for chip in step.attention where seen.insert(chip).inserted { out.append(chip) }
        }
        return out
    }

    /// The chip being read right now, if any: the live step's attention.
    var currentAttention: ThinkingStep.Attention? {
        current?.attention.last
    }

    /// "1m 12s" — the shared duration format (matches `ActivityWords.duration`).
    static func duration(_ secs: TimeInterval) -> String { ActivityWords.duration(secs) }
}
