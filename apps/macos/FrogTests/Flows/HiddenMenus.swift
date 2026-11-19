import AppKit
import ObjectiveC
import XCTest

/// A menu popped from a hidden test window never reaches the screen: its pop-up is caught before
/// it tracks (a tracking menu would take the mouse and keyboard from whoever is at the Mac), and
/// kept here for the flow driver to choose from. Installed with `HideChildren`.
///
/// SwiftUI pops a `Menu` (the title chevron, the where-menu) and a `.contextMenu` itself through
/// one of NSMenu's pop-up entry points; each is replaced with one that records the menu when the
/// view's window is hidden, and runs the original otherwise. If a menu still starts tracking
/// from a hidden window (a path this file doesn't know), it's cancelled at once and the test
/// that did it fails by name.
@MainActor
enum HiddenMenus {
    /// The menus popped from hidden windows, newest last, and the view each popped from.
    private(set) static var popped: [(menu: NSMenu, view: NSView?)] = []
    /// A test that runs into the safety net fails through this.
    static var onEscape: ((String) -> Void)?

    static func take() -> NSMenu? { popped.popLast()?.menu }
    static func reset() { popped.removeAll() }

    static func install() {
        // -popUpMenuPositioningItem:atLocation:inView: (and the appearance variant, which
        // SwiftUI's Menu uses): BOOL, the view is the third argument.
        replace(NSMenu.self, "popUpMenuPositioningItem:atLocation:inView:") { (orig: IMP, sel: Selector) in
            typealias F = @convention(c) (NSMenu, Selector, NSMenuItem?, NSPoint, NSView?) -> Bool
            let call = unsafeBitCast(orig, to: F.self)
            let block: @convention(block) (NSMenu, NSMenuItem?, NSPoint, NSView?) -> Bool = { menu, item, at, view in
                if hidden(view) { record(menu, view); return true }
                return call(menu, sel, item, at, view)
            }
            return imp_implementationWithBlock(block)
        }
        replace(NSMenu.self, "popUpMenuPositioningItem:atLocation:inView:appearance:") { orig, sel in
            typealias F = @convention(c) (NSMenu, Selector, NSMenuItem?, NSPoint, NSView?, NSAppearance?) -> Bool
            let call = unsafeBitCast(orig, to: F.self)
            let block: @convention(block) (NSMenu, NSMenuItem?, NSPoint, NSView?, NSAppearance?) -> Bool = { menu, item, at, view, look in
                if hidden(view) { record(menu, view); return true }
                return call(menu, sel, item, at, view, look)
            }
            return imp_implementationWithBlock(block)
        }
        // +popUpContextMenu:withEvent:forView: (and withFont:): a right click's menu.
        replace(object_getClass(NSMenu.self)!, "popUpContextMenu:withEvent:forView:") { orig, sel in
            typealias F = @convention(c) (AnyClass, Selector, NSMenu, NSEvent, NSView) -> Void
            let call = unsafeBitCast(orig, to: F.self)
            let block: @convention(block) (AnyClass, NSMenu, NSEvent, NSView) -> Void = { cls, menu, event, view in
                if hidden(view) { return record(menu, view) }
                call(cls, sel, menu, event, view)
            }
            return imp_implementationWithBlock(block)
        }
        replace(object_getClass(NSMenu.self)!, "popUpContextMenu:withEvent:forView:withFont:") { orig, sel in
            typealias F = @convention(c) (AnyClass, Selector, NSMenu, NSEvent, NSView, NSFont?) -> Void
            let call = unsafeBitCast(orig, to: F.self)
            let block: @convention(block) (AnyClass, NSMenu, NSEvent, NSView, NSFont?) -> Void = { cls, menu, event, view, font in
                if hidden(view) { return record(menu, view) }
                call(cls, sel, menu, event, view, font)
            }
            return imp_implementationWithBlock(block)
        }
        // SwiftUI's Menu (MenuPresentationBridge) goes straight to the menu implementation:
        // -[NSCocoaMenuImpl popUpMenu:atLocation:width:view:selectedItemIndexProvider:font:
        // positioningRect:flags:options:]. It tracks synchronously, so returning at once reads to
        // SwiftUI as the menu closing with nothing chosen.
        if let impl = NSClassFromString("NSCocoaMenuImpl") {
            replace(impl, "popUpMenu:atLocation:width:view:selectedItemIndexProvider:font:positioningRect:flags:options:") { orig, sel in
                typealias F = @convention(c) (AnyObject, Selector, NSMenu, NSPoint, CGFloat, NSView?, AnyObject?, NSFont?, NSRect, UInt, AnyObject?) -> Bool
                let call = unsafeBitCast(orig, to: F.self)
                let block: @convention(block) (AnyObject, NSMenu, NSPoint, CGFloat, NSView?, AnyObject?, NSFont?, NSRect, UInt, AnyObject?) -> Bool = {
                    me, menu, at, width, view, provider, font, rect, flags, options in
                    if hidden(view) { record(menu, view); return false }
                    return call(me, sel, menu, at, width, view, provider, font, rect, flags, options)
                }
                return imp_implementationWithBlock(block)
            }
        }
        // Any other path: the menu's window is hidden as it orders in (before the first frame),
        // and its tracking is cancelled the moment it starts, with the menu kept like the rest.
        replace(NSWindow.self, "orderWindow:relativeTo:") { orig, sel in
            typealias F = @convention(c) (NSWindow, Selector, NSWindow.OrderingMode, Int) -> Void
            let call = unsafeBitCast(orig, to: F.self)
            let block: @convention(block) (NSWindow, NSWindow.OrderingMode, Int) -> Void = { window, place, other in
                if place != .out, isMenuWindow(window), anyHiddenTestWindow() {
                    window.alphaValue = 0
                    window.ignoresMouseEvents = true
                    window.animationBehavior = .none
                }
                call(window, sel, place, other)
            }
            return imp_implementationWithBlock(block)
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let menu = object as? NSMenu, menu !== NSApp.mainMenu, menu.supermenu == nil else { return }
                guard anyHiddenTestWindow() else { return }
                menu.cancelTrackingWithoutAnimation()
                record(menu, nil)
                // A menu window someone could see is the background guard's to report.
                if let seen = NSApp.windows.first(where: { isMenuWindow($0) && $0.isSeenByUser }) {
                    onEscape?("a menu (\(menu.items.map(\.title).filter { !$0.isEmpty }.prefix(4).joined(separator: ", "))) showed \(type(of: seen)) on screen")
                }
            }
        }
    }

    nonisolated private static func isMenuWindow(_ w: NSWindow) -> Bool {
        let name = NSStringFromClass(type(of: w))
        return name.contains("Menu") && name.contains("Window")
    }

    /// A test window is up, so a menu now comes from a test (the host has no windows of its own).
    nonisolated private static func anyHiddenTestWindow() -> Bool {
        NSApp.windows.contains { $0.alphaValue <= 0.01 && $0.isVisible && !isMenuWindow($0) }
    }

    private static func hidden(_ view: NSView?) -> Bool {
        guard let w = view?.window else { return false }
        return w.alphaValue <= 0.01 || w.hasHiddenAncestor
    }

    private static func record(_ menu: NSMenu, _ view: NSView?) {
        // What opening does before the menu shows: SwiftUI fills and updates it here.
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        popped.append((menu, view))
    }

    private static func replace(_ cls: AnyClass, _ name: String, _ make: (IMP, Selector) -> IMP) {
        let sel = NSSelectorFromString(name)
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        method_setImplementation(m, make(method_getImplementation(m), sel))
    }
}
