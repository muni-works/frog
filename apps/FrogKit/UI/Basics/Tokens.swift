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
    /// Rails that nest content (quotes, tool output, the sidebar's started-by tree). Never a border.
    static let line = Color(light: (0.89, 0.89, 0.89, 1), dark: (0.165, 0.165, 0.165, 1))
    /// Primary text on the Mac (solid, same as fg).
    static let text = Color(light: (0.106, 0.114, 0.102, 1), dark: (0.925, 0.925, 0.925, 1))
    /// Secondary text on the Mac (solid, same as muted).
    static let textSecondary = Color(light: (0.369, 0.369, 0.369, 1), dark: (0.639, 0.639, 0.639, 1))
    /// Tertiary text on the Mac (solid, same as faint).
    static let textTertiary = Color(light: (0.463, 0.463, 0.463, 1), dark: (0.502, 0.502, 0.502, 1))
    /// Hints, the faintest meta (solid, same as faint).
    static let textQuaternary = Color(light: (0.502, 0.502, 0.502, 1), dark: (0.502, 0.502, 0.502, 1))
    /// THE accent: running, selected, verified, send. The only decorative color.
    static let accent = Color(light: (0.18, 0.62, 0.31, 1), dark: (0.345, 0.8, 0.435, 1))
    /// Needs-you on the Mac (amber). Deprecated; use notice instead.
    static let signal = Color(light: (0.8, 0.522, 0.122, 1), dark: (0.898, 0.647, 0.294, 1))
    /// Failed on the Mac. Deprecated; use warn instead.
    static let fail = Color(light: (0.851, 0.251, 0.231, 1), dark: (1.0, 0.412, 0.38, 1))
    /// Failed, removed, over a limit (reddish-orange). The Mac's failure rows move here from fail.
    static let warn = Color(light: (0.769, 0.318, 0.239, 1), dark: (0.898, 0.467, 0.373, 1))
    /// Where a model runs: local (this Mac or a paired node). Blue, the same lightness as the green beside it; 4.3:1 on white, 8.3:1 on black (the green is 3.4:1 and 10:1). Only through placeColor / Color.place(_:).
    static let placeLocal = Color(light: (0.204, 0.471, 0.878, 1), dark: (0.392, 0.643, 1.0, 1))
    /// Where a model runs: any cloud (Frog Cloud, Anthropic, OpenAI). Frog green, the accent. Only through placeColor / Color.place(_:).
    static let placeCloud = Color(light: (0.18, 0.62, 0.31, 1), dark: (0.345, 0.8, 0.435, 1))
    /// A PR's dot (pr.*): checks failing. Worst first: failing > checks > draft > approved > closed > merged. Only through prColor / Color.pr(_:).
    static let prFailing = Color(light: (0.851, 0.251, 0.231, 1), dark: (0.898, 0.467, 0.373, 1))
    /// A PR's dot: checks running.
    static let prChecks = Color(light: (0.8, 0.522, 0.122, 1), dark: (1.0, 0.624, 0.039, 1))
    /// A PR's dot: a draft.
    static let prDraft = Color(light: (0.541, 0.541, 0.541, 1), dark: (0.557, 0.557, 0.557, 1))
    /// A PR's dot: approved and mergeable.
    static let prApproved = Color(light: (0.18, 0.62, 0.31, 1), dark: (0.345, 0.8, 0.435, 1))
    /// A PR's dot: closed without merging.
    static let prClosed = Color(light: (0.69, 0.29, 0.235, 1), dark: (0.788, 0.439, 0.373, 1))
    /// A PR's dot: merged.
    static let prMerged = Color(light: (0.51, 0.314, 0.875, 1), dark: (0.659, 0.529, 0.941, 1))

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
