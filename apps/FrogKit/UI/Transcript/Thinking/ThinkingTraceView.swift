import SwiftUI

/// The thinking trace of a turn (phase 1, visual only): one collapsed line while it thinks —
/// the frog avatar, a shimmering elapsed clock, the current sentence — opening to a margin-ruled
/// trace with a step timeline, done steps collapsed to a line each, attention chips, self-talk
/// "beats", code blocks, options weighed, and DECIDED callouts. Finished, it's one muted line
/// with the final gist. See docs/design/thinking-trace.md.
struct ThinkingTraceView: View {
    let trace: ThinkingTrace
    let conversation: Conversation
    /// The turn is over: "✓ Thought for 2m 14s · <gist>", still clickable.
    var finished: Bool
    /// A gist for the whole turn, once it's done.
    var finalGist: String?

    @State private var expanded = false
    @State private var decidedPulse = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the avatar is up to: thinking while any step runs, sad if nothing has progressed
    /// for 60 s (no new text and no step moving), done when finished.
    private var mood: FrogMood {
        if finished { return .done }
        if stuck { return .sad }
        return .thinking
    }

    /// No progress for 60 s: nothing streaming in the live thought and no tool running.
    private var stuck: Bool {
        guard let current = trace.current else { return false }
        let last = current.items.last ?? current.items.first
        guard let startedAt = last?.startedAt ?? trace.since else { return false }
        let streaming = (current.kind == .thought && !current.text.isEmpty)
            || (last?.done == false)
        return !streaming && Date.now.timeIntervalSince(startedAt) > 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                expandedBody
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: expanded)
    }

    // MARK: Header

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                ThinkingAvatar(mood: mood, hop: finished ? 1 : 0, decided: decidedPulse)
                if finished {
                    Text("✓ Thought \(totalDuration.map(ThinkingTrace.duration) ?? "")")
                        .foregroundStyle(.secondary)
                    if let finalGist, !finalGist.isEmpty {
                        Text("· \(finalGist)").italic().foregroundStyle(.tertiary)
                    }
                } else {
                    ShimmeringClock(since: trace.since, reduceMotion: reduceMotion)
                    Text(currentGist)
                        .italic()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                chevron
            }
            .font(.callout)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .help(expanded ? "Hide the trace" : "Show the trace")
        .onChange(of: decidedCount) { _, _ in decidedPulse += 1 }
    }

    private var chevron: some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    /// The sentence being written now, for the live one-line preview.
    private var currentGist: String {
        trace.current?.gist ?? trace.steps.last?.gist ?? ""
    }

    private var totalDuration: TimeInterval? {
        guard let since = trace.since else { return nil }
        let end = trace.steps.compactMap(\.endedAt).max() ?? Date.now
        return end.timeIntervalSince(since)
    }

    private var decidedCount: Int {
        trace.steps.reduce(0) { $0 + Self.decided(in: $1.text).count }
    }

    /// Sentences where the model commits, for the avatar's smile.
    static let decidedMarkers = ["I'll define", "I'll add", "I'll use", "I'll make", "I'll write", "I'll create",
                                 "I'll build", "I'll start", "Decision:", "Going with", "I'll go with", "I'll put"]

    /// The sentences of a thought where the model commits ("I'll define", "Decision:", "Going
    /// with"), each with its marker.
    static func decided(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard Self.decidedMarkers.contains(where: { l.hasPrefix($0) || l.contains(" \($0)") }) else { return nil }
            return String(l)
        }
    }

    // MARK: Expanded

    private var expandedBody: some View {
        HStack(alignment: .top, spacing: 0) {
            // A 2 pt margin rule, like a margin note.
            Rectangle()
                .fill(Color.frog.opacity(0.55))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 10) {
                StepTimeline(steps: trace.steps, current: trace.current)
                ForEach(trace.steps) { step in
                    ThinkingStepView(step: step, live: trace.current?.id == step.id && !step.done)
                }
                if !trace.attention.isEmpty {
                    AttentionChips(chips: trace.attention,
                                   active: finished ? nil : trace.currentAttention,
                                   progress: liveProgress)
                }
            }
            .padding(.leading, 22)
        }
    }

    /// The live step's progress, 0…1, when its tool reports one.
    private var liveProgress: Double? {
        guard let current = trace.current else { return nil }
        for item in current.items.reversed() {
            if let p = item.progress, let total = p.total, total > 0 {
                return p.progress / total
            }
            if let p = item.progress, p.total == nil, p.progress > 0 {
                return p.progress
            }
        }
        return nil
    }
}

/// A "Thinking · 1m 12s" clock that shimmers while it runs, updating every second; a steady
/// muted clock under Reduce Motion.
struct ShimmeringClock: View {
    let since: Date?
    var reduceMotion: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if reduceMotion {
                Text("Thinking \(elapsed(at: timeline.date))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Shimmer(text: "Thinking \(elapsed(at: timeline.date))")
            }
        }
        .fixedSize()
    }

    private func elapsed(at now: Date) -> String {
        guard let since else { return "" }
        let secs = now.timeIntervalSince(since)
        guard secs >= 1 else { return "0s" }
        return ThinkingTrace.duration(secs)
    }
}

/// Text with a soft moving highlight, like a shimmering placeholder, that never animates under
/// Reduce Motion (callers substitute a plain label).
struct Shimmer: View {
    let text: String
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .background {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Color.frog.opacity(0.45), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.6)
                        .blendMode(.plusLighter)
                        .mask(Text(text).monospacedDigit())
                }
            }
            .task {
                while !Task.isCancelled {
                    withAnimation(.linear(duration: 1.6)) { phase = 1 }
                    try? await Task.sleep(for: .milliseconds(1600))
                    phase = -1
                }
            }
    }
}
