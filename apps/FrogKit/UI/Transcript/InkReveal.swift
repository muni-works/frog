#if os(macOS)
import AppKit
import QuartzCore

/// An answer that writes itself: words appear at a reading pace, on the display's clock rather
/// than the network's, and each one inks in, starting in frog green and settling into its own
/// color, behind a soft pen at the end of the text.
///
/// Nothing here lays text out. Everything that has arrived is already in the text view, laid
/// out once as it arrives; what hasn't been revealed yet is drawn clear with a TextKit temporary
/// attribute, and each frame only restyles the few dozen characters around the pen. Under
/// Reduce Motion text simply appears as it arrives.
@MainActor
final class InkReveal: NSObject {
    private unowned let view: MessageTextView
    /// Characters of the text storage shown so far.
    private(set) var revealed = 0
    /// Recently revealed runs, fading from green to ink, each with the fade step it was last
    /// drawn at (-1: not yet), so a frame only restyles runs whose color has moved.
    private var inked: [(range: NSRange, at: CFTimeInterval, step: Int)] = []
    /// Recent arrivals (time, length), for the stream's rate.
    private var arrivals: [(at: CFTimeInterval, length: Int)] = []
    /// The stream is too fast for the ink to show: text simply appears, as under Reduce Motion.
    private var instant = false
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    /// Fractional characters owed from earlier frames.
    private var carry = 0.0
    /// A short breath after a sentence, while there's little waiting.
    private var holdUntil: CFTimeInterval = 0
    private let pen = CALayer()
    private var penShown = false
    /// Styled on the last frame, so this one can clear it: the ink window and the hidden tail.
    private var styledFrom = Int.max
    private var started = false

    var streaming = false {
        didSet { if streaming != oldValue { schedule() } }
    }

    /// How long a word takes to settle from green into its own color.
    private static let inkTime = 0.42
    /// How far behind arrival the pen may run while streaming, and after (a quick catch-up).
    private static let lagStreaming = 0.32
    private static let lagDone = 0.1
    /// The slowest pace, in characters a second: about reading speed.
    private static let minRate = 42.0
    /// Fade steps from green to ink: a run is restyled only when it crosses one.
    private static let fadeSteps = 10
    /// Runs fading at once; older ones settle early. ~30 frames' worth at 60 Hz.
    private static let maxRuns = 30
    /// Above this arrival rate (characters a second, ~300 tokens/s) the pen reveals several
    /// words a frame and the ink window spans most of the view: the fade can't be seen, only
    /// paid for. Text just appears until the stream slows below `slowRate`.
    private static let fastRate = 1200.0
    private static let slowRate = 600.0

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Text appears as it arrives: Reduce Motion, or a stream too fast to ink.
    private var plain: Bool { reduceMotion || instant || Self.off }
    /// For the perf probe: what streaming costs without the ink (as under Reduce Motion).
    nonisolated(unsafe) static var off = false
    private var length: Int { view.textStorage?.length ?? 0 }

    init(view: MessageTextView) {
        self.view = view
        super.init()
        pen.cornerRadius = 1.5
        pen.opacity = 0
        pen.actions = ["position": NSNull(), "bounds": NSNull()]
    }

    // MARK: Events from the view

    /// The storage changed (new text arrived, or the tail was re-parsed).
    func textChanged() {
        if !started {
            started = true
            // A finished message, or one this view picks up halfway (scrolled back into view,
            // reopened), is simply there.
            if !streaming || reduceMotion || length > 600 { revealed = length }
        }
        let now = CACurrentMediaTime()
        measureRate(now: now)
        if plain {
            revealed = length
            // Nothing hidden or fading: no restyling to do, and the clock stops (in `schedule`).
            if inked.isEmpty, styledFrom == Int.max { return schedule() }
        }
        revealed = min(revealed, length)
        inked.removeAll { $0.range.location >= length }
        style(now: now)
        schedule()
    }

    /// How fast text is arriving, over the last half second; switches `instant` with some
    /// hysteresis so a stream near the line doesn't flicker between the two.
    private func measureRate(now: CFTimeInterval) {
        guard streaming else { instant = false; arrivals.removeAll(); return }
        let total = length
        if let last = arrivals.last, total < last.length { arrivals.removeAll() }
        arrivals.append((now, total))
        arrivals.removeAll { now - $0.at > 0.5 }
        guard let first = arrivals.first, arrivals.count > 1 else { return }
        let rate = Double(total - first.length) / max(now - first.at, 0.05)
        if !instant, rate > Self.fastRate { instant = true }
        else if instant, rate < Self.slowRate { instant = false }
    }

