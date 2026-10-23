import SwiftUI

/// What the frog is up to; the face follows.
enum FrogMood: Equatable {
    case idle, reading, thinking, working, done, waiting, sad
}

/// The frog from the app mark (round 3, tree weight), drawn live: it breathes, blinks,
/// scans, tilts, hops and droops with the conversation. Under Reduce Motion it holds a
/// still pose per mood and runs no timers.
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
    /// Vertical pupil offset, glyph units (0 = resting).
    @State private var gazeY: CGFloat = 0
    /// Points off the ground.
    @State private var lift: CGFloat = 0
    /// Squash-stretch during the done hop, as fractions of the box.
    @State private var squash: CGSize = .zero
    /// Waiting mood: head tilt in degrees, side to side.
    @State private var tilt: CGFloat = 0

    private var still: Bool { reduceMotion }

    var body: some View {
        ZStack {
            FrogShape(part: .body)
                .fill(Self.skin)
            FrogShape(part: .spots)
                .fill(Self.spot)
            FrogShape(part: .mouth, frown: mood == .sad)
                .fill(Self.ink)
            FrogShape(part: .eyes, lids: still ? resting : lids, gaze: still ? 0 : gaze, gazeY: still ? restingY : gazeY)
                .fill(Self.ink)
            FrogShape(part: .glints, lids: still ? resting : lids, gaze: still ? 0 : gaze, gazeY: still ? restingY : gazeY)
                .fill(Self.paper)
        }
        .frame(width: size, height: size)
        .scaleEffect(x: 1 + squash.width, y: 1 + squash.height, anchor: .bottom)
        .scaleEffect(mood == .waiting && !still ? 1.12 : 1)
        .rotationEffect(.degrees(tilt))
        .offset(y: still ? sink : 0)
        .offset(y: -lift)
        .animation(.snappy(duration: 0.25), value: mood)
        .onChange(of: mood, initial: true) { _, new in settle(new) }
        .onChange(of: hop) { _, _ in jump() }
        .task(id: mood) { await live() }
        .accessibilityHidden(true)
    }

    // Locked round-3 palette (tree weight), spec-exact rather than the appearance-
    // adaptive accent: the face must match the icon at every size.
    static let skin = Color(red: 0x51 / 255.0, green: 0xda / 255.0, blue: 0x60 / 255.0)
    static let spot = Color(red: 0x36 / 255.0, green: 0xb3 / 255.0, blue: 0x47 / 255.0)
    static let ink = Color(red: 0x15 / 255.0, green: 0x17 / 255.0, blue: 0x1a / 255.0)
    static let paper = Color(red: 0xfb / 255.0, green: 0xfb / 255.0, blue: 0xf9 / 255.0)

    /// How open the eyes rest in this mood.
    private var resting: CGFloat {
        switch mood {
        case .thinking: 0.82
        case .sad: 0.55
        default: 1
        }
    }

    /// The mood's resting pupil lift, in glyph units.
    private var restingY: CGFloat {
        switch mood {
        case .thinking: -3.4
        case .sad: 1.6
        default: 0
        }
    }

    /// How far the body sinks in a mood (12/1024 of the box for sad).
    private var sink: CGFloat {
        mood == .sad ? size * 12 / 1024 : 0
    }

    private func settle(_ mood: FrogMood) {
        guard !still else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            lids = resting
            gaze = 0
            gazeY = restingY
        }
        withAnimation(.easeInOut(duration: 0.2)) { tilt = 0 }
        if mood == .done { jump() }
    }

    /// Squash, hop, stretch, land, settle -- the done-hop from the locked spec.
    private func jump() {
        guard !still else { return }
        withAnimation(.easeOut(duration: 0.08)) { squash = CGSize(width: 0.10, height: -0.14) }
        withAnimation(.easeIn(duration: 0.1).delay(0.08)) { squash = CGSize(width: -0.06, height: 0.08) }
        withAnimation(.spring(duration: 0.22, bounce: 0.4).delay(0.08)) { lift = size * 120 / 1024 }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.3, bounce: 0.5)) {
                squash = CGSize(width: 0.12, height: -0.16)
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { squash = .zero }
        }
    }

    /// The mood loops: idle/working blinks, thinking drift, reading scan, waiting tilt,
    /// on their own timer while the mood lasts. sad droops are geometry on `mood`.
    private func live() async {
        guard !still else { return }
        switch mood {
        case .idle:
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 4...7)))
                guard !Task.isCancelled else { return }
                await blink()
            }
        case .working:
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 3...4)))
                guard !Task.isCancelled else { return }
                await blink()
            }
        case .thinking:
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 1.2)) { gaze = .random(in: -1...1) }
                withAnimation(.easeInOut(duration: 1.2)) { gazeY = -3.4 + CGFloat.random(in: -0.8...0.8) }
                try? await Task.sleep(for: .seconds(1.4))
            }
        case .reading:
            var side: CGFloat = -1
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.55)) { gaze = side }
                side = -side
                try? await Task.sleep(for: .seconds(1.2))
            }
        case .waiting:
            // Head tilts side to side, eyes a little wide.
            withAnimation(.easeInOut(duration: 0.2)) { lids = 1 }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.9)) { tilt = tilt == 0 ? -7 : (tilt < 0 ? 7 : -7) }
                try? await Task.sleep(for: .seconds(0.9))
            }
        case .sad:
            withAnimation(.easeInOut(duration: 0.5)) { lids = 0.45 }
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
}

