import SwiftUI

/// The frog avatar of a thinking trace, about 22 pt: it blinks slowly while thinking, smiles
/// briefly when the model commits to something, frowns when it's stuck, and hops once when the
/// turn is done (see the thinking-trace design). Drawn from the app mark's own shape, tinted
/// green; still per mood under Reduce Motion.
struct ThinkingAvatar: View {
    /// What the model is up to right now.
    var mood: FrogMood
    /// Bump to make the frog hop once (the turn finishing).
    var hop: Int = 0
    /// Bump to make it smile once (a DECIDED sentence just appeared).
    var decided: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lids: CGFloat = 1
    @State private var lift: CGFloat = 0
    @State private var smiling = false

    private var still: Bool { reduceMotion }

    var body: some View {
        ZStack {
            FrogShape(part: .body, lids: 1, gaze: 0, crossed: false)
                .fill(Color.frog, style: FillStyle(eoFill: true))
            FrogShape(part: .eyes, lids: still ? resting : lids, gaze: 0, crossed: mood == .sad)
                .fill(Color.frog, style: FillStyle(eoFill: mood == .sad))
        }
        .frame(width: 22, height: 22)
        .scaleEffect(mood == .sad ? 1 : (smiling ? 1.08 : 1))
        .rotationEffect(mood == .sad ? .degrees(0) : (smiling ? .degrees(-3) : .zero))
        .offset(y: still ? 0 : -lift)
        .animation(.snappy(duration: 0.25), value: mood)
        .onChange(of: mood, initial: true) { _, new in settle(new) }
        .onChange(of: hop) { _, _ in jump() }
        .onChange(of: decided) { _, _ in smile() }
        .task(id: mood) { await live() }
        .accessibilityHidden(true)
    }

    /// How open the eyes rest in this mood: half-lidded while thinking.
    private var resting: CGFloat { mood == .thinking ? 0.45 : 1 }

    private func settle(_ mood: FrogMood) {
        guard !still else { return }
        withAnimation(.easeInOut(duration: 0.2)) { lids = resting }
        if mood == .done { jump() }
    }

    /// Up 2 points and back, on a spring, once.
    private func jump() {
        guard !still else { return }
        withAnimation(.spring(duration: 0.22, bounce: 0.4)) { lift = 2 }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(duration: 0.3, bounce: 0.5)) { lift = 0 }
        }
    }

    /// A brief smile-and-bounce for a commitment (a DECIDED sentence).
    private func smile() {
        guard !still else { return }
        withAnimation(.spring(duration: 0.2, bounce: 0.3)) { smiling = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.4)) { smiling = false }
        }
    }

    /// The slow blink of thinking, on its own timer while the mood lasts.
    private func live() async {
        guard !still, mood == .thinking else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.09)) { lids = 0.12 }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.14)) { lids = resting }
        }
    }
}
