import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum Platform {
    /// Whether the app is showing in dark mode right now.
    static var isDark: Bool {
        #if os(macOS)
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #else
        UITraitCollection.current.userInterfaceStyle == .dark
        #endif
    }

    /// Open a URL or file with the system: the default app on the Mac, a web page or app on iOS.
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

extension EnvironmentValues {
    /// The project folder, for resolving the relative paths the engine reports.
    @Entry var projectFolder: URL?
    /// Space the window's chrome takes over the canvas (the Mac's toolbar and sidebars).
    @Entry var canvasInsets = EdgeInsets()
    /// Frog's questions are pinned where you type (the phone), not shown in the turn.
    @Entry var pinsQuestions = false
}

#if !os(macOS)
extension View {
    /// A path shown in the UI: on the Mac, open, reveal, Quick Look and drag out (FileActions);
    /// on a phone, where the file isn't, its path to copy.
    func fileActions(_ path: String) -> some View {
        contextMenu {
            Button("Copy Path", systemImage: "doc.on.doc") { Clipboard.copy(path) }
        }
    }
}
#endif
