import SwiftUI
import CoreText

/// The shell's design tokens, so views read one palette, one type ramp and one set of radii
/// instead of picking their own. Same as the web app (docs/design/frog-web/README.md, "as
/// built"): dark is true black and surfaces step up from it (#0a0a0a sidebar, #121212 raised);
/// light is true white and they step down (#fafafa, #f4f4f4). No lines: hairlines are clear,
/// so things separate by fill. The Watch is always dark.
///
/// Rules that come with them: state color lives on glyphs only (a dot, a check, a hairline),
/// never on fills; numbers are tabular; the composer field is the only thing with a shadow.
enum Tokens {
    // MARK: surfaces

    /// The transcript and main area (#000 in the dark, #fff in the light; `FrogCanvas` is this on the Mac).
    static let canvas = Color(light: (1.0, 1.0, 1.0), dark: (0.0, 0.0, 0.0))
    /// The sidebar and inspector: opaque, one step off the canvas (#0a0a0a).
    static let sidebar = Color(light: (0.980, 0.980, 0.980), dark: (0.039, 0.039, 0.039))
    /// Bubbles, cards, the composer field, menus (#121212).
    static let raised = Color(light: (0.957, 0.957, 0.957), dark: (0.071, 0.071, 0.071))
    /// The prompt bubble: `raised` in the dark; a soft gray in the light, where white would
    /// vanish on a white phone background.
    static let bubble = Color(light: (0.957, 0.957, 0.957), dark: (0.071, 0.071, 0.071))

    // MARK: hairlines

    /// Dividers: clear now (no lines); kept so call sites still compile while they move to fills.
    static let hairline = Color(light: (0, 0, 0, 0), dark: (1, 1, 1, 0))
    /// Field strokes and controls: a faint 6% wash, for the few controls that still need an edge.
    static let hairlineStrong = Color(light: (0, 0, 0, 0.05), dark: (1, 1, 1, 0.06))

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

// MARK: - Type

/// IBM Plex, like the web app: Sans for words, Mono for code. Rounded stays SF, since
/// Plex has no rounded cut. Fonts ship in FrogKit/UI/Fonts and register on first use.
public extension Font {
    static func frog(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        guard design != .rounded, PlexFonts.registered else { return .frog(size: size, weight: weight, design: design) }
        return .custom(design == .monospaced ? "IBM Plex Mono" : "IBM Plex Sans", fixedSize: size).weight(weight)
    }
}

enum PlexFonts {
    static let registered: Bool = {
        let urls = ["IBMPlexSans", "IBMPlexMono-Regular", "IBMPlexMono-Medium"]
            .compactMap { Bundle.main.url(forResource: $0, withExtension: "ttf") }
        urls.forEach { CTFontManagerRegisterFontsForURL($0 as CFURL, .process, nil) }
        return !urls.isEmpty
    }()
}
