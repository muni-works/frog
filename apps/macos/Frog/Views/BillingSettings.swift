import SwiftUI

/// Settings › Billing, as on the web: the plan and its allowance windows (or the plans to pick
/// from), then credit, which pays past the plan or for every turn without one. Checkout is
/// Stripe, in the browser.
struct BillingSettings: View {
    @State private var account = CloudAccount.shared
    @State private var amount = 10
    @State private var signingIn: Task<Void, Never>?
    @State private var failure: String?
    /// The sign-in that failed, for Try Again.
    @State private var retry: (@MainActor () async throws -> Void)?

    var body: some View {
        Form {
            if !account.signedIn {
                Section {
                    Text("Sign in to see your plan and credit. Everything on this Mac works without an account; Frog Cloud adds sessions in their own sandbox and hosted models, with $5 free to start.")
                        .foregroundStyle(.secondary)
                    if let task = signingIn {
                        LabeledContent("Signing In… Finish in your browser.") { Button("Cancel") { task.cancel() } }
                    } else {
                        ForEach([("github", "Sign In with GitHub"), ("google", "Sign In with Google")], id: \.0) { provider, title in
                            Button(title) { start { try await CloudAccount.signInAndSave(provider: provider) } }
                        }
                    }
                }
            } else if let me = account.me {
                Section("Account") {
                    LabeledContent(me.name ?? me.handle ?? "Signed in") {
                        Text([me.handle.map { "@\($0)" }, me.email].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                    Text("Cloud sessions belong to your account, so they show up on every device you sign in on.")
                        .font(.frog(size: 11)).foregroundStyle(.secondary)
                }
                Section("Sign-in") {
                    login("GitHub", me.handle.map { "@\($0)" }, why: "Needed for your repos.", provider: "github")
                    login("Google", me.google, why: "Sign in with your Google account.", provider: "google")
                }
                Section {
                    HStack {
                        Link("Devices and keys", destination: URL(string: "https://frog.toys/?settings=account")!)
                        Spacer()
                        Button("Sign Out") { Task { await signOut() } }
                    }
                }
                plan(me)
                credit(me)
                Section {
                    Text("Frog Cloud bills per token, at each model's prices.")
                        .font(.frog(size: 11)).foregroundStyle(.secondary)
                }
            } else if account.error == nil {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
            if let failure {
                Section {
                    LabeledContent {
                        if let retry, signingIn == nil { Button("Try Again") { start(retry) } }
                    } label: { Text(failure).foregroundStyle(.red) }
                }
            } else if let error = account.error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .task { await account.refresh() }
    }

    /// Runs a sign-in in the browser, cancellable, saying why if it doesn't finish.
    private func start(_ run: @escaping @MainActor () async throws -> Void) {
        failure = nil
        retry = run
        signingIn = Task {
            defer { signingIn = nil }
            do { try await run() } catch { failure = CloudAccount.signInFailure(error) }
        }
    }

    /// Forgets this Mac's Frog Cloud key, as signing out on the web forgets the browser's.
    private func signOut() async {
        await ProviderStore.shared.setKey("", for: "cloud")
        await account.reloadKey()
        await account.refresh()
        await CloudSessions.shared.refresh()
    }

    /// One sign-in the account has, or a Connect button that adds it to this account.
    private func login(_ name: String, _ who: String?, why: String, provider: String) -> some View {
        LabeledContent {
            if who != nil {
                Text("Connected").foregroundStyle(.secondary)
            } else if let task = signingIn {
                Button("Cancel") { task.cancel() }
            } else {
                Button("Connect") { start { try await CloudAccount.connect(provider) } }
            }
        } label: {
            Text(name)
            Text(who ?? "Not connected. \(why)")
        }
    }

    @ViewBuilder
    private func plan(_ me: CloudAccount.Me) -> some View {
        if let sub = me.subscription {
            Section(sub.name) {
                ForEach(sub.windows, id: \.self) { WindowBar(window: $0) }
                Link("Change or cancel your plan", destination: URL(string: "https://frog.toys/?settings=billing")!)
                    .font(.frog(size: 12))
            }
        } else {
            Section {
                Text("Subscribe for an included allowance every 5 hours and every week. Past it, you keep going on credit at usage prices.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(CloudAccount.plans, id: \.id) { p in
                        Button { Task { await account.subscribe(p.id) } } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(.frog(size: 13, weight: .semibold))
                                Text("$\(p.price)/mo").font(.frog(size: 16, weight: .semibold))
                                Text(p.blurb).font(.frog(size: 11)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Tokens.raised, in: .rect(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Usage pricing · no subscription")
            }
        }
    }

    private func credit(_ me: CloudAccount.Me) -> some View {
        Section {
            LabeledContent("Usage credit", value: CloudFormat.dollars(me.credit_cents))
            Text(me.subscription == nil ? "Each turn pays from credit at the model's prices." : "Used only past your plan's allowance.")
                .font(.frog(size: 11)).foregroundStyle(.secondary)
            Picker("Add credit", selection: $amount) {
                ForEach(CloudAccount.topUps, id: \.self) { Text("$\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            Button("Add $\(amount)") { Task { await account.topUp(amount) } }
                .buttonStyle(.borderedProminent)
            Text("Paid through Stripe. Credit doesn't expire.")
                .font(.frog(size: 11)).foregroundStyle(.secondary)
        }
    }
}
