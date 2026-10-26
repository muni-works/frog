import SwiftUI

/// What the frog is up to; the face follows.
enum FrogMood: Equatable {
    case idle, reading, thinking, working, done, waiting, sad
}

/// The frog from the app mark (round 3, tree), drawn live. Each mood is a gentle loop, so the
/// 16 pt activity pill never looks frozen: idle breathes and blinks, thinking looks up and
/// drifts, reading scans a line, working pumps its throat, done hops, waiting tilts its head
/// with wide eyes, sad droops and sinks. The loops are the locked prototype's keyframes
/// (design/round3/anim.py). Under Reduce Motion each mood holds its first frame and nothing
/// ticks.
struct FrogFace: View {
    var mood: FrogMood
    var size: CGFloat = 16
    /// Bump to make the frog hop once, whatever its mood.
    var hop: Int = 0
    /// Off, the frog holds its pose and nothing ticks (a hidden frog's loop still redraws).
    var animating = true
    /// Drawn at this moment instead of ticking on its own: for a frog snapshotted where nothing
    /// drives a timeline (the Dock tile).
    var at: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the current mood began; its loop starts from frame 0 here.
    @State private var since = Date()
    /// When the last one-off hop began.
    @State private var hopped: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !animating || at != nil)) { timeline in
            #if DEBUG
            let _ = PillProbe.frog()
            #endif
            let now = at ?? timeline.date
            let pose = FrogPose(
                mood: mood,
                t: reduceMotion ? 0 : now.timeIntervalSince(at == nil ? since : .distantPast),
                hop: reduceMotion ? nil : hopped.map { now.timeIntervalSince($0) })
            let unit = size / FrogMark.box.width
            MarkCanvas(eyes: pose.eyes, frown: mood == .sad)
                .frame(width: size, height: size)
                .scaleEffect(x: pose.body.sx, y: pose.body.sy, anchor: FrogMark.feet)
                .rotationEffect(.degrees(pose.body.rotation), anchor: FrogMark.feet)
                .offset(x: pose.body.tx * unit, y: pose.body.ty * unit)
        }
        .frame(width: size, height: size)
        .onChange(of: mood) { since = .now }
        .onChange(of: hop) { hopped = .now }
        .accessibilityHidden(true)
    }
}

/// The mark itself, painted in one pass: head, spots clipped to it, pupils with their two
/// glints (moved together by `eyes`, about each pupil's centre), and the mouth.
private struct MarkCanvas: View {
    var eyes: Move
    var frown: Bool

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / FrogMark.box.width
            ctx.translateBy(x: (size.width - FrogMark.box.width * k) / 2, y: (size.height - FrogMark.box.height * k) / 2)
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -FrogMark.box.minX, y: -FrogMark.box.minY)

            ctx.fill(FrogMark.silhouette, with: .color(FrogMark.skin))
            var skin = ctx
            skin.clip(to: FrogMark.silhouette)
            skin.fill(FrogMark.spots, with: .color(FrogMark.spot))
            for c in FrogMark.pupils {
                var eye = ctx
                eye.concatenate(eyes.matrix(about: c))
                eye.fill(FrogMark.circle(c, FrogMark.pupil), with: .color(FrogMark.ink))
                eye.fill(FrogMark.glints(c), with: .color(FrogMark.paper))
            }
            var mouth = ctx
            if frown { mouth.concatenate(FrogMark.frown) }
            mouth.fill(FrogMark.mouth, with: .color(FrogMark.ink))
        }
    }
}

/// The round-3 mark on its 1024 grid, transcribed from design/round3/build.py (tree weight).
/// Views draw it through `box` (build.py's GLYPH_BOX, the square crop around the marks).
enum FrogMark {
    static let box = CGRect(x: 160, y: 200, width: 704, height: 704)
    /// Bottom centre of the frog (head bottom 568 + 234), where the body moves pivot.
    static let feet = UnitPoint(x: (512 - box.minX) / box.width, y: (802 - box.minY) / box.height)

    static let skin = Color(srgb: 0x51da60)
    static let spot = Color(srgb: 0x36b347)
    static let ink = Color(srgb: 0x15171a)
    static let paper = Color(srgb: 0xfbfbf9)

    /// Pupils r68 sit 8 above the bump centres (512 ± 152, 352).
    static let pupil: CGFloat = 68
    static let pupils = [CGPoint(x: 360, y: 344), CGPoint(x: 664, y: 344)]

    /// Head ellipse at (512, 568), rx296 ry224, its bottom half 10 deeper (belly overshoot),
    /// plus the two r120 eye bumps.
    static let silhouette: Path = {
        var head = Path()
        let at = CGAffineTransform(translationX: 512, y: 568)
        head.move(to: CGPoint(x: 216, y: 568))
        head.addRelativeArc(center: .zero, radius: 1, startAngle: .degrees(180), delta: .degrees(180),
                            transform: at.scaledBy(x: 296, y: 224))
        head.addRelativeArc(center: .zero, radius: 1, startAngle: .zero, delta: .degrees(180),
                            transform: at.scaledBy(x: 296, y: 234))
        head.closeSubpath()
        var bumps = Path()
        for x in [360.0, 664.0] { bumps.addPath(circle(CGPoint(x: x, y: 352), 120)) }
        return head.union(bumps)
    }()

