import SwiftUI

/// Every conversation on the Mac: what needs you first, then what's running, then the rest.
struct SessionListView: View {
    let remote: Remote
    /// iPad: rows select the conversation shown beside the list instead of pushing it.
    var selection: Binding<String?>? = nil
    @Namespace private var zoom
    @Environment(\.startNewChat) private var startNewChat
    @State private var settings = false
    @State private var query = ""
    @State private var renaming: RemoteSession?
    @State private var newTitle = ""

    /// What the search matches, as the sidebar's does: title, first message, folder.
    private func matches(_ s: RemoteSession) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return [s.title, s.info.firstInput, s.folder].compactMap { $0?.lowercased() }.contains { $0.contains(q) }
    }

    private var shown: [RemoteSession] { remote.sessions.filter(matches) }
    private func isLive(_ s: RemoteSession) -> Bool { s.live == .waiting || s.live == .running }

    var body: some View {
        List(selection: selection) {
            if case .failed(let why) = remote.state {
                Label(why, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            CloudSection(query: query)
            section("Needs you", shown.filter { $0.live == .waiting })
            section("Running", shown.filter { $0.live == .running })
            section("Pinned", shown.filter { $0.pinned && !isLive($0) })
            section("Open on your Mac", shown.filter { $0.open && !$0.pinned && !isLive($0) })
            // The rest by day, as in the Mac's sidebar.
            ForEach(SessionDays.group(shown.filter { !$0.open && !$0.pinned && !isLive($0) }, day: \.modified), id: \.0) { title, rows in
                section(title, rows)
            }
            if !remote.archived.isEmpty, query.isEmpty {
                Section {
                    NavigationLink {
                        ArchivedListView(remote: remote)
                    } label: {
                        Label("Archived (\(remote.archived.count))", systemImage: "archivebox")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search conversations")
        .navigationTitle(title)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let r = renaming { remote.manage(r.id, "rename", title: newTitle) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .navigationDestination(for: NewChat.self) { _ in NewChatView(remote: remote) }
        .navigationDestination(for: CloudGateway.Session.self) { s in CloudChat(session: s) }
        .navigationDestination(for: RemoteSession.self) { s in
            let c = remote.conversation(s)
            ChatView(conversation: c, link: remote.openLink, title: s.title) { remote.close(c) }
                .navigationTransition(.zoom(sourceID: s.id, in: zoom))
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("New Chat", systemImage: "square.and.pencil") { startNewChat() }
                Button("Settings", systemImage: "gearshape") { settings = true }
            }
        }
        .sheet(isPresented: $settings) { SettingsSheet(remote: remote) }
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
                        } else {
                            Button("Archive", systemImage: "archivebox") { remote.manage(s.id, "archive") }
                                .tint(.indigo)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button(s.pinned ? "Unpin" : "Pin", systemImage: s.pinned ? "pin.slash" : "pin") {
                            remote.manage(s.id, s.pinned ? "unpin" : "pin")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button("Rename…", systemImage: "pencil") {
                            newTitle = s.title
                            renaming = s
                        }
                        Button(s.pinned ? "Unpin" : "Pin", systemImage: s.pinned ? "pin.slash" : "pin") {
                            remote.manage(s.id, s.pinned ? "unpin" : "pin")
                        }
                        Divider()
                        Button("Archive", systemImage: "archivebox") { remote.manage(s.id, "archive") }
                    }
                }
            }
        }
    }
}

/// The Mac's archive: open any of them, or swipe one back.
struct ArchivedListView: View {
    let remote: Remote
    @State private var query = ""

    private var shown: [RemoteSession] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return remote.archived }
        return remote.archived.filter { s in
            [s.title, s.info.firstInput, s.folder].compactMap { $0?.lowercased() }.contains { $0.contains(q) }
        }
    }

    var body: some View {
        List {
            ForEach(SessionDays.group(shown, day: \.modified), id: \.0) { title, rows in
                Section(title) {
                    ForEach(rows) { s in
                        NavigationLink(value: s) { SessionRow(session: s) }
                            .swipeActions(edge: .trailing) {
                                Button("Unarchive", systemImage: "tray.and.arrow.up") { remote.manage(s.id, "unarchive") }
                                    .tint(.indigo)
                            }
                            .contextMenu {
                                Button("Unarchive", systemImage: "tray.and.arrow.up") { remote.manage(s.id, "unarchive") }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search the archive")
        .navigationTitle("Archived")
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Nothing archived" : "No matches", systemImage: "archivebox")
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

/// Frog Cloud's sessions, above the Mac's: title, then repo and age, as on the web.
struct CloudSection: View {
    let query: String
    @State private var cloud = CloudPhone.shared
    @State private var renaming: CloudGateway.Session?
    @State private var deleting: CloudGateway.Session?
    @State private var newTitle = ""

    private var rows: [CloudGateway.Session] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return cloud.live.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.repo.lowercased().contains(q) }
    }

    var body: some View {
        if cloud.key != nil {
            Section {
                ForEach(rows) { s in
                    NavigationLink(value: s) {
                        HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title.isEmpty ? "New session" : s.title).lineLimit(1)
                            Text([s.repo.isEmpty ? "No repo" : s.repo, SessionAge.short(Date(timeIntervalSince1970: (s.last_turn ?? s.updated) / 1000))].joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        // As on the web: a sandbox starting, or the open session's turn, runs.
                        if s.state == "starting" || cloud.running.contains(s.id) {
                            ProgressView().controlSize(.small)
                        }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = s }
                        Button("Archive") { Task { await cloud.archive(s.id) } }.tint(.indigo)
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { newTitle = s.title; renaming = s }
                        Button("Archive", systemImage: "archivebox") { Task { await cloud.archive(s.id) } }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = s }
                    }
                }
            } header: {
                Label("Frog Cloud", systemImage: "cloud")
            }
            .task { cloud.start() }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Rename") {
                    if let s = renaming, let gateway = cloud.gateway {
                        CloudLink.rename(s.id, to: newTitle, gateway: gateway)
                        Task { try? await Task.sleep(for: .seconds(9)); await cloud.refresh() }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("Delete this session?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let s = deleting { Task { await cloud.remove(s.id) } }
                    deleting = nil
                }
            } message: {
                Text("Its sandbox, changes and conversation are gone for good.")
            }
        }
    }
}

/// One cloud session, in the same chat view as the Mac's.
struct CloudChat: View {
    let session: CloudGateway.Session
    /// Sent once it's open: the first message from the new-chat screen.
    var first: String? = nil
    @State private var conversation: Conversation?

    var body: some View {
        Group {
            if let conversation {
                ChatView(conversation: conversation, link: nil, title: session.title.isEmpty ? "New session" : session.title)
            } else {
                ProgressView()
            }
        }
        .task {
            guard conversation == nil else { return }
            conversation = CloudPhone.shared.conversation(session)
            if let first { conversation?.submit(first) }
        }
        .onChange(of: conversation?.busy) { _, busy in
            if busy == true { CloudPhone.shared.running.insert(session.id) } else { CloudPhone.shared.running.remove(session.id) }
        }
        .onDisappear {
            conversation?.stop()
            CloudPhone.shared.running.remove(session.id)
        }
    }
}
