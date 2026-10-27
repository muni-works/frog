import SwiftUI

/// The shell's design tokens: the premium redesign's c.0 block as constants, so views read one
/// palette, one type ramp and one set of radii instead of picking their own. Dark values are the
/// spec's (Claude Code Desktop's calm near-black); light values are their mirror on the light
/// canvas. The Watch is always dark.
///
/// Rules that come with them: state color lives on glyphs only (a dot, a check, a hairline),
/// never on fills; numbers are tabular; the composer field is the only thing with a shadow.
enum Tokens {
    // MARK: surfaces

    /// The transcript and main area (#191919 in the dark; `FrogCanvas` is this on the Mac).
    static let canvas = Color(light: (0.955, 0.955, 0.955), dark: (0.098, 0.098, 0.098))
    /// The sidebar: opaque, one step darker than the canvas (#141414).
    static let sidebar = Color(light: (0.925, 0.925, 0.925), dark: (0.078, 0.078, 0.078))
    /// Bubbles, cards, the composer field, menus (#232323).
    static let raised = Color(light: (1.0, 1.0, 1.0), dark: (0.137, 0.137, 0.137))

    // MARK: hairlines

    /// Dividers (white .065 in the dark).
    static let hairline = Color(light: (0, 0, 0, 0.08), dark: (1, 1, 1, 0.065))
    /// Field strokes and controls (white .11 in the dark).
    static let hairlineStrong = Color(light: (0, 0, 0, 0.13), dark: (1, 1, 1, 0.11))

    // MARK: text

    /// Primary text (#ececec).
    static let text = Color(light: (0.10, 0.10, 0.10, 1), dark: (0.925, 0.925, 0.925, 1))
    /// Secondary text (.58).
    static let textSecondary = Color(light: (0.10, 0.10, 0.10, 0.62), dark: (0.925, 0.925, 0.925, 0.58))
    /// Tertiary text (.34).
    static let textTertiary = Color(light: (0.10, 0.10, 0.10, 0.42), dark: (0.925, 0.925, 0.925, 0.34))
    /// Quaternary text (.2): hints, the faintest meta.
    static let textQuaternary = Color(light: (0.10, 0.10, 0.10, 0.28), dark: (0.925, 0.925, 0.925, 0.2))

    // MARK: state

    /// THE accent (#58cc6f): running, selected, verified, send. The only decorative color.
    static let accent = Color.frog
    /// Needs-you only (#e5a54b), never decoration.
    static let signal = Color(light: (0.800, 0.520, 0.120), dark: (0.898, 0.647, 0.294))
    /// Failed only (#ff6961).
    static let fail = Color(light: (0.850, 0.250, 0.230), dark: (1.0, 0.412, 0.380))

    // MARK: type ramp (five steps, no half-steps between them)

    enum Size {
        /// Body text: prose, prompts.
        static let body: CGFloat = 14
        /// Secondary UI: sidebar rows, controls.
        static let secondary: CGFloat = 13
        /// Status rows: the activity lines.
        static let status: CGFloat = 12.5
        /// Meta: ages, footers, hints.
        static let meta: CGFloat = 11.5
        /// Small-caps labels (QUEUED, section heads).
        static let label: CGFloat = 10.5
    }

    // MARK: radii

    enum Radius {
        /// The composer field.
        static let field: CGFloat = 16
        /// Window chrome.
        static let chrome: CGFloat = 14
        /// Cards.
        static let card: CGFloat = 12
        /// The prompt bubble.
        static let bubble: CGFloat = 16
        /// Controls: rows, pills, selection.
        static let control: CGFloat = 7
    }

    // MARK: motion

    /// The one status pulse: a slow breathe for live dots (Motion.swift keeps the springs).
    static let pulse = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)
}

extension Color {
    /// A translucent color that follows the appearance (components 0...1, alpha last).
    init(light: (Double, Double, Double, Double), dark: (Double, Double, Double, Double)) {
        #if os(watchOS)
        self.init(red: dark.0, green: dark.1, blue: dark.2, opacity: dark.3)
        #elseif os(macOS)
        self.init(nsColor: NSColor(name: nil) { a in
            let c = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
        #else
        self.init(uiColor: UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
        #endif
    }
}
