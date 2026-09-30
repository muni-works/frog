import SwiftUI

/// One conversation on the canvas: the transcript, full-bleed within the pane, with the composer
/// under it, and the pane's own instruments floating at its right edge (changes as a card or
/// pill, over the timeline rail). When the window is split, a glass header names the pane and
/// shows whether it's the one menus and the sidebar act on.
struct PaneView: View {
    let pane: Pane
    let panes: Panes
    /// 1-based, when the window is split.
    let number: Int?
    let insets: EdgeInsets
    let changesDocked: Bool
    let toggleChanges: () -> Void
    let window: NSWindow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Namespace private var glass

    static let headerHeight: CGFloat = 32

    private var workspace: Workspace { pane.workspace }
    private var ui: WindowState { pane.ui }
    private var conversation: Conversation? { pane.conversation }
    private var focused: Bool { panes.focusedID == pane.id }
    private var changesVisible: Bool { changesDocked || (pane.peekChanges && pane.hasTabs) }
    private var margin: CGFloat { WorkspaceView.margin }

    var body: some View {
        paneBody
            .onReceive(NotificationCenter.default.publisher(for: TurnRequest.name)) { note in
                if let r = note.object as? TurnRequest { handle(r) }
            }
    }

    @ViewBuilder
    private var paneBody: some View {
        ZStack(alignment: .topLeading) {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Nothing spills into the pane beside or below.
                .clipped()
                .contentMargins(.leading, insets.leading, for: .scrollContent)
                .contentMargins(.trailing, insets.trailing, for: .scrollContent)
                .contentMargins(.top, number == nil ? 0 : Self.headerHeight + margin, for: .scrollContent)

            GeometryReader { geo in
                let room = max(120, geo.size.height - margin * 2)
                GlassEffectContainer(spacing: 20) {
                    HStack(alignment: .top, spacing: 0) {
                        Spacer(minLength: 0)
                        instruments(room: room)
                    }
                }
                .padding(margin)
            }

            if let number {
                header(number)
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                    .padding(.top, margin)
                    .frame(maxWidth: .infinity)
            }

            if ui.findShown, let conversation {
                FindBar(state: ui, turns: conversation.turns)
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                    .frame(maxWidth: .infinity)
                    .padding(.top, margin + (number == nil ? 0 : Self.headerHeight + 8))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .environment(\.canvasInsets, insets)
        .environment(\.projectFolder, workspace.folder)
        .environment(\.models, workspace.models)
        .environment(\.switchFolder) { url in panes.switchFolder(url, in: pane) }
        .environment(\.startConversation) { url, prompt in panes.start(prompt, in: url, pane: pane) }
        .environment(\.openSession) { s in panes.open(s, in: pane, window: window) }
        // The agent moved the conversation to another folder: follow it there once the turn ends.
        .onChange(of: workspace.conversation.flatMap { $0.busy ? nil : $0.movedTo }) { _, url in
            if let url { panes.move(pane, to: url) }
        }
        // Clicking anywhere in a pane focuses it, without swallowing the click.
        .simultaneousGesture(TapGesture().onEnded { panes.focus(pane) })
        .animation(Motion.panel(reduced: reduceMotion), value: changesVisible)
        // Frog opened a terminal or preview: show it, rather than a button to find it by.
        .onChange(of: pane.toolCount) { old, new in
            if new > old, !changesVisible { toggleChanges() }
        }
        .animation(Motion.quick(reduced: reduceMotion), value: pane.hasRail)
        .animation(Motion.quick(reduced: reduceMotion), value: ui.findShown)
        .onChange(of: conversation.map(ObjectIdentifier.init)) { ui.visibleTurns = []; pane.peekChanges = false }
        .onChange(of: workspace.conversation?.sessionID, initial: true) { _, _ in noteSession() }
        .onChange(of: window) { _, _ in noteSession() }
        .onChange(of: activeState, initial: true) { _, _ in noteSession() }
        .onChange(of: focused) { _, _ in noteSession() }
        .confirmationDialog(
            undoTurn.flatMap(\.number).map { "Undo turn \($0)?" } ?? "Undo the last turn?",
            isPresented: Bindable(ui).confirmUndo
        ) {
            Button("Undo Changes", role: .destructive) {
                if let n = undoTurn?.number { Task { await workspace.rewind(toBefore: n) } }
            }
        } message: {
            Text("Files frog edited in that turn go back to how they were, and the conversation continues from just before it. The current session is kept, so you can go back to it.")
        }
        .onChange(of: workspace.conversation?.busy ?? false, initial: true) { _, busy in
            DockActivity.shared.set(ObjectIdentifier(workspace), busy: busy)
        }
        .onDisappear { DockActivity.shared.set(ObjectIdentifier(workspace), busy: false) }
        // A new workspace in this pane starts its views fresh.
        .id(ObjectIdentifier(workspace))
    }

    /// Tell the sidebar which window shows this conversation, and whether it's in front.
    private func noteSession() {
        guard let id = workspace.conversation?.sessionID else { return }
        Library.shared.register(window: window, for: id)
        if activeState == .key && focused {
            Library.shared.focused = id
            Library.shared.markRead(id)
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var detail: some View {
        if let race = workspace.race {
            RaceView(race: race) { workspace.endRace() }
        } else if let conversation = workspace.conversation {
            TranscriptView(
                conversation: conversation,
                actions: turnActions,
                jump: Bindable(ui).jumpTo,
                onVisibleTurns: { ui.visibleTurns = Set($0) }
            )
            // Another conversation is a fresh scroll view, starting at its end, not this one's
            // offset over different content.
            .id(ObjectIdentifier(conversation))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    BiggerModelLine(workspace: workspace, conversation: conversation)
                        .id(ObjectIdentifier(conversation))
                    PingLine(conversation: conversation)
                        .id(ObjectIdentifier(conversation))
                    ComposerView(workspace: workspace, conversation: conversation, window: ui)
                        .id(ObjectIdentifier(conversation))
                        // The panes you're not typing into step back a little.
                        .opacity(focused ? 1 : 0.72)
                }
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
            }
            .modifier(ConversationDropZone(conversation: conversation))
        }
    }

    /// When split, each pane gets the activity capsule the toolbar shows for a single pane (what
    /// it's doing, its model), led by its number (tinted when focused) and with a close button
    /// on hover.
    @ViewBuilder
    private func header(_ number: Int) -> some View {
        let badge = ActivityViewer.PaneBadge(number: number, focused: focused) { panes.close(pane) }
        Group {
            if let c = workspace.conversation, workspace.race == nil {
                ActivityViewer(workspace: workspace, conversation: c, jump: { ui.jumpTo = $0 }, pane: badge)
            } else if workspace.race != nil {
                Text("\(number)  \(workspace.name) · Racing")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        // The handle: drag it onto another pane's edge to move this pane there.
        .paneDraggable(.pane(pane.id), title: conversation?.title ?? workspace.name)
        .opacity(focused ? 1 : 0.8)
    }

    /// Changes (card or pill) above the timeline rail.
    @ViewBuilder
    private func instruments(room: CGFloat) -> some View {
        let top = number == nil ? 0 : WorkspaceView.headerClearance
        if let conversation, pane.hasTabs || pane.hasRail {
            VStack(alignment: .trailing, spacing: 8) {
                if pane.hasTabs {
                    if changesVisible {
                        // Changes, and any terminal or preview frog opened, as tabs of one card.
                        PaneArea(conversation: conversation,
                                 height: max(160, room - top - (pane.hasRail ? 160 : 0)),
                                 width: .constant(pane.cardWidth),
                                 collapse: { toggleChanges() })
                            .glassEffect(.regular, in: .rect(cornerRadius: 18))
                            .glassEffectID("changes", in: glass)
                            .shadow(color: .black.opacity(pane.peekChanges && !changesDocked ? 0.35 : 0), radius: 24, y: 10)
                    } else {
                        Button(action: toggleChanges) {
                            let changes = conversation.sessionChanges
                            HStack(spacing: 6) {
                                if !changes.isEmpty {
                                    Text("+\(changes.reduce(0) { $0 + $1.added })").foregroundStyle(.green)
                                    Text("−\(changes.reduce(0) { $0 + $1.removed })").foregroundStyle(.red)
                                }
                                if pane.toolCount > 0 {
                                    Image(systemName: conversation.panes.panes.contains { $0.kind == .preview } ? "globe" : "terminal")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(height: WorkspaceView.button)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectID("changes", in: glass)
                        .help(pane.changeCount > 0
                              ? "\(pane.changeCount) file\(pane.changeCount == 1 ? "" : "s") changed (⌥⌘0)"
                              : "Terminal and preview (⌥⌘0)")
                    }
                }
                if pane.hasRail {
                    TimelineRail(
                        conversation: conversation,
                        visible: ui.visibleTurns,
                        marked: ui.findShown ? Set(ui.matches(in: conversation.turns)) : [],
                        actions: turnActions,
                        jump: { ui.jumpTo = $0 }
                    )
                    // Grows with the conversation instead of standing full height from turn one.
                    .frame(height: min(room - top, CGFloat(conversation.turns.count) * 22 + 28))
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("timeline", in: glass)
                    .transition(.opacity)
                }
            }
            .padding(.top, top)
            .frame(maxHeight: room, alignment: .top)
        }
    }

    /// The latest finished turn that changed files (what Edit > Undo Last Turn reverts).
    private var undoTurn: TurnState? {
        conversation?.turns.last { $0.finished && $0.number != nil && !TurnParts($0).changes.isEmpty }
    }

    /// A phone asked to fork or rewind a turn of what this pane shows: do it here, as the
    /// transcript's own actions would, and say which session it continues in.
    private func handle(_ r: TurnRequest) {
        guard let c = conversation, c.sessionID == r.session, r.claim() else { return }
        Task {
            switch r.action {
            case .fork:
                let next = workspace.fork(afterTurn: r.turn)
                for _ in 0..<100 where next?.sessionID == nil { try? await Task.sleep(for: .milliseconds(100)) }
                r.done(next?.sessionID)
            case .rewind:
                r.done(await workspace.rewind(toBefore: r.turn))
            }
        }
    }

    private var turnActions: TurnActions {
        TurnActions(
            fork: { workspace.fork(afterTurn: $0) },
            rewind: { turn in Task { await workspace.rewind(toBefore: turn) } }
        )
    }
}

/// The line between two panes: invisible until hovered, then a small glass grip; drag it to
/// resize the panes beside it, double-click to share the space evenly again.
struct PaneDividerHandle: View {
    let divider: PaneLayout.Divider
    @Binding var resizing: Bool
    let move: (CGFloat) -> Void
    let equalize: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    static let hit: CGFloat = 12

    private var horizontal: Bool { divider.axis == .horizontal }

    var body: some View {
        let p = divider.parent
        let frame = horizontal
            ? CGRect(x: divider.position - Self.hit / 2, y: p.minY, width: Self.hit, height: p.height)
            : CGRect(x: p.minX, y: divider.position - Self.hit / 2, width: p.width, height: Self.hit)
        Color.clear
            .contentShape(.rect)
            .overlay {
                Capsule()
                    .fill(.tint.opacity(dragging ? 0.9 : 0.5))
                    .frame(width: horizontal ? 4 : 44, height: horizontal ? 44 : 4)
                    .glassEffect(.regular, in: .capsule)
                    .opacity(hovering || dragging ? 1 : 0)
            }
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .pointerStyle(horizontal ? .columnResize : .rowResize)
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { equalize() }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(WorkspaceView.canvasSpace))
                    .onChanged { g in
                        dragging = true
                        resizing = true
                        let t = horizontal
                            ? (g.location.x - p.minX) / max(p.width, 1)
                            : (g.location.y - p.minY) / max(p.height, 1)
                        move(t)
                    }
                    .onEnded { _ in
                        dragging = false
                        resizing = false
                    }
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help("Drag to resize, double-click to even out")
    }
}
