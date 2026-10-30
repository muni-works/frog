import SwiftUI

/// A new chat, as a place in the navigation (the phone opens on one when nothing is fresh).
struct NewChat: Hashable {}

extension EnvironmentValues {
    /// Go to a new chat, from wherever you are.
    @Entry var startNewChat: () -> Void = {}
}

/// Start something new on the Mac: what frog should do, and where (a plain chat, or one of your
/// projects). Like a fresh thread in a chat app: the frog, a question, and the composer ready.
/// Becomes the conversation once the Mac has it going.
struct NewChatView: View {
    let remote: Remote
    @State private var text = ""
    /// A conversation whose folder to start in; nil for a chat.
    @State private var like: String?
    @State private var sending = false
    /// Frog Cloud instead of the Mac: `.some(nil)` a sandbox with no repo, `.some(repo)` on it.
    @State private var cloud: String??
    @State private var repos: [CloudGateway.Repos.Repo] = []
    @State private var made: CloudGateway.Session?
    @State private var firstMessage: String?
    /// What was sent, shown as sent while the Mac starts it.
    @State private var sent: String?
    @State private var failure: String?
    @FocusState private var focused: Bool

    /// One conversation per project folder, most recent first, to borrow its folder.
    private var places: [RemoteSession] {
        var seen = Set<String>()
        return remote.sessions.filter { s in
            guard !s.chat, let f = s.folder else { return false }
            return seen.insert(f).inserted
        }
    }

    private var place: String {
        switch cloud {
        case .some(.none): return "Frog Cloud"
        case .some(.some(let r)): return r.split(separator: "/").last.map(String.init) ?? r
        case .none: return like.flatMap { id in places.first { $0.id == id }?.folder } ?? "Chat"
        }
    }
    private var canSend: Bool {
        !sending && (cloud != nil || remote.isConnected) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            FrogFace(mood: sending ? .thinking : .idle, size: 64).tint(Color.frog)
            Text(sending ? (cloud == nil ? "Starting on your Mac…" : "Starting a sandbox…") : "What should frog do?")
                .font(.title3.weight(.semibold))
                .contentTransition(.opacity)
            placeMenu
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 24)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Spacer()
            if let sent {
                Text(sent)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.frog, in: .rect(cornerRadius: 20))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture { focused = false }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("New Chat")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: sending)
        .onAppear {
            focused = true
            // Without a Mac, a new conversation can only run in the cloud.
            if !remote.isConnected, CloudPhone.shared.key != nil, cloud == nil { cloud = .some(nil) }
        }
        .task { repos = (try? await CloudPhone.shared.gateway?.repos())?.repos ?? [] }
        .navigationDestination(item: $made) { CloudChat(session: $0, first: firstMessage) }
    }

    /// Where it runs: a chat, or one of your projects.
    private var placeMenu: some View {
        Menu {
            if remote.isConnected {
                Section("Your Mac") {
                    Button("Chat", systemImage: "bubble.left") { cloud = nil; like = nil }
                    ForEach(places) { s in
                        Button(s.folder ?? s.title, systemImage: "folder") { cloud = nil; like = s.id }
                    }
                }
            }
            if CloudPhone.shared.key != nil {
                // As on the web: the repo picker, a sandbox of its own.
                Section("Frog Cloud") {
                    ForEach(repos, id: \.self) { r in
                        Button(r.name, systemImage: r.private ? "lock" : "book.closed") { cloud = .some(r.name) }
                    }
                    Button("No Repo", systemImage: "cloud") { cloud = .some(nil) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: cloud != nil ? "cloud" : like == nil ? "bubble.left" : "folder")
                Text(place)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(sending)
        .accessibilityLabel("Where: \(place)")
    }

    private var composer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message frog", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                    .focused($focused)
                    .disabled(sending)
                    .onSubmit { Task { await start() } }
                Button { Task { await start() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(canSend ? .white : .secondary)
                        .frame(width: 44, height: 44)
                }
                .glassEffect(canSend ? .regular.tint(Color.frog).interactive() : .regular, in: .circle)
                .disabled(!canSend)
                .accessibilityLabel("Start")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func start() async {
        guard canSend else { return }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        failure = nil
        sent = message
        text = ""
        FrogSounds.shared.play(.plip)
        if let target = cloud {
            if let session = await CloudPhone.shared.create(repo: target) {
                firstMessage = message
                made = session
            } else {
                failure = CloudPhone.shared.error ?? "Couldn't start a sandbox."
                text = message  // nothing started: what you wrote stays
            }
            sending = false
            sent = nil
            return
        }
        switch await remote.startNew(message, like: like) {
        case .success(let id):
            // The root swaps this screen for the conversation once the list has it.
            remote.requested = id
        case .failure(let e):
            failure = e.message
            sending = false
            sent = nil
            text = message
        }
    }
}
