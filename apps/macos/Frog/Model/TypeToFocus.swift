import AppKit

/// Type-to-focus: when a key window has no text field focused, a printable character goes to
/// the conversation's composer — like Slack or Messages, you just start typing.
///
/// The wiring is deliberately narrow: a local key monitor *only* promotes the composer to
/// first responder. It never edits, rewrites or consumes events — the very key that triggered
/// it continues down the normal chain and is then delivered to the composer (now first
/// responder), so the character lands through the field editor exactly as if the user had
/// clicked there. IME compositions, dead keys and autocorrect all survive untouched.
///
/// Everything the monitor decides is `decide` + `isEditing`, pure and unit-tested; `route`
/// only applies the answer.
@MainActor
enum TypeToFocus {
    /// What to do with a keydown.
    enum Decision: Equatable {
        /// Key continues down the responder chain untouched.
        case pass
        /// Nothing else would take this character; it goes to the composer. (`write` is the
        /// character that would land there — the wiring delivers the real event instead.)
        case compose(write: String)
    }

    /// What `decide` needs from an `NSEvent`, so tests pass a value rather than an event.
    struct Event {
        var characters: String?
        var modifiers: NSEvent.ModifierFlags

        init(characters: String?, modifiers: NSEvent.ModifierFlags = []) {
            self.characters = characters
            self.modifiers = modifiers
        }

        init(_ event: NSEvent) {
            characters = event.characters
            modifiers = event.modifierFlags
        }
    }

    /// The decision list, in order:
    /// 1. The window isn't key — another app is in front, or a frog window sits behind: the
    ///    key belongs where it's headed.
    /// 2. Something here already owns text keys — the composer or any field (every field
    ///    editor is an `NSTextView`), the terminal, IME machinery, the web preview's page:
    ///    the key is spoken for.
    /// 3. Modifiers besides ⇧, caps-lock and the keypad's numeric flag: ⌘/⌃/⌥ mean a
    ///    shortcut or an ⌥-composition, not a character to type.
    /// 4. Not one visible character — flags-changed events (`characters` nil), F-keys (in
    ///    the private-use range), control characters, Return, Tab, Esc, delete, space (scroll
    ///    views page on it): nothing to type. ⇧-shifted capitals stay; they're text.
    /// 5. No composer to take it (between conversations): the key is nobody's,
    ///    as before this existed.
    static func decide(
        _ event: Event, isKeyWindow: Bool, editing: Bool, canFocusComposer: Bool
    ) -> Decision {
        guard isKeyWindow else { return .pass }
        guard !editing else { return .pass }
        guard event.modifiers.subtracting(.numericPad).isSubset(of: [.shift, .capsLock]) else { return .pass }
        guard let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.count == 1,
              let c = chars.unicodeScalars.first, isPrintable(c), c != " "
        else { return .pass }
        guard canFocusComposer else { return .pass }
        return .compose(write: chars)
    }

    /// A scalar someone would call text: not a C0 control (0x00–0x1F: Return, Tab, Esc, ⌃
    /// letters), not DEL or the C1 range (0x7F–0x9F), and not AppKit's private-use function
    /// keys (0xF700–0xF8FF: arrows, F-keys, Home/End).
    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00..<0x20: return false
        case 0x20..<0x7F: return true
        case 0x7F...0x9F: return false
        case 0xF700...0xF8FF: return false
        default: return true
        }
    }

    /// Whether the responder owns keyboard entry, so the key is already spoken for.
    static func isEditing(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        // The composer and every field's editor (search, rename, settings — SwiftUI fields
        // run on NSTextView field editors, the textfield itself covers unedited moments).
        if responder is NSTextView || responder is NSTextField { return true }
        // The terminal's keys are the shell's.
        if responder is TerminalGridView { return true }
        // IME machinery (IMK…) and the web preview's page (WK…) hold keys of their own.
        let name = String(describing: type(of: responder))
        return name.hasPrefix("IMK") || name.hasPrefix("WK")
    }

    // MARK: Wiring

    private struct Entry {
        weak var window: NSWindow?
        weak var panes: Panes?
    }

    /// Windows with a workspace, by registration; entries decay with their windows and are
    /// swept here, so a closed window's keys (dialogs, alerts) are never mistaken for keys.
    private static var registered: [ObjectIdentifier: Entry] = [:]
    private static var monitor: Any?

    /// Call once at startup: installs the local key monitor. Monitor and registry are
    /// app-lifetime.
    static func begin() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { TypeToFocus.route(event) }
            return event
        }
    }

    /// Mirror of `Library.shared.register(window:panes:)`, which already pairs each window
    /// with its panes; called beside it.
    static func register(window: NSWindow, panes: Panes) {
        registered = registered.filter { $0.value.window != nil && $0.value.panes != nil }
        registered[ObjectIdentifier(window)] = Entry(window: window, panes: panes)
    }

    /// See whether this key pre-focuses the composer. Never consumes or edits: returns having
    /// at most changed the first responder.
    static func route(_ event: NSEvent) {
        // Only a key frog workspace window plays. Sheets, popovers, the settings and diagram
        // windows never register, so their keys pass untouched.
        guard let window = event.window, window.isKeyWindow,
              let panes = registered.first(where: { $0.value.window === window })?.value.panes
        else { return }
        let ui = panes.focused.ui
        // The ⌘K palette and find bar hold the window's keys.
        guard !ui.paletteShown, !ui.findShown, let composer = ui.composer, composer.textView != nil
        else { return }
        guard case .compose = decide(
            Event(event), isKeyWindow: window.isKeyWindow,
            editing: isEditing(window.firstResponder),
            canFocusComposer: true
        ) else { return }
        // Promotion only: the event keeps routing, and the composer (now first responder)
        // receives this same character through its field editor.
        composer.focus()
    }
}
