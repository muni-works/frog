import SwiftUI

/// The conversation is the canvas: it fills the window, and the session list and the changes
/// panel float over it as Liquid Glass cards (no split view). Each card hugs its content, up to
/// the window's height, and the conversation is inset so nothing important sits underneath.
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @AppStorage("showSessions") private var showSessions = true
    @AppStorage("showChanges") private var showChanges = false
    @State private var showPalette = false

    static let sessionsWidth: CGFloat = 250
    static let changesWidth: CGFloat = 380
    static let margin: CGFloat = 12

    private var changesShown: Bool {
        showChanges && workspace.conversation != nil && workspace.race == nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Keep the conversation clear of the cards; it still scrolls under their edges.
                .safeAreaPadding(.leading, showSessions ? Self.sessionsWidth + Self.margin : 0)
                .safeAreaPadding(.trailing, changesShown ? Self.changesWidth + Self.margin : 0)

            GeometryReader { geo in
                let room = max(120, geo.size.height - Self.margin * 2)
                HStack(alignment: .top, spacing: 0) {
                    if showSessions {
                        SessionList(workspace: workspace, maxHeight: room)
                            .frame(width: Self.sessionsWidth)
                            .floatingPanel()
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if changesShown, let conversation = workspace.conversation {
                        ChangesInspector(conversation: conversation, maxHeight: room)
                            .frame(width: Self.changesWidth)
                            .floatingPanel()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(Self.margin)
            }

            if showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { showPalette = false }
                    CommandPalette(commands: workspace.commands(showChanges: $showChanges)) {
                        showPalette = false
                    }
                    .padding(.top, 80)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        // One backdrop for the whole canvas, so the conversation reads as a single surface under
        // the cards rather than a lighter column between them.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .animation(.snappy(duration: 0.22), value: showSessions)
        .animation(.snappy(duration: 0.22), value: changesShown)
        .animation(.snappy(duration: 0.18), value: showPalette)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showSessions.toggle()
                } label: {
                    Label("Sessions", systemImage: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help("Sessions (⌃⌘S)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Commands", systemImage: "command") { showPalette.toggle() }
                    .keyboardShortcut("k")
                    .help("Command palette (⌘K)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Session", systemImage: "square.and.pencil") {
                    workspace.newSession()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .primaryAction) {
                let count = workspace.conversation?.sessionChanges.count ?? 0
                Button {
                    showChanges.toggle()
                } label: {
                    Label("Changes", systemImage: "plusminus")
                }
                .badge(count)
                .keyboardShortcut("0", modifiers: [.command, .option])
                .help("Changes in this session (⌥⌘0)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Compact", systemImage: "arrow.down.right.and.arrow.up.left") {
                    workspace.conversation?.compact()
                }
                .disabled(workspace.conversation?.busy ?? true || workspace.conversation?.turns.isEmpty ?? true)
                .help("Summarize the conversation to free up context")
            }
        }
    }
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
    private var detail: some View {
        if let race = workspace.race {
            RaceView(race: race) { workspace.endRace() }
                .navigationTitle(workspace.name)
                .navigationSubtitle("Racing")
        } else if let conversation = workspace.conversation {
            TranscriptView(
                conversation: conversation,
                actions: TurnActions(
                    fork: { workspace.fork(afterTurn: $0) },
                    rewind: { turn in Task { await workspace.rewind(toBefore: turn) } }
                )
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView(workspace: workspace, conversation: conversation)
                    .id(ObjectIdentifier(conversation))
            }
            .navigationTitle(workspace.name)
            .navigationSubtitle(conversation.title ?? conversation.status?.model ?? "")
        }
    }
}

struct SessionList: View {
    @Bindable var workspace: Workspace
    let maxHeight: CGFloat

    var body: some View {
        HuggingScroll(maxHeight: maxHeight) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sessions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
