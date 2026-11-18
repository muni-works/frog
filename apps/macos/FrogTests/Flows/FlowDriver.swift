import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import Frog

/// Drives a whole user flow through the app's real window content, in the background.
///
/// **Why in process, not XCUITest.** An XCUITest target launches the app as its own process and
/// brings it to the front, and its clicks and typing are real events: they move the pointer and
/// go to whatever app is frontmost. That breaks the rule that a test run never takes the screen
/// or keyboard from whoever is at the Mac (`BackgroundGuard`). In process, the window is ordered
/// in hidden (`orderInForTest`), the host stays an inactive accessory app, and nothing is sent as
/// an event.
///
/// **How it sees and presses.** Through the Accessibility API on this process's own app element,
/// called on the main thread (`AXUIElementCreateApplication(getpid())`). That is SwiftUI's full
/// accessibility tree: every button, label, text, field and its identifier, the toolbar, sheets.
/// (Walking `NSView` subviews or calling `accessibilityChildren()` in process finds almost none
/// of it: SwiftUI builds its nodes for the AX entry point, not for in-process calls.) Asking your
/// own process needs no Accessibility permission. `AXPress` presses a control, setting
/// `AXValue` types into a field and `AXConfirm` submits it (a SwiftUI `onSubmit`).
///
/// **Menus.** A `Menu` pressed in a hidden window doesn't track (`HiddenMenus` catches it):
/// `menu(_:)` presses the control and hands back the menu to choose from. The menu bar is the
/// app's real main menu built by `FrogCommands`, acting on this window through `StagedWindow`
/// (a test host has no key window, so `@FocusedValue` would be nil); `menuBar(_:)` performs an
/// item by its titles and `shortcut(_:_:)` sends a key equivalent the way the menu bar gets one.
@MainActor
final class FlowWindow {
    let panes: Panes
    let window: NSWindow
    private let started = Date()
    private var restores: [() -> Void] = []

    var workspace: Workspace { panes.focused.workspace }
    var conversation: Conversation? { panes.focused.conversation }

    /// The app's window content for these panes, hosted hidden, with its toolbar and title, and
    /// the menu bar pointed at it. Signed out of Frog Cloud and with no network offers, so the
    /// Mac's real account and machines never reach a flow (the test host shares the login
    /// Keychain).
    init(panes: Panes, size: CGSize = CGSize(width: 1300, height: 820), file: StaticString = #filePath, line: UInt = #line) {
        self.panes = panes
        Self.isolate(&restores)
        let host = NSHostingView(rootView: FlowRoot { WorkspaceView(panes: panes) })
        host.sceneBridgingOptions = [.toolbars, .title]
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled, .resizable, .fullSizeContentView, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderInForTest()
        HiddenMenus.reset()
        pump(0.5)
        if !waitUntil(timeout: 5, { self.axWindow != nil }) {
            XCTFail("the hosted window never showed in the accessibility tree", file: file, line: line)
        }
    }

