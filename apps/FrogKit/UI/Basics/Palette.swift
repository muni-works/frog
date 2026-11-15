import SwiftUI

extension Color {
    /// Where a model runs, the one color rule (docs/models.md, "Place color"): cloud green for
    /// any cloud (Frog Cloud, Anthropic, OpenAI), local blue for this Mac, Apple's model and your
    /// paired nodes. Every model name, place tag and "where it runs" chip goes through here.
    static func place(_ place: ModelIdentity.Place) -> Color { place.isCloud ? Tokens.placeCloud : Tokens.placeLocal }

    /// The app mark's green, a little brighter in the dark (the Mac's accent color).
    static let frog = Color(light: (0.180, 0.620, 0.310), dark: (0.345, 0.800, 0.435))

    /// A color that follows the appearance. The Watch is always dark.
    init(light: (Double, Double, Double), dark: (Double, Double, Double)) {
        #if os(watchOS)
        self.init(red: dark.0, green: dark.1, blue: dark.2)
        #elseif os(macOS)
        self.init(nsColor: NSColor(name: nil) { a in
            let c = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }
}
