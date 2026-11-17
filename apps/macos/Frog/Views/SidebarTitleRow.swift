import SwiftUI

/// The sidebar's header, in the window's title row beside the traffic lights: the frog and its
/// name, the list's view options, and the button that collapses it (or, while it peeks, keeps
/// it open). Content under the toolbar can't take clicks on macOS 27, so the header lives in
/// the toolbar and the list below starts with New session.
struct SidebarTitleRow: View {
    /// The documentation's sidebar: no view options.
    var docs = false
    var peeking = false
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            FrogFace(mood: .waiting, size: 18)
            Text("Frog").font(.frog(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            if !docs { SidebarViewOptions() }
            Button(action: toggle) {
                Image(systemName: "sidebar.left").frame(width: 24, height: 24).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.textSecondary)
            .help(peeking ? "Keep the sidebar open (⌃⌘S)" : "Collapse the sidebar (⌃⌘S)")
            .accessibilityLabel(peeking ? "Keep the sidebar open" : "Collapse the sidebar")
        }
        // Clear of the sidebar's hairline, as the list's rows are.
        .padding(.trailing, Tokens.Space.row * 2)
    }
}

/// How the list is grouped, sorted and filtered, like Finder's View menu.
struct SidebarViewOptions: View {
    @AppStorage("sidebarGroup") private var grouping = SessionList.Grouping.date
    @AppStorage("sidebarSort") private var sort = SessionList.Sort.activity
    @AppStorage("compactSidebar") private var compactSidebar = false
    @SceneStorage("sidebarArchived") private var showArchived = false

    var body: some View {
        Menu {
            Toggle("Compact", isOn: $compactSidebar)
                .disabled(grouping == .org)
            Divider()
            Picker("Show", selection: $showArchived) {
                Text("Active").tag(false)
                Text("Archived").tag(true)
            }
            Divider()
            Picker("Group By", selection: $grouping) {
                ForEach(SessionList.Grouping.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Sort By", selection: $sort) {
                ForEach(SessionList.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease").frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Group and sort conversations")
    }
}

/// With the sidebar gone: the button that brings it back, beside the traffic lights. It
/// carries what needs you, an amber dot when a conversation is waiting on you, and hovering it
/// lists the live ones, a click from any of them.
struct SidebarToggle: View {
    let toggle: () -> Void
    let open: (SessionInfo) -> Void
    @State private var library = Library.shared
    @State private var hovering = false
    @State private var listHovered = false
    @State private var showList = false

    /// Waiting on you first, then running; unread last.
    var live: [(session: SessionInfo, state: SessionLive)] {
        let rank: [SessionLive: Int] = [.waiting: 0, .running: 1, .unread: 2]
        return library.sessions.compactMap { s in library.live[s.id].map { (s, $0) } }
            .sorted { (rank[$0.state] ?? 3, -$0.session.modified) < (rank[$1.state] ?? 3, -$1.session.modified) }
    }

    var needsYou: Bool { library.live.values.contains(.waiting) }

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "sidebar.left")
                .frame(width: 28, height: 24)
                .overlay(alignment: .topTrailing) {
                    if needsYou {
                        Circle().fill(Tokens.signal)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(FrogCanvas.color, lineWidth: 2))
                            .offset(x: -3, y: 3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.textSecondary)
        .help(needsYou ? "Show the sidebar: a conversation needs you (⌃⌘S)" : "Show the sidebar (⌃⌘S)")
        .accessibilityLabel(needsYou ? "Show the sidebar, a conversation needs you" : "Show the sidebar")
        .animation(.snappy(duration: 0.22), value: needsYou)
        .onHover { hovering = $0; settle() }
        .popover(isPresented: $showList, arrowEdge: .bottom) {
            LiveList(live: live) { s in
                showList = false
                open(s)
            }
            .onHover { listHovered = $0; settle() }
        }
    }

    /// The list opens after a short rest on the button and closes once the pointer has left
    /// both the button and the list.
    private func settle() {
        let want = hovering || listHovered
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(want ? 350 : 250))
            let now = hovering || listHovered
            if now == want, showList != want, !live.isEmpty || !want { showList = want }
        }
    }
}

/// The live conversations, as the collapsed sidebar's toggle lists them on hover.
private struct LiveList: View {
    let live: [(session: SessionInfo, state: SessionLive)]
    let open: (SessionInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(live, id: \.session.id) { item in
                Button { open(item.session) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(color(item.state)).frame(width: 7, height: 7)
                        Text(item.session.displayTitle).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(label(item.state)).foregroundStyle(Tokens.textSecondary)
                    }
                    .font(.frog(size: Tokens.Size.status))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 240)
    }

    private func color(_ s: SessionLive) -> Color {
        switch s {
        case .waiting: Tokens.signal
        case .running: Tokens.accent
        case .unread: Tokens.textTertiary
        }
    }

    private func label(_ s: SessionLive) -> String {
        switch s {
        case .waiting: "needs you"
        case .running: "running"
        case .unread: "unread"
        }
    }
}
