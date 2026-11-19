import AppKit

/// `-FrogSnapshot <path.png>` (with optional `-FrogSnapshotDelay <seconds>`, default 10) renders
/// the main window, title bar included, to a PNG and quits. A process may capture its own
/// windows, so the parity harness needs no Screen Recording permission (`docs/design/parity/capture.sh`).
///
/// `-FrogMetrics <path.json>` (with or without a snapshot, same delay) writes the transcript's
/// rows as `frog-transcript-metrics/1` (docs/design/parity/README.md, "Metrics") and quits.
///
/// `-FrogChromeMetrics <path.json>` writes the window chrome's controls (`ChromeMetrics`).
@MainActor
enum Snapshot {
    static func scheduleIfAsked() {
        let path = UserDefaults.standard.string(forKey: "FrogSnapshot") ?? ""
        let metrics = UserDefaults.standard.string(forKey: "FrogMetrics") ?? ""
        let chrome = UserDefaults.standard.string(forKey: "FrogChromeMetrics") ?? ""
        let edges = UserDefaults.standard.string(forKey: "FrogEdges") ?? ""
        guard !path.isEmpty || !metrics.isEmpty || !chrome.isEmpty || !edges.isEmpty else { return }
        // A capture shows text as it lands: the ink runs on the display, which an off-screen
        // window doesn't get, so a reply would stay unwritten (and short) in the picture.
        InkReveal.off = true
        let delay = UserDefaults.standard.double(forKey: "FrogSnapshotDelay")
        Task { @MainActor in
            // `-FrogSnapshotSize 520x760` (points): the window at that size, set early so the
            // transcript lays out at it before the capture (the parity fuzz's narrow pass).
            if let size = UserDefaults.standard.string(forKey: "FrogSnapshotSize") {
                try? await Task.sleep(for: .seconds(1))
                resize(to: size)
            }
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 10))
            var ok = true
            if !metrics.isEmpty {
                ok = writeMetrics(to: URL(fileURLWithPath: metrics))
                if !ok {
                    let seen = NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) \($0.frame)" }.joined(separator: "; ")
                    FileHandle.standardError.write(Data("FrogMetrics: no window to measure (\(seen))\n".utf8))
                }
            }
            if !chrome.isEmpty {
                let measured = mainWindow.map { ChromeMetrics.write(to: URL(fileURLWithPath: chrome), window: $0) } ?? false
                if !measured { FileHandle.standardError.write(Data("FrogChromeMetrics: no accessibility window to measure\n".utf8)) }
                ok = ok && measured
            }
            if !edges.isEmpty, let window = mainWindow {
                window.contentView?.layoutSubtreeIfNeeded()
                let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let data = TranscriptMetrics.shared.edgesJSON(width: window.frame.width, height: window.frame.height, look: dark ? "dark" : "light")
                ok = ok && (try? data.write(to: URL(fileURLWithPath: edges))) != nil
            }
            if !path.isEmpty {
                let drawn = write(to: URL(fileURLWithPath: path))
                if !drawn { FileHandle.standardError.write(Data("FrogSnapshot: no window to draw\n".utf8)) }
                ok = ok && drawn
            }
            exit(ok ? 0 : 1)
        }
    }

    private static func resize(to spec: String) {
        let parts = spec.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window = mainWindow else { return }
        window.minSize = NSSize(width: min(window.minSize.width, parts[0]), height: min(window.minSize.height, parts[1]))
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: parts[0], height: parts[1])), display: true)
    }

    /// The transcript's rows, as the parity metrics read them.
    static func writeMetrics(to url: URL) -> Bool {
        guard let window = mainWindow else { return false }
        window.contentView?.layoutSubtreeIfNeeded()
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let data = TranscriptMetrics.shared.json(width: window.frame.width, height: window.frame.height, look: dark ? "dark" : "light")
        return (try? data.write(to: url)) != nil
    }

    /// `-FrogOffscreen YES`: windows are parked off every screen as soon as they show, so a
    /// capture run on the Mac someone is using never covers their work (launch it with
    /// `open -g`, which never activates it). The window server still draws them, so the PNG
    /// and the metrics come out the same.
    static func stayInBackground() {
        let center = NotificationCenter.default
        for name in [NSWindow.didUpdateNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    for window in NSApp.windows where window.isVisible && window.frame.minX > -20_000 {
                        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
                    }
                }
            }
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.orderedWindows.first { $0.isVisible && !($0 is NSPanel) && $0.frame.width > 200 } ?? NSApp.mainWindow
            // An accessory app parked off-screen (`-FrogOffscreen`) has no main window.
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.frame.width > 200 }
    }

    /// The frontmost real window (not a panel or the status item), drawn by its frame view.
    static func write(to url: URL) -> Bool {
        guard let window = mainWindow,
              let view = window.contentView?.superview ?? window.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // The view hierarchy drawn into a bitmap: the window server's picture of our own
        // window (`CGWindowListCreateImage`) comes back blank on macOS 27 without Screen
        // Recording, and never shows a window parked off-screen (`-FrogOffscreen`).
        // `-FrogSnapshotWindowServer YES` keeps the old path for the table transcript, which
        // `cacheDisplay` drew blank once a card was up.
        let cached: NSBitmapImageRep? = {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }()
        let rep = UserDefaults.standard.bool(forKey: "FrogSnapshotWindowServer")
            ? windowServerImage(window).map(NSBitmapImageRep.init(cgImage:)) ?? cached
            : cached
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
