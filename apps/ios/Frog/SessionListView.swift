import SwiftUI

/// Every conversation on the Mac: what needs you first, then what's running, then the rest.
struct SessionListView: View {
    let remote: Remote

    var body: some View {
        List {
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
            ChatView(model: remote.attach(s), remote: remote)
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
                ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Start one on your Mac and it shows up here."))
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
                    NavigationLink(value: s) { SessionRow(session: s) }
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: RemoteSession

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(session.isLocal ? Color.imessageBlue : Color.imessageGreen)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.body.weight(session.live == .unread ? .semibold : .regular))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            badge
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !session.chat, let f = session.folder { parts.append(f) }
        parts.append(Models.short(session.model))
        parts.append(session.modified.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var badge: some View {
        switch session.live {
        case .waiting:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .running:
            ProgressView().controlSize(.small)
        case .unread:
            Circle().fill(Color.accentColor).frame(width: 10, height: 10)
        case nil:
            EmptyView()
        }
    }
}

extension Color {
    /// The Mac's bubble colors: blue when the model runs on your hardware, green in the cloud.
    static let imessageBlue = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let imessageGreen = Color(red: 0.19, green: 0.78, blue: 0.35)
}