    /// Four small spots and two r30 cheeks, in the darker spot shade.
    static let spots: Path = {
        var p = Path()
        for (x, y, r) in [(290.0, 469.0, 18.0), (262, 523, 11), (742, 463, 16), (772, 510, 10), (323, 541, 30), (701, 541, 30)] {
            p.addPath(circle(CGPoint(x: x, y: y), r))
        }
        return p
    }()

    /// A r22 glint up and right of the pupil centre, and a r9 one down and left.
    static func glints(_ c: CGPoint) -> Path {
        var p = circle(CGPoint(x: c.x + 22, y: c.y - 22), 22)
        p.addPath(circle(CGPoint(x: c.x - 24, y: c.y + 24), 9))
        return p
    }

    /// The rounded smile: a 30-wide round-capped stroke on (420,572) ⟶ (604,572), pulled
    /// down through a control point at (512,636).
    static let mouth: Path = {
        var line = Path()
        line.move(to: CGPoint(x: 420, y: 572))
        line.addQuadCurve(to: CGPoint(x: 604, y: 572), control: CGPoint(x: 512, y: 636))
        return line.strokedPath(StrokeStyle(lineWidth: 30, lineCap: .round))
    }()

    /// Sad: the smile flipped about its own middle (y 588) and dropped 18, i.e. y ↦ 1194 − y.
    static let frown = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1194)

    /// One colour with the eyes and mouth knocked out (build.py's glyph): ring pupils, an ink
    /// dot in each. `lids` squashes the eyes for a blink (1 open, 0 shut).
    static func glyph(lids: CGFloat, frown: Bool) -> Path {
        var holes = Path()
        var dots = Path()
        for c in pupils {
            let squash = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: 1, y: max(lids, 0.08))
                .translatedBy(x: -c.x, y: -c.y)
            holes.addPath(circle(c, pupil).applying(squash))
            dots.addPath(circle(CGPoint(x: c.x + 4, y: c.y + 4), 34).applying(squash))
        }
        holes.addPath(frown ? mouth.applying(Self.frown) : mouth)
        return silhouette.subtracting(holes).union(dots)
    }

    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
}

/// The mark as a Shape, fitted into any rect through `FrogMark.box`: the plain silhouette, or
/// the one-colour glyph for monochrome places (the thinking avatar).
struct FrogShape: Shape {
    enum Part { case silhouette, glyph }
    var part: Part
    /// 1 is open, 0 is shut (glyph only).
    var lids: CGFloat = 1
    /// Turn the smile down (glyph only).
    var frown = false

    var animatableData: CGFloat {
        get { lids }
        set { lids = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / FrogMark.box.width
        let fit = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: k, y: k)
            .translatedBy(x: -FrogMark.box.midX, y: -FrogMark.box.midY)
        let p = part == .silhouette ? FrogMark.silhouette : FrogMark.glyph(lids: lids, frown: frown)
        return p.applying(fit)
    }
}

// MARK: - Motion

/// A CSS-style 2D move: translate (grid units), scale and rotate (degrees), applied as
/// translate · rotate · scale about a pivot, like `transform: translate() scale()` with a
/// transform-origin.
struct Move: Equatable {
    var tx: CGFloat = 0, ty: CGFloat = 0
    var sx: CGFloat = 1, sy: CGFloat = 1
    var rotation: CGFloat = 0

    static let rest = Move()

    func matrix(about c: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: c.x + tx, y: c.y + ty)
            .rotated(by: rotation * .pi / 180)
            .scaledBy(x: sx, y: sy)
            .translatedBy(x: -c.x, y: -c.y)
    }

    func mix(_ to: Move, _ f: CGFloat) -> Move {
        func m(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * f }
        return Move(tx: m(tx, to.tx), ty: m(ty, to.ty), sx: m(sx, to.sx), sy: m(sy, to.sy),
                    rotation: m(rotation, to.rotation))
    }
}

