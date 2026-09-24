import AppKit

/// Code editors frog can hand a file to, detected by bundle ID.
struct Editor: Identifiable, Hashable {
    let id: String   // bundle ID
    let name: String

    static let known: [Editor] = [
        Editor(id: "com.apple.dt.Xcode", name: "Xcode"),
        Editor(id: "com.microsoft.VSCode", name: "Visual Studio Code"),
        Editor(id: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        Editor(id: "dev.zed.Zed", name: "Zed"),
        Editor(id: "com.sublimetext.4", name: "Sublime Text"),
        Editor(id: "com.panic.Nova", name: "Nova"),
        Editor(id: "com.jetbrains.intellij", name: "IntelliJ IDEA"),
    ]

    static var installed: [Editor] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    /// The editor chosen in Settings, else the first one installed.
    static var preferred: Editor? {
        let chosen = UserDefaults.standard.string(forKey: "editor")
        return installed.first { $0.id == chosen } ?? installed.first
    }

    var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Open files in the preferred editor, or the system default app if there isn't one.
    static func open(_ urls: [URL]) {
        guard let editor = preferred,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.id) else {
            urls.forEach { NSWorkspace.shared.open($0) }
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
