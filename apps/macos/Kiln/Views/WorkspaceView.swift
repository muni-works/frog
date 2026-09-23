import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @AppStorage("showChanges") private var showChanges = false
    @State private var showPalette = false

    var body: some View {
        NavigationSplitView {
            SessionList(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
        } detail: {
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A plain side panel, not `.inspector`: an inspector is a third split-view column,
                // and its size negotiation with the transcript loops AppKit's constraint passes
                // (crash on launch with the panel left open).
                if showChanges, let conversation = workspace.conversation, workspace.race == nil {
                    Divider()
                    ChangesInspector(conversation: conversation)
                        .frame(width: 380)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .overlay(alignment: .top) {
            if showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { showPalette = false }
                    CommandPalette(commands: workspace.commands(showChanges: $showChanges)) {
                        showPalette = false
                    }
                    .padding(.top, 80)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.snappy(duration: 0.18), value: showPalette)
        .toolbar {
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
                    withAnimation { showChanges.toggle() }
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

    var body: some View {
        List(selection: $workspace.selection) {
            Section("Sessions") {
                ForEach(workspace.sessions) { s in
                    SessionRow(session: s)
                        .tag(s.id)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if workspace.sessions.isEmpty {
                Text("No sessions yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
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
