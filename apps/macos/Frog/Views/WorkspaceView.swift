import SwiftUI

/// The conversation is the canvas: it fills the window, and everything else floats over it as
/// Liquid Glass. The window holds one to three panes side by side, each a conversation with its
/// own composer and its own instruments (changes and the timeline rail) at its right edge. The
/// session list (left) floats over the first pane and folds into a rail of status tiles. Each
/// pane's column is centered in the space its cards leave, and the toolbar's activity capsule
/// sits over the focused pane's column.
struct WorkspaceView: View {
    let panes: Panes
    /// What the user asked for, per window. Whether the list actually docks also depends on the
    /// window's width (`docked`), so widening a window brings it back.
    @SceneStorage("showSessions") private var showSessions = true
    @State private var canvasSize = CGSize(width: 1100, height: 760)
    /// The canvas in global coordinates, to place a drag's pointer.
    @State private var canvasOrigin: CGPoint = .zero
    @State private var dragger = PaneDragger()
    /// A divider being dragged: layout changes follow the pointer, unanimated.
    @State private var resizing = false
    @State private var docked = Docked()
    /// Too narrow for even the session rail: sessions live behind a toolbar button.
    @State private var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The session list floated over the conversation because the window is too narrow to dock it.
    @State private var peekSessions = false
    @Namespace private var glass
    /// This view's window, so the sidebar can bring an already-open conversation forward.
    @State private var window: NSWindow?
    @State private var renamingTitle = false
    @State private var newTitle = ""

    struct Docked: Equatable {
        var sessions = false
        /// Panes whose changes card stands beside their column.
        var changes: Set<Pane.ID> = []
    }

    /// Everything the layout depends on, so it's resolved again when any of it changes.
    private struct LayoutInputs: Equatable {
        var size: CGSize
        var sessions: Bool
        var layout: PaneLayout
        var panes: [PaneInputs]
    }

    private struct PaneInputs: Equatable {
        var id: Pane.ID
        /// What it shows: another conversation is a cut, so the cards it brings don't animate in.
        var shows: ObjectIdentifier?
        var changes: Bool
        var hasChanges: Bool
        var hasRail: Bool
    }

    static let sessionsWidth: CGFloat = 250
    static let changesWidth: CGFloat = 380
    static let button: CGFloat = 36
    /// Estimated width of the collapsed changes pill ("+42 −7").
    static let changesPill: CGFloat = 96
    static let margin: CGFloat = 12
    /// Clearance between a card and the conversation.
    static let gap: CGFloat = 16
    /// Narrowest a column may get; a card that would squeeze it further stays folded.
    static let minColumn: CGFloat = 520
    /// Split panes accept narrower columns: that's the point of splitting.
    static let minSplitColumn: CGFloat = 460
    /// Below this the session rail folds away too.
    static let compactWidth: CGFloat = 760
    /// Hysteresis: a card that's docked stays docked until the column would lose this much more,
    /// so dragging a window edge near a threshold doesn't flicker the layout.
    static let slack: CGFloat = 40
    /// Room a split pane's instruments leave for its header.
    static let headerClearance: CGFloat = PaneView.headerHeight + 8

    private var focused: Pane { panes.focused }
    private var workspace: Workspace { focused.workspace }
    private var minColumn: CGFloat { panes.isSplit ? Self.minSplitColumn : Self.minColumn }

    // Layout. Panes fill the window right of the session list in rows and columns
    // (`PaneLayout`); panes against the left edge extend under the list, so their transcripts
    // scroll beneath its glass. Within a pane the column is centered between its cards. A card
    // docks only if every column still gets `minColumn`; otherwise it folds to its rail or pill,
    // and that floats it over the conversation instead ("peek"). The session list comes first:
    // changes dock in what's left.

    private func extent(sessions open: Bool) -> CGFloat {
        if !open && compact { return Self.gap }
        return Self.margin + (open ? Self.sessionsWidth : SessionRail.width) + Self.gap
    }

    private func extent(changes open: Bool, _ pane: Pane) -> CGFloat {
        guard pane.changeCount > 0 || pane.hasRail else { return Self.gap }
        let width = open ? Self.changesWidth : (pane.changeCount > 0 ? Self.changesPill : TimelineRail.width)
        return Self.margin + width + Self.gap
    }

