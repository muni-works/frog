import SwiftUI

@main
struct FrogApp: App {
    @State private var remote = Remote()

    var body: some Scene {
        WindowGroup {
            RootView(remote: remote)
                .task { if !remote.code.isEmpty { remote.connect() } }
        }
    }
}

struct RootView: View {
    let remote: Remote
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            Group {
                if remote.code.isEmpty || !everConnected {
                    ConnectView(remote: remote)
                } else {
                    SessionListView(remote: remote)
                }
            }
        }
        .onChange(of: remote.state) { _, s in
            if case .connected = s { everConnected = true }
        }
        .onChange(of: phase) { _, p in
            // iOS drops the socket in the background; come back where we were.
            if p == .active, !remote.code.isEmpty, !remote.isConnected { remote.connect() }
        }
    }

    @State private var everConnected = false
}

struct ConnectView: View {
    @Bindable var remote: Remote

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Text("🐸").font(.system(size: 56))
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
