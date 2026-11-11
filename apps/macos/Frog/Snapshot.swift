import AppKit

/// `-FrogSnapshot <path.png>` (with optional `-FrogSnapshotDelay <seconds>`, default 10) renders
/// the main window, title bar included, to a PNG and quits. The app draws itself, so the parity
/// harness needs no Screen Recording permission (`docs/design/parity/capture.sh`).
@MainActor
enum Snapshot {
    static func scheduleIfAsked() {
        guard let path = UserDefaults.standard.string(forKey: "FrogSnapshot"), !path.isEmpty else { return }
        let delay = UserDefaults.standard.double(forKey: "FrogSnapshotDelay")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 10))
            let ok = write(to: URL(fileURLWithPath: path))
            if !ok { FileHandle.standardError.write(Data("FrogSnapshot: no window to draw\n".utf8)) }
            exit(ok ? 0 : 1)
        }
    }

    /// The frontmost real window (not a panel or the status item), drawn by its frame view.
    static func write(to url: URL) -> Bool {
        let windows = NSApp.orderedWindows.filter { $0.isVisible && !($0 is NSPanel) && $0.frame.width > 200 }
        guard let window = windows.first ?? NSApp.mainWindow,
              let view = window.contentView?.superview ?? window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
