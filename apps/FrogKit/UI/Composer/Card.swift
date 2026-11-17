import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The composer's parts (docs/design/composer/spec.md): a card of two rows at rest, the field
/// and its controls, with an optional status line on top. Everything here renders
/// `ComposerModel.State` and sends intents, so the live composer and the snapshots draw the same.
/// Frog-drawn from the tokens: no glass, no shadow, no system menus.
enum ComposerMetrics {
    static let radius = Tokens.Radius.field
    static let status: CGFloat = 32
    static let chip: CGFloat = 24
    static let action: CGFloat = 28
    static let icon: CGFloat = 14
    static let maxWidth: CGFloat = 720
    /// Under this the model chip drops its name and the where chip truncates in the middle.
    static let narrow: CGFloat = 420
    static let plate = Color.primary.opacity(0.08)
}

// MARK: - Icons

/// A 14-point glyph in a 14-point box, the controls' one icon size.
struct ComposerIcon: View {
    let name: String
    var color: Color?

    init(_ name: String, color: Color? = nil) {
        self.name = name
        self.color = color
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 11.5, weight: .regular))
            .frame(width: ComposerMetrics.icon, height: ComposerMetrics.icon)
            .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
    }
}

extension ComposerModel.Where {
    /// The where chip's glyph: a folder, a cloud, or a speech bubble.
    var icon: String {
        switch self {
        case .folder: "folder"
        case .cloud: "cloud"
        case .chat: "bubble.left"
        case .session(let s): s.repo == nil ? "bubble.left" : "folder"
        }
    }

    /// The chip's name: the folder's last component, the repo, or "Just chat".
    var name: String {
        switch self {
        case .folder(let folder, _, _, _, _): (folder as NSString).lastPathComponent
        case .cloud(let repo, _): repo
        case .chat: "Just chat"
        case .session(let s): s.repo.map { ($0 as NSString).lastPathComponent } ?? "Just chat"
        }
    }

    /// The branch beside the name; nil outside git, in a chat and for "No repo".
    var branch: String? {
        switch self {
        case .folder(_, let branch, _, let git, _): git && !branch.isEmpty ? branch : nil
        case .cloud(let repo, let branch): repo == "No repo" || branch.isEmpty ? nil : branch
        case .chat: nil
        case .session(let s): s.branch
        }
    }
}

extension ComposerModel.PrState {
    /// The word beside a PR's dot: always there, so colour is never the only signal.
    var short: String {
        switch self {
        case .failing: "failing"
        case .checks: "checking"
        case .draft: "draft"
        case .approved: "approved"
        case .closed: "closed"
        case .merged: "merged"
        }
    }
}

// MARK: - Chips

