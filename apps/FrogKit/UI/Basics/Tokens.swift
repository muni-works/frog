// generated from design/tokens.json by design/generate.mjs; edit the JSON, not this file.
import SwiftUI
import CoreText

/// The shell's design tokens, so views read one palette, one type ramp and one set of radii
/// instead of picking their own. The web app's tokens.css comes from the same JSON
/// (docs/design/frog-web/README.md, "One look"): dark is true black and surfaces step up from it
/// (#0a0a0a sidebar, #121212 raised, #1a1a1a wells); light is true white and they step down
/// (#fafafa, #f4f4f4, #ececec). No lines: things separate by fill. The Watch is always dark.
///
/// Rules that come with them: state color lives on glyphs only (a dot, a check, a hairline),
/// never on fills; numbers are tabular; the composer field is the only thing with a shadow.
enum Tokens {
    /// The page: the transcript and main area. True black in the dark, true white in the light.
    static let canvas = Color(light: (1.0, 1.0, 1.0, 1), dark: (0.0, 0.0, 0.0, 1))
    /// The sidebar and inspector: opaque, one step off the canvas.
    static let sidebar = Color(light: (0.98, 0.98, 0.98, 1), dark: (0.039, 0.039, 0.039, 1))
    /// Cards, bubbles, the composer field, menus.
    static let raised = Color(light: (0.957, 0.957, 0.957, 1), dark: (0.071, 0.071, 0.071, 1))
    /// The prompt bubble: the same fill as cards.
    static let bubble = Color(light: (0.957, 0.957, 0.957, 1), dark: (0.071, 0.071, 0.071, 1))
    /// Wells inside a card: code, fields, the command in an ask card.
    static let well = Color(light: (0.925, 0.925, 0.925, 1), dark: (0.102, 0.102, 0.102, 1))
    /// One quiet fill for a row under the pointer and the row you're on.
    static let hover = Color(light: (0.0, 0.0, 0.0, 0.05), dark: (1.0, 1.0, 1.0, 0.07))
    /// Dividers: clear (no lines); kept so call sites still compile while they move to fills.
    static let hairline = Color(light: (0.0, 0.0, 0.0, 0), dark: (1.0, 1.0, 1.0, 0))
    /// Field strokes: a faint wash, for the few controls that still need an edge.
    static let hairlineStrong = Color(light: (0.0, 0.0, 0.0, 0.05), dark: (1.0, 1.0, 1.0, 0.06))
    /// Primary text on the Mac.
    static let text = Color(light: (0.102, 0.102, 0.102, 1), dark: (0.925, 0.925, 0.925, 1))
    /// Secondary text on the Mac.
    static let textSecondary = Color(light: (0.102, 0.102, 0.102, 0.62), dark: (0.925, 0.925, 0.925, 0.58))
    /// Tertiary text on the Mac.
    static let textTertiary = Color(light: (0.102, 0.102, 0.102, 0.42), dark: (0.925, 0.925, 0.925, 0.34))
    /// Hints, the faintest meta.
    static let textQuaternary = Color(light: (0.102, 0.102, 0.102, 0.28), dark: (0.925, 0.925, 0.925, 0.2))
    /// THE accent: running, selected, verified, send. The only decorative color.
    static let accent = Color(light: (0.18, 0.62, 0.31, 1), dark: (0.345, 0.8, 0.435, 1))
    /// Needs-you on the Mac, never decoration. (Web: notice; to converge.)
    static let signal = Color(light: (0.8, 0.522, 0.122, 1), dark: (0.898, 0.647, 0.294, 1))
    /// Failed on the Mac. (Web: warn; to converge.)
    static let fail = Color(light: (0.851, 0.251, 0.231, 1), dark: (1.0, 0.412, 0.38, 1))

    /// Type ramp: five steps, no half-steps between them.
    enum Size {
        /// Body text: prose, prompts.
        static let body: CGFloat = 14
        /// Secondary UI: sidebar rows, controls.
        static let secondary: CGFloat = 13
        /// Status rows: the activity lines.
        static let status: CGFloat = 12.5
        /// Meta: footers, hints.
        static let meta: CGFloat = 11.5
        /// Small-caps labels (QUEUED, section heads).
        static let label: CGFloat = 10.5
    }

    enum Radius {
        /// Controls: rows, pills, selection.
        static let control: CGFloat = 7
        /// Cards, and the inset sidebar panel.
        static let card: CGFloat = 12
        /// Window chrome.
        static let chrome: CGFloat = 14
        /// The composer field.
        static let field: CGFloat = 16
        /// The prompt bubble.
        static let bubble: CGFloat = 16
    }

    enum Space {
        /// Row padding, and the inset sidebar panel's margin.
        static let row: CGFloat = 8
    }

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
        guard design != .rounded, PlexFonts.registered else { return .system(size: size, weight: weight, design: design) }
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