    /// The area panes share: the window right of the session list.
    private func region(sessions open: Bool) -> CGRect {
        let ext = extent(sessions: open)
        return CGRect(x: ext, y: 0, width: max(0, canvasSize.width - ext), height: canvasSize.height)
    }

    /// Smallest a pane may be dragged to, across a divider.
    static let minPane: CGFloat = 280
    /// The canvas's coordinate space, for dragging dividers.
    static let canvasSpace = "frog-canvas"

    /// A pane's frame in the window and the insets that keep its column clear of the cards.
    private func placement(_ pane: Pane, sessions open: Bool, changes: Bool) -> (frame: CGRect, insets: EdgeInsets) {
        let ext = extent(sessions: open)
        var r = panes.layout.frames(in: region(sessions: open))[pane.id] ?? .zero
        let leftmost = r.minX <= ext + 0.5
        if leftmost {
            r.size.width += r.minX
            r.origin.x = 0
        }
        // Split panes have a header to keep clear of.
        let top = panes.isSplit ? Self.headerClearance + Self.margin : 0
        return (r, EdgeInsets(top: top, leading: leftmost ? ext : Self.gap, bottom: 0, trailing: extent(changes: changes, pane)))
    }

    private func placement(_ pane: Pane) -> (frame: CGRect, insets: EdgeInsets) {
        placement(pane, sessions: docked.sessions, changes: docked.changes.contains(pane.id))
    }

    /// The column a pane is left with.
    private func column(_ pane: Pane, sessions open: Bool, changes: Bool) -> CGFloat {
        let p = placement(pane, sessions: open, changes: changes)
        return p.frame.width - p.insets.leading - p.insets.trailing
    }

    private func fits(_ column: CGFloat, keeping: Bool) -> Bool {
        column >= minColumn - (keeping ? Self.slack : 0)
    }

    private var layoutInputs: LayoutInputs {
        LayoutInputs(size: canvasSize, sessions: showSessions, layout: panes.layout, panes: panes.items.map {
            PaneInputs(id: $0.id, shows: $0.conversation.map(ObjectIdentifier.init), changes: $0.showChanges, hasChanges: $0.changeCount > 0, hasRail: $0.hasRail)
        })
    }

    private func relayout() {
        compact = canvasSize.width < Self.compactWidth + (compact ? Self.slack : 0)
        let sessions = showSessions && panes.items.allSatisfy {
            fits(column($0, sessions: true, changes: false), keeping: docked.sessions)
        }
        var changes: Set<Pane.ID> = []
        for p in panes.items where p.showChanges && p.changeCount > 0 {
            if fits(column(p, sessions: sessions, changes: true), keeping: docked.changes.contains(p.id)) {
                changes.insert(p.id)
            }
        }
        docked = Docked(sessions: sessions, changes: changes)
        if sessions { peekSessions = false }
        for p in panes.items where changes.contains(p.id) { p.peekChanges = false }
    }

    private var sessionsVisible: Bool { docked.sessions || peekSessions }

    private func changesVisible(_ pane: Pane) -> Bool {
        docked.changes.contains(pane.id) || (pane.peekChanges && pane.changeCount > 0)
    }

    /// Where the (only) pane's column is centered, relative to the window's center.
    private var focusedOffset: CGFloat {
        let p = placement(focused)
        return p.frame.minX + p.insets.leading + (p.frame.width - p.insets.leading - p.insets.trailing) / 2 - canvasSize.width / 2
    }

    private func toggleSessions() {
        Haptics.settle()
        let fitsOpen = panes.items.allSatisfy {
            fits(column($0, sessions: true, changes: docked.changes.contains($0.id)), keeping: false)
        }
        if docked.sessions || fitsOpen {
            peekSessions = false
            showSessions.toggle()
        } else {
            peekSessions.toggle()
        }
    }

    private func toggleChanges(_ pane: Pane) {
        Haptics.settle()
        if docked.changes.contains(pane.id) || fits(column(pane, sessions: docked.sessions, changes: true), keeping: false) {
            pane.peekChanges = false
            pane.showChanges.toggle()
        } else {
            pane.peekChanges.toggle()
        }
    }

    // MARK: Dragging

