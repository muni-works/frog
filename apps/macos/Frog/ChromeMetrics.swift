import AppKit
import ApplicationServices

/// `-FrogChromeMetrics <path.json>` (beside `-FrogSnapshot`, same delay) writes where the window
/// chrome's controls stand as `frog-chrome-metrics/1` (docs/design/chrome/parity/README.md): the
/// top-right group and each of its buttons, the turn rail, the title. Read from the app's own
/// accessibility tree, so it measures what's on screen, title bar included, whoever draws it.
@MainActor
enum ChromeMetrics {
    /// The controls measured, by their accessibility label (a prefix for the rail, whose label
    /// carries its turn count). `id` is the name both apps' dumps use.
    static let wanted: [(id: String, label: String, prefix: Bool)] = [
        ("group", "Window controls", false),
        ("split", "Split", false),
        ("palette", "Commands", false),
        ("inspector", "Inspector", false),
        ("rail", "Timeline", true),
        ("title", "Session menu", false),
    ]
    /// Controls found by their accessibility identifier instead (a label that is their content).
    static let byIdentifier: [String: String] = ["title.menu": "title"]

    static func write(to url: URL, window: NSWindow) -> Bool {
        let app = AXUIElementCreateApplication(getpid())
        // The window's own element: its top-left is the origin every control is measured from.
        guard let ax = axWindow(app, title: window.title, frame: window.frame) else { return false }
        let origin = point(ax, kAXPositionAttribute) ?? .zero
        var found: [String: CGRect] = [:]
        walk(ax, depth: 0) { el in
            if let ident = string(el, "AXIdentifier"), let id = byIdentifier[ident], found[id] == nil,
               let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute), s.width > 0 {
                found[id] = CGRect(x: p.x - origin.x, y: p.y - origin.y, width: s.width, height: s.height)
            }
            let label = string(el, kAXDescriptionAttribute) ?? string(el, kAXTitleAttribute) ?? ""
            guard !label.isEmpty else { return }
            for w in wanted where found[w.id] == nil {
                guard w.prefix ? label.hasPrefix(w.label) : label == w.label,
                      let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute), s.width > 0 else { continue }
                found[w.id] = CGRect(x: p.x - origin.x, y: p.y - origin.y, width: s.width, height: s.height)
            }
        }
        let width = window.frame.width
        let r1 = { (v: CGFloat) in (v * 10).rounded() / 10 }
        let controls: [[String: Any]] = wanted.compactMap { w in
            guard let f = found[w.id] else { return nil }
            return ["id": w.id, "x": r1(f.minX), "top": r1(f.minY), "width": r1(f.width), "height": r1(f.height), "right": r1(width - f.maxX)]
        }
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let dump: [String: Any] = [
            "format": "frog-chrome-metrics/1", "app": "mac",
            "width": r1(width), "height": r1(window.frame.height), "look": dark ? "dark" : "light",
            // Where the conversation area starts: the docked sidebar's width, its hairline included.
            "main": r1(WorkspaceView.savedSidebarWidth),
            "controls": controls,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private static func axWindow(_ app: AXUIElement, title: String, frame: NSRect) -> AXUIElement? {
        guard let windows = children(app, kAXWindowsAttribute), !windows.isEmpty else { return nil }
        return windows.first { (size($0, kAXSizeAttribute)?.width ?? 0) == frame.width } ?? windows.first
    }

    private static func walk(_ el: AXUIElement, depth: Int, _ visit: (AXUIElement) -> Void) {
        guard depth < 40 else { return }
        visit(el)
        for c in children(el, kAXChildrenAttribute) ?? [] { walk(c, depth: depth + 1, visit) }
    }

    private static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private static func children(_ el: AXUIElement, _ attr: String) -> [AXUIElement]? {
        value(el, attr) as? [AXUIElement]
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }

    private static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
}
