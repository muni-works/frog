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
    @State private var path = NavigationPath()
    /// Landed somewhere since launch (or since coming back after a while).
    @State private var landed = false
    @State private var leftAt: Date?
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
                        .environment(\.startNewChat) { selection = nil }
                } detail: {
                    if let id = selection, let s = remote.session(id) {
                        let c = remote.conversation(s)
                        ChatView(conversation: c, link: remote.openLink, title: s.title) { remote.close(c) }.id(id)
                            .environment(\.startNewChat) { selection = nil }
                    } else {
                        // Never a blank page: a new chat until you pick one.
                        NavigationStack { NewChatView(remote: remote) }
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    // Signed in to Frog Cloud, the list works without a Mac: its sessions are the cloud's.
                    if connected || CloudPhone.shared.key != nil { SessionListView(remote: remote) } else { ConnectView(remote: remote) }
                }
                .environment(\.startNewChat) { if size != .regular { go(NewChat(), animated: true) } }
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
        .onChange(of: remote.sessions) {
            openPending()
            land()
        }
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
            if p == .background { leftAt = .now }
            guard p == .active else { return }
            // Back after a while: start from what's fresh, as on launch.
            if let leftAt, Date.now.timeIntervalSince(leftAt) > Self.away { landed = false; land() }
            leftAt = nil
            // iOS drops the socket in the background; come back where we were.
            if !remote.code.isEmpty, !remote.isConnected { remote.connect() }
        }
    }


    private func openPending() {
        guard let id = pending, let s = remote.session(id) else { return }
        pending = nil
        landed = true
        if size == .regular { selection = s.id } else { go(s) }
    }

    /// Gone this long, the phone starts from what's fresh rather than where you left off.
    static let away: TimeInterval = 30 * 60
    /// A conversation touched this recently is the one to pick up; older, a new chat.
    static let fresh: TimeInterval = 60 * 60

    /// Never a bare list: on an iPhone, open the latest conversation if it's fresh, else a new
    /// chat. Once per launch (or return), once the Mac's list is in, unless a link already chose.
    private func land() {
        guard !landed, size != .regular, connected, remote.isConnected, pending == nil, remote.requested == nil else { return }
        landed = true
        if let latest = remote.sessions.max(by: { $0.modified < $1.modified }),
           latest.live != nil || Date.now.timeIntervalSince(latest.modified) < Self.fresh {
            go(latest)
        } else {
            go(NewChat())
        }
    }

    /// Show `place` with the list one step back: dropped straight in (on launch, from a link, a
    /// new chat turning into its conversation), or pushed when you asked for it.
    private func go(_ place: some Hashable, animated: Bool = false) {
        var t = Transaction()
        t.disablesAnimations = !animated
        withTransaction(t) {
            var p = NavigationPath()
            p.append(place)
            path = p
        }
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
                Button(CloudPhone.shared.signingIn ? "Signing In…" : "Sign In with GitHub", systemImage: "cloud") { CloudPhone.shared.signIn(provider: "github") }
                    .disabled(CloudPhone.shared.signingIn)
                Button("Sign In with Google", systemImage: "person.crop.circle") { CloudPhone.shared.signIn(provider: "google") }
                    .disabled(CloudPhone.shared.signingIn)
            } footer: {
                Text("No Mac needed: sessions run in their own cloud sandbox, on a repo you pick.")
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