    /// Where a drag at this (global) point would land: a pane and a zone of it. Nothing over
    /// the session list or rail, or for a pane over itself. A pane under the list only splits
    /// in the part that's its own.
    private func dropTarget(_ payload: PaneDragger.Payload?, at global: CGPoint) -> (pane: Pane, drop: PaneDrop, frame: CGRect)? {
        guard let payload else { return nil }
        let p = CGPoint(x: global.x - canvasOrigin.x, y: global.y - canvasOrigin.y)
        let ext = extent(sessions: docked.sessions) - Self.gap
        guard p.x >= ext else { return nil }
        for pane in panes.items {
            var f = placement(pane).frame
            guard f.contains(p) else { continue }
            if case .pane(let id) = payload, id == pane.id { return nil }
            if f.minX == 0 {
                f.size.width -= ext
                f.origin.x = ext
            }
            return (pane, PaneDrop(at: p, in: f), f)
        }
        return nil
    }

    private func perform(_ payload: PaneDragger.Payload, at global: CGPoint) {
        guard let target = dropTarget(payload, at: global) else { return }
        Haptics.settle()
        panes.drop(payload, on: target.pane, target.drop, window: window)
    }

    /// While dragging: the zone the drop would take, and a small capsule following the pointer.
    @ViewBuilder
    private var dragPreview: some View {
        if dragger.active {
            let target = dropTarget(dragger.payload, at: dragger.location)
            ZStack(alignment: .topLeading) {
                if let target {
                    let r = target.drop.rect(in: target.frame).insetBy(dx: 8, dy: 8)
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.tint.opacity(0.14))
                        .strokeBorder(.tint.opacity(0.75), lineWidth: 2)
                        .overlay {
                            Label(dropLabel(target.drop), systemImage: dropSymbol(target.drop))
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .glassEffect(.regular, in: .capsule)
                        }
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
                Text(dragger.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .frame(maxWidth: 260)
                    .glassEffect(.regular, in: .capsule)
                    .fixedSize()
                    .offset(x: dragger.location.x - canvasOrigin.x + 10, y: dragger.location.y - canvasOrigin.y + 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .animation(.snappy(duration: 0.18), value: target.map { "\($0.pane.id)\($0.drop)" })
            .transition(.opacity)
        }
    }

    private func dropLabel(_ drop: PaneDrop) -> String {
        guard case .edge(let e) = drop else {
            if case .pane = dragger.payload { return "Swap" }
            return "Open here"
        }
        switch e {
        case .left: return "Split left"
        case .right: return "Split right"
        case .top: return "Split up"
        case .bottom: return "Split down"
        }
    }

    private func dropSymbol(_ drop: PaneDrop) -> String {
        switch drop {
        case .center: "arrow.left.arrow.right"
        case .edge(.left), .edge(.right): "rectangle.split.2x1"
        case .edge(.top), .edge(.bottom): "rectangle.split.1x2"
        }
    }

    private func openInFocused(_ s: SessionInfo) {
        panes.open(s, in: focused, window: window)
    }

    private func split(_ s: SessionInfo? = nil, _ edge: PaneEdge = .right) {
        Haptics.settle()
        panes.split(s, on: edge, window: window)
    }

    var body: some View {
        let numbers = panes.numbers
        ZStack(alignment: .topLeading) {
            ForEach(Array(panes.items.enumerated()), id: \.element.id) { i, pane in
                let place = placement(pane)
                PaneView(
                    pane: pane,
                    panes: panes,
                    number: panes.isSplit ? i + 1 : nil,
                    insets: place.insets,
                    changesDocked: docked.changes.contains(pane.id),
                    toggleChanges: { toggleChanges(pane) },
                    window: window
                )
                .frame(width: max(0, place.frame.width), height: max(0, place.frame.height))
                .offset(x: place.frame.minX, y: place.frame.minY)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            GeometryReader { geo in
                let room = max(120, geo.size.height - Self.margin * 2)
                GlassEffectContainer(spacing: 20) {
                    sessions(room: room)
                }
                .padding(Self.margin)
            }
            .environment(\.openSession) { openInFocused($0) }
            .environment(\.openSessionInSplit) { split($0) }
            .environment(\.switchFolder) { panes.switchFolder($0, in: focused) }
            .environment(\.paneNumbers, numbers)

            ForEach(panes.layout.dividers(in: region(sessions: docked.sessions))) { d in
                PaneDividerHandle(divider: d, resizing: $resizing) { t in
                    panes.moveDivider(d, to: t, minimum: Self.minPane)
                } equalize: {
                    panes.equalize(d)
                }
            }

            dragPreview

            if focused.ui.paletteShown {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { focused.ui.paletteShown = false }
                    CommandPalette(commands: workspace.commands(showChanges: Binding(
                        get: { focused.showChanges },
                        set: { _ in toggleChanges(focused) }
                    ))) {
                        focused.ui.paletteShown = false
                    }
                    .padding(.top, 80)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        // Always the window's size, whatever the panes' fixed widths add up to: the panes are
        // sized from this, so it mustn't be sized from them.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(Self.canvasSpace))
        .onGeometryChange(for: CGSize.self, of: \.size) { canvasSize = $0 }
        .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .global).origin }) { canvasOrigin = $0 }
        .environment(\.paneDragger, dragger)
        .onAppear { dragger.onDrop = { perform($0, at: $1) } }
        .animation(.easeOut(duration: 0.15), value: dragger.active)
        .onChange(of: layoutInputs, initial: true) { old, new in
            if old.panes.map(\.shows) != new.panes.map(\.shows) { Motion.cut(relayout) } else { relayout() }
        }
        // Over everything in the window: sidebar, rail, and (hidden meanwhile) the toolbar.
        .modifier(LightboxHost())
        .environment(\.projectFolder, workspace.folder)
        // The focused pane's folder as the window's document: proxy icon in the title bar
        // (⌘-click for its path, drag it anywhere).
        .navigationDocument(workspace.folder)
        .navigationTitle(windowTitle)
        .navigationSubtitle(place)
        .toolbarTitleMenu { if let c = workspace.conversation { titleMenu(c) } }
        // One backdrop for the whole canvas, so the conversation reads as a single surface.
        .background(FrogCanvas.color.ignoresSafeArea())
        .background(WindowReader { window = $0 })
        .animation(Motion.panel(reduced: reduceMotion), value: sessionsVisible)
        .animation(Motion.panel(reduced: reduceMotion), value: docked)
        .animation(resizing ? nil : Motion.panel(reduced: reduceMotion), value: panes.layout)
        .animation(Motion.quick(reduced: reduceMotion), value: focused.ui.paletteShown)
        .onChange(of: workspace.selection) { peekSessions = false }
        .onChange(of: panes.focusedID) { peekSessions = false }
        .onExitCommand {
            if focused.ui.findShown {
                focused.ui.findShown = false
            } else {
                peekSessions = false
                panes.items.forEach { $0.peekChanges = false }
            }
        }
        .focusedSceneValue(\.frogWindow, FrogWindow(
            workspace: workspace, state: focused.ui,
            toggleSessions: toggleSessions, toggleChanges: { toggleChanges(focused) },
            sessionsShown: sessionsVisible, changesShown: changesVisible(focused),
            newChat: {
                panes.switchFolder(nil, in: focused)
                focused.ui.focusComposer()
            },
            split: panes.canSplit ? { split(nil, $0 == .vertical ? .bottom : .right) } : nil,
            closePane: panes.isSplit ? { panes.close(focused) } : nil,
            focusPane: panes.isSplit ? { panes.focus(step: $0) } : nil
        ))
        // The phone asked for a conversation: here if this pane is a blank chat, else beside it,
        // so nothing on screen is replaced.
        .onReceive(NotificationCenter.default.publisher(for: OpenRequest.name)) { note in
            guard let r = note.object as? OpenRequest, r.claim() else { return }
            let blank = focused.conversation.map { $0.sessionID == nil && $0.turns.isEmpty } ?? true
            if let s = r.session {
                if !blank, panes.canSplit { panes.split(s, window: window) } else { panes.open(s, in: focused, window: window) }
            } else {
                if !blank, panes.canSplit { panes.split(window: window) }
                panes.switchFolder(r.folder, in: panes.focused)
            }
            let pane = panes.focused
            Task {
                // Resuming swaps the pane's workspace in once its history is loaded.
                for _ in 0..<30 where pane.conversation == nil || (r.session != nil && pane.conversation?.sessionID != r.session?.id) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let text = r.text, !text.isEmpty { pane.conversation?.submit(text) }
                r.done(pane.conversation)
            }
        }
        // Handoff: the phone offers the conversation you're reading here, and back.
        .userActivity(Handoff.conversation, isActive: workspace.conversation?.sessionID != nil) { a in
            a.title = workspace.conversation?.title ?? "Conversation"
            a.userInfo = ["session": workspace.conversation?.sessionID ?? ""]
            a.isEligibleForHandoff = true
        }
        .onContinueUserActivity(Handoff.conversation) { a in
            guard let id = a.userInfo?["session"] as? String,
                  let s = Library.shared.sessions.first(where: { $0.id == id }) else { return }
            openInFocused(s)
        }
        .alert("Rename Conversation", isPresented: $renamingTitle) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let id = workspace.conversation?.sessionID {
                    Task { await Library.shared.rename(id, to: newTitle) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .toolbar {
            if compact && !sessionsVisible {
                ToolbarItem(placement: .navigation) {
                    Button("Show Conversations", systemImage: "sidebar.left", action: toggleSessions)
                        .help("Show conversations (⌃⌘S)")
                }
            }
            ToolbarItem(placement: .principal) {
                // Split, each pane shows its own in its header.
                if !panes.isSplit, let c = workspace.conversation, workspace.race == nil {
                    // Over the column, not the window.
                    ActivityViewer(workspace: workspace, conversation: c) { focused.ui.jumpTo = $0 }
                        .environment(\.openSession) { openInFocused($0) }
                        .offset(x: focusedOffset)
                }
            }
            // The viewer draws its own glass capsule; without this the toolbar adds a second.
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button("Split", systemImage: "rectangle.split.2x1") { split() }
                    .contextMenu {
                        Button("Split Right") { split(nil, .right) }
                        Button("Split Down") { split(nil, .bottom) }
                    }
                    .help("Split pane (⌘\\)")
                    .disabled(!panes.canSplit)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Commands", systemImage: "command") { focused.ui.paletteShown.toggle() }
                    .help("Command Palette (⌘K)")
            }
        }
    }

    // MARK: Glass

    /// The session list, or the rail it folds to.
    @ViewBuilder
    private func sessions(room: CGFloat) -> some View {
        if sessionsVisible {
            SessionList(workspace: workspace, maxHeight: room) { toggleSessions() }
                .frame(width: Self.sessionsWidth)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .glassEffectID("sessions", in: glass)
                .shadow(color: .black.opacity(peekSessions ? 0.35 : 0), radius: 24, y: 10)
        } else if !compact {
            // Folded, it's a rail of status tiles that morphs back out.
            SessionRail(workspace: workspace, maxHeight: room, expand: toggleSessions)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .glassEffectID("sessions", in: glass)
        }
    }
}

extension EnvironmentValues {
    /// Horizontal space the floating cards take from the canvas, for content positioned outside
    /// scroll views (which get it as content margins).
    @Entry var canvasInsets = EdgeInsets()
}

extension View {
    /// A floating Liquid Glass card.
    func floatingPanel(radius: CGFloat = 18) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: radius))
    }
}

/// A scroll view as tall as its content, up to `maxHeight`, so a floating card hugs short
/// content instead of stretching to the window.
struct HuggingScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height, 1), maxHeight))
    }
}

