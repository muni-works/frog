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

    enum Peek { case sessions, changes }

    static let sessionsWidth: CGFloat = 250
    static let changesWidth: CGFloat = 380
    static let button: CGFloat = 36
    /// Estimated width of the collapsed changes pill ("± 12").
    static let changesPill: CGFloat = 64
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
        Self.margin + (open ? Self.sessionsWidth : Self.button) + Self.gap
    }

    private func extent(changes open: Bool) -> CGFloat {
        guard changeCount > 0 || hasRail else { return Self.gap }
        let width = open ? Self.changesWidth : (changeCount > 0 ? Self.changesPill : TimelineRail.width)
        return Self.margin + width + Self.gap
    }

    private func fits(_ left: CGFloat, _ right: CGFloat) -> Bool {
        canvasWidth - 2 * max(left, right) >= Self.minColumn
    }

    private var sessionsDocked: Bool {
        showSessions && fits(extent(sessions: true), extent(changes: false))
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
        if fits(extent(sessions: true), extent(changes: changesDocked)) {
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
        .environment(\.projectFolder, workspace.folder)
        // The folder as the window's document: proxy icon in the title bar (⌘-click for its
        // path, drag it anywhere).
        .navigationDocument(workspace.folder)
        // One backdrop for the whole canvas, so the conversation reads as a single surface.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
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
            ToolbarItem(placement: .principal) {
                if let c = workspace.conversation, workspace.race == nil {
                    ActivityViewer(conversation: c)
                }
            }
            // The viewer draws its own glass capsule; without this the toolbar adds a second.
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button("Commands", systemImage: "command") { ui.paletteShown.toggle() }
                    .help("Command Palette (⌘K)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Session", systemImage: "square.and.pencil") {
                    workspace.newSession()
                }
                .help("New Session (⇧⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Compact", systemImage: "arrow.down.right.and.arrow.up.left") {
                    workspace.conversation?.compact()
                }
                .disabled(workspace.conversation?.busy ?? true || workspace.conversation?.turns.isEmpty ?? true)
                .help("Compact Conversation: summarize to free up context (⇧⌘K)")
            }
        }
    }

    // MARK: Glass

    /// The session list, or the button it folds into. Same glass ID, so one morphs into the other.
    @ViewBuilder
    private func sessions(room: CGFloat) -> some View {
        if sessionsVisible {
            SessionList(workspace: workspace, maxHeight: room) { toggleSessions() }
                .frame(width: Self.sessionsWidth)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .glassEffectID("sessions", in: glass)
                .shadow(color: .black.opacity(peek == .sessions ? 0.35 : 0), radius: 24, y: 10)
        } else {
            Button(action: toggleSessions) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: Self.button, height: Self.button)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID("sessions", in: glass)
            .help("Show sessions (⌃⌘S)")
        }
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
                            HStack(spacing: 5) {
                                Image(systemName: "plusminus")
                                Text("\(changeCount)").monospacedDigit()
                            }
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
            .navigationTitle(workspace.name)
            .navigationSubtitle(conversation.title ?? "New session")
        }
    }
}

struct SessionList: View {
    @Bindable var workspace: Workspace
    let maxHeight: CGFloat
    var collapse: (() -> Void)?

    var body: some View {
        HuggingScroll(maxHeight: maxHeight) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Sessions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let collapse {
                        Button(action: collapse) {
                            Image(systemName: "sidebar.left")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Hide sessions (⌃⌘S)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                if workspace.sessions.isEmpty {
                    Text("No sessions yet")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(8)
                }
                ForEach(workspace.sessions) { s in
                    let selected = workspace.selection == s.id
                    Button {
                        workspace.selection = s.id
                    } label: {
                        SessionRow(session: s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                selected ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear),
                                in: .rect(cornerRadius: 10)
                            )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .onChange(of: workspace.selection) { _, id in
            if let id { workspace.open(id) }
        }
    }
}

struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if session.forkedFrom != nil {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                        .help("Forked from \(session.forkedFrom!.session)")
                }
                Text(session.displayTitle)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(session.modifiedDate, format: .relative(presentation: .named))
                Text("·")
                Text(session.model.replacingOccurrences(of: "ollama/", with: ""))
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
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
