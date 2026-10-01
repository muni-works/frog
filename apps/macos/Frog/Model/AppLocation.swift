import AppKit

/// Where this copy of Frog runs from. Opened straight from the disk image or Downloads, macOS
/// runs it from a random read-only folder (App Translocation): updates can't replace it and a
/// command line link would break as soon as the image is ejected. So it asks to be moved, once
/// per launch, before anything else.
enum AppLocation {
    static var isTemporary: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    /// The release build only: dev builds run from DerivedData on purpose.
    static func checkOnLaunch() {
        guard Bundle.main.bundleIdentifier == "eco.frog", isTemporary else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Move Frog to Applications"
            alert.informativeText = "Frog is running from the disk image, so it can't update itself. Drag Frog into Applications, then open it from there."
            alert.addButton(withTitle: "Show Applications")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            NSApp.terminate(nil)
        }
    }
}
