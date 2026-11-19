import SwiftUI

/// The conversation is the canvas, between two flush columns (docs/design/flush): the session
/// list at the window's left edge and, per pane, the inspector at the pane's right edge, each the
/// window's full height (up under the title bar) with a hairline on its inner edge. The window
/// holds one to three panes side by side, each a conversation with its own composer, inspector
/// and timeline rail. The session list folds into a rail of status tiles. Each pane's column is
/// centered in the space the columns leave. Collapsed, the session list is gone: its toggle
/// waits beside the traffic lights (with a dot when something needs you), and the list peeks
/// over the page from the left edge on hover.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The session list floated over the conversation because the window is too narrow to dock it.
    @State private var peekSessions = false
    /// The peek came from the pointer at the window's left edge: it goes when the pointer
    /// moves out over the page.
    @State private var peekByHover = false
    /// The sidebar's width, as last dragged (`savedSidebarWidth`).
    @AppStorage(WorkspaceView.sidebarWidthKey) private var sidebarWidthRaw = Double(WorkspaceView.sessionsWidth)
    private var sidebarWidth: CGFloat { Self.clampSidebar(sidebarWidthRaw) }
    /// This view's window, so the sidebar can bring an already-open conversation forward.
    @State private var window: NSWindow?
    @State private var renamingTitle = false
    /// The session the title menu's Delete… is asking about.
    @State private var deletingSession: String?
    @State private var newTitle = ""
    // The sidebar's view options, for the quick-switch shortcuts' reading of it.
    @AppStorage("sidebarGroup") private var sidebarGroup = SessionList.Grouping.date
    @AppStorage("sidebarSort") private var sidebarSort = SessionList.Sort.activity
    @AppStorage("sidebarScope") private var sidebarScope = AttentionTree.Scope.live

    struct Docked: Equatable {
        var sessions = false
        /// Panes whose changes card stands beside their column.
        var changes: Set<Pane.ID> = []
    }

    /// Everything the layout depends on, so it's resolved again when any of it changes.
    private struct LayoutInputs: Equatable {
        var size: CGSize
        var sessions: Bool
        var sidebar: CGFloat
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

    /// The sidebar's default width; dragged between `minSessions` and `maxSessions`, kept under
    /// `sidebarWidthKey` beside the inspector's.
    static let sessionsWidth: CGFloat = 250
    static let minSessions: CGFloat = 220
    static let maxSessions: CGFloat = 400
    static let sidebarWidthKey = "sidebarWidth"
    static func clampSidebar(_ w: Double) -> CGFloat {
        min(maxSessions, max(minSessions, w > 0 ? CGFloat(w) : sessionsWidth))
    }
    /// The width last dragged to, else the default.
    static var savedSidebarWidth: CGFloat { clampSidebar(UserDefaults.standard.double(forKey: sidebarWidthKey)) }
    static let button: CGFloat = 36
    /// Room between the timeline rail and the inspector's hairline (or the pane's edge), and
    /// above the rail and a split pane's header.
    static let inset = Tokens.Space.row
    /// Where the traffic lights end, from the window's leading edge: the sidebar's header in
    /// the title row fills from there to its hairline, so the title starts past it.
    static let trafficLights: CGFloat = 84
    /// The strip at the window's left edge that peeks the collapsed sidebar on hover.
    static let peekEdge: CGFloat = 6
    /// The toolbar's own inset at the window's trailing edge: the inspector's tabs in the title
    /// row are this much narrower than its column, so they start at its hairline.
    static let toolbarTrailing: CGFloat = 8
    /// Narrowest a column may get; a card that would squeeze it further stays folded.
    static let minColumn: CGFloat = 520
    /// Split panes accept narrower columns: that's the point of splitting.
    static let minSplitColumn: CGFloat = 460
    /// Hysteresis: a card that's docked stays docked until the column would lose this much more,
    /// so dragging a window edge near a threshold doesn't flicker the layout.
    static let slack: CGFloat = 40

    init(panes: Panes, sessionsOpen: Bool = true) {
        self.panes = panes
        // The scene's stored choice wins; this is the default (and a test's, with no scene).
        _showSessions = SceneStorage(wrappedValue: sessionsOpen, "showSessions")
    }

    private var focused: Pane { panes.focused }

    /// What this window offers the menu bar.
    private var frogWindow: FrogWindow {
        FrogWindow(
            workspace: workspace, state: focused.ui,
            toggleSessions: toggleSessions, toggleChanges: { toggleChanges(focused) },
            showTerminal: showTerminal, showPreview: showPreview, toggleInspect: toggleInspect,
            sessionsShown: sessionsVisible, changesShown: changesVisible(focused),
            newChat: newSession,
            split: panes.canSplit ? { split(nil, $0 == .vertical ? .bottom : .right) } : nil,
            closePane: panes.isSplit ? { panes.close(focused) } : nil,
            focusPane: panes.isSplit ? { panes.focus(step: $0) } : nil,
            toggleMaximize: panes.isSplit ? { panes.toggleMaximized(focused) } : nil,
            maximized: panes.maximizedPane != nil,
            sidebarOrder: sidebarOrder,
            openSidebarSession: { openInFocused($0) },
            showDocs: { showDocs() },
            showSettings: { showSettings($0) },
            showCustomize: { showCustomize($0) }
        )
    }

    /// The sidebar's conversations as its top-level rows, in the order its groups show them:
    /// pins, then one group per project folder (newest activity first), then chats — the
    /// started-by children are nested under their parents and don't count. What the
    /// quick-switch shortcuts (⌘1…9, ⇧⌘]/⇧⌘[) step through.
    /// Derived by `SessionOrder` (below) from the listing, pins, archive and grouping — none of
    /// which a streamed turn touches. The window root used to re-derive it on every body pass
    /// (per streamed delta): the tree walk sorted every session, twice, per 30 Hz batch.
    private var sidebarOrder: [SessionInfo] {
        SessionOrder.order(group: sidebarGroup, sort: sidebarSort, scope: sidebarScope,
                           current: workspace.opening ?? workspace.currentSession)
    }
    private var workspace: Workspace { focused.workspace }
    private var minColumn: CGFloat { panes.isSplit ? Self.minSplitColumn : Self.minColumn }

    // Layout. Panes fill the window right of the session list's hairline in rows and columns
    // (`PaneLayout`). Within a pane the column is centered between the inspector (with the rail
    // beside it) and the pane's leading edge; the transcript and composer bring their own gutter.
    // A column docks only if every conversation column still gets `minColumn`; otherwise it
    // folds away, and opening it floats it over the conversation instead ("peek"). The session
    // list comes first: inspectors dock in what's left.

    /// The session list's width, its hairline included: where the panes start. Collapsed, it's
    /// gone.
    private func extent(sessions open: Bool) -> CGFloat {
        open ? sidebarWidth : 0
    }

    /// What a pane's right edge keeps from its conversation: the inspector when docked, and the
    /// timeline rail beside it.
    private func extent(changes open: Bool, _ pane: Pane, paneWidth: CGFloat = .infinity) -> CGFloat {
        let card = open && pane.hasTabs ? pane.cardWidth : 0
        guard pane.hasRail else { return card }
        // A narrow split pane's rail is its slim strip (see `PaneWidth`): it reserves only that.
        let rail = panes.isSplit && PaneWidth(paneWidth) == .narrow ? TimelineRail.slimWidth : TimelineRail.width
        return card + Self.inset + rail
    }

    /// The area panes share: the window right of the session list.
    private func region(sessions open: Bool) -> CGRect {
        let ext = extent(sessions: open)
        return CGRect(x: ext, y: 0, width: max(0, canvasSize.width - ext), height: canvasSize.height)
    }

    /// Smallest a pane may be dragged to, across a divider.
    /// Smaller is unreadable even with a narrow pane's slimmed chrome.
    static let minPane: CGFloat = 360
    /// Smallest a pane showing a terminal or preview may get: the card is the pane's point, and
    /// a preview reads fine at this width. (A conversation pane keeps `minPane`.)
    static let minToolPane: CGFloat = 260
    /// The canvas's coordinate space, for dragging dividers.
    static let canvasSpace = "frog-canvas"

    /// A pane's frame in the window and the insets that keep its column clear of the cards.
    /// A maximized pane takes the whole canvas region; the others are empty (their contents
    /// step aside, cut to nothing), and the layout comes back exactly on restore.
    private func placement(_ pane: Pane, sessions open: Bool, changes: Bool) -> (frame: CGRect, insets: EdgeInsets) {
        let r = panes.layout.frames(in: region(sessions: open), maximizing: panes.maximized)[pane.id] ?? .zero
        if r == .zero { return (r, EdgeInsets()) }
        // No pane has a header, split or not: every pane's top is the line under the title bar.
        return (r, EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: extent(changes: changes, pane, paneWidth: r.width)))
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
        LayoutInputs(size: canvasSize, sessions: showSessions, sidebar: sidebarWidth, layout: panes.layout, panes: panes.items.map {
            PaneInputs(id: $0.id, shows: $0.conversation.map(ObjectIdentifier.init), changes: $0.showChanges, hasChanges: $0.hasTabs, hasRail: $0.hasRail)
        })
    }

    private func relayout() {
        let sessions = showSessions && panes.items.allSatisfy {
            fits(column($0, sessions: true, changes: false), keeping: docked.sessions)
        }
        var changes: Set<Pane.ID> = []
        for p in panes.items where p.showChanges && p.hasTabs {
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
        docked.changes.contains(pane.id) || (pane.peekChanges && pane.hasTabs)
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

    /// Show the focused pane's side card, if it's hidden.
    private func revealPanes(_ pane: Pane) {
        if !changesVisible(pane) { toggleChanges(pane) }
    }

    /// A terminal in the focused conversation's folder (⇧⌘T).
    private func showTerminal() {
        guard let conversation = focused.conversation else { return }
        conversation.panes.openTerminal(cwd: workspace.folder)
        revealPanes(focused)
    }

    /// The live preview (⇧⌘P).
    private func showPreview() {
        guard let conversation = focused.conversation else { return }
        conversation.panes.openPreview()
        revealPanes(focused)
    }

    /// Inspect mode in the preview (⇧⌘I): shows the preview if it isn't in front.
    private func toggleInspect() {
        guard let hub = focused.conversation?.panes else { return }
        if let p = hub.previews.first { hub.selected = .pane(p.id) } else { hub.openPreview() }
        revealPanes(focused)
        hub.inspecting.toggle()
    }

    // MARK: Dragging

    /// Where a drag at this (global) point would land: a pane and a zone of it. Nothing over
    /// the session list or rail, or for a pane over itself.
    private func dropTarget(_ payload: PaneDragger.Payload?, at global: CGPoint) -> (pane: Pane, drop: PaneDrop, frame: CGRect)? {
        guard let payload else { return nil }
        let p = CGPoint(x: global.x - canvasOrigin.x, y: global.y - canvasOrigin.y)
        guard p.x >= extent(sessions: docked.sessions) else { return nil }
        for pane in panes.items {
            let f = placement(pane).frame
            guard f.contains(p) else { continue }
            if case .pane(let id) = payload, id == pane.id { return nil }
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
        panes.backToApp()
        panes.open(s, in: focused, window: window)
    }

    // MARK: Documentation

    private var inDocs: Bool { panes.mode == .docs }
    /// Documentation or Settings: the panes stay mounted under the page, out of reach.
    private var inMode: Bool { panes.mode != .threads }
    private var docs: AppDocs? { AppDocs.bundled }
    /// The page on screen: the one last shown, else the first.
    private var docsPage: AppDocs.Page? { docs?.page(panes.docsPage) ?? docs?.pages.first }

    /// Documentation mode, on a page if given. The panes stay mounted underneath; only the
    /// keyboard leaves the composer, so typing doesn't land in a draft you can't see.
    private func showDocs(_ slug: String? = nil) {
        if !inMode { window?.makeFirstResponder(nil) }
        panes.showDocs(slug ?? panes.docsPage ?? docs?.pages.first?.slug)
    }

    /// Back to the thread, the composer taking the keyboard back.
    private func backToApp() {
        guard inMode else { return }
        panes.backToApp()
        focused.ui.focusComposer()
    }

    private var docsCommands: [PaletteCommand] {
        guard let docs else { return [] }
        var out = [PaletteCommand(id: "docs", title: "Documentation", subtitle: "Help", symbol: "book") { showDocs() }]
        for page in docs.pages {
            out.append(PaletteCommand(id: "docs-\(page.slug)", title: page.title, subtitle: "Documentation, \(page.section)", symbol: "book") {
                showDocs(page.slug)
            })
        }
        return out
    }

    // MARK: Settings

    /// Settings mode, on a section if given (an id or an old tab name), else the last one.
    private func showSettings(_ section: String? = nil) {
        if !inMode { window?.makeFirstResponder(nil) }
        panes.showSettings(section)
    }

    private var settingsCommands: [PaletteCommand] {
        var out = [PaletteCommand(id: "settings", title: "Settings", subtitle: "⌘,", symbol: "gearshape") { showSettings() }]
        for s in SettingsCatalog.bundled.sections {
            out.append(PaletteCommand(id: "settings-\(s.id)", title: s.label, subtitle: "Settings", symbol: "gearshape") { showSettings(s.id) })
        }
        return out
    }

    // MARK: Customize

    /// Customize mode, on a section if given (an id or an old name), else the last one.
    private func showCustomize(_ section: String? = nil) {
        if !inMode { window?.makeFirstResponder(nil) }
        panes.showCustomize(section)
    }

    private var customizeCommands: [PaletteCommand] {
        var out = [PaletteCommand(id: "customize", title: "Customize", subtitle: "Skills, connections, rules, memory", symbol: "slider.horizontal.3") { showCustomize() }]
        for s in CustomizeCatalog.bundled.sections {
            out.append(PaletteCommand(id: "customize-\(s.id)", title: s.label, subtitle: "Customize", symbol: "slider.horizontal.3") { showCustomize(s.id) })
        }
        return out
    }

    /// The Customize page, opaque over the panes right of the sidebar.
    @ViewBuilder
    private var customizeLayer: some View {
        if panes.mode == .customize {
            CustomizeView(panes: panes) { prompt in
                let folder = panes.customize.folder
                backToApp()
                panes.start(prompt, in: folder, pane: focused)
            }
            .padding(.leading, extent(sessions: docked.sessions))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(FrogCanvas.color)
            .transition(.opacity)
        }
    }

    /// The section, opaque over the panes right of the sidebar.
    @ViewBuilder
    private var settingsLayer: some View {
        if panes.mode == .settings {
            SettingsSectionView(section: panes.settingsSection,
                                machine: Binding(get: { panes.settingsMachine }, set: { panes.settingsMachine = $0 }))
                .padding(.leading, extent(sessions: docked.sessions))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(FrogCanvas.color)
                .transition(.opacity)
        }
    }

    /// The page, opaque over the panes right of the sidebar.
    @ViewBuilder
    private var docsLayer: some View {
        if inDocs {
            DocsPageView(docs: docs, page: docsPage) { showDocs($0) }
                .padding(.leading, extent(sessions: docked.sessions))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(FrogCanvas.color)
                .transition(.opacity)
        }
    }

    /// The phone offered the conversation you're reading here, and back: open it focused.
    private func continueHandoff(_ a: NSUserActivity) {
        let id = a.userInfo?["session"] as? String
        let s = id.flatMap { id in Library.shared.sessions.first { $0.id == id } }
        guard let s else { return }
        openInFocused(s)
    }

    /// A new chat in the focused pane, the composer taking the keyboard (⌘N).
    private func newSession() {
        panes.backToApp()
        panes.switchFolder(nil, in: focused)
        focused.ui.focusComposer()
    }

    private func split(_ s: SessionInfo? = nil, _ edge: PaneEdge = .right) {
        Haptics.settle()
        panes.split(s, on: edge, window: window)
    }

    /// One pane, placed: its frame, its clip, and its part in the documentation's cover.
    private func paneCell(_ pane: Pane, number: Int?, stripInTitleRow: Bool) -> some View {
        let place = placement(pane)
        return PaneView(
            pane: pane,
            panes: panes,
            number: number,
            insets: place.insets,
            underTitleBar: place.frame.minY < 0.5,
            stripInTitleRow: stripInTitleRow,
            trailingEdge: place.frame.maxX >= canvasSize.width - 0.5,
            changesDocked: docked.changes.contains(pane.id),
            toggleChanges: { toggleChanges(pane) },
            window: window
        )
        // Exactly its frame: content that wants more is cut at the pane's own edge, never
        // centered out over its neighbors (the rail and text of one pane over the next).
        // Open at the top for a pane under the title bar: its inspector's column runs up
        // under it.
        .frame(width: max(0, place.frame.width), height: max(0, place.frame.height), alignment: .topLeading)
        .clipShape(TitleBarClip(open: place.frame.minY < 0.5))
        .offset(x: place.frame.minX, y: place.frame.minY)
        // Under the documentation, still mounted: its turn keeps running and its
        // scroll, draft and inspector are there when you come back.
        .allowsHitTesting(!inMode)
        .accessibilityHidden(inMode)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    var body: some View {
        let numbers = panes.numbers
        let corner = cornerInspector?.id
        ZStack(alignment: .topLeading) {
            ForEach(Array(panes.items.enumerated()), id: \.element.id) { i, pane in
                paneCell(pane, number: panes.isSplit ? i + 1 : nil, stripInTitleRow: corner == pane.id)
            }

            docsLayer
            settingsLayer
            customizeLayer

            GeometryReader { geo in
                sessions(room: max(120, geo.size.height))
            }
            .environment(\.openSession) { openInFocused($0) }
            .environment(\.openSessionInSplit) { split($0) }
            .environment(\.switchFolder) { panes.switchFolder($0, in: focused) }
            .environment(\.startConversation) { panes.start($1, in: $0, pane: focused) }
            .environment(\.paneNumbers, numbers)
            .environment(\.showDocs) { showDocs() }
            .environment(\.showSettings) { showSettings($0) }
            .environment(\.showCustomize) { showCustomize($0) }

            // Collapsed: the pointer at the left edge brings the list out over the page.
            if !sessionsVisible {
                Color.clear
                    .frame(width: Self.peekEdge)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .onHover { inside in
                        guard inside else { return }
                        peekByHover = true
                        peekSessions = true
                    }
            }

            ForEach(inMode ? [] : panes.layout.dividers(in: region(sessions: docked.sessions), maximizing: panes.maximized)) { d in
                PaneDividerHandle(divider: d, resizing: $resizing) { t in
                    panes.moveDivider(d, to: t, minimum: panes.minimum(paneWidth: Self.minPane, forToolPanes: Self.minToolPane, beside: d))
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
                    )) + docsCommands + settingsCommands + customizeCommands) {
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
        // A hover peek goes when the pointer moves out over the page.
        .onContinuousHover(coordinateSpace: .named(Self.canvasSpace)) { phase in
            guard peekByHover, peekSessions, case .active(let p) = phase,
                  p.x > sidebarWidth + Tokens.Space.row * 3 else { return }
            peekSessions = false
        }
        .onChange(of: peekSessions) { if !peekSessions { peekByHover = false } }
        .onGeometryChange(for: CGSize.self, of: \.size) { canvasSize = $0 }
        .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .global).origin }) { canvasOrigin = $0 }
        .environment(\.paneDragger, dragger)
        // Every "open Settings on…" in the window (the composer's Billing, the footer, the model
        // menu's Manage) lands on Settings mode here.
        .environment(\.showSettings) { showSettings($0) }
        .environment(\.showCustomize) { showCustomize($0) }
        // A turn's energy popover: History is Settings › Usage.
        .environment(\.showEnergyHistory) { showSettings("usage") }
        // ⌘, with no window, or a frog://settings/<section> link: the front window takes it, or
        // this one if it's the one that just opened for it.
        .onReceive(NotificationCenter.default.publisher(for: SettingsRequest.name)) { _ in
            guard window?.isKeyWindow == true || NSApp.keyWindow == nil else { return }
            if let s = SettingsRequest.take() { showSettings(s) }
        }
        .onAppear { if let s = SettingsRequest.take() { showSettings(s) } }
        .onAppear { dragger.onDrop = { perform($0, at: $1) } }
        .animation(.easeOut(duration: 0.15), value: dragger.active)
        .onChange(of: layoutInputs, initial: true) { old, new in
            if old.panes.map(\.shows) != new.panes.map(\.shows) { Motion.cut(relayout) } else { relayout() }
        }
        // Over everything in the window: sidebar, rail, and (hidden meanwhile) the toolbar.
        .modifier(LightboxHost())
        .environment(\.projectFolder, workspace.folder)
        // The focused pane's folder as the window's document: proxy icon in the title bar
        // (⌘-click for its path, drag it anywhere). Not for Chats: their folder is frog's own
        // scratch space, not a document of yours.
        .modifier(FolderDocument(folder: workspace.isChat ? nil : workspace.folder))
        .navigationTitle(windowTitle)
        // The menu's content builds when it opens (a title menu is deferred by the system), but
        // the toolbar's item body runs per body pass: read the mirror, not the conversation.
        // The title bar is the title and a ⌄ menu (Rename, Archive, Delete), as on the web: the
        // system's title menu shows no chevron, so the title is drawn here and the system's hidden.
        .toolbar(removing: .title)
        // One backdrop for the whole canvas, so the conversation reads as a single surface.
        .background(FrogCanvas.color.ignoresSafeArea())
        .background(WindowReader {
            window = $0
            Library.shared.register(window: $0, panes: panes)
            if let w = $0 { TypeToFocus.register(window: w, panes: panes) }
        })
        .animation(Motion.panel(reduced: reduceMotion), value: sessionsVisible)
        .animation(Motion.panel(reduced: reduceMotion), value: docked)
        .animation(resizing ? nil : Motion.panel(reduced: reduceMotion), value: panes.layout)
        .animation(Motion.panel(reduced: reduceMotion), value: panes.maximized)
        .animation(Motion.quick(reduced: reduceMotion), value: focused.ui.paletteShown)
        .onChange(of: workspace.selection) { peekSessions = false }
        .onChange(of: panes.focusedID) { peekSessions = false }
        .onExitCommand {
            if inMode {
                backToApp()
            } else if let maxed = panes.maximizedPane {
                panes.toggleMaximized(maxed)
            } else if focused.ui.findShown {
                focused.ui.findShown = false
            } else {
                peekSessions = false
                panes.items.forEach { $0.peekChanges = false }
            }
        }
        .focusedSceneValue(\.frogWindow, frogWindow)
        #if DEBUG
        // Flow tests: a test host never has a key window, so the menu bar acts on this one
        // when a test asks (`StagedWindow`). Off otherwise.
        .onChange(of: StagedWindow.key(frogWindow), initial: true) {
            if StagedWindow.shared.capturing == ObjectIdentifier(panes) { StagedWindow.shared.window = frogWindow }
        }
        #endif
        // ⌘L and friends ask for the composer: that's a way back to the thread.
        .onChange(of: focused.ui.focusComposerRequest) { if inMode { panes.backToApp() } }
        .animation(Motion.quick(reduced: reduceMotion), value: panes.mode)
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
        // Handoff: the phone offers the conversation you're reading here, and back. The id via
        // the workspace's mirror, so the root body doesn't observe the streaming conversation.
        .userActivity(Handoff.conversation, isActive: workspace.currentSession != nil) { a in
            a.title = workspace.currentTitle ?? "Conversation"
            a.userInfo = ["session": workspace.currentSession ?? ""]
            a.isEligibleForHandoff = true
        }
        .onContinueUserActivity(Handoff.conversation) { a in
            continueHandoff(a)
        }
        .confirmationDialog("Delete this conversation?", isPresented: Binding(
            get: { deletingSession != nil }, set: { if !$0 { deletingSession = nil } }
        )) {
            Button("Move to Trash", role: .destructive) {
                if let id = deletingSession {
                    Library.shared.delete(id)
                    workspace.newSession()
                }
                deletingSession = nil
            }
            Button("Cancel", role: .cancel) { deletingSession = nil }
        } message: {
            Text("Its log moves to the Trash.")
        }
        .alert("Rename Conversation", isPresented: $renamingTitle) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let id = workspace.currentSession {
                    Task { await Library.shared.rename(id, to: newTitle) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .toolbar {
            // Beside the traffic lights: the sidebar's header over the sidebar (docked or
            // peeking), else its toggle and New session. Then, as on the web, a plain title (no
            // glass pill) over the conversation, and the controls at the right, short of a docked
            // inspector.
            if sessionsVisible {
                ToolbarItem(placement: .navigation) {
                    SidebarTitleRow(docs: inMode, peeking: peekSessions, toggle: toggleSessions)
                        .frame(width: sidebarWidth - Self.trafficLights)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    SidebarToggle(toggle: toggleSessions, open: openInFocused)
                }
                .sharedBackgroundVisibility(.hidden)
                if !inMode {
                    ToolbarItem(placement: .navigation) {
                        Button(action: newSession) {
                            Image(systemName: "square.and.pencil").frame(width: 28, height: 24).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.textSecondary)
                        .help("New session (⌘N)")
                        .accessibilityLabel("New session")
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            ToolbarItem(placement: .navigation) { titleBar }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
            // Customize: the page's one figure and one action, at the header's right.
            if panes.mode == .customize {
                ToolbarItem(placement: .primaryAction) { CustomizeHeaderTrailing(panes: panes) }
                    .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Split", systemImage: "rectangle.split.2x1") { split() }
                    .contextMenu {
                        Button("Split Right") { split(nil, .right) }
                        Button("Split Down") { split(nil, .bottom) }
                    }
                    .help("Split pane (⌘\\)")
                    .disabled(!panes.canSplit || inMode)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Commands", systemImage: "command") { focused.ui.paletteShown.toggle() }
                    .help("Command Palette (⌘K)")
            }
            // The inspector toggle, rightmost: Changes, Terminal and Preview as tabs of one panel.
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.right") { toggleChanges(focused) }
                    .help("Inspector: changes, terminal, preview (⌥⌘0)")
                    .disabled(focused.conversation == nil || inMode)
            }
            // The top-right inspector's tabs, over its column: the controls sit left of it.
            if let corner = cornerInspector, let c = corner.conversation {
                ToolbarItem(placement: .primaryAction) {
                    PaneArea(conversation: c, height: 0, width: .constant(corner.cardWidth),
                             collapse: { toggleChanges(corner) },
                             folder: corner.workspace.isChat ? nil : corner.workspace.folder)
                        .strip
                        .frame(width: max(0, corner.cardWidth - Self.toolbarTrailing))
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    /// The pane whose docked inspector stands at the window's top-right: its tabs are in the
    /// title row, at the toolbar's trailing end. (Another pane's inspector, in a split, keeps
    /// its tabs on its first row: the toolbar's items run in one row from each end.)
    private var cornerInspector: Pane? {
        guard !inMode else { return nil }
        let corner = panes.items.first { pane in
            let f = placement(pane).frame
            return f.minY < 0.5 && f.maxX >= canvasSize.width - 0.5
        }
        guard let corner, docked.changes.contains(corner.id), corner.hasTabs else { return nil }
        return corner
    }

    // MARK: Columns

    /// The session list: a flush column at the window's left edge, docked or peeking over the
    /// page. Collapsed, nothing (its toggle is in the title row). Its header is the title row's.
    @ViewBuilder
    private func sessions(room: CGFloat) -> some View {
        if sessionsVisible {
            Group {
                if panes.mode == .settings {
                    SettingsSidebar(selected: panes.settingsSection, maxHeight: room,
                                    open: { showSettings($0) }, back: backToApp)
                } else if panes.mode == .customize {
                    CustomizeSidebar(selected: panes.customizeSection, maxHeight: room,
                                     open: { s in showCustomize(s); panes.customizePage = nil }, back: backToApp)
                } else if inDocs {
                    DocsSidebar(docs: docs, selected: docsPage?.slug, maxHeight: room, titleRow: false,
                                open: { showDocs($0) }, back: backToApp, collapse: toggleSessions)
                } else {
                    // One look: an opaque column one step off the canvas (#0a0a0a), not glass. It
                    // also draws in -FrogSnapshot, which glass doesn't.
                    SessionList(workspace: workspace, maxHeight: room, titleRow: false) { toggleSessions() }
                }
            }
            .frame(width: sidebarWidth)
            .flushColumn(trailing: true, floating: peekSessions)
            // Drag its hairline to resize it, as the inspector's.
            .overlay(alignment: .trailing) {
                if docked.sessions {
                    ColumnGrip(width: Binding(get: { sidebarWidth }, set: { sidebarWidthRaw = Double($0) }),
                               range: Self.minSessions...Self.maxSessions, reset: Self.sessionsWidth, growsLeft: false,
                               help: "Drag to resize the sidebar, double-click to reset")
                        .offset(x: ColumnGrip.reach)
                }
            }
            .transition(.move(edge: .leading))
        }
    }
}

extension View {
    /// A flush column (docs/design/flush): the sidebar's fill, square, from the top of the space
    /// it's given to the bottom, running up under the title bar when `underTitleBar`, with a
    /// `Tokens.edge` hairline on the edges it shares with the page. Floating (a peek, or an
    /// inspector the window is too narrow to dock) it keeps its shadow.
    func flushColumn(leading: Bool = false, trailing: Bool = false, floating: Bool = false,
                     underTitleBar: Bool = true) -> some View {
        let up: Edge.Set = underTitleBar ? .top : []
        return frame(maxHeight: .infinity, alignment: .top)
            .background { Tokens.sidebar.ignoresSafeArea(edges: up) }
            .overlay(alignment: .leading) {
                if leading { Tokens.edge.frame(width: 1).ignoresSafeArea(edges: up).allowsHitTesting(false) }
            }
            .overlay(alignment: .trailing) {
                if trailing { Tokens.edge.frame(width: 1).ignoresSafeArea(edges: up).allowsHitTesting(false) }
            }
            .shadow(color: .black.opacity(floating ? 0.35 : 0), radius: 24, y: 10)
    }
}

/// A pane's clip: its frame, open at the top for a pane under the title bar so its inspector's
/// column can run up under it.
struct TitleBarClip: Shape {
    let open: Bool

    func path(in r: CGRect) -> Path {
        let up: CGFloat = open ? 400 : 0
        return Path(CGRect(x: r.minX, y: r.minY - up, width: r.width, height: r.height + up))
    }
}

extension WorkspaceView {
    private var windowTitle: String {
        if panes.mode == .docs { return "Documentation" }
        if panes.mode == .customize { return CustomizeCrumbs.title(section: panes.customizeSection, page: panes.customizePage) }
        if panes.mode == .settings {
            let label = SettingsCatalog.bundled.sections.first { $0.id == panes.settingsSection }?.label
            return ["Settings", label].compactMap { $0 }.joined(separator: " › ")
        }
        // The mirror (see `Workspace.currentTitle`), not the conversation: the root body
        // reading the streaming conversation re-evaluated per delta to redraw a title that
        // only changes when the engine names the session.
        if let t = workspace.currentTitle { return t }
        return workspace.conversation?.title ?? (workspace.isChat ? "New Chat" : "New Conversation")
    }

    /// Where the focused conversation lives: the project and its branch; nothing for a chat.
    private var place: String {
        guard !workspace.isChat else { return "" }
        return [workspace.name, workspace.git?.branch].compactMap { $0 }.joined(separator: ", ")
    }

    /// The title and its ⌄ menu. The menu's content builds when it opens; the label reads the
    /// mirror, not the streaming conversation.
    @ViewBuilder
    private var titleBar: some View {
        if panes.mode == .settings {
            SettingsCrumbs(section: panes.settingsSection,
                           machine: panes.settingsSection == "models" ? panes.settingsMachine.flatMap { id in SettingsBindings.devices.list.first { $0.id == id }?.name } : nil,
                           backToSection: { panes.settingsMachine = nil })
        } else if panes.mode == .customize {
            CustomizeCrumbs(panes: panes)
        } else if panes.mode != .threads {
            Text(windowTitle).font(.frog(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
        } else {
            threadTitleBar
        }
    }

    private var threadTitleBar: some View {
        Menu {
            if let c = workspace.conversation { titleMenu(c) }
        } label: {
            HStack(spacing: 5) {
                Text(windowTitle).font(.frog(size: 13, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.frog(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.textSecondary)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rename, archive or delete this conversation")
        .accessibilityIdentifier("title.menu")
    }

    @ViewBuilder
    private func titleMenu(_ conversation: Conversation) -> some View {
        Button("Rename…") {
            newTitle = conversation.title ?? ""
            renamingTitle = true
        }
        .disabled(conversation.sessionID == nil)
        if let id = conversation.sessionID {
            // This menu is the open conversation's own: archiving it always clears the view,
            // which is what ArchiveNav decides for every view of a session.
            Button("Archive") { ArchiveNav.archive(id, from: workspace) }
            Divider()
            Button("Delete…", role: .destructive) {
                deletingSession = id
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
            // Item providers, not `dropDestination(for: URL.self)`: the screenshot thumbnail
            // drags a file promise and image data, not a file URL (see `DropFiles`).
            .onDrop(of: DropFiles.types, isTargeted: $targeted) { providers in
                guard !providers.isEmpty else { return false }
                // The drag pasteboard only holds this drag's promises until the drop ends.
                let promises = DropFiles.pendingPromises()
                Task { @MainActor in
                    let urls = await DropFiles.urls(from: providers, promises: promises, into: DropFiles.folder())
                    if !urls.isEmpty { conversation.dropped = urls }
                }
                return true
            }
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
                    .font(.frog(size: 13, weight: .semibold))
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
            Label("Session tree", systemImage: "arrow.triangle.branch").font(.frog(size: 13, weight: .semibold))
            if let diagram, !diagram.nodes.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    DiagramCanvas(diagram: diagram, onNode: { node in
                        workspace.selection = node.id
                        dismiss()
                    }, expanded: true)
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

/// The window's represented document, when there is one.
private struct FolderDocument: ViewModifier {
    let folder: URL?
    func body(content: Content) -> some View {
        if let folder { content.navigationDocument(folder) } else { content }
    }
}
