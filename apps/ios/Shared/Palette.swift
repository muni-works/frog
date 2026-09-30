import SwiftUI

extension Color {
    /// The app mark's green, a little brighter in the dark (as the Mac's accent color).
    static let frog = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.345, green: 0.800, blue: 0.435, alpha: 1)
            : UIColor(red: 0.180, green: 0.620, blue: 0.310, alpha: 1)
    })

    /// The Mac's bubble colors: blue when the model runs on your hardware, green in the cloud.
    static let imessageBlue = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let imessageGreen = Color(red: 0.19, green: 0.78, blue: 0.35)
}

/// Stand-ins for the Mac-only helpers that the shared protocol file refers to.
enum Frog {
    static func isChat(_ url: URL) -> Bool { url.path.hasSuffix("/.local/share/frog/chat") }
}
