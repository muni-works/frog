import SwiftUI

/// The right side of the canvas as one card: tabs for Changes, the terminal and the preview,
/// with the selected one below. Drag its leading edge to resize. Frog draws everything inside
/// it from `Tokens`, the same spec as the web's inspector (docs/design/frog-web/README.md).
struct PaneArea: View {
    let conversation: Conversation
    let height: CGFloat
    @Binding var width: CGFloat
    var collapse: (() -> Void)?
    /// Where a terminal opened from its tab starts.
    var folder: URL? = nil
    /// Runs one of the composer tray's git actions (`draft_commit`, `open_pr`, `push`); nil
    /// where there's no repo, so the Changes tab shows no Commit or Open PR.
    var git: ((String) -> Void)? = nil
    @State private var dragStart: CGFloat?
    @State private var gripHover = false
    /// Terminal or Preview picked while there's no pane to show (a chat has no folder to open
    /// a shell in): the tab is still there, with its empty state.
    @State private var placeholder: PaneKind?

    static let minWidth: CGFloat = 360
    static let maxWidth: CGFloat = 560
    static let defaultWidth: CGFloat = 420
    /// The grip's hit area: this far out over the gap beside the card, and this far in.
    static let gripReach: CGFloat = 8
    static let gripInside: CGFloat = 8
    static let widthKey = "inspectorWidth"
    /// The width last dragged to, else the default.
    static var savedWidth: CGFloat {
        let w = UserDefaults.standard.double(forKey: widthKey)
        return w > 0 ? min(maxWidth, max(minWidth, w)) : defaultWidth
    }

    private var hub: PaneHub { conversation.panes }
    /// Any changed file at all. The count would walk every turn's diffs per body pass; the
    /// card's tab list only needs whether there are any (see `Conversation.changesVersion`).
    private var hasChanges: Bool { conversation.changesVersion > 0 && !conversation.sessionChanges.isEmpty }

    /// One place in the strip: Changes, a pane, or Terminal / Preview with no pane yet.
    enum Slot: Hashable {
        case tab(PaneHub.Tab)
        case open(PaneKind)
    }

    /// The strip, always Changes, Terminal, Preview in that order (the first pane of each kind,
    /// or a tab that opens one), then any further panes as they opened.
    var slots: [Slot] {
        let terminal = hub.panes.first { $0.kind == .terminal }
        let preview = hub.panes.first { $0.kind == .preview }
        let rest = hub.panes.filter { $0.id != terminal?.id && $0.id != preview?.id }
        return [.tab(.changes),
                terminal.map { .tab(.pane($0.id)) } ?? .open(.terminal),
                preview.map { .tab(.pane($0.id)) } ?? .open(.preview)]
            + rest.map { .tab(.pane($0.id)) }
    }

    /// Tabs with something behind them: Changes, then panes as they opened.
    var tabs: [PaneHub.Tab] {
        [.changes] + hub.panes.map { .pane($0.id) }
    }

