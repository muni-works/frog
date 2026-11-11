import SwiftUI

/// The sidebar's foot, as on the web: who's signed in to Frog Cloud and their credit, a click
/// from Settings › Billing. Signed out, the same place offers sign-in and says what it adds,
/// since everything on this Mac works without it.
struct UserFooter: View {
    @State private var account = CloudAccount.shared
    @State private var signingIn: Task<Void, Never>?
    @State private var failure: String?
    /// The provider of the sign-in that failed, for Try Again.
    @State private var lastProvider: String?
    @AppStorage("settingsTab") private var settingsTab = "general"
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let me = account.me {
                Button {
                    settingsTab = "billing"
                    openSettings()
                } label: {
                    row(avatar: me.handle.map { "https://github.com/\($0).png?size=56" } ?? me.image, title: Self.firstName(me) ?? "Signed in", detail: Self.creditLine(me), warn: me.credit_cents <= 0 && me.subscription == nil)
                }
                .help("Account and billing")
            } else if account.signedIn && account.error == nil {
                row(avatar: nil, title: "Frog Cloud", detail: "Loading…")
            } else if let task = signingIn {
                // Waiting on the browser: a click gives up, so a closed tab never leaves it spinning.
                Button { task.cancel() } label: {
                    row(avatar: nil, title: "Signing in…", detail: "Finish in your browser, or click to cancel")
                }
                .help("Cancel signing in")
            } else {
                Menu {
                    if failure != nil, let lastProvider {
                        Button("Try Again") { signIn(lastProvider) }
                        Divider()
                    }
                    Button("Continue with GitHub") { signIn("github") }
                    Button("Continue with Google") { signIn("google") }
                } label: {
                    row(avatar: nil, title: "Sign in to Frog Cloud",
                        detail: failure ?? (account.signedIn ? "Access to more powerful models" : "Cloud sessions · $5 free to start"),
                        warn: failure != nil)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Sign in with GitHub or Google. Your conversations on this Mac don't need it.")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .task { await account.refresh() }
    }

    private func row(avatar: String?, title: String, detail: String, warn: Bool = false) -> some View {
        HStack(spacing: 9) {
            Group {
                if let avatar, let url = URL(string: avatar) {
                    AsyncImage(url: url) { $0.resizable() } placeholder: { Circle().fill(Tokens.raised) }
                        .clipShape(Circle())
                } else {
                    Image(systemName: account.me == nil ? "person.crop.circle.badge.plus" : "person.crop.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.green.opacity(0.85))
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.frog(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(detail).font(.frog(size: 11)).foregroundStyle(warn ? .orange : .secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .hoverPlate(h: 0, v: 0, radius: 8)
    }

    private func signIn(_ provider: String) {
        failure = nil
        lastProvider = provider
        signingIn = Task {
            defer { signingIn = nil }
            do {
                try await CloudAccount.signInAndSave(provider: provider)
            } catch {
                failure = CloudAccount.signInFailure(error)
            }
        }
    }

    static func firstName(_ me: CloudAccount.Me) -> String? {
        me.name?.split(separator: " ").first.map(String.init) ?? me.handle ?? me.email
    }

    /// "Pro · $12.40 credit", or just the credit on usage pricing.
    static func creditLine(_ me: CloudAccount.Me) -> String {
        let d = me.credit_cents / 100
        let credit = d > 0 && d < 0.01 ? "<$0.01" : String(format: "$%.2f", d)
        return [me.subscription?.name, "\(credit) credit"].compactMap { $0 }.joined(separator: " · ")
    }
}

extension CloudAccount {
    /// GitHub or Google in the browser, back with this Mac's own key, saved where frog reads it;
    /// then everything that shows the account catches up.
    static func signInAndSave(provider: String = "github") async throws {
        let key = try await CloudSignIn.run(provider: provider)
        guard await ProviderStore.shared.setKey(key, for: "cloud") else { throw SignInError.notSaved }
        await shared.reloadKey()
        await shared.refresh()
        await CloudSessions.shared.refresh()
    }

    /// Signed in with Google: GitHub in the browser, joined to this Mac's account (the link
    /// token makes sure of that, whatever the browser's cookie), so its repos show up.
    static func connectGitHub() async throws { try await connect("github") }

    /// Adds a sign-in ("github" or "google") to this Mac's account, as `connectGitHub` does.
    static func connect(_ provider: String) async throws {
        let link = try await shared.linkToken()
        let key = try await CloudSignIn.run(provider: provider, link: link)
        guard await ProviderStore.shared.setKey(key, for: "cloud") else { throw SignInError.notSaved }
        await shared.reloadKey()
        await shared.refresh()
        await CloudSessions.shared.refresh()
    }
}