/// The round-3 mark's geometry in a 100-point box, transcribed from the locked design
/// (build.py, tree weight, 1024 grid; GLYPH_BOX = x160 y200 size704):
///
/// head ellipse (512, 568) rx 296 ry 224 with a +10 belly overshoot on the bottom arc;
/// eye bumps r 120 at 512 ± 152, cy 352; pupils r 68 nudged 8 up (cy 344); glint r 22
/// up-right plus a second glint r 9 low-left; 4 spots + 2 cheek spots in the darker
/// spot shade; mouth a 30-wide round-capped stroke, a rounded smile (flipped for frown).
///
/// Parts are separate so fills layer in a ZStack (spots under the pupils) instead of
/// interacting inside one path.
struct FrogShape: Shape {
    enum Part { case body, spots, mouth, eyes, glints }
    var part: Part
    /// 1 is open, 0 is shut.
    var lids: CGFloat = 1
    /// -1 looks left, 1 looks right, in glyph units of pupil offset.
    var gaze: CGFloat = 0
    /// Vertical pupil offset in glyph units (negative = up).
    var gazeY: CGFloat = 0
    /// Mouth flips (sad).
    var frown: Bool = false
    /// Legacy sad-bars eyes (kept for ThinkingAvatar's monochrome avatar).
    var crossed: Bool = false