    /// Skips the test while the Mac's screen is locked: macOS then counts no window as on
    /// screen, so the accessibility tree has none to read (seen 2026-11-18: every window came back
    /// as the bare app element until the screen was unlocked).
    nonisolated static func requireScreen() throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true {
            throw XCTSkip("the screen is locked: macOS lists no windows to accessibility, so a flow can't be driven")
        }
    }

    /// A new window on a fresh workspace in `folder`.
    convenience init(folder: URL, size: CGSize = CGSize(width: 1300, height: 820)) {
        self.init(panes: Panes(Workspace(folder: folder, fresh: true)), size: size)
    }

    func close() {
        StagedWindow.shared.window = nil
        window.close()
        panes.stopAll()
        restores.reversed().forEach { $0() }
        restores.removeAll()
        pump(0.05)
    }

    private static func isolate(_ restores: inout [() -> Void]) {
        CloudAccount.shared.stage(nil)
        Library.shared.cloudChanged([])
        let offer = Devices.shared.hideOffer
        Devices.shared.hideOffer = true
        restores.append { CloudAccount.shared.unstage(); Devices.shared.hideOffer = offer }
    }

    // MARK: Time

    func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Pumps until `ok` holds or the time is up (multiplied on CI), and says which.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 5, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout * TestRunner.slack)
        while Date() < end {
            if ok() { return true }
            pump(0.03)
        }
        return ok()
    }

    // MARK: Reading the screen

    private var axWindow: AXElement? {
        let app = AXElement(AXUIElementCreateApplication(getpid()))
        // Only real windows (the list can come back holding the app itself while AppKit's
        // window list catches up), and ours by its size.
        let windows = app.elements(kAXWindowsAttribute).filter { $0.role == kAXWindowRole as String }
        return windows.first { $0.frame.size == window.frame.size } ?? windows.first
    }

    /// Everything on screen in this window, depth first: its content, toolbar and any sheet.
    var elements: [AXElement] { axWindow?.descendants ?? [] }

    /// Every piece of text a person can read in the window (static texts, labels, titles,
    /// field values).
    var texts: [String] {
        elements.flatMap { e in [e.value, e.label, e.title].compactMap { $0 }.filter { !$0.isEmpty } }
    }

    /// The text is on screen somewhere (a substring of any readable text).
    func shows(_ text: String) -> Bool { texts.contains { $0.contains(text) } }

    func find(_ q: Query) -> AXElement? {
        guard q.inSheet else { return elements.first(where: q.matches) }
        return elements.filter { $0.role == kAXSheetRole as String }.flatMap(\.descendants).first(where: q.matches)
    }

    /// The element, waiting for it to appear; fails the test if it never does.
    @discardableResult
    func element(_ q: Query, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) -> AXElement? {
        var found: AXElement?
        waitUntil(timeout: timeout) { found = find(q); return found != nil }
        if found == nil {
            XCTFail("no \(q) on screen; buttons: \(elements.filter { $0.role == kAXButtonRole as String }.compactMap { $0.label ?? $0.title ?? $0.identifier }.prefix(40))", file: file, line: line)
        }
        return found
    }

    // MARK: Acting

    /// Presses the control (a button, a menu's control, a row).
    func press(_ q: Query, file: StaticString = #filePath, line: UInt = #line) {
        guard let e = element(q, file: file, line: line) else { return }
        if !e.enabled { XCTFail("\(q) is disabled", file: file, line: line); return }
        let err = e.perform(kAXPressAction)
        if err != .success { XCTFail("pressing \(q) failed: \(err.rawValue)", file: file, line: line) }
        pump()
    }

    /// Types into a text field (its whole value becomes `text`) and, with `submit`, presses
    /// Return in it (`onSubmit`).
    func type(_ text: String, into q: Query, submit: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        guard let e = element(q, file: file, line: line) else { return }
        _ = e.set(kAXFocusedAttribute, kCFBooleanTrue)
        let err = e.set(kAXValueAttribute, text as CFString)
        if err != .success { XCTFail("typing into \(q) failed: \(err.rawValue)", file: file, line: line) }
        pump()
        if submit { _ = e.perform(kAXConfirmAction); pump() }
    }

    /// Presses a control that opens a menu and hands back that menu, without it tracking.
    func menu(_ q: Query, file: StaticString = #filePath, line: UInt = #line) -> PoppedMenu? {
        HiddenMenus.reset()
        press(q, file: file, line: line)
        var menu: NSMenu?
        waitUntil(timeout: 2) { menu = HiddenMenus.take(); return menu != nil }
        if menu == nil { XCTFail("pressing \(q) opened no menu", file: file, line: line) }
        return menu.map { PoppedMenu(menu: $0, window: self) }
    }

    // MARK: The composer

    /// The composer's text view (AppKit, so it's driven the way AppKit delivers typing).
    var composerField: NSTextView? {
        func find(_ v: NSView) -> NSTextView? {
            if let t = v as? NSTextView, t.isEditable, t.enclosingScrollView != nil, String(describing: Swift.type(of: t)).contains("Pasting") { return t }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// Types at the composer's caret, as typing does.
    func typeInComposer(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let tv = composerField else { return XCTFail("no composer on screen", file: file, line: line) }
        tv.insertText(text, replacementRange: tv.selectedRange())
        pump()
    }

    /// Presses Return in the composer: sends the draft (or picks the open mention).
    func pressReturnInComposer(file: StaticString = #filePath, line: UInt = #line) {
        guard let tv = composerField else { return XCTFail("no composer on screen", file: file, line: line) }
        _ = tv.delegate?.textView?(tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        pump()
    }

    /// Types a message and sends it.
    func send(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        typeInComposer(text, file: file, line: line)
        pressReturnInComposer(file: file, line: line)
    }

    // MARK: The menu bar

    /// The menu bar's item at this path (`["Session", "Interrupt"]`), as the app built it for
    /// this window.
    func menuBarItem(_ path: [String], file: StaticString = #filePath, line: UInt = #line) -> NSMenuItem? {
        guard StagedWindow.shared.window != nil || waitUntil(timeout: 2, { StagedWindow.shared.window != nil }) else {
            XCTFail("the window never offered itself to the menu bar", file: file, line: line)
            return nil
        }
        pump()
        var menu = NSApp.mainMenu
        var item: NSMenuItem?
        for title in path {
            menu?.update()
            item = menu?.items.first { $0.title == title } ?? menu?.items.first { $0.title.hasPrefix(title) }
            menu = item?.submenu
        }
        if item == nil {
            XCTFail("no menu bar item \(path.joined(separator: " › ")); there: \(NSApp.mainMenu?.items.map(\.title) ?? [])", file: file, line: line)
        }
        return item
    }

    /// Chooses the menu bar item at this path, as clicking it would; fails if it's disabled.
    func menuBar(_ path: String..., file: StaticString = #filePath, line: UInt = #line) {
        guard let item = menuBarItem(path, file: file, line: line), let parent = item.menu,
              let index = parent.items.firstIndex(of: item) else { return }
        parent.update()
        guard item.isEnabled else { return XCTFail("menu bar item \(path.joined(separator: " › ")) is disabled", file: file, line: line) }
        parent.performActionForItem(at: index)
        pump()
    }

    /// Sends a keyboard shortcut the way the menu bar receives one (its key equivalents);
    /// returns whether a menu item took it.
    @discardableResult
    func shortcut(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        _ = menuBarItem([NSApp.mainMenu?.items.first?.title ?? ""], file: file, line: line)
        NSApp.mainMenu?.update()
        NSApp.mainMenu?.items.forEach { $0.submenu?.update() }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: key,
                                           charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)
        else { return false }
        let taken = Self.enabledItem(for: event, in: NSApp.mainMenu) != nil && (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
        pump()
        return taken
    }

    /// The enabled menu item whose key equivalent this event is, if any (`performKeyEquivalent`
    /// answers yes for a disabled one too).
    private static func enabledItem(for event: NSEvent, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        for item in menu.items {
            if let sub = item.submenu, let hit = enabledItem(for: event, in: sub) { return hit }
            if item.isEnabled, !item.keyEquivalent.isEmpty, item.keyEquivalent == event.charactersIgnoringModifiers,
               item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == mods {
                return item
            }
        }
        return nil
    }
}

/// The window's root, wrapped: it reads the `FrogWindow` the window publishes for the menu bar
/// (the focused value the real menu bar reads in a key window) and stages it.
private struct FlowRoot<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @FocusedValue(\.frogWindow) private var frogWindow

    var body: some View {
        // Each body pass is the window's latest offer (its closures and flags); staged after
        // the pass, so the update doesn't write state mid-render.
        let current = frogWindow
        DispatchQueue.main.async { if let current { StagedWindow.shared.window = current } }
        return content()
    }
}

/// A menu a flow opened, to choose from.
@MainActor
struct PoppedMenu {
    let menu: NSMenu
    let window: FlowWindow

    var titles: [String] { menu.items.map(\.title).filter { !$0.isEmpty } }

    func isEnabled(_ title: String) -> Bool { menu.items.first { $0.title == title }?.isEnabled ?? false }

    /// Chooses the first item whose title starts with `prefix`.
    func choose(startingWith prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let title = menu.items.first(where: { $0.title.hasPrefix(prefix) })?.title else {
            return XCTFail("no item starting \(prefix) in the menu: \(titles)", file: file, line: line)
        }
        choose(title, file: file, line: line)
    }

    /// Chooses the item, as clicking it would (a path for a submenu: "Group By", "Folder").
    func choose(_ path: String..., file: StaticString = #filePath, line: UInt = #line) {
        var m = menu
        for (i, title) in path.enumerated() {
            m.update()
            guard let index = m.items.firstIndex(where: { $0.title == title }) else {
                return XCTFail("no \(title) in the menu: \(m.items.map(\.title))", file: file, line: line)
            }
            let item = m.items[index]
            if i < path.count - 1, let sub = item.submenu { m = sub; continue }
            guard item.isEnabled else { return XCTFail("\(title) is disabled", file: file, line: line) }
            m.performActionForItem(at: index)
        }
        window.pump(0.1)
    }
}

/// What to look for: by accessibility identifier, label (a control's name), visible text or
/// role, alone or together.
struct Query: CustomStringConvertible {
    var id: String?
    var label: String?
    var text: String?
    var role: String?
    /// Only inside a sheet (an alert's field, a dialog's buttons).
    var inSheet = false

    static func id(_ s: String) -> Query { Query(id: s) }
    static func label(_ s: String) -> Query { Query(label: s) }
    static func text(_ s: String) -> Query { Query(text: s) }
    static func button(_ label: String) -> Query { Query(label: label, role: kAXButtonRole as String) }
    static func field(placeholder: String) -> Query { Query(text: placeholder, role: kAXTextFieldRole as String) }
    static var sheetField: Query { Query(role: kAXTextFieldRole as String, inSheet: true) }
    static func sheetButton(_ label: String) -> Query { Query(label: label, role: kAXButtonRole as String, inSheet: true) }

    func matches(_ e: AXElement) -> Bool {
        if let id, e.identifier != id { return false }
        if let role, e.role != role { return false }
        if let label, e.label != label && e.title != label { return false }
        if let text, !(e.value?.contains(text) ?? false) && !(e.placeholder?.contains(text) ?? false)
            && !(e.label?.contains(text) ?? false) && !(e.title?.contains(text) ?? false) { return false }
        return true
    }

    var description: String {
        [id.map { "id \($0)" }, label.map { "“\($0)”" }, text.map { "text “\($0)”" }, role, inSheet ? "in a sheet" : nil].compactMap { $0 }.joined(separator: " ")
    }
}

/// One node of the accessibility tree.
struct AXElement {
    let ref: AXUIElement
    init(_ ref: AXUIElement) { self.ref = ref }

    func raw(_ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(ref, name as CFString, &v) == .success ? v : nil
    }
    private func string(_ name: String) -> String? { raw(name).flatMap { $0 as? String } }

    var role: String? { string(kAXRoleAttribute) }
    var identifier: String? { string(kAXIdentifierAttribute) }
    /// A control's name (its accessibility label).
    var label: String? { string(kAXDescriptionAttribute) }
    var title: String? { string(kAXTitleAttribute) }
    var placeholder: String? { string(kAXPlaceholderValueAttribute) }
    /// Its tooltip.
    var help: String? { string(kAXHelpAttribute) }
    var value: String? {
        guard let v = raw(kAXValueAttribute) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    var enabled: Bool { (raw(kAXEnabledAttribute) as? Bool) ?? true }
    var frame: CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let p = raw(kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &origin) }
        if let s = raw(kAXSizeAttribute) { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    func elements(_ name: String) -> [AXElement] {
        (raw(name) as? [AXUIElement] ?? []).map(AXElement.init)
    }
    var children: [AXElement] { elements(kAXChildrenAttribute) }
    /// Depth first, without recursion, each node once: the tree isn't always a tree (a node can
    /// list an ancestor among its children), so a walk that trusts it never ends.
    var descendants: [AXElement] {
        var out: [AXElement] = []
        var seen: [CFHashCode: [AXUIElement]] = [:]
        func visit(_ e: AXElement) -> Bool {
            let h = CFHash(e.ref)
            if seen[h, default: []].contains(where: { CFEqual($0, e.ref) }) { return false }
            seen[h, default: []].append(e.ref)
            return true
        }
        _ = visit(self)
        var stack = Array(children.reversed())
        while let e = stack.popLast(), out.count < 20_000 {
            guard visit(e) else { continue }
            out.append(e)
            stack.append(contentsOf: e.children.reversed())
        }
        return out
    }

    func perform(_ action: String) -> AXError { AXUIElementPerformAction(ref, action as CFString) }
    func set(_ name: String, _ value: CFTypeRef) -> AXError { AXUIElementSetAttributeValue(ref, name as CFString, value) }
}
