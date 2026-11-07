import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import Frog

/// File > Open Folder… from an empty chat crashed in AppKit's layout pass: a second window
/// opened, and the two windows' roots re-rendered each other through `SessionOrder`'s shared,
/// observable one-slot cache until AppKit raised "more Update Constraints in Window passes than
/// there are views in the window". These host the real window content, drive the same state
/// change, and fail on any exception AppKit reports (or crash, as the app did).
@MainActor
final class OpenFolderLayoutTests: XCTestCase {
    /// Exceptions AppKit caught in the display cycle (it reports them rather than crashing while
    /// `NSApplicationCrashOnExceptions` is off).
    nonisolated(unsafe) static var caught: [NSException] = []
    private static var swizzled = false

    override func setUp() async throws {
        UserDefaults.standard.set(false, forKey: "NSApplicationCrashOnExceptions")
        Self.caught = []
        guard !Self.swizzled else { return }
        Self.swizzled = true
        let sel = #selector(NSApplication.reportException(_:))
        guard let method = class_getInstanceMethod(NSApplication.self, sel) else { return }
        let block: @convention(block) (NSApplication, NSException) -> Void = { _, e in
            OpenFolderLayoutTests.caught.append(e)
            print("CAUGHT \(e.name.rawValue): \(e.reason ?? "")")
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func window(_ panes: Panes) -> NSWindow {
        let host = NSHostingView(rootView: WorkspaceView(panes: panes).frame(minWidth: 720, minHeight: 480))
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760),
                         styleMask: [.titled, .resizable, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFrontRegardless()
        return w
    }

    private var repo: URL {
        // This checkout: a git repository with history, as ~/Developer/frog was.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func assertNoExceptions(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(Self.caught.isEmpty, "layout raised: " + Self.caught.map { "\($0.name.rawValue): \($0.reason ?? "")" }.joined(separator: "\n"),
                      file: file, line: line)
    }

    /// The empty chat switches to a repository in place (a recent-project chip, or Open Folder
    /// landing on this window).
    func testEmptyChatSwitchesToFolder() throws {
        let panes = Panes(Workspace(folder: Frog.chatFolder, fresh: true))
        let w = window(panes)
        defer { panes.stopAll(); w.close() }
        pump(1.5)
        panes.switchFolder(repo, in: panes.focused)
        pump(3)
        assertNoExceptions()
    }

    /// Open Folder's new window: a repository's empty conversation, beside the chat's window.
    func testOpenFolderWindow() throws {
        let chat = Panes(Workspace(folder: Frog.chatFolder, fresh: true))
        let w1 = window(chat)
        pump(1)
        let panes = Panes(Workspace(folder: repo))
        let w2 = window(panes)
        defer { chat.stopAll(); panes.stopAll(); w1.close(); w2.close() }
        pump(3)
        assertNoExceptions()
    }
}
