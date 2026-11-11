import AppKit

/// `-FrogSnapshot <path.png>` (with optional `-FrogSnapshotDelay <seconds>`, default 10) renders
/// the main window, title bar included, to a PNG and quits. A process may capture its own
/// windows, so the parity harness needs no Screen Recording permission (`docs/design/parity/capture.sh`).
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
        // The window server's picture of our own window first: it has everything (glass, the
        // table-backed transcript, which `cacheDisplay` drew blank once a card was up), and a
        // process may always capture its own windows, so no Screen Recording.
        let rep = windowServerImage(window).map(NSBitmapImageRep.init(cgImage:)) ?? {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }()
        guard let rep, let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// `CGWindowListCreateImage` for one window, looked up at runtime: the SDK marks it
    /// unavailable, but it still captures the caller's own windows without a permission prompt.
    private static func windowServerImage(_ window: NSWindow) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(sym, to: Fn.self)
        // .optionIncludingWindow, .boundsIgnoreFraming | .bestResolution
        return create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }
}