    private var current: Slot {
        if let placeholder { return .open(placeholder) }
        if let s = hub.selected, tabs.contains(s) { return .tab(s) }
        return .tab(.changes)
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
            ZStack {
                switch current {
                case .tab(.changes):
                    if hasChanges {
                        ChangesInspector(conversation: conversation, maxHeight: height - 44,
                                         commit: git.map { git in { git("draft_commit") } },
                                         pr: git.map { git in { git(conversation.boundPrs.isEmpty ? "open_pr" : "push") } },
                                         hasPr: !conversation.boundPrs.isEmpty)
                            .frame(maxHeight: .infinity, alignment: .top)
                    } else {
                        InspectorEmpty(symbol: "plusminus", title: "No changes yet", detail: "Files Frog edits show up here.")
                    }
                case .open(.terminal):
                    InspectorEmpty(symbol: "terminal", title: "No terminal",
                                   detail: "A chat has no folder to open a shell in.")
                case .open(.preview):
                    InspectorEmpty(symbol: "globe", title: "No preview",
                                   detail: "Pages Frog opens show up here.")
                case .tab(.pane):
                    EmptyView()
                }
                // Panes stay mounted behind the front one: the engine keeps reading a preview
                // (and a shell keeps its focus) while another tab is up.
                ForEach(hub.panes) { pane in
                    let front = current == .tab(.pane(pane.id))
                    Group {
                        switch pane.kind {
                        case .terminal: TerminalPane(pane: pane, hub: hub)
                        case .preview: PreviewPane(pane: pane, hub: hub)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(front ? 1 : 0)
                    .allowsHitTesting(front)
                    .accessibilityHidden(!front)
                }
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .leading) { handle }
        // A pane frog (or a shortcut) brings to the front wins over a tab's empty state.
        .onChange(of: hub.selected) { placeholder = nil }
    }

    private var strip: some View {
        HStack(spacing: 2) {
            ForEach(slots, id: \.self) { slot in
                let paneID: String? = if case .tab(.pane(let id)) = slot { id } else { nil }
                TabButton(
                    title: title(slot), symbol: symbol(slot), selected: slot == current,
                    close: paneID.map { id in { hub.close(id) } }
                ) {
                    select(slot)
                }
            }
            Spacer(minLength: 0)
            if let collapse {
                Button(action: collapse) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textSecondary)
                .help("Hide inspector (⌥⌘0)")
                .accessibilityLabel("Hide inspector")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func select(_ slot: Slot) {
        switch slot {
        case .tab(let tab):
            placeholder = nil
            hub.selected = tab
        case .open(.terminal):
            // Terminal opens a shell where there's a folder for it; a chat shows the empty state.
            if let folder {
                placeholder = nil
                hub.openTerminal(cwd: folder)
            } else {
                placeholder = .terminal
            }
        case .open(.preview):
            placeholder = nil
            hub.openPreview()
        }
    }

    private func title(_ slot: Slot) -> String {
        switch slot {
        case .tab(.changes): "Changes"
        case .open(.terminal): "Terminal"
        case .open(.preview): "Preview"
        case .tab(.pane(let id)):
            switch hub.pane(id)?.kind {
            case .terminal: "Terminal"
            case .preview:
                // The fixed Preview tab keeps its label; a further preview shows its page.
                if slots.dropFirst(2).first == slot { "Preview" }
                else { hub.pane(id).map { $0.title.isEmpty ? "Preview" : $0.title } ?? "Preview" }
            case nil: "Pane"
            }
        }
    }

    private func symbol(_ slot: Slot) -> String {
        switch slot {
        case .tab(.changes): "plusminus"
        case .open(.terminal): "terminal"
        case .open(.preview): "globe"
        case .tab(.pane(let id)): hub.pane(id)?.kind == .preview ? "globe" : "terminal"
        }
    }

    /// The resize grip on the card's leading edge: a bar shows on hover (the web's grip), and it
    /// takes presses a little outside the card too. It was an invisible 8 pt strip inside the
    /// edge, so a press just off it landed on the canvas, which drags the window; and its pushed
    /// resize cursor could outlive the hover (the card moving away from under the pointer).
    private var handle: some View {
        Color.clear
            .frame(width: Self.gripReach + Self.gripInside)
            .contentShape(.rect)
            .overlay {
                Capsule()
                    .fill(Tokens.textTertiary)
                    .frame(width: 3, height: 36)
                    .opacity(gripHover || dragStart != nil ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .offset(x: -Self.gripReach)
            .pointerStyle(.columnResize)
            .onHover { gripHover = $0 }
            .animation(.easeOut(duration: 0.12), value: gripHover)
            .gesture(
                DragGesture(minimumDistance: 1).onChanged { g in
                    let start = dragStart ?? width
                    dragStart = start
                    width = min(Self.maxWidth, max(Self.minWidth, start - g.translation.width))
                }
                .onEnded { _ in dragStart = nil }
            )
            // Double-click puts the default width back, like the web's grip.
            .onTapGesture(count: 2) { width = Self.defaultWidth }
    }
}

/// One tab: icon and label, a pill behind the selected one, and a close button on hover for
/// panes.
private struct TabButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let close: (() -> Void)?
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5))
                Text(title).font(.frog(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
                if let close {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .semibold)).frame(width: 14, height: 14)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.textTertiary)
                    .opacity(hovering ? 1 : 0)
                    .help("Close")
                    .accessibilityLabel("Close \(title)")
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, close == nil ? 9 : 5)
            .padding(.vertical, 5)
            .background(selected ? Tokens.hover : (hovering ? Tokens.hover.opacity(0.5) : .clear), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Tokens.text : Tokens.textSecondary)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
