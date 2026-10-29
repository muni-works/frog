import AppKit
import XCTest
@testable import Frog

@MainActor
final class MessageTextTests: XCTestCase {
    /// A code block's line is as tall as the block, so the text after it sits below it.
    func testCodeBlockReservesItsHeight() throws {
        let view = MessageTextView(usingTextLayoutManager: false)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.show([.paragraph("before"), .code(language: "rust", text: "fn a() {}\nfn b() {}\nfn c() {}"), .paragraph("after")])
        let height = view.height(for: 500)
        let layout = try XCTUnwrap(view.layoutManager)
        let storage = try XCTUnwrap(view.textStorage)
        let after = (storage.string as NSString).range(of: "after")
        let afterRect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: after, actualCharacterRange: nil),
                                            in: try XCTUnwrap(view.textContainer))
        var cellHeight: CGFloat = -1
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let c = (v as? NSTextAttachment)?.attachmentCell as? CodeAttachmentCell { cellHeight = c.height }
        }
        XCTAssertGreaterThan(cellHeight, 80)
        XCTAssertGreaterThan(afterRect.minY, cellHeight)
        XCTAssertGreaterThan(height, afterRect.maxY - 1)
    }

    /// Copying across a code block writes its code, not the attachment character.
    func testCopyAcrossACodeBlock() throws {
        let view = MessageTextView(usingTextLayoutManager: false)
        view.show([.heading(level: 2, text: "Plan"), .bullet(indent: 0, marker: "•", text: "one **bold**"),
                   .code(language: "sh", text: "ls -la\necho hi"), .paragraph("done")])
        view.selectAll(nil)
        let board = NSPasteboard(name: NSPasteboard.Name("frog-test-\(UUID().uuidString)"))
        XCTAssertTrue(view.writeSelection(to: board, types: [.string]))
        let text = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(text, "Plan\n•\tone bold\nls -la\necho hi\ndone")
        board.releaseGlobally()
    }

    /// Every block kind in one message, rendered for review: `$TMPDIR/frog-snapshots/message-text.png`.
    func testRenderMessage() throws {
        let md = """
        ## Backends

        | spec | backend | notes |
        |---|:--:|--:|
        | `tang/<repo>` | the **bundled** sidecar | Metal |
        | `apple` | on-device | free |

        A paragraph right after the table.

        | a | b |
        |---|---|
        | 1 | 2 |

        > A quote that runs long enough to wrap onto a second line, to check the bar runs the full height.

        ---

        - top level bullet with enough words that it wraps onto another line under its own text
          - nested bullet
        1. numbered, with a [link](https://frog.toys) and *emphasis*

        ```swift
        let x = 1
        ```
        """
        let view = MessageTextView(usingTextLayoutManager: false)
        view.textContainer?.lineFragmentPadding = 0
        view.drawsBackground = false
        view.show(Markdown.parse(md))
        let width: CGFloat = 520
        let height = view.height(for: width)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 40, height: height + 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSView(frame: window.contentLayoutRect)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.frame.origin = CGPoint(x: 20, y: 20)
        host.addSubview(view)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        // See `SnapshotTests.outDir`.
        let dir = ProcessInfo.processInfo.environment["FROG_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appending(path: "message-text.png"))
    }
}