/// A CSS cubic-bezier timing function.
struct Ease {
    var x1, y1, x2, y2: Double
    static let ease = Ease(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    static let inOut = Ease(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    static let out = Ease(x1: 0, y1: 0, x2: 0.58, y2: 1)

    func callAsFunction(_ x: Double) -> Double {
        func bez(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let s = (lo + hi) / 2
            if bez(s, x1, x2) < x { lo = s } else { hi = s }
        }
        return bez((lo + hi) / 2, y1, y2)
    }
}

/// A looping keyframe track: stops at fractions of `period`, each with the easing of the
/// segment that leaves it (CSS `animation-timing-function` per keyframe).
struct Track {
    var period: Double
    var alternate = false
    var stops: [(at: Double, move: Move, ease: Ease)]

    func at(_ t: Double) -> Move {
        let p = max(t, 0) / period
        var f = p.truncatingRemainder(dividingBy: 1)
        if alternate, Int(p) % 2 == 1 { f = 1 - f }
        guard let i = stops.lastIndex(where: { $0.at <= f }), i + 1 < stops.count else {
            return stops.last?.move ?? .rest
        }
        let a = stops[i], b = stops[i + 1]
        let local = b.at > a.at ? (f - a.at) / (b.at - a.at) : 1
        return a.move.mix(b.move, CGFloat(a.ease(local)))
    }
}

/// Where the body and the pupils are `t` seconds into a mood (anim.py's keyframes, grid units).
struct FrogPose {
    var body = Move.rest
    var eyes = Move.rest

    init(mood: FrogMood, t: Double, hop: Double? = nil) {
        switch mood {
        case .idle:
            body = Self.breathe.at(t)
            eyes = Self.blink(5).at(t)
        case .thinking:
            body = Self.breathe.at(t)
            eyes = Self.ponder.at(t)
        case .reading:
            eyes = Self.scan.at(t)
        case .working:
            body = Self.pump.at(t)
            eyes = Self.blink(3.3).at(t)
        case .done:
            body = Self.hop.at(t)
        case .waiting:
            body = Self.tilt.at(t)
            eyes = Self.wide.at(t)
        case .sad:
            body = Self.sink.at(t)
            eyes = Self.droop.at(t)
        }
        // A one-off hop (the empty-state frog when poked) plays the done hop once, over the mood.
        if let hop, hop >= 0, hop < Self.hop.period * 0.4 { body = Self.hop.at(hop) }
    }

    static let breathe = Track(period: 3.2, stops: [
        (0, .rest, .inOut), (0.5, Move(sx: 1.012, sy: 0.982), .inOut), (1, .rest, .inOut)])
    static let pump = Track(period: 1.1, stops: [
        (0, .rest, .inOut), (0.45, Move(sx: 1.05, sy: 0.94), .inOut), (1, .rest, .inOut)])
    static func blink(_ period: Double) -> Track {
        Track(period: period, stops: [
            (0, .rest, .ease), (0.92, .rest, .ease), (0.95, Move(sy: 0.08), .ease), (1, .rest, .ease)])
    }
    static let ponder = Track(period: 4, stops: [
        (0, Move(tx: 22, ty: -44, sy: 0.8), .inOut), (0.33, Move(tx: 44, ty: -30, sy: 0.8), .inOut),
        (0.66, Move(tx: -10, ty: -48, sy: 0.8), .inOut), (1, Move(tx: 22, ty: -44, sy: 0.8), .inOut)])
    static let scan = Track(period: 2.4, stops: [
        (0, Move(tx: -46, ty: 12), .ease), (0.25, Move(tx: -16, ty: 12), .ease),
        (0.5, Move(tx: 16, ty: 12), .ease), (0.75, Move(tx: 46, ty: 12), .ease),
        (0.88, Move(tx: -46, ty: 22), .ease), (1, Move(tx: -46, ty: 12), .ease)])
    static let hop = Track(period: 2.4, stops: [
        (0, .rest, .out),
        (0.08, Move(sx: 1.1, sy: 0.86), Ease(x1: 0.2, y1: 0.8, x2: 0.3, y2: 1)),
        (0.20, Move(ty: -120, sx: 0.94, sy: 1.08), Ease(x1: 0.6, y1: 0, x2: 0.8, y2: 0.4)),
        (0.31, Move(sx: 1.12, sy: 0.84), .out),
        (0.36, Move(sx: 0.98, sy: 1.02), .ease),
        (0.40, .rest, .out), (1, .rest, .out)])
    static let tilt = Track(period: 1.8, stops: [
        (0, Move(rotation: -7), .inOut), (0.5, Move(rotation: 7), .inOut), (1, Move(rotation: -7), .inOut)])
    static let wide = Track(period: 1.8, stops: [
        (0, Move(sx: 1.12, sy: 1.12), .inOut), (0.5, Move(sx: 1.04, sy: 1.04), .inOut),
        (1, Move(sx: 1.12, sy: 1.12), .inOut)])
    static let droop = Track(period: 3, alternate: true, stops: [
        (0, Move(ty: 14, sy: 0.5), .inOut), (1, Move(ty: 18, sy: 0.42), .inOut)])
    static let sink = Track(period: 3, alternate: true, stops: [
        (0, .rest, .inOut), (1, Move(ty: 12), .inOut)])
}

private extension Color {
    /// An sRGB colour from a 0xRRGGBB literal, for the locked mark palette.
    init(srgb hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
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