/// A control in the controls row: plain text until hovered or open, then the hover plate and
/// the normal text colour. 24 tall, 8 padding, 4 between icon and label.
struct ComposerChip<Label: View>: View {
    var open = false
    /// Marks the chip an error concerns (the notice stroke).
    var marked = false
    var help = ""
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { label }
                .font(.frog(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: ComposerMetrics.chip)
                .foregroundStyle(open || hovering ? Tokens.text : Tokens.textSecondary)
                .background(open || hovering ? ComposerMetrics.plate : .clear, in: .capsule)
                .overlay { if marked { Capsule().strokeBorder(Tokens.notice, lineWidth: 1.5) } }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(help)
        #if !os(watchOS)
        .onHover { hovering = $0 }
        #endif
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A status-line button: text on the 8% plate, 22 tall. `quiet`: plain muted text, no plate (a
/// secondary or Cancel). `urged`: the one filled button the line ever has (Open PR when done).
struct StatusButton: View {
    let title: String
    var quiet = false
    var urged = false
    var marked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.frog(size: 12, weight: urged ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .foregroundStyle(urged ? Tokens.onAccent : quiet ? Tokens.textSecondary : Tokens.text)
                .background(urged ? Tokens.accent : quiet ? .clear : ComposerMetrics.plate, in: .capsule)
                .overlay { if marked { Capsule().strokeBorder(Tokens.notice, lineWidth: 1.5) } }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// The status line's dismiss control.
struct StatusDismiss: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { ComposerIcon("xmark").padding(4).contentShape(.rect) }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.textSecondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
    }
}

// MARK: - The card

/// The card: fill, a 1px control stroke (muted when focused), radius 16. The status line on top
/// when there is something to say, then what waits above the field (queued follow-ups and
/// attachments), the field, and the controls.
struct ComposerCard<Status: View, Above: View, Field: View, Controls: View>: View {
    var showStatus = false
    var showAbove = false
    var focused = false
    @ViewBuilder let status: Status
    @ViewBuilder let above: Above
    @ViewBuilder let field: Field
    @ViewBuilder let controls: Controls

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: ComposerMetrics.radius, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showStatus {
                status
                    .font(.frog(size: 12))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
                    .frame(height: ComposerMetrics.status - 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Tokens.line).frame(height: 1)
            }
            if showAbove {
                above
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
            }
            field
                .padding(.top, 12)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            controls
                .frame(height: ComposerMetrics.action)
                .padding(.top, 6)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .zIndex(1)
        }
        // The 1px stroke sits outside the content, as the board's CSS border does.
        .padding(1)
        .background(Tokens.raised, in: shape)
        .overlay(shape.strokeBorder(focused ? Tokens.textSecondary : Tokens.lineStrong, lineWidth: 1).allowsHitTesting(false))
        .animation(.easeOut(duration: 0.22), value: showStatus)
    }
}

/// One waiting thing above the field: a queued follow-up or an attachment. Name first, detail in
/// muted, a remove control.
struct ComposerPendingChip: View {
    let title: String
    var detail: String?
    var help = ""
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(Tokens.text).lineLimit(1).truncationMode(.tail)
            if let detail { Text(detail).foregroundStyle(Tokens.textSecondary).lineLimit(1) }
            Button(action: remove) { ComposerIcon("xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textSecondary)
                .help("Remove")
                .accessibilityLabel("Remove \(title)")
        }
        .font(.frog(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: 320, alignment: .leading)
        .help(help)
    }
}

/// Queued follow-ups, then attachments, wrapping.
struct ComposerPending: View {
    let queued: [ComposerModel.Queued]
    let attachments: [ComposerModel.Attachment]
    let send: (ComposerModel.Intent) -> Void

    var body: some View {
        ComposerFlow(spacing: 6) {
            ForEach(Array(queued.enumerated()), id: \.offset) { i, q in
                ComposerPendingChip(
                    title: q.text.isEmpty ? "\(q.attachments.count) image\(q.attachments.count == 1 ? "" : "s")" : q.text,
                    detail: q.text.isEmpty || q.attachments.isEmpty ? nil : "+\(q.attachments.count)",
                    help: "Queued: goes in when Frog is ready for it"
                ) { send(.removeQueued(i)) }
            }
            ForEach(Array(attachments.enumerated()), id: \.offset) { i, a in
                ComposerPendingChip(title: a.name, detail: a.size > 0 ? ComposerPending.size(a.size) : nil) { send(.removeAttachment(i)) }
            }
        }
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : "\(max(1, bytes / 1000)) KB"
    }
}

/// A wrapping row.
struct ComposerFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += line + spacing
                line = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: .init(width: min(s.width, bounds.width), height: s.height))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (width: CGFloat, height: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: width, height: nil))
            if x > 0, x + s.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += s.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, s.height)
        }
        return (widest, y + line)
    }
}

// MARK: - The action

/// The one action: a 28 circle whose glyph changes in place. Only Send is filled green.
struct ComposerAction: View {
    let state: ComposerModel.State
    let send: (ComposerModel.Intent) -> Void
    @State private var hovering = false
    @State private var spin = false

    var body: some View {
        let d = ComposerModel.derive(state)
        let sending = state.busy == .sending
        Button { send(.action) } label: {
            ZStack {
                if sending {
                    Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 2)
                    Circle().trim(from: 0, to: 0.25)
                        .stroke(Tokens.text, style: .init(lineWidth: 2, lineCap: .round))
                        .padding(1)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
                } else {
                    Circle().fill(d.action == .send ? Tokens.accent : Color.primary.opacity(hovering ? 0.14 : 0.08))
                    glyph(d.action)
                        .id(d.action)
                        .transition(.opacity)
                }
            }
            .frame(width: ComposerMetrics.action, height: ComposerMetrics.action)
            .overlay {
                if d.action == .listening { Circle().strokeBorder(Tokens.accent, lineWidth: 2).padding(-2) }
                if state.error?.control == "action" { Circle().strokeBorder(Tokens.notice, lineWidth: 1.5).padding(-1.5) }
            }
            .animation(.easeOut(duration: 0.12), value: d.action)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(sending)
        #if !os(watchOS)
        .onHover { hovering = $0 }
        #endif
        .help(Self.help(d.action, state.busy))
        .accessibilityLabel(Self.help(d.action, state.busy))
    }

