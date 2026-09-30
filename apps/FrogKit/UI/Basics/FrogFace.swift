import SwiftUI

/// What the frog is up to; the face follows.
enum FrogMood: Equatable {
    case idle, reading, thinking, working, done, waiting, sad
}

/// The frog from the app mark, drawn live: it blinks, glances, hops and droops with the
/// conversation. Under Reduce Motion it holds a still pose per mood and runs no timers.
struct FrogFace: View {
    var mood: FrogMood
    var size: CGFloat = 16
    /// Bump to make the frog hop once, whatever its mood.
    var hop: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 1 is open, 0 is shut.
    @State private var lids: CGFloat = 1
    /// -1 looks left, 1 looks right.
    @State private var gaze: CGFloat = 0
    /// Points off the ground.
    @State private var lift: CGFloat = 0

    private var still: Bool { reduceMotion }

    var body: some View {
        ZStack {
            FrogShape(part: .body, lids: 1, gaze: 0, crossed: false)
                .fill(.tint, style: FillStyle(eoFill: true))
            FrogShape(part: .eyes, lids: still ? resting : lids, gaze: still ? 0 : gaze, crossed: mood == .sad)
                .fill(.tint, style: FillStyle(eoFill: mood != .sad))
        }
        .frame(width: size, height: size)
        .scaleEffect(mood == .waiting ? 1.08 : 1)
        .rotationEffect(mood == .waiting ? .degrees(-5) : .zero)
        .offset(y: still ? 0 : -lift)
        .animation(.snappy(duration: 0.25), value: mood)
        .onChange(of: mood, initial: true) { _, new in settle(new) }
        .onChange(of: hop) { _, _ in jump() }
        .task(id: mood) { await live() }
        .accessibilityHidden(true)
    }

    /// How open the eyes rest in this mood.
    private var resting: CGFloat {
        switch mood {
        case .thinking: 0.45
        default: 1
        }
    }

    private func settle(_ mood: FrogMood) {
        guard !still else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            lids = resting
            gaze = 0
        }
        if mood == .done { jump() }
    }

    /// Up 3 points and back, on a spring, once.
    private func jump() {
        guard !still else { return }
        withAnimation(.spring(duration: 0.22, bounce: 0.4)) { lift = 3 }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(duration: 0.3, bounce: 0.5)) { lift = 0 }
        }
    }

    /// The idle blink and the reading glance, on their own timer while the mood lasts.
    private func live() async {
        guard !still else { return }
        switch mood {
        case .idle, .working:
            while !Task.isCancelled {
                let wait = mood == .idle ? Double.random(in: 4...7) : Double.random(in: 3...6)
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                await blink()
                if mood == .working { bob() }
            }
        case .reading:
            var side: CGFloat = -1
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.7)) { gaze = side }
                side = -side
                try? await Task.sleep(for: .seconds(1.6))
            }
        default:
            return
        }
    }

    private func blink() async {
        withAnimation(.easeIn(duration: 0.07)) { lids = 0 }
        try? await Task.sleep(for: .milliseconds(90))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.12)) { lids = resting }
    }

    private func bob() {
        withAnimation(.easeOut(duration: 0.15)) { lift = 1 }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeIn(duration: 0.2)) { lift = 0 }
        }
    }
}

/// The mark's geometry in a 100-point box: two eyes with pupils, a body with a smile and two
/// nostrils. The eyes and body are separate parts so their overlap fills instead of cancelling
/// under the even-odd rule that cuts the holes.
struct FrogShape: Shape {
    enum Part { case body, eyes }
    var part: Part
    var lids: CGFloat
    var gaze: CGFloat
    var crossed: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(lids, gaze) }
        set { lids = newValue.first; gaze = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        let t = CGAffineTransform(translationX: rect.midX - 50 * s, y: rect.midY - 50 * s).scaledBy(x: s, y: s)
        var p = Path()
        switch part {
        case .body:
            p.addEllipse(in: CGRect(x: 8, y: 33, width: 84, height: 58))
            p.move(to: CGPoint(x: 31, y: 66))
            p.addQuadCurve(to: CGPoint(x: 69, y: 66), control: CGPoint(x: 50, y: 82))
            p.addQuadCurve(to: CGPoint(x: 31, y: 66), control: CGPoint(x: 50, y: 75))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: 41.5, y: 50.5, width: 5, height: 5))
            p.addEllipse(in: CGRect(x: 53.5, y: 50.5, width: 5, height: 5))
        case .eyes:
            for cx in [30.0, 70.0] {
                if crossed {
                    for deg in [45.0, -45.0] {
                        let bar = CGRect(x: cx - 12, y: 27.5, width: 24, height: 5)
                        let spin = CGAffineTransform(translationX: cx, y: 30)
                            .rotated(by: deg * .pi / 180)
                            .translatedBy(x: -cx, y: -30)
                        p.addPath(Path(bar).applying(spin))
                    }
                    continue
                }
                let open = max(lids, 0.12)
                let h = 36 * open
                p.addEllipse(in: CGRect(x: cx - 18, y: 30 - h / 2, width: 36, height: h))
                // The pupil shrinks and sinks as the lid comes down, so it stays inside the eye.
                let r = 6.5 * min(1, max(0, (lids - 0.4) / 0.35))
                if r > 2 {
                    let cy = 27 + (1 - lids) * 3
                    p.addEllipse(in: CGRect(x: cx + gaze * 5 - r, y: cy - r, width: r * 2, height: r * 2))
                }
            }
        }
        return p.applying(t)
    }
}

/// A round pad with a notch, for the frog to sit on.
struct LilyPad: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addArc(center: .zero, radius: 1, startAngle: .degrees(50), endAngle: .degrees(370), clockwise: false)
        p.closeSubpath()
        return p.applying(
            CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: rect.width / 2, y: rect.height / 2))
    }
}

/// Where the empty-state frog is, so the drop overlay can reach it with the tongue.
struct FrogAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Lines the frog says when you hover it.
enum FrogCopy {
    static let hovers = ["what shall we fix?", "ready when you are", "drop a file on me"]
}