    func windowChanged() {
        if view.window == nil {
            stop()
        } else {
            schedule()
        }
    }

    /// The height of the revealed text (to the bottom of the pen's line), or nil once it's all
    /// shown and the view is simply as tall as its text.
    func writtenHeight() -> CGFloat? {
        guard revealed < length, let layout = view.layoutManager else { return nil }
        guard revealed > 0 else { return 0 }
        let glyph = layout.glyphIndexForCharacter(at: revealed - 1)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        // On the last line there's nothing hidden below: the full height, so the view doesn't
        // flicker between the two as the pen catches up with the text and falls behind again.
        let last = layout.lineFragmentRect(forGlyphAt: max(0, layout.numberOfGlyphs - 1), effectiveRange: nil)
        return line.minY >= last.minY ? nil : line.maxY
    }

    /// The bottom of the pen's line last frame: when it moves, the view grows (a line at a time).
    private var lastWritten: CGFloat = -1

    private func grewIfNeeded() {
        let h = writtenHeight() ?? .greatestFiniteMagnitude
        guard h != lastWritten else { return }
        lastWritten = h
        view.sizeChanged()
    }

    /// Code blocks are views of their own: they appear when the pen reaches them.
    func codeVisible(at location: Int) -> Bool { location < revealed }

    // MARK: Clock

