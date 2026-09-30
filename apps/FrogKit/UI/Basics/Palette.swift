import SwiftUI

extension Color {
    /// Where a model runs, as the Mac and phone color prompts and names: iMessage blue on your
    /// own hardware (this Mac, your server), green in the cloud.
    static func place(cloud: Bool) -> Color { cloud ? .green : .blue }

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