    @ViewBuilder
    private func glyph(_ a: ComposerModel.Action) -> some View {
        switch a {
        case .dictate: ComposerIcon("mic", color: Tokens.text)
        case .listening: ComposerIcon("waveform", color: Tokens.text)
        case .send: Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.onAccent)
        case .stop: RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Tokens.text).frame(width: 9, height: 9)
        case .queue: Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.text)
        }
    }

    static func help(_ a: ComposerModel.Action, _ busy: ComposerModel.Busy) -> String {
        switch a {
        case .dictate: "Dictate (⌥⌘V)"
        case .listening: "Stop dictating"
        case .send: busy == .sending ? "Sending" : "Send (↩)"
        case .stop: busy == .loading_model ? "Stop loading the model (Esc)" : "Stop (Esc)"
        case .queue: "Queue a follow-up (↩)"
        }
    }
}

// MARK: - Mode

extension ComposerModel.Mode {
    /// The mode menu's one line under each name (board 4).
    var line: String {
        switch self {
        case .default: "Asks before edits and commands"
        case .accept_edits: "Edits run; commands still ask"
        case .auto: "Runs what plainly serves the task"
        case .yolo: "Runs every step without asking"
        }
    }

    /// The menu's order: Ask, Accept edits, Auto, Yolo.
    static let menuOrder: [ComposerModel.Mode] = [.default, .accept_edits, .auto, .yolo]
}

/// The mode chip: the mode's name, and for Yolo a small bolt in the notice colour.
struct ModeChipLabel: View {
    let mode: ComposerModel.Mode
    var body: some View {
        if mode == .yolo { ComposerIcon("bolt.fill", color: Tokens.notice) }
        Text(mode.label)
    }
}

/// "When Frog asks": each mode with its line, a check on the current one.
struct ModeMenu: View {
    let mode: ComposerModel.Mode
    let send: (ComposerModel.Intent) -> Void
    var close: () -> Void = {}

