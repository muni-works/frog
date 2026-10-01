import SwiftUI

/// Every conversation on the Mac: what needs you first, then what's running, then the rest.
struct SessionListView: View {
    let remote: Remote
    /// iPad: rows select the conversation shown beside the list instead of pushing it.
    var selection: Binding<String?>? = nil
    @Namespace private var zoom
    @State private var composing = false
    @State private var settings = false

    var body: some View {
        List(selection: selection) {
            if case .failed(let why) = remote.state {
                Label(why, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            section("Needs you", remote.sessions.filter { $0.live == .waiting })
            section("Running", remote.sessions.filter { $0.live == .running })
            section("Open on your Mac", remote.sessions.filter { $0.open && $0.live != .waiting && $0.live != .running })
            section("Recent", remote.sessions.filter { !$0.open && $0.live != .waiting && $0.live != .running })
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationDestination(for: RemoteSession.self) { s in
            let c = remote.conversation(s)
            ChatView(conversation: c, link: remote.openLink, title: s.title) { remote.close(c) }
                .navigationTransition(.zoom(sourceID: s.id, in: zoom))
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
            Button("New", systemImage: "square.and.pencil") { composing = true }
            Button("Settings", systemImage: "gearshape") { settings = true }
            }
        }
        .sheet(isPresented: $settings) { SettingsSheet(remote: remote) }
        .sheet(isPresented: $composing) {
            NewConversationSheet(remote: remote) { id in remote.requested = id }
        }
        .refreshable { remote.refresh() }
        // The Mac sends changes as they happen; this is for coming back to the list.
        .task { remote.refresh() }
        .overlay {
            if remote.sessions.isEmpty, remote.isConnected {
                ContentUnavailableView {
                    Label { Text("No conversations yet") } icon: { FrogFace(mood: .idle, size: 48).tint(.frog) }
                } description: {
                    Text("Start one on your Mac and it shows up here.")
                }
            }
        }
    }

    private var title: String {
        if case .connected(let host) = remote.state { return host }
        return "Frog"
    }

    @ViewBuilder
    private func section(_ name: String, _ rows: [RemoteSession]) -> some View {
        if !rows.isEmpty {
            Section(name) {
                ForEach(rows) { s in
                    Group {
                        if selection != nil {
                            SessionRow(session: s).tag(s.id)
                        } else {
                            NavigationLink(value: s) {
                                SessionRow(session: s).matchedTransitionSource(id: s.id, in: zoom)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if let q = s.question {
                            Button("Allow", systemImage: "checkmark") { remote.answer(q, in: s.id, allow: true) }
                                .tint(Color(red: 0.18, green: 0.62, blue: 0.31))
                            Button("Deny", systemImage: "xmark") { remote.answer(q, in: s.id, allow: false) }
                                .tint(.gray)
                        }
                    }
                }
            }
        }
    }
}

/// A conversation, as in the Mac's sidebar (the same monogram, label and live glyph); while it
/// runs or waits, what it's doing or asking takes the place line.
struct SessionRow: View {
    let session: RemoteSession

    var body: some View {
        HStack(spacing: 12) {
            Monogram(session: session.info, size: 34, selected: false, live: session.live)
            ConversationRowLabel(session: session.info, live: session.live, detail: detail, detailTint: tint)
            Spacer(minLength: 0)
            if session.live == .unread { LiveGlyph(live: .unread) }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        if let q = session.question { return q.text }
        if session.live == .running { return session.activity }
        return nil
    }

    private var tint: Color { session.question != nil ? .orange : .secondary }
}

/// Recorded sessions, for designing without a Mac (`-fixtures`).
struct FixtureListView: View {
    @State private var players: [String: FixturePlayer] = Dictionary(
        uniqueKeysWithValues: FixturePlayer.names.compactMap { n in FixturePlayer(name: n).map { (n, $0) } })
    @State private var path: [String] = []
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            List(FixturePlayer.names, id: \.self) { name in
                NavigationLink(value: name) {
                    if let s = FixturePlayer.session(name) {
                        SessionRow(session: s).matchedTransitionSource(id: name, in: zoom)
                    }
                }
            }
            .navigationTitle("Recordings")
            .navigationDestination(for: String.self) { name in
                if let player = players[name] {
                    ChatView(conversation: player.conversation, link: nil, title: player.session.title)
                        .navigationTransition(.zoom(sourceID: name, in: zoom))
                        .task { await player.play() }
                }
            }
        }
        .onAppear {
            if let name = UserDefaults.standard.string(forKey: "fixture"), path.isEmpty { path = [name] }
        }
    }
}
