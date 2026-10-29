import SwiftUI

/// The right side of the canvas as one card: tabs for Changes, the terminal and the preview,
/// with the selected one below. Drag its leading edge to resize.
struct PaneArea: View {
    let conversation: Conversation
    let height: CGFloat
    @Binding var width: CGFloat
    var collapse: (() -> Void)?
    @State private var dragStart: CGFloat?

    static let minWidth: CGFloat = 420
    static let maxWidth: CGFloat = 560

    private var hub: PaneHub { conversation.panes }
    private var changeCount: Int { conversation.sessionChanges.count }

    /// Tabs in order: Changes (when there are any), then panes as they opened.
    var tabs: [PaneHub.Tab] {
        (changeCount > 0 ? [.changes] : []) + hub.panes.map { .pane($0.id) }
    }

    private var current: PaneHub.Tab? {
        if let s = hub.selected, tabs.contains(s) { return s }
        return tabs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
            ZStack {
                if current == .changes {
                    ChangesInspector(conversation: conversation, maxHeight: height - 44)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                // Panes stay mounted behind the front one: the engine keeps reading a preview
                // (and a shell keeps its focus) while another tab is up.
                ForEach(hub.panes) { pane in
                    Group {
                        switch pane.kind {
                        case .terminal: TerminalPane(pane: pane, hub: hub)
                        case .preview: PreviewPane(pane: pane, hub: hub)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(current == .pane(pane.id) ? 1 : 0)
                    .allowsHitTesting(current == .pane(pane.id))
                    .accessibilityHidden(current != .pane(pane.id))
                }
                if current == nil {
                    ContentUnavailableView("No Panes", systemImage: "rectangle.righthalf.inset.filled", description: Text("⇧⌘T opens a terminal, ⇧⌘P a preview."))
                }
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .leading) { handle }
    }

    private var strip: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                let paneID: String? = if case .pane(let id) = tab { id } else { nil }
                TabButton(
                    title: title(tab), symbol: symbol(tab), selected: tab == current,
                    close: paneID.map { id in { hub.close(id) } }
                ) {
                    hub.selected = tab
                }
            }
            Spacer(minLength: 0)
            if let collapse {
                Button(action: collapse) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide panes (⌥⌘0)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func title(_ tab: PaneHub.Tab) -> String {
        switch tab {
        case .changes: "Changes"
        case .pane(let id):
            switch hub.pane(id)?.kind {
            case .terminal: "Terminal"
            case .preview: hub.pane(id).map { $0.title.isEmpty || $0.title == "Preview" ? "Preview" : $0.title } ?? "Preview"
            case nil: "Pane"
            }
        }
    }

    private func symbol(_ tab: PaneHub.Tab) -> String {
        switch tab {
        case .changes: "plusminus"
        case .pane(let id): hub.pane(id)?.kind == .preview ? "globe" : "terminal"
        }
    }

    /// The resize grip on the card's leading edge.
    private var handle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .contentShape(.rect)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1).onChanged { g in
                    let start = dragStart ?? width
                    dragStart = start
                    width = min(Self.maxWidth, max(Self.minWidth, start - g.translation.width))
                }
                .onEnded { _ in dragStart = nil }
            )
    }
}

/// One tab: icon, title, and a close button that appears on hover for panes.
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
                Image(systemName: symbol).font(.frog(size: 10))
                Text(title).font(.frog(size: 12)).lineLimit(1)
                if let close {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.caption2.weight(.semibold)).frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(hovering || selected ? 1 : 0)
                    .help("Close")
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, close == nil ? 9 : 5)
            .padding(.vertical, 5)
            .background(selected ? AnyShapeStyle(.primary.opacity(0.10)) : (hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear)), in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .onHover { hovering = $0 }
    }
}
