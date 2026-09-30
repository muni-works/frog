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
                    .environment(\.models, remote.models)
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
    @Environment(\.horizontalSizeClass) private var size
    @State private var path: [RemoteSession] = []
    /// iPad: the conversation beside the list.
    @State private var selection: String?
    /// A conversation to open once the list knows it (from Handoff or a notification).
    @State private var pending: String?

    private var connected: Bool { remote.paired && !remote.code.isEmpty }

    var body: some View {
        Group {
            if size == .regular, connected {
                // iPad: the list beside the conversation, like Messages.
                NavigationSplitView {
                    SessionListView(remote: remote, selection: $selection)
                } detail: {
                    if let id = selection, let s = remote.sessions.first(where: { $0.id == id }) {
                        let c = remote.conversation(s)
                        ChatView(conversation: c, link: remote.openLink, title: s.title) { remote.close(c) }.id(id)
                    } else {
                        ContentUnavailableView {
                            Label { Text("Pick a conversation") } icon: { FrogFace(mood: .idle, size: 56).tint(.frog) }
                        } description: {
                            Text("What frog is doing on your Mac shows up here.")
                        }
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    if connected { SessionListView(remote: remote) } else { ConnectView(remote: remote) }
                }
            }
        }
        .onOpenURL { url in
            // frog://pair?..., the QR code in the Mac's settings, from the Camera app.
            if remote.pair(url) { return }
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
                Task { await Notifications.shared.requestPermission() }
            }
        }
        .onChange(of: phase) { _, p in
            // iOS drops the socket in the background; come back where we were.
            if p == .active, !remote.code.isEmpty, !remote.isConnected { remote.connect() }
        }
    }


    private func openPending() {
        guard let id = pending, let s = remote.sessions.first(where: { $0.id == id }) else { return }
        pending = nil
        if size == .regular { selection = s.id } else { path = [s] }
    }
}

struct ConnectView: View {
    @Bindable var remote: Remote
    @State private var finder = MacFinder()
    @State private var scanning = false
    @State private var advanced = false

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
            if Scanner.available {
                Section {
                    Button("Scan the Code on Your Mac", systemImage: "qrcode.viewfinder") { scanning = true }
                }
            }
            Section {
                if finder.names.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for your Mac…").foregroundStyle(.secondary)
                    }
                }
                ForEach(finder.names, id: \.self) { name in
                    Button { remote.host = name } label: {
                        HStack {
                            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                            Text(name).foregroundStyle(.primary)
                            Spacer()
                            if remote.host == name { Image(systemName: "checkmark").foregroundStyle(Color.frog) }
                        }
                    }
                }
            } header: {
                Text("Macs nearby")
            } footer: {
                Text("On your Mac: Frog → Settings → General → Let frog on iPhone connect.")
            }
            Section {
                TextField("Code", text: $remote.code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                DisclosureGroup("Address", isExpanded: $advanced) {
                    TextField("Mac name or host:port", text: $remote.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
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
                .disabled(remote.code.isEmpty || remote.host.isEmpty || remote.state == .connecting)
                if case .failed(let why) = remote.state {
                    Label(why, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Connect")
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
        .onChange(of: finder.names) { _, names in
            // One Mac nearby and nothing chosen yet: that's the one.
            if names.count == 1, remote.host.isEmpty { remote.host = names[0] }
        }
        .sheet(isPresented: $scanning) {
            Scanner { url in
                scanning = false
                _ = remote.pair(url)
            }
            .ignoresSafeArea()
        }
    }
}
