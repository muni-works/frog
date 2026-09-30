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
    /// Recently revealed runs, fading from green to ink.
    private var inked: [(range: NSRange, at: CFTimeInterval)] = []
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

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
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
        if reduceMotion { revealed = length }
        revealed = min(revealed, length)
        inked.removeAll { $0.range.location >= length }
        style(now: CACurrentMediaTime())
        schedule()
    }

    func windowChanged() {
        if view.window == nil {
            stop()
        } else {
            schedule()
        }
    }

    /// Code blocks are views of their own: they appear when the pen reaches them.
    func codeVisible(at location: Int) -> Bool { location < revealed }

    // MARK: Clock

    private func schedule() {
        let pending = revealed < length || !inked.isEmpty || (streaming && !reduceMotion)
        guard pending, view.window != nil, !reduceMotion else {
            if !pending || reduceMotion { finish() }
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
        style(now: now)
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
        inked.append((NSRange(location: start, length: target - start), now))
        // A breath after a sentence or paragraph, when the model isn't far ahead.
        if streaming, total - target < 24, target >= 2 {
            let prev = text.character(at: target - 2)
            if [".", "!", "?", ":"].contains(Character(UnicodeScalar(prev) ?? " ")) || text.character(at: target - 1) == 10 {
                holdUntil = now + 0.09
            }
        }
    }

    // MARK: Styling

    private func style(now: CFTimeInterval) {
        guard let layout = view.layoutManager, let storage = view.textStorage else { return }
        let total = storage.length
        inked.removeAll { now - $0.at >= Self.inkTime }
        let from = min(styledFrom, inked.first?.range.location ?? revealed, revealed, total)
        if from < total {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: from, length: total - from))
        }
        styledFrom = Int.max
        // Not yet revealed: laid out, but drawn clear.
        if revealed < total {
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.clear,
                                         forCharacterRange: NSRange(location: revealed, length: total - revealed))
            styledFrom = revealed
        }
        // Newly revealed: green, faint, settling into each run's own color.
        let accent = NSColor(named: "AccentColor") ?? .controlAccentColor
        for ink in inked {
            let range = NSIntersectionRange(ink.range, NSRange(location: 0, length: total))
            guard range.length > 0 else { continue }
            let t = Self.ease((now - ink.at) / Self.inkTime)
            storage.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
                let own = (value as? NSColor) ?? .labelColor
                let color = accent.blended(withFraction: t, of: own) ?? own
                layout.addTemporaryAttribute(.foregroundColor, value: color.withAlphaComponent(own.alphaComponent * (0.2 + 0.8 * t)),
                                             forCharacterRange: sub)
            }
            styledFrom = min(styledFrom, range.location)
        }
        view.syncCodeVisibility()
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
