import SwiftUI

@main
struct FrogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var remote = Remote.shared

    var body: some Scene {
        WindowGroup {
            if Self.recordings {
                FixtureListView()
            } else {
                RootView(remote: remote)
                    .task { if !remote.code.isEmpty { remote.connect() } }
            }
        }
    }
}

extension FrogApp {
    /// Launched with `-fixtures YES` or `-fixture <name>`: recorded sessions instead of a Mac.
    static var recordings: Bool {
        UserDefaults.standard.bool(forKey: "fixtures") || UserDefaults.standard.string(forKey: "fixture") != nil
    }
}

struct RootView: View {
    let remote: Remote
    @Environment(\.scenePhase) private var phase
    @State private var path: [RemoteSession] = []
    /// A conversation to open once the list knows it (from Handoff or a notification).
    @State private var pending: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if remote.code.isEmpty || !(everConnected || remote.isConnected) {
                    ConnectView(remote: remote)
                } else {
                    SessionListView(remote: remote)
                }
            }
        }
        .onOpenURL { url in
            // frog://session/<id>, from the Live Activity and widgets.
            if url.host() == "session", let id = url.pathComponents.last { remote.requested = id }
        }
        .onContinueUserActivity(Handoff.conversation) { a in
            pending = a.userInfo?["session"] as? String
            openPending()
        }
        .onChange(of: remote.sessions) { openPending() }
        .onChange(of: remote.requested) { _, id in
            guard let id else { return }
            remote.requested = nil
            pending = id
            openPending()
        }
        .onChange(of: remote.state) { _, s in
            if case .connected = s {
                everConnected = true
                Task { await Notifications.shared.requestPermission() }
            }
        }
        .onChange(of: phase) { _, p in
            // iOS drops the socket in the background; come back where we were.
            if p == .active, !remote.code.isEmpty, !remote.isConnected { remote.connect() }
        }
    }

    @State private var everConnected = false

    private func openPending() {
        guard let id = pending, let s = remote.sessions.first(where: { $0.id == id }) else { return }
        pending = nil
        path = [s]
    }
}

struct ConnectView: View {
    @Bindable var remote: Remote

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    FrogFace(mood: remote.state == .connecting ? .reading : .idle, size: 64).tint(.frog)
                    Text("Frog on your Mac, in your pocket")
                        .font(.headline)
                    Text("Watch your conversations, answer frog's questions and send it the next thing, while the work runs on your Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                TextField("Code", text: $remote.code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                TextField("Address", text: $remote.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } footer: {
                Text("On your Mac: Frog → Settings → General → Let frog on iPhone connect.")
            }
            Section {
                Button {
                    remote.connect()
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer()
                        if remote.state == .connecting { ProgressView() }
                    }
                }
                .disabled(remote.code.isEmpty || remote.state == .connecting)
                if case .failed(let why) = remote.state {
                    Label(why, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Connect")
    }
}
