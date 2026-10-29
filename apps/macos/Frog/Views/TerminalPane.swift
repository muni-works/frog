import AppKit
import SwiftUI

/// A shell the engine runs, shown from the grids it sends (`paneScreen`). Keys go back as
/// `paneInput`; the view tells the engine its size in cells whenever that changes.
struct TerminalPane: View {
    let pane: ToolPane
    let hub: PaneHub
    @State private var typedAt: Date?
    @State private var focused = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if let screen = pane.screen {
                    TerminalGrid(
                        screen: screen,
                        live: !pane.closed,
                        focused: $focused,
                        input: { data in
                            hub.input(pane.id, data)
                            typedAt = Date()
                        },
                        resize: { cols, rows in hub.resize(pane.id, cols: cols, rows: rows) }
                    )
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(scheme == .dark ? 0.28 : 0.05), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08)))
            .padding([.horizontal, .bottom], 10)
        }
        .animation(.easeOut(duration: 0.2), value: typedAt != nil)
        .task(id: typedAt) {
            guard typedAt != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            typedAt = nil
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text(pane.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? pane.title)
                .font(.frog(size: 12))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if let exit = pane.exit {
                Text(exit == 0 ? "exited" : "exited \(exit)")
                    .font(.frog(size: 10))
                    .foregroundStyle(exit == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            } else if typedAt != nil {
                // The engine shares this shell: show it when the user is the one typing.
                Label("You", systemImage: "keyboard")
                    .font(.frog(size: 10))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Starting shell…").font(.frog(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// The grid itself: monospaced lines, a block cursor, a drag selection you can copy, and keys
/// translated to what a terminal sends.
struct TerminalGrid: NSViewRepresentable {
    let screen: PaneScreen
    let live: Bool
    @Binding var focused: Bool
    let input: (String) -> Void
    let resize: (Int, Int) -> Void

    func makeNSView(context: Context) -> TerminalGridView {
        let v = TerminalGridView()
        v.input = input
        v.resize = resize
        v.onFocus = { focused = $0 }
        v.screen = screen
        return v
    }

    func updateNSView(_ v: TerminalGridView, context: Context) {
        v.input = input
        v.resize = resize
        v.onFocus = { focused = $0 }
        v.live = live
        if v.screen != screen {
            v.screen = screen
            v.needsDisplay = true
        }
    }
}

final class TerminalGridView: NSView, NSUserInterfaceValidations {
    var screen: PaneScreen? { didSet { needsDisplay = true } }
    var live = true
    var input: (String) -> Void = { _ in }
    var resize: (Int, Int) -> Void = { _, _ in }
    var onFocus: (Bool) -> Void = { _ in }

    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var cell: CGSize {
        let w = ("M" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: ceil(w), height: ceil(font.ascender - font.descender + font.leading) + 2)
    }
    private let inset: CGFloat = 8
    /// Selection as (row, col) endpoints, in reading order once normalized.
    private var anchor: (Int, Int)?
    private var head: (Int, Int)?
    private var reported: (Int, Int)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func becomeFirstResponder() -> Bool {
        onFocus(true)
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocus(false)
        needsDisplay = true
        return true
    }

    override func layout() {
        super.layout()
        let c = cell
        let cols = max(20, Int((bounds.width - 2 * inset) / c.width))
        let rows = max(4, Int((bounds.height - 2 * inset) / c.height))
        if reported.map({ $0 != (cols, rows) }) ?? true {
            reported = (cols, rows)
            resize(cols, rows)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let screen else { return }
        let c = cell
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink: NSColor = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let sel = selection
        for (row, line) in screen.lines.prefix(screen.rows).enumerated() {
            let y = inset + CGFloat(row) * c.height
            if let sel, row >= sel.from.0, row <= sel.to.0 {
                let start = row == sel.from.0 ? sel.from.1 : 0
                let end = row == sel.to.0 ? sel.to.1 : screen.cols
                if end > start {
                    let r = NSRect(x: inset + CGFloat(start) * c.width, y: y, width: CGFloat(end - start) * c.width, height: c.height)
                    NSColor.selectedTextBackgroundColor.withAlphaComponent(0.5).setFill()
                    r.fill()
                }
            }
            (line as NSString).draw(at: NSPoint(x: inset, y: y + 1), withAttributes: attrs)
        }
        // A block cursor: solid when focused and the shell is live, hollow otherwise.
        let cur = NSRect(
            x: inset + CGFloat(screen.cursorCol) * c.width, y: inset + CGFloat(screen.cursorRow) * c.height,
            width: c.width, height: c.height)
        if live, window?.firstResponder === self {
            ink.withAlphaComponent(0.85).setFill()
            cur.fill()
            let row = screen.cursorRow < screen.lines.count ? screen.lines[screen.cursorRow] : ""
            if let ch = row.dropFirst(screen.cursorCol).first {
                (String(ch) as NSString).draw(at: NSPoint(x: cur.minX, y: cur.minY + 1), withAttributes: [.font: font, .foregroundColor: dark ? NSColor.black : NSColor.white])
            }
        } else if live {
            ink.withAlphaComponent(0.6).setStroke()
            NSBezierPath(rect: cur.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard live else { return }
        // ⌘ shortcuts are the app's (copy and paste arrive as menu actions).
        guard !event.modifierFlags.contains(.command) else { return }
        if let s = Self.sequence(for: event) {
            input(s)
            clearSelection()
        }
    }

    /// What a terminal sends for a key: control characters, escape sequences for arrows and
    /// the like, ESC-prefixed text for ⌥ (Meta), and plain text otherwise.
    static func sequence(for event: NSEvent) -> String? {
        let flags = event.modifierFlags
        let special: [UInt16: String] = [
            126: "\u{1B}[A", 125: "\u{1B}[B", 124: "\u{1B}[C", 123: "\u{1B}[D", // arrows
            115: "\u{1B}[H", 119: "\u{1B}[F", // home, end
            116: "\u{1B}[5~", 121: "\u{1B}[6~", // page up, down
            117: "\u{1B}[3~", // forward delete
            53: "\u{1B}", 36: "\r", 76: "\r", 48: "\t", 51: "\u{7F}",
            122: "\u{1B}OP", 120: "\u{1B}OQ", 99: "\u{1B}OR", 118: "\u{1B}OS", // F1–F4
        ]
        if let s = special[event.keyCode] {
            if flags.contains(.shift), event.keyCode == 48 { return "\u{1B}[Z" }
            return s
        }
        if flags.contains(.control), let ch = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first {
            switch ch {
            case "a"..."z": return String(UnicodeScalar(ch.value - 96)!)
            case "[": return "\u{1B}"
            case "\\": return "\u{1C}"
            case "]": return "\u{1D}"
            case " ", "@": return "\u{00}"
            default: return nil
            }
        }
        guard let text = event.characters, !text.isEmpty else { return nil }
        if flags.contains(.option), let plain = event.charactersIgnoringModifiers { return "\u{1B}" + plain }
        return text
    }

    override func flagsChanged(with event: NSEvent) {}

    @objc func paste(_ sender: Any?) {
        guard live, let s = NSPasteboard.general.string(forType: .string) else { return }
        input(s)
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let screen else { return }
        anchor = (0, 0)
        head = (max(0, screen.rows - 1), screen.cols)
        needsDisplay = true
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return selectedText?.isEmpty == false
        case #selector(paste(_:)): return live
        case #selector(selectAll(_:)): return screen != nil
        default: return true
        }
    }

    // MARK: Selection

    private func cellAt(_ p: NSPoint) -> (Int, Int) {
        let c = cell
        let col = Int(((p.x - inset) / c.width).rounded(.down))
        let row = Int(((p.y - inset) / c.height).rounded(.down))
        return (max(0, min(row, (screen?.rows ?? 1) - 1)), max(0, min(col, screen?.cols ?? 0)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        anchor = cellAt(p)
        head = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        head = cellAt(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let a = anchor, let h = head, a == h { clearSelection() }
    }

    private func clearSelection() {
        anchor = nil
        head = nil
        needsDisplay = true
    }

    private var selection: (from: (Int, Int), to: (Int, Int))? {
        guard let a = anchor, let h = head, a != h else { return nil }
        return (a.0, a.1) <= (h.0, h.1) ? (a, h) : (h, a)
    }

    var selectedText: String? {
        guard let screen, let sel = selection else { return nil }
        var out: [String] = []
        for row in sel.from.0...sel.to.0 where row < screen.lines.count {
            let line = screen.lines[row]
            let start = row == sel.from.0 ? sel.from.1 : 0
            let end = row == sel.to.0 ? sel.to.1 : line.count
            let s = line.index(line.startIndex, offsetBy: min(start, line.count))
            let e = line.index(line.startIndex, offsetBy: min(max(start, end), line.count))
            out.append(String(line[s..<e]))
        }
        return out.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n")
    }
}