    private func schedule() {
        let pending = revealed < length || !inked.isEmpty || (streaming && !plain)
        guard pending, view.window != nil, !plain else {
            if !pending || plain { finish() }
            return
        }
        guard link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        last = CACurrentMediaTime()
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    /// Everything shown and settled: stop the clock, clear the styling, let the pen go.
    private func finish() {
        stop()
        revealed = length
        inked.removeAll()
        style(now: CACurrentMediaTime())
        grewIfNeeded()
        hidePen()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = min(max(now - last, 0), 1.0 / 20)
        last = now
        let total = length
        if revealed < total, now >= holdUntil || !streaming {
            advance(by: dt, total: total, now: now)
        }
        styleFrame(now: now)
        grewIfNeeded()
        if revealed >= total, inked.isEmpty, !streaming {
            finish()
        } else {
            placePen(now: now, waiting: revealed >= total)
        }
    }

    /// Move the pen on: fast enough to stay within a fraction of a second of arrival, never
    /// slower than reading pace, a whole word at a time.
    private func advance(by dt: Double, total: Int, now: CFTimeInterval) {
        let backlog = Double(total - revealed)
        let rate = max(Self.minRate, backlog / (streaming ? Self.lagStreaming : Self.lagDone))
        carry += rate * dt
        guard carry >= 1, let text = view.textStorage?.string as NSString? else { return }
        var target = min(total, revealed + Int(carry))
        carry -= Double(target - revealed)
        // Finish the word the target landed in.
        while target < total, let c = UnicodeScalar(text.character(at: target - 1)), !CharacterSet.whitespacesAndNewlines.contains(c) {
            target += 1
        }
        let start = revealed
        revealed = target
        inked.append((NSRange(location: start, length: target - start), now, -1))
        // A breath after a sentence or paragraph, when the model isn't far ahead.
        if streaming, total - target < 24, target >= 2 {
            let prev = text.character(at: target - 2)
            if [".", "!", "?", ":"].contains(Character(UnicodeScalar(prev) ?? " ")) || text.character(at: target - 1) == 10 {
                holdUntil = now + 0.09
            }
        }
    }

    // MARK: Styling

    /// Everything from the oldest fading run to the end, again: for when the storage changed
    /// (new text to hide, or a re-parsed tail whose temporary attributes can't be trusted).
    private func style(now: CFTimeInterval) {
        guard let layout = view.layoutManager, let storage = view.textStorage else { return }
        let total = storage.length
        settle(now: now)
        let from = min(styledFrom, inked.first?.range.location ?? revealed, revealed, total)
        if from < total {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: from, length: total - from))
            #if DEBUG
            TranscriptProbe.inkStyles += 1
            TranscriptProbe.inkStyledChars += total - from
            #endif
        }
        styledFrom = Int.max
        // Not yet revealed: laid out, but drawn clear.
        if revealed < total {
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.clear,
                                         forCharacterRange: NSRange(location: revealed, length: total - revealed))
            styledFrom = revealed
        }
        for i in inked.indices { paint(i, now: now) }
        view.syncCodeVisibility()
    }

    /// One frame: only what moved. The newly revealed run (drawn over its clear), runs whose
    /// fade crossed a step, and runs that have settled (back to their own color). The hidden
    /// tail keeps the clear it was given when it arrived.
    private func styleFrame(now: CFTimeInterval) {
        guard let layout = view.layoutManager, let storage = view.textStorage else { return }
        let total = storage.length
        for range in settle(now: now) {
            let r = NSIntersectionRange(range, NSRange(location: 0, length: total))
            if r.length > 0 { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r) }
        }
        var touched = false
        for i in inked.indices where inked[i].step != Self.step(now - inked[i].at) {
            paint(i, now: now)
            touched = true
        }
        if touched { view.syncCodeVisibility() }
    }

    /// Drops runs that have finished fading, and the oldest past `maxRuns`; returns their ranges.
    @discardableResult
    private func settle(now: CFTimeInterval) -> [NSRange] {
        var done: [NSRange] = []
        inked.removeAll { run in
            guard now - run.at >= Self.inkTime else { return false }
            done.append(run.range)
            return true
        }
        if inked.count > Self.maxRuns {
            done += inked.prefix(inked.count - Self.maxRuns).map(\.range)
            inked.removeFirst(inked.count - Self.maxRuns)
        }
        return done
    }

    /// Looked up once: `NSColor(named:)` on every painted run was a visible slice of streaming.
    private static let accent = NSColor(named: "AccentColor") ?? .controlAccentColor

    private static func step(_ age: Double) -> Int {
        min(fadeSteps, Int((age / inkTime) * Double(fadeSteps)))
    }

    /// Newly revealed: green, faint, settling into the run's own color, at its fade step.
    private func paint(_ i: Int, now: CFTimeInterval) {
        guard let layout = view.layoutManager, let storage = view.textStorage else { return }
        let range = NSIntersectionRange(inked[i].range, NSRange(location: 0, length: storage.length))
        let step = Self.step(now - inked[i].at)
        inked[i].step = step
        guard range.length > 0 else { return }
        let accent = Self.accent
        let t = Self.ease(Double(step) / Double(Self.fadeSteps))
        storage.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
            let own = (value as? NSColor) ?? .labelColor
            let color = accent.blended(withFraction: t, of: own) ?? own
            layout.addTemporaryAttribute(.foregroundColor, value: color.withAlphaComponent(own.alphaComponent * (0.2 + 0.8 * t)),
                                         forCharacterRange: sub)
        }
        styledFrom = min(styledFrom, range.location)
        #if DEBUG
        TranscriptProbe.inkStyles += 1
        TranscriptProbe.inkStyledChars += range.length
        #endif
    }

    private static func ease(_ t: Double) -> CGFloat {
        let x = min(max(t, 0), 1)
        return CGFloat(1 - pow(1 - x, 3))
    }

    // MARK: Pen

    /// A soft green mark where the writing is; it breathes while the model thinks mid-answer.
    private func placePen(now: CFTimeInterval, waiting: Bool) {
        guard streaming || revealed < length, revealed > 0, let layout = view.layoutManager,
              let container = view.textContainer else { return hidePen() }
        if pen.superlayer == nil {
            view.wantsLayer = true
            view.layer?.addSublayer(pen)
        }
        pen.backgroundColor = (NSColor(named: "AccentColor") ?? .controlAccentColor).cgColor
        // Just past a code block (one attachment character, as tall as the block): no pen until
        // the next words, rather than a bar the height of the code.
        if let text = view.textStorage?.string as NSString?, text.character(at: revealed - 1) == 0xFFFC {
            return hidePen()
        }
        let glyph = layout.glyphIndexForCharacter(at: max(0, revealed - 1))
        var rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        // A newline's box sits at the start of the next line: keep the pen after the last word.
        if let text = view.textStorage?.string as NSString?, revealed > 0, text.character(at: revealed - 1) == 10, revealed >= 2 {
            let before = layout.glyphIndexForCharacter(at: revealed - 2)
            rect = layout.boundingRect(forGlyphRange: NSRange(location: before, length: 1), in: container)
        }
        let origin = view.textContainerOrigin
        let height = max(10, rect.height * 0.72)
        pen.frame = CGRect(x: origin.x + rect.maxX + 3, y: origin.y + rect.midY - height / 2, width: 3, height: height)
        let breathe = waiting ? 0.35 + 0.65 * (0.5 + 0.5 * cos(now * 4.2)) : 1
        pen.opacity = Float(breathe)
        penShown = true
    }

    private func hidePen() {
        guard penShown else { return }
        penShown = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = pen.opacity
        fade.toValue = 0
        fade.duration = 0.3
        pen.add(fade, forKey: "dissolve")
        pen.opacity = 0
    }
}
#endif