    var animatableData: AnimatablePackage {
        get { AnimatablePackage(lids: lids, gaze: gaze, gazeY: gazeY, frown: frown ? 1 : 0) }
        set { lids = newValue.lids; gaze = newValue.gaze; gazeY = newValue.gazeY; frown = newValue.frown > 0.5 }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        let t = CGAffineTransform(translationX: rect.midX - 50 * s, y: rect.midY - 50 * s).scaledBy(x: s, y: s)
        var p = Path()
        switch part {
        case .body:
            // Head ellipse + two eye bumps, drawn as one silhouette: the bumps' bottom
            // arcs are above the head's top arc (which peaks at y 35.2), so the union
            // of the three subpaths fills the right shape with the default fill rule.
            p.addEllipse(in: CGRect(x: 22, y: 35.2, width: 58, height: 43.75))   // (512,568) rx296 ry224(+10)
            for cx in [30.0, 70.0] {
                p.addEllipse(in: CGRect(x: cx - 11.7, y: 34.35 - 11.7, width: 23.4, height: 23.4))  // r120 cy352
            }
        case .spots:
            // 4 spots at build.py's SPOTS layout + 2 cheek spots (r30, smile y - 0.14 ry).
            for (fx, fy, fr) in [(-0.75, -0.44, 0.061), (-0.845, -0.20, 0.037),
                                 (0.777, -0.47, 0.054), (0.88, -0.26, 0.034)] {
                let cx = 50 + fx * 28.9
                let cy = 45.55 + fy * 21.9
                let r = fr * 28.9
                p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
            for sx in [-1.0, 1.0] {
                let cx = 50 + sx * 0.64 * 28.9
                let cy = 50.2 - 0.14 * 21.9
                p.addEllipse(in: CGRect(x: cx - 2.93, y: cy - 2.93, width: 5.85, height: 5.85))
            }
        case .mouth:
            // Rounded smile: a 30-wide round-capped stroke along
            // (x0+20, y) -> (512, y+64) -> (x1-20, y), from build.py mouth(tree).
            let y0: CGFloat = 50.2, x0: CGFloat = 34.5, x1: CGFloat = 65.5
            var stroke = Path()
            stroke.move(to: CGPoint(x: x0, y: y0))
            stroke.addQuadCurve(to: CGPoint(x: x1, y: y0), control: CGPoint(x: 50, y: y0 + 6.3))
            p.addPath(stroke.strokedPath(StrokeStyle(lineWidth: 2.95, lineCap: .round)))
        case .eyes:
            if crossed {
                for cx in [30.0, 70.0] {
                    for deg in [45.0, -45.0] {
                        let bar = CGRect(x: cx - 9, y: 31.6, width: 18, height: 3)
                        let spin = CGAffineTransform(translationX: cx, y: 33)
                            .rotated(by: deg * .pi / 180)
                            .translatedBy(x: -cx, y: -33)
                        p.addPath(Path(bar).applying(spin))
                    }
                }
            } else {
                for cx in [30.0, 70.0] {
                // The eye: the bump's inner disc, clipped by the lid.
                let open = max(lids, 0.12)
                let h = 11.7 * 2 * open * 0.62
                p.addEllipse(in: CGRect(x: cx - 6.6, y: 34.35 - h / 2, width: 13.2, height: h))
                // The pupil (r 68 -> 5.9, resting cy 344 -> 31.6 after the 8-up nudge)
                // shrinks and sinks as the lid comes down, so it stays inside the eye.
                let pr = 5.9 * min(1, max(0, (lids - 0.35) / 0.3))
                if pr > 1 {
                    let cy = 31.6 + gazeY * 0.098 + (1 - lids) * 1.2
                    let px = cx + gaze * 4.4
                    p.addEllipse(in: CGRect(x: px - pr, y: cy - pr, width: pr * 2, height: pr * 2))
                }
                }
            }
        case .glints:
            // Main glint r 22 up-right of the pupil centre + second glint r 9 low-left,
            // both travelling with the pupil.
            for cx in [30.0, 70.0] {
                let pr = 5.9 * min(1, max(0, (lids - 0.35) / 0.3))
                if pr > 1 {
                    let cy = 31.6 + gazeY * 0.098 + (1 - lids) * 1.2
                    let px = cx + gaze * 4.4
                    p.addEllipse(in: CGRect(x: px + 1.3, y: cy - 2.4, width: 2.05, height: 2.05))
                    p.addEllipse(in: CGRect(x: px - 2.1, y: cy + 1.3, width: 0.85, height: 0.85))
                }
            }
        }
        if frown && part == .mouth {
            // Flip the smile about its centre line.
            var spin = CGAffineTransform(translationX: 50 * s, y: 51 * s)
                .rotated(by: .pi)
                .translatedBy(x: -50 * s, y: -51 * s)
            return p.applying(spin.concatenating(t))
        }
        return p.applying(t)
    }
}

/// Four animatable scalars in one package, so the face can tween lids, gaze, pupil
/// lift and the frown flip together.
struct AnimatablePackage: VectorArithmetic {
    var lids: CGFloat
    var gaze: CGFloat
    var gazeY: CGFloat
    var frown: CGFloat

    var magnitudeSquared: Double {
        Double(lids * lids + gaze * gaze + gazeY * gazeY + frown * frown)
    }

    static var zero: AnimatablePackage { .init(lids: 0, gaze: 0, gazeY: 0, frown: 0) }

    static func - (lhs: AnimatablePackage, rhs: AnimatablePackage) -> AnimatablePackage {
        .init(lids: lhs.lids - rhs.lids, gaze: lhs.gaze - rhs.gaze, gazeY: lhs.gazeY - rhs.gazeY, frown: lhs.frown - rhs.frown)
    }

    static func + (lhs: AnimatablePackage, rhs: AnimatablePackage) -> AnimatablePackage {
        .init(lids: lhs.lids + rhs.lids, gaze: lhs.gaze + rhs.gaze, gazeY: lhs.gazeY + rhs.gazeY, frown: lhs.frown + rhs.frown)
    }

    static func += (lhs: inout AnimatablePackage, rhs: AnimatablePackage) { lhs = lhs + rhs }
    static func -= (lhs: inout AnimatablePackage, rhs: AnimatablePackage) { lhs = lhs - rhs }
    mutating func scale(by rhs: Double) {
        lids *= CGFloat(rhs); gaze *= CGFloat(rhs); gazeY *= CGFloat(rhs); frown *= CGFloat(rhs)
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
