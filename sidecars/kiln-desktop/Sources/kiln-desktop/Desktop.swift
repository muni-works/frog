import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Reading and driving other apps through the accessibility API, which works in the background
/// (no cursor, no focus change) for most controls. Keyboard and mouse events are the fallback.
@MainActor
final class Desktop {
    /// The elements listed by the last snapshot of each app, so `[n]` indexes stay valid.
    private var elements: [pid_t: [AXUIElement]] = [:]
    private var lastLines: [pid_t: Set<String>] = [:]

    enum Failure: Error, CustomStringConvertible {
        case message(String)
        var description: String { if case .message(let m) = self { m } else { "" } }
    }

    // MARK: Permissions

    func requireTrust() throws {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            throw Failure.message("Accessibility permission is needed: System Settings › Privacy & Security › Accessibility, then allow Kiln (or your terminal), and try again.")
        }
    }

    // MARK: Apps

    func apps() -> String {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return running.map { app in
            let name = app.localizedName ?? "?"
            let front = app.isActive ? " (frontmost)" : ""
            let windows = windowTitles(app.processIdentifier)
            let w = windows.isEmpty ? "" : " — windows: " + windows.prefix(5).map { "\"\($0)\"" }.joined(separator: ", ")
            return "\(name) [\(app.bundleIdentifier ?? "")]\(front)\(w)"
        }.joined(separator: "\n")
    }

    func find(_ query: String) throws -> NSRunningApplication {
        let q = query.lowercased()
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let app = running.first(where: { $0.bundleIdentifier?.lowercased() == q || $0.localizedName?.lowercased() == q })
            ?? running.first(where: { $0.localizedName?.lowercased().contains(q) == true }) {
            return app
        }
        throw Failure.message("\(query) isn't running. Use `open` to launch it, or `apps` to see what's running.")
    }

    func open(_ name: String) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = name.contains(".") && !name.contains(" ") ? ["-g", "-b", name] : ["-g", "-a", name]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.message("couldn't open \(name)") }
        try await Task.sleep(for: .seconds(1.5))
        return "Opened \(name) in the background."
    }

    // MARK: Snapshot

    private func windowTitles(_ pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        return (attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).compactMap { string($0, kAXTitleAttribute) }
    }

    private func window(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let w = attr(app, kAXFocusedWindowAttribute) { return (w as! AXUIElement) }
        if let w = attr(app, kAXMainWindowAttribute) { return (w as! AXUIElement) }
        return (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    private static let interesting: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSecureTextField",
        "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXLink", "AXMenuItem", "AXSlider", "AXTab",
        "AXIncrementor", "AXDisclosureTriangle", "AXCell", "AXRow", "AXStaticText", "AXImage",
        "AXSearchField", "AXSegmentedControl", "AXColorWell", "AXDateField", "AXHeading",
    ]

    /// The window's elements as `[n] role "label" = value @ x,y wxh` lines (window-relative).
    func snapshot(_ app: NSRunningApplication) throws -> String {
        let pid = app.processIdentifier
        guard let win = window(pid) else {
            throw Failure.message("\(app.localizedName ?? "the app") has no open window. Use `key` with cmd+n, or open a document.")
        }
        let origin = point(win, kAXPositionAttribute) ?? .zero
        var found: [AXUIElement] = []
        var lines: [String] = []
        var visited = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 40, visited < 4000, found.count < 400 else { return }
            visited += 1
            let role = string(el, kAXRoleAttribute) ?? ""
            if Self.interesting.contains(role), let line = describe(el, role: role, origin: origin, index: found.count) {
                found.append(el)
                lines.append(line)
            }
            for child in attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                walk(child, depth: depth + 1)
            }
        }
        walk(win, depth: 0)
        elements[pid] = found
        let title = string(win, kAXTitleAttribute) ?? ""
        let size = self.size(win, kAXSizeAttribute) ?? .zero
        var out = "\(app.localizedName ?? "?") — window \"\(title)\" (\(Int(size.width))×\(Int(size.height)))\n"
        out += lines.joined(separator: "\n")
        if found.count >= 400 { out += "\n… (more elements not listed)" }
        return out
    }

    private func describe(_ el: AXUIElement, role: String, origin: CGPoint, index: Int) -> String? {
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
            .lazy.compactMap { self.string(el, $0) }.first { !$0.isEmpty } ?? ""
        var value = ""
        if role == "AXSecureTextField" {
            value = "(password)"
        } else if let v = attr(el, kAXValueAttribute) {
            if let s = v as? String { value = s } else if let n = v as? NSNumber { value = n.stringValue }
        }
        // Text and images only matter when they say something; empty containers are noise.
        if ["AXStaticText", "AXImage", "AXRow", "AXCell", "AXHeading"].contains(role), label.isEmpty, value.isEmpty { return nil }
        guard let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute), s.width > 1, s.height > 1 else { return nil }
        let enabled = (attr(el, kAXEnabledAttribute) as? Bool) == false ? " (disabled)" : ""
        let focused = (attr(el, kAXFocusedAttribute) as? Bool) == true ? " (focused)" : ""
        var line = "[\(index)] \(role.dropFirst(2))"
        if !label.isEmpty { line += " \"\(clip(label, 80))\"" }
        if !value.isEmpty { line += " = \"\(clip(value, 120))\"" }
        line += "\(enabled)\(focused) @ \(Int(p.x - origin.x)),\(Int(p.y - origin.y)) \(Int(s.width))×\(Int(s.height))"
        return line
    }

    /// A fresh snapshot, with how much changed since the last one: the cheap way to tell
    /// whether an action did anything.
    func after(_ app: NSRunningApplication, _ what: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(450))
        let pid = app.processIdentifier
        let before = lastLines[pid] ?? []
        let snap = try snapshot(app)
        let now = Set(snap.split(separator: "\n").dropFirst().map { line in
            // Compare without the index, which shifts when elements come and go.
            String(line.drop(while: { $0 != "]" }).dropFirst())
        })
        lastLines[pid] = now
        let changed = before.isEmpty ? nil : before.symmetricDifference(now).count
        let note = changed.map { $0 == 0 ? "\n(Nothing in the window changed — the action may not have worked.)" : "\n(\($0) element lines changed.)" } ?? ""
        return "\(what)\(note)\n\n\(snap)"
    }

    func remember(_ app: NSRunningApplication, _ snap: String) {
        lastLines[app.processIdentifier] = Set(snap.split(separator: "\n").dropFirst().map {
            String($0.drop(while: { $0 != "]" }).dropFirst())
        })
    }

    func element(_ app: NSRunningApplication, _ index: Int) throws -> AXUIElement {
        guard let list = elements[app.processIdentifier], list.indices.contains(index) else {
            throw Failure.message("No element [\(index)]. Call `look` first; indexes come from the latest listing.")
        }
        return list[index]
    }

    // MARK: Screenshot

    /// The app's window as PNG, scaled to at most 1440 px wide.
    func screenshot(_ app: NSRunningApplication) async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return nil }
        let windows = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier && $0.isOnScreen && $0.frame.width > 50 }
        guard let win = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let config = SCStreamConfiguration()
        let scale = min(2, 1440 / max(win.frame.width, 1))
        config.width = Int(win.frame.width * scale)
        config.height = Int(win.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: config) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: Actions

    func press(_ el: AXUIElement) -> Bool {
        for action in [kAXPressAction, kAXConfirmAction, kAXPickAction] {
            if AXUIElementPerformAction(el, action as CFString) == .success { return true }
        }
        if AXUIElementSetAttributeValue(el, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success { return true }
        return false
    }

    func center(_ el: AXUIElement) -> CGPoint? {
        guard let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute) else { return nil }
        return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    }

    func windowOrigin(_ app: NSRunningApplication) -> CGPoint {
        window(app.processIdentifier).flatMap { point($0, kAXPositionAttribute) } ?? .zero
    }

    /// A real click at a screen point. It needs the app in front, so this activates it.
    func click(at p: CGPoint, app: NSRunningApplication, double: Bool) async {
        app.activate()
        try? await Task.sleep(for: .milliseconds(250))
        let src = CGEventSource(stateID: .hidSystemState)
        for n in 1...(double ? 2 : 1) {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    func isSecure(_ el: AXUIElement) -> Bool {
        string(el, kAXRoleAttribute) == "AXSecureTextField" || string(el, kAXSubroleAttribute) == "AXSecureTextField"
    }

    /// Insert text at the element's caret (or replace its value), through accessibility.
    func setText(_ el: AXUIElement, _ text: String, replace: Bool) -> Bool {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if replace {
            return AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) == .success
        }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Keyboard events straight to the app's process; they work while it's in the background.
    func typeKeys(_ text: String, pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        for chunk in text.chunked(20) {
            let utf16 = Array(chunk.utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                e?.postToPid(pid)
            }
        }
    }

    func key(_ combo: String, pid: pid_t) throws {
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:
                guard let c = Self.keycodes[part] else { throw Failure.message("unknown key `\(part)` in `\(combo)`") }
                code = c
            }
        }
        guard let code else { throw Failure.message("no key in `\(combo)`") }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.postToPid(pid)
        }
    }

    func scroll(pid: pid_t, at p: CGPoint?, dy: Int) {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(-dy), wheel2: 0, wheel3: 0)
        if let p { e?.location = p }
        e?.postToPid(pid)
    }

    private static let keycodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "forward_delete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "`": 50, "\\": 42,
        ]
        let letters = "asdfhgzxcv bqweryt123465=97-80]ou[ip lj'k;\\,/nm."
        for (i, c) in letters.enumerated() where c != " " && m[String(c)] == nil { m[String(c)] = CGKeyCode(i) }
        return m
    }()

    // MARK: AX helpers

    private func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private func string(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    private func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private func size(_ el: AXUIElement, _ name: String) -> CGSize? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    private func clip(_ s: String, _ n: Int) -> String {
        // Keep both ends: the end of a field (a calculator's result, a path) often matters most.
        let one = s.replacingOccurrences(of: "\n", with: " ")
        guard one.count > n else { return one }
        return String(one.prefix(n / 3)) + " … " + String(one.suffix(n - n / 3))
    }
}

extension String {
    func chunked(_ n: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for c in self {
            cur.append(c)
            if cur.count == n { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