    var body: some View {
        ComposerMenuPanel(width: 260) {
            ComposerMenuLabel("When Frog asks")
            ForEach(ComposerModel.Mode.menuOrder, id: \.self) { m in
                ComposerMenuButton(lit: m == mode) {
                    send(.setMode(m))
                    close()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            if m == .yolo { ComposerIcon("bolt.fill", color: Tokens.notice) }
                            Text(m.label).foregroundStyle(Tokens.text)
                            Spacer(minLength: 4)
                            if m == mode { ComposerIcon("checkmark", color: Tokens.text) }
                        }
                        Text(m.line).font(.frog(size: 12)).foregroundStyle(Tokens.textSecondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

// MARK: - The menu shell

/// A frog-drawn menu: the card's fill and stroke, radius 12, 4 inside. It opens upward from its
/// chip (`composerMenu`).
struct ComposerMenuPanel<Content: View>: View {
    var width: CGFloat = 300
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .font(.frog(size: 13))
            .padding(4)
            .frame(width: width, alignment: .leading)
            .background(Tokens.raised, in: .rect(cornerRadius: Tokens.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous).strokeBorder(Tokens.lineStrong, lineWidth: 1))
    }
}

/// A group's small label.
struct ComposerMenuLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.frog(size: Tokens.Size.label))
            .foregroundStyle(Tokens.textSecondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// A hairline between groups.
struct ComposerMenuRule: View {
    var body: some View { Rectangle().fill(Tokens.line).frame(height: 1).padding(.vertical, 4) }
}

/// A row you can press: at least 28 tall, the 7-radius plate under the pointer or the keyboard.
struct ComposerMenuButton<Label: View>: View {
    var lit = false
    var enabled = true
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(enabled && (lit || hovering) ? ComposerMetrics.plate : .clear,
                            in: .rect(cornerRadius: Tokens.Radius.control, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        #if !os(watchOS)
        .onHover { hovering = $0 }
        #endif
    }
}

/// The common row: an icon, a title, detail right-aligned in muted, a check for the current one.
struct ComposerMenuRow: View {
    var icon: String?
    var iconColor: Color?
    let title: String
    var detail: String?
    var key: String?
    var checked = false
    var dim = false
    var chevron = false
    var lit = false
    let action: () -> Void

    var body: some View {
        ComposerMenuButton(lit: lit, action: action) {
            HStack(spacing: 8) {
                if let icon { ComposerIcon(icon, color: iconColor) }
                Text(title).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(dim ? Tokens.textSecondary : Tokens.text)
                Spacer(minLength: 6)
                if let detail { Text(detail).font(.frog(size: 12)).foregroundStyle(Tokens.textSecondary).lineLimit(1).truncationMode(.head) }
                if let key { Text(key).font(.frog(size: 11, design: .monospaced)).foregroundStyle(Tokens.textSecondary) }
                if checked { ComposerIcon("checkmark", color: Tokens.text) }
                if chevron { ComposerIcon("chevron.right", color: Tokens.textSecondary) }
            }
            .foregroundStyle(Tokens.textSecondary)
        }
    }
}

/// The filter at the top of a menu. It takes focus when the menu opens.
struct ComposerMenuFilter: View {
    let placeholder: String
    @Binding var text: String
    var move: (Int) -> Void = { _ in }
    var pick: () -> Void = {}
    var close: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ComposerIcon("magnifyingglass", color: Tokens.textTertiary)
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Tokens.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.frog(size: 13))
                    .foregroundStyle(Tokens.text)
                    .focused($focused)
                    .onSubmit(pick)
                    #if os(macOS)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    #endif
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 7)
            Rectangle().fill(Tokens.line).frame(height: 1)
        }
        .padding(.bottom, 2)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

/// A small switch in the accent colour (New worktree).
struct ComposerSwitch: View {
    let on: Bool
    var body: some View {
        Capsule()
            .fill(on ? Tokens.accent : Color.primary.opacity(0.14))
            .frame(width: 22, height: 13)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(on ? Tokens.onAccent : Tokens.textSecondary).frame(width: 10, height: 10).padding(1.5)
            }
            .animation(.easeOut(duration: 0.12), value: on)
    }
}

extension View {
    /// Shows `panel` above this view while `open`, its leading or trailing edge on this view's,
    /// 6 above it. A click outside or Esc calls `close`.
    func composerMenu<Panel: View>(_ open: Bool, trailing: Bool = false, close: @escaping () -> Void,
                                   @ViewBuilder panel: () -> Panel) -> some View {
        overlay(alignment: trailing ? .topTrailing : .topLeading) {
            if open {
                panel()
                    .fixedSize()
                    #if os(macOS)
                    .background(MenuDismissal(close: close))
                    #endif
                    .padding(.bottom, 6)
                    // A zero-height frame at the anchor's top, the panel's bottom on it: it
                    // grows upward whatever its size.
                    .frame(height: 0, alignment: trailing ? .bottomTrailing : .bottomLeading)
                    .transition(.opacity)
            }
        }
    }
}

#if os(macOS)
/// Closes an open menu on a click outside it, or on Esc, without taking the keyboard.
private struct MenuDismissal: NSViewRepresentable {
    let close: () -> Void

    final class Box: NSView {
        var close: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
                guard let self, let window = self.window, e.window === window else { return e }
                if e.type == .keyDown {
                    guard e.keyCode == 53 else { return e }
                    DispatchQueue.main.async { self.close() }
                    return nil
                }
                let inside = self.convert(e.locationInWindow, from: nil)
                if !self.bounds.contains(inside) {
                    MenuDismissal.closedAt = .now
                    DispatchQueue.main.async { self.close() }
                }
                return e
            }
        }

        // Leaving the window (the menu closed) removes the monitor, above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// When a click outside last closed a menu: the chip that opened it must not reopen it on
    /// the same click.
    @MainActor static var closedAt = Date.distantPast

    func makeNSView(context: Context) -> Box {
        let v = Box()
        v.close = close
        return v
    }

    func updateNSView(_ v: Box, context: Context) { v.close = close }
}

enum ComposerMenus {
    /// True right after a click outside closed a menu, so the chip under that click doesn't
    /// reopen it.
    @MainActor static var justClosed: Bool { Date.now.timeIntervalSince(MenuDismissal.closedAt) < 0.35 }
}
#else
enum ComposerMenus {
    @MainActor static var justClosed: Bool { false }
}
#endif
