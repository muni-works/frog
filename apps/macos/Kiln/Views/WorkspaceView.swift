import SwiftUI

/// The conversation is the canvas: it fills the window, and everything else floats over it as
/// Liquid Glass. Sessions (left) and Changes (right) are cards that fold into small glass
/// buttons in their corners and morph back out; under Changes, a timeline rail maps the whole
/// conversation. The conversation and composer are centered on the window when there's room
/// (equal insets on both sides), and fit between the cards when there isn't.
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @AppStorage("showSessions") private var showSessions = true
    @AppStorage("showChanges") private var showChanges = false
    @State private var canvasWidth: CGFloat = 1100
    @State private var ui = WindowState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A card shown floating over the conversation because the window is too narrow to dock it.
    @State private var peek: Peek?
    @Namespace private var glass
    /// This view's window, so the sidebar can bring an already-open conversation forward.
    @State private var window: NSWindow?
    @Environment(\.controlActiveState) private var activeState
    @State private var renamingTitle = false
    @State private var newTitle = ""

    enum Peek { case sessions, changes }

    static let sessionsWidth: CGFloat = 250
    static let changesWidth: CGFloat = 380
    static let button: CGFloat = 36
    /// Estimated width of the collapsed changes pill ("+42 −7").
    static let changesPill: CGFloat = 96
    static let margin: CGFloat = 12
    /// Clearance between a card and the conversation.
    static let gap: CGFloat = 16
    /// Narrowest the centered column may get; a card that would squeeze it further stays folded.
    static let minColumn: CGFloat = 520

    /// The conversation shown on the canvas (a race has its own view).
    private var conversation: Conversation? { workspace.race == nil ? workspace.conversation : nil }
    private var changeCount: Int { conversation?.sessionChanges.count ?? 0 }
    /// Open only when there's something in it: an empty "No Changes Yet" card is clutter.
    private var changesOpen: Bool { showChanges && changeCount > 0 }
    private var hasRail: Bool { !(conversation?.turns.isEmpty ?? true) }

    // Layout. The column is centered on the window with equal insets. A card docks (stands
    // beside the column) only if the column still gets `minColumn` with it; otherwise it folds to
    // its button, and the button floats it over the conversation instead ("peek").

    private func extent(sessions open: Bool) -> CGFloat {
        open ? Self.margin + Self.sessionsWidth + Self.gap : Self.gap
    }

    private func extent(changes open: Bool) -> CGFloat {
        guard changeCount > 0 || hasRail else { return Self.gap }
        let width = open ? Self.changesWidth : (changeCount > 0 ? Self.changesPill : TimelineRail.width)
        return Self.margin + width + Self.gap
    }

    private func fits(_ left: CGFloat, _ right: CGFloat) -> Bool {
        canvasWidth - 2 * max(left, right) >= Self.minColumn
    }

    /// Room for the column between the cards, even if it can't be centered.
    private func fitsBeside(_ left: CGFloat, _ right: CGFloat) -> Bool {
        canvasWidth - left - right >= Self.minColumn
    }

    /// The conversation list is a full-height column, so floating it over the conversation
    /// would cover the composer: it docks whenever the column still fits beside it (off
    /// center if it must), and only peeks in windows too narrow for that.
    private var sessionsDocked: Bool {
        showSessions && fitsBeside(extent(sessions: true), extent(changes: false))
    }

    private var changesDocked: Bool {
        changesOpen && fits(extent(sessions: sessionsDocked), extent(changes: true))
    }

    private var sessionsVisible: Bool { sessionsDocked || peek == .sessions }
    private var changesVisible: Bool { changesDocked || (peek == .changes && changeCount > 0) }

    private var insets: EdgeInsets {
        let left = extent(sessions: sessionsDocked), right = extent(changes: changesDocked)
        let even = max(left, right)
        // Equal insets center the column; a window below the minimum gives up symmetry.
        return fits(left, right)
            ? EdgeInsets(top: 0, leading: even, bottom: 0, trailing: even)
            : EdgeInsets(top: 0, leading: left, bottom: 0, trailing: right)
    }

    private func toggleSessions() {
        Haptics.settle()
        if fitsBeside(extent(sessions: true), extent(changes: changesDocked)) {
            peek = nil
            showSessions.toggle()
        } else {
            peek = peek == .sessions ? nil : .sessions
        }
    }

    private func toggleChanges() {
        Haptics.settle()
        if fits(extent(sessions: sessionsDocked), extent(changes: true)) {
            peek = nil
            showChanges.toggle()
        } else {
            peek = peek == .changes ? nil : .changes
        }
    }

    private func noteSession() {
        guard let id = workspace.conversation?.sessionID else { return }
        Library.shared.register(window: window, for: id)
        if activeState == .key {
            Library.shared.focused = id
            Library.shared.markRead(id)
        }
    }

    var body: some View {
        let insets = insets
        ZStack(alignment: .topLeading) {
            // Full-bleed, like a viewport: the scroll view spans the window and scrolls under the
            // glass; only its content (and the composer) keeps clear.
            detail(insets: insets)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentMargins(.leading, insets.leading, for: .scrollContent)
                .contentMargins(.trailing, insets.trailing, for: .scrollContent)
                .environment(\.canvasInsets, insets)
                .environment(\.projectFolder, workspace.folder)

            GeometryReader { geo in
                let room = max(120, geo.size.height - Self.margin * 2)
                GlassEffectContainer(spacing: 20) {
                    HStack(alignment: .top, spacing: 0) {
                        sessions(room: room)
                        Spacer(minLength: 0)
                        instruments(room: room)
                    }
                }
                .padding(Self.margin)
            }

            if ui.findShown, let conversation {
                FindBar(state: ui, turns: conversation.turns)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Self.margin)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if ui.paletteShown {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { ui.paletteShown = false }
                    CommandPalette(commands: workspace.commands(showChanges: $showChanges)) {
                        ui.paletteShown = false
                    }
                    .padding(.top, 80)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { canvasWidth = $0 }
        // Over everything in the window: sidebar, rail, and (hidden meanwhile) the toolbar.
        .modifier(LightboxHost())
        .environment(\.projectFolder, workspace.folder)
        // The folder as the window's document: proxy icon in the title bar (⌘-click for its
        // path, drag it anywhere).
        .navigationDocument(workspace.folder)
        // One backdrop for the whole canvas, so the conversation reads as a single surface.
        .background(KilnCanvas.color.ignoresSafeArea())
        .background(WindowReader { window = $0 })
        // Tell the sidebar which window shows which conversation, and what's in front.
        .onChange(of: workspace.conversation?.sessionID, initial: true) { _, _ in noteSession() }
        .onChange(of: window) { _, _ in noteSession() }
        .onChange(of: activeState, initial: true) { _, _ in noteSession() }
        .animation(Motion.panel(reduced: reduceMotion), value: sessionsVisible)
        .animation(Motion.panel(reduced: reduceMotion), value: changesVisible)
        .animation(Motion.panel(reduced: reduceMotion), value: insets)
        .animation(Motion.quick(reduced: reduceMotion), value: hasRail)
        .animation(Motion.quick(reduced: reduceMotion), value: ui.paletteShown)
        .animation(Motion.quick(reduced: reduceMotion), value: ui.findShown)
        .onChange(of: conversation.map(ObjectIdentifier.init)) { ui.visibleTurns = []; peek = nil }
        .onChange(of: workspace.selection) { if peek == .sessions { peek = nil } }
        .onExitCommand {
            if ui.findShown { ui.findShown = false } else { peek = nil }
        }
        .focusedSceneValue(\.kilnWindow, KilnWindow(
            workspace: workspace, state: ui,
            toggleSessions: toggleSessions, toggleChanges: toggleChanges,
            sessionsShown: sessionsVisible, changesShown: changesVisible
        ))
        .alert("Rename Conversation", isPresented: $renamingTitle) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let id = workspace.conversation?.sessionID {
                    Task { await Library.shared.rename(id, to: newTitle) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            undoTurn.flatMap(\.number).map { "Undo turn \($0)?" } ?? "Undo the last turn?",
            isPresented: $ui.confirmUndo
        ) {
            Button("Undo Changes", role: .destructive) {
                if let n = undoTurn?.number { Task { await workspace.rewind(toBefore: n) } }
            }
        } message: {
            Text("Files kiln edited in that turn go back to how they were, and the conversation continues from just before it. The current session is kept, so you can go back to it.")
        }
        .onChange(of: workspace.conversation?.busy ?? false, initial: true) { _, busy in
            DockActivity.shared.set(ObjectIdentifier(workspace), busy: busy)
        }
        .onDisappear { DockActivity.shared.set(ObjectIdentifier(workspace), busy: false) }
        .toolbar {
            if !sessionsVisible {
                ToolbarItem(placement: .navigation) {
                    Button("Show Conversations", systemImage: "sidebar.left", action: toggleSessions)
                        .help("Show conversations (⌃⌘S)")
                }
            }
            ToolbarItem(placement: .principal) {
                if let c = workspace.conversation, workspace.race == nil {
                    ActivityViewer(workspace: workspace, conversation: c) { ui.jumpTo = $0 }
                }
            }
            // The viewer draws its own glass capsule; without this the toolbar adds a second.
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button("Commands", systemImage: "command") { ui.paletteShown.toggle() }
                    .help("Command Palette (⌘K)")
            }
        }
    }

    // MARK: Glass

    /// The session list, when shown.
    @ViewBuilder
    private func sessions(room: CGFloat) -> some View {
        if sessionsVisible {
            SessionList(workspace: workspace, maxHeight: room) { toggleSessions() }
                .frame(width: Self.sessionsWidth)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .glassEffectID("sessions", in: glass)
                .shadow(color: .black.opacity(peek == .sessions ? 0.35 : 0), radius: 24, y: 10)
        }
        // Folded, its toggle lives in the title bar, beside the traffic lights.
    }

    /// The right-hand column: changes (card or pill) above the timeline rail.
    @ViewBuilder
    private func instruments(room: CGFloat) -> some View {
        if let conversation, changeCount > 0 || hasRail {
            VStack(alignment: .trailing, spacing: 8) {
                if changeCount > 0 {
                    if changesVisible {
                        ChangesInspector(conversation: conversation, maxHeight: max(120, room - (hasRail ? 160 : 0))) {
                            toggleChanges()
                        }
                        .frame(width: Self.changesWidth)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                        .glassEffectID("changes", in: glass)
                        .shadow(color: .black.opacity(peek == .changes ? 0.35 : 0), radius: 24, y: 10)
                    } else {
                        Button(action: toggleChanges) {
                            let changes = conversation.sessionChanges
                            HStack(spacing: 6) {
                                Text("+\(changes.reduce(0) { $0 + $1.added })").foregroundStyle(.green)
                                Text("−\(changes.reduce(0) { $0 + $1.removed })").foregroundStyle(.red)
                            }
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(height: Self.button)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectID("changes", in: glass)
                        .help("\(changeCount) file\(changeCount == 1 ? "" : "s") changed (⌥⌘0)")
                    }
                }
                if hasRail {
                    TimelineRail(
                        conversation: conversation,
                        visible: ui.visibleTurns,
                        marked: ui.findShown ? Set(ui.matches(in: conversation.turns)) : [],
                        actions: turnActions,
                        jump: { ui.jumpTo = $0 }
                    )
                    // Grows with the conversation instead of standing full height from turn one.
                    .frame(height: min(room, CGFloat(conversation.turns.count) * 22 + 28))
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("timeline", in: glass)
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: room, alignment: .top)
        }
    }

    /// The latest finished turn that changed files (what Edit > Undo Last Turn reverts).
    private var undoTurn: TurnState? {
        conversation?.turns.last { $0.finished && $0.number != nil && !TurnParts($0).changes.isEmpty }
    }

    private var turnActions: TurnActions {
        TurnActions(
            fork: { workspace.fork(afterTurn: $0) },
            rewind: { turn in Task { await workspace.rewind(toBefore: turn) } }
        )
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
    /// Where the conversation lives: the project and its branch; nothing for a plain chat.
    private var place: String {
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

    @ViewBuilder
    private func detail(insets: EdgeInsets) -> some View {
        if let race = workspace.race {
            RaceView(race: race) { workspace.endRace() }
                .navigationTitle(workspace.name)
                .navigationSubtitle("Racing")
        } else if let conversation = workspace.conversation {
            TranscriptView(
                conversation: conversation,
                actions: turnActions,
                jump: $ui.jumpTo,
                onVisibleTurns: { ui.visibleTurns = Set($0) }
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView(workspace: workspace, conversation: conversation, window: ui)
                    .id(ObjectIdentifier(conversation))
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
            }
            .modifier(ConversationDropZone(conversation: conversation))
            .navigationTitle(conversation.title ?? (workspace.isChat ? "New Chat" : "New Conversation"))
            .navigationSubtitle(place)
            .toolbarTitleMenu { titleMenu(conversation) }
        }
    }
}

/// The whole conversation takes dropped files, not just the composer: images attach to the
/// next message and other files are mentioned.
struct ConversationDropZone: ViewModifier {
    let conversation: Conversation
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                conversation.dropped = urls
                return true
            } isTargeted: { targeted = $0 }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.tint, lineWidth: 2)
                        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            Label("Drop to attach", systemImage: "paperclip")
                                .font(.headline)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .glassEffect(.regular, in: .capsule)
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

/// Every conversation, newest first: pinned ones, then by day. Search, start a new one, and
/// rename, pin, reveal or archive any of them. Rows show where each lives (a folder, or a chat)
/// and whether it's running, waiting on you, or finished while you were away.
struct SessionList: View {
    @Bindable var workspace: Workspace
    let maxHeight: CGFloat
    var collapse: (() -> Void)?
    @State private var library = Library.shared
    @State private var query = ""
    @State private var showArchived = false
    @State private var showTree = false
    @State private var renaming: SessionInfo?
    @State private var newTitle = ""
    @Environment(\.openSession) private var openSession
    @Environment(\.switchFolder) private var switchFolder

    private var current: String? { workspace.conversation?.sessionID }

    private var visible: [SessionInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return library.sessions.filter { s in
            guard library.archived.contains(s.id) == showArchived else { return false }
            guard !q.isEmpty else { return true }
            let hay = [s.title, s.firstInput, s.folder?.lastPathComponent].compactMap { $0?.lowercased() }
            return hay.contains { $0.contains(q) }
        }
    }

    private var groups: [(String, [SessionInfo])] {
        let cal = Calendar.current
        let now = Date()
        var out: [(String, [SessionInfo])] = []
        func add(_ title: String, _ items: [SessionInfo]) { if !items.isEmpty { out.append((title, items)) } }
        let all = visible
        let pinned = showArchived ? [] : all.filter { library.pinned.contains($0.id) }
        let rest = all.filter { showArchived || !library.pinned.contains($0.id) }
        add("Pinned", pinned)
        add("Today", rest.filter { cal.isDateInToday($0.modifiedDate) })
        add("Yesterday", rest.filter { cal.isDateInYesterday($0.modifiedDate) })
        let week = cal.date(byAdding: .day, value: -7, to: now)!
        let month = cal.date(byAdding: .day, value: -30, to: now)!
        let older = rest.filter { !cal.isDateInToday($0.modifiedDate) && !cal.isDateInYesterday($0.modifiedDate) }
        add("Previous 7 Days", older.filter { $0.modifiedDate >= week })
        add("Previous 30 Days", older.filter { $0.modifiedDate < week && $0.modifiedDate >= month })
        add("Older", older.filter { $0.modifiedDate < month })
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(groups, id: \.0) { title, items in
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 3)
                        ForEach(items) { s in
                            ConversationRow(
                                session: s,
                                selected: s.id == current,
                                pinned: library.pinned.contains(s.id),
                                live: library.live[s.id]
                            ) {
                                openSession?(s)
                            } menu: {
                                rowMenu(s)
                            }
                        }
                    }
                    if groups.isEmpty {
                        Text(query.isEmpty ? (showArchived ? "Nothing archived" : "No conversations yet") : "No matches")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(height: maxHeight)
        .onAppear { library.refresh() }
        .alert("Rename Conversation", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let s = renaming { Task { await library.rename(s.id, to: newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .popover(isPresented: $showTree, arrowEdge: .trailing) {
            SessionTree(workspace: workspace) { showTree = false }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
            Button {
                switchFolder?(nil)
            } label: {
                Image(systemName: "square.and.pencil").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New conversation")
            if let collapse {
                Button(action: collapse) {
                    Image(systemName: "sidebar.left").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide conversations (⌃⌘S)")
            }
        }
        .padding(10)
    }

    private var footer: some View {
        let count = library.archived.count
        return HStack {
            if showArchived {
                Button { showArchived = false } label: { Label("Back to conversations", systemImage: "chevron.left") }
            } else if count > 0 {
                Button { showArchived = true } label: { Label("Archived (\(count))", systemImage: "archivebox") }
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, count > 0 || showArchived ? 9 : 0)
    }

    @ViewBuilder
    private func rowMenu(_ s: SessionInfo) -> some View {
        Button("Rename…") {
            newTitle = s.displayTitle
            renaming = s
        }
        Button(library.pinned.contains(s.id) ? "Unpin" : "Pin") { library.togglePin(s.id) }
        if let folder = s.folder, !s.isChat {
            Button("Reveal Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
        if s.id == current {
            Button("Session Tree…") { showTree = true }
        }
        Divider()
        if library.archived.contains(s.id) {
            Button("Unarchive") { library.setArchived(s.id, false) }
        } else {
            Button("Archive") { library.setArchived(s.id, true) }
        }
    }
}

/// One conversation: its title, where it lives and when, and whether it's live.
struct ConversationRow<Menu: View>: View {
    let session: SessionInfo
    let selected: Bool
    let pinned: Bool
    let live: Library.Live?
    let open: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if session.forkedFrom != nil {
                            Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(session.displayTitle)
                            .lineLimit(1)
                            .fontWeight(live == .unread ? .semibold : .regular)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: session.isChat ? "bubble.left" : "folder")
                        Text(session.isChat ? "Chat" : session.folder?.lastPathComponent ?? "")
                            .lineLimit(1)
                        Text("·")
                        Text(Self.ago(session.modifiedDate))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background, in: .rect(cornerRadius: 9))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { menu() }
        .help(helpText)
    }

    @ViewBuilder
    private var trailing: some View {
        if hovering {
            SwiftUI.Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis").frame(width: 18, height: 18)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        } else {
            switch live {
            case .running: ProgressView().controlSize(.mini)
            case .waiting: Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
            case .unread: Circle().fill(.tint).frame(width: 7, height: 7)
            case nil: if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(.tint.opacity(0.22)) }
        if hovering { return AnyShapeStyle(.quaternary.opacity(0.6)) }
        return AnyShapeStyle(.clear)
    }

    private var helpText: String {
        var parts = [session.displayTitle]
        if let f = session.folder, !session.isChat { parts.append(f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        parts.append(session.model)
        return parts.joined(separator: "\n")
    }

    /// "now", "5m", "3h", "2d", "4w", then a date.
    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        case ..<(86400 * 7): return "\(s / 86400)d"
        case ..<(86400 * 30): return "\(s / (86400 * 7))w"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
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
