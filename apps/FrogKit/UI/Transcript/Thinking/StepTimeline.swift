import SwiftUI

/// The trace's scrubber: one dot per step, above the expanded thinking trace. Done steps are
/// dark green, the one running is bright green and pulses, and hovering a dot shows the step's
/// summary. Under Reduce Motion the live dot is a steady bright green.
struct StepTimeline: View {
    let steps: [ThinkingStep]
    /// The step running now, if any.
    var current: ThinkingStep?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: ThinkingStep.ID?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps) { step in
                dot(step)
                    .help(step.title)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Steps")
        .accessibilityValue(accessibilitySummary)
    }

    private func dot(_ step: ThinkingStep) -> some View {
        let running = current?.id == step.id && !step.done
        return Circle()
            .fill(running ? Color.frog : Color.frog.opacity(0.45))
            .frame(width: running ? 7 : 5, height: running ? 7 : 5)
            .overlay {
                if !reduceMotion, running {
                    Circle()
                        .stroke(Color.frog.opacity(0.7), lineWidth: 1)
                        .frame(width: 11, height: 11)
                        .pulse()
                }
            }
            .animation(.snappy(duration: 0.25), value: step.done)
            .onHover { h in hovered = h ? step.id : (hovered == step.id ? nil : hovered) }
            .background {
                // The hover target is bigger than the dot.
                RoundedRectangle(cornerRadius: 4).fill(.clear).padding(-5)
            }
    }

    private var accessibilitySummary: String {
        let doneCount = steps.filter(\.done).count
        return "\(doneCount) of \(steps.count) done"
    }
}

/// A steady breathing pulse for the live step's dot; nothing at all under Reduce Motion
/// (callers gate it, but this stays quiet on its own).
private struct Pulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on && !reduceMotion ? 1.25 : 1)
            .opacity(on && !reduceMotion ? 0.4 : 1)
            .task {
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 1.1)) { on.toggle() }
                    try? await Task.sleep(for: .seconds(1.1))
                }
            }
    }
}

private extension View {
    func pulse() -> some View { modifier(Pulse()) }
}