extension WorkspaceView {
    private var windowTitle: String {
        if workspace.race != nil { return workspace.name }
        return workspace.conversation?.title ?? (workspace.isChat ? "New Chat" : "New Conversation")
    }

    /// Where the focused conversation lives: the project and its branch; nothing for a chat.
    private var place: String {
        if workspace.race != nil { return "Racing" }
        guard !workspace.isChat else { return "" }
        return [workspace.name, workspace.git?.branch].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func titleMenu(_ conversation: Conversation) -> some View {
        Button("Rename…") {
            newTitle = conversation.title ?? ""
            renamingTitle = true
        }
        .disabled(conversation.sessionID == nil)
        if !workspace.isChat {
            Button("Show Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.folder]) }
        }
        Picker("Cloud Models", selection: Binding(get: { workspace.cloud }, set: { c in Task { await workspace.setCloud(c) } })) {
            Text("Ask First").tag(Workspace.CloudPolicy.ask)
            Text("Allow").tag(Workspace.CloudPolicy.allow)
            Text("Keep Code on Your Devices").tag(Workspace.CloudPolicy.deny)
        }
        if let id = conversation.sessionID {
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(id, forType: .string)
            }
            Divider()
            Button("Archive") {
                Library.shared.setArchived(id, true)
                workspace.newSession()
            }
        }
    }
}

/// The whole conversation takes dropped files, not just the composer: images attach to the
/// next message and other files are mentioned.
struct ConversationDropZone: ViewModifier {
    let conversation: Conversation
    @State private var targeted = false
    @AppStorage("playfulFrog") private var playful = true

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                conversation.dropped = urls
                return true
            } isTargeted: { targeted = $0 }
            .overlayPreferenceValue(FrogAnchorKey.self) { frog in
                if targeted {
                    DropOverlay(playful: playful, frog: frog)
                        .padding(8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

/// "Drop to attach", over a green lily pad tint. With the playful frog on, the frog's tongue
/// reaches from its mouth to the label: the empty-state frog's if it's on screen, else a small
/// frog that appears just above the label.
private struct DropOverlay: View {
    let playful: Bool
    let frog: Anchor<CGRect>?
    @State private var out = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let mouth = frog.map { a in
                let r = geo[a]
                return CGPoint(x: r.midX, y: r.maxY - r.height * 0.18)
            } ?? CGPoint(x: center.x, y: center.y - 46)
            ZStack {
                RoundedRectangle(cornerRadius: playful ? 24 : 16)
                    .strokeBorder(.tint, lineWidth: 2)
                    .background(.tint.opacity(playful ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: playful ? 24 : 16))
                if playful {
                    Path { p in
                        p.move(to: mouth)
                        p.addLine(to: CGPoint(x: center.x, y: center.y - 18))
                    }
                    .trim(from: 0, to: out ? 1 : 0)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    if frog == nil {
                        FrogFace(mood: .waiting, size: 28)
                            .position(x: mouth.x, y: mouth.y - 8)
                    }
                }
                Label("Drop to attach", systemImage: "paperclip")
                    .font(.headline)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .position(center)
            }
        }
        .onAppear {
            if reduceMotion {
                out = true
            } else {
                withAnimation(.easeOut(duration: 0.25)) { out = true }
            }
        }
    }
}

/// Find in the conversation: a glass bar under the toolbar. Matches are whole turns (prompt or
/// output); Return / ⌘G steps through them, and they're marked on the timeline rail.
struct FindBar: View {
    @Bindable var state: WindowState
    let turns: [TurnState]
    @FocusState private var focused: Bool

    var body: some View {
        let matches = state.matches(in: turns)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in conversation", text: $state.findQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(width: 220)
                .onSubmit { state.find(1, in: turns) }
            Text(matches.isEmpty ? (state.findQuery.isEmpty ? "" : "No matches") : "\(min(state.findIndex, matches.count - 1) + 1) of \(matches.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            Button { state.find(-1, in: turns) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(matches.isEmpty)
                .help("Find Previous (⇧⌘G)")
            Button { state.find(1, in: turns) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(matches.isEmpty)
                .help("Find Next (⌘G)")
            Button("Done") { state.findShown = false }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .onAppear { focused = true }
        .onChange(of: state.findQuery) {
            state.findIndex = -1
            state.find(1, in: turns)
        }
    }
}

/// Sessions as a tree: forks hang off the session they branched from. Click one to open it.
struct SessionTree: View {
    let workspace: Workspace
    let dismiss: () -> Void
    @State private var diagram: Diagram?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Session tree", systemImage: "arrow.triangle.branch").font(.headline)
            if let diagram, !diagram.nodes.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    DiagramCanvas(diagram: diagram) { node in
                        workspace.selection = node.id
                        dismiss()
                    }
                }
                .frame(width: min(720, (diagram.layout?.width ?? 300) + 4), height: min(520, (diagram.layout?.height ?? 200) + 4))
            } else if loaded {
                Text("No sessions yet").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(width: 200, height: 80)
            }
        }
        .padding(16)
        .task {
            diagram = await Diagram.sessionTree(in: workspace.folder)
            loaded = true
        }
    }
}

/// Hands a SwiftUI view its NSWindow.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { found(v.window) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { found(v.window) }
    }
}
