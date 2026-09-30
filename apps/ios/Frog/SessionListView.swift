import SwiftUI

/// Every conversation on the Mac: what needs you first, then what's running, then the rest.
struct SessionListView: View {
    let remote: Remote
    /// iPad: rows select the conversation shown beside the list instead of pushing it.
    var selection: Binding<String?>? = nil
    @Namespace private var zoom
    @AppStorage("playfulSounds") private var sounds = true

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
            let model = remote.attach(s)
            ChatView(model: model) { remote.detach(model) }
                .navigationTransition(.zoom(sourceID: s.id, in: zoom))
        }
        .toolbar {
            Menu {
                Toggle("Frog sounds", systemImage: "speaker.wave.2", isOn: $sounds)
                Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { remote.disconnect(forget: true) }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
        .refreshable { remote.refresh() }
        .task {
            // The Mac doesn't push list changes yet; a light poll keeps "running" honest.
            while !Task.isCancelled {
                remote.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
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

struct SessionRow: View {
    let session: RemoteSession

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                switch session.live {
                case .waiting: FrogFace(mood: .waiting, size: 22).tint(.frog)
                case .running: FrogFace(mood: .working, size: 22).tint(.frog)
                default:
                    Circle()
                        .fill(session.isLocal ? Color.imessageBlue : Color.imessageGreen)
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.body.weight(session.live == .unread ? .semibold : .regular))
                    .lineLimit(1)
                if let q = session.question {
                    Text(q.text).font(.caption.weight(.medium)).foregroundStyle(.orange).lineLimit(1)
                } else if session.live == .running, let a = session.activity {
                    Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1).shimmer()
                } else {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            switch session.live {
            case .waiting:
                Text("Needs you").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            case .unread:
                Circle().fill(Color.imessageBlue).frame(width: 10, height: 10)
            default:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !session.chat, let f = session.folder { parts.append(f) }
        parts.append(Models.short(session.model))
        parts.append(session.modified.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
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
                    ChatView(model: player.model)
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
