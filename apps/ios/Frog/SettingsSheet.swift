import SwiftUI

/// The phone's settings: what the Mac has spent and used, and how the phone behaves. Spending
/// and energy are the Mac's record, as it sent them; the cap is set on the Mac.
struct SettingsSheet: View {
    let remote: Remote
    @Environment(\.dismiss) private var dismiss
    @AppStorage("playfulSounds") private var sounds = true
    @AppStorage(WatchLink.directKey) private var watchURL = ""
    private let stats = ModelStats.shared
    @State private var cloud = CloudPhone.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if cloud.key != nil {
                        Button("Sign Out", role: .destructive) { cloud.signOut() }
                    } else {
                        Button(cloud.signingIn ? "Signing In…" : "Sign In with GitHub") { cloud.signIn(provider: "github") }
                            .disabled(cloud.signingIn)
                        Button("Sign In with Google") { cloud.signIn(provider: "google") }
                            .disabled(cloud.signingIn)
                    }
                    if let e = cloud.error { Text(e).font(.footnote).foregroundStyle(.red) }
                } header: {
                    Text("Frog Cloud")
                } footer: {
                    Text("Sessions in their own cloud sandbox, on a repo you pick. They belong to your account, so they show up on the web and your Mac too.")
                }

                if cloud.key != nil {
                    CloudBilling()
                }

                Section {
                    LabeledContent("This week", value: ModelStats.spent(stats.spentThisWeek))
                    if stats.monthlyCap > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("This month", value: "\(ModelStats.spent(stats.spentThisMonth)) of \(ModelStats.money(stats.monthlyCap))")
                            ProgressView(value: min(1, stats.spentThisMonth / stats.monthlyCap))
                                .tint(stats.overCap ? .red : .accentColor)
                        }
                    } else {
                        LabeledContent("This month", value: ModelStats.spent(stats.spentThisMonth))
                    }
                } header: {
                    Text("Cloud models")
                } footer: {
                    Text(stats.overCap
                         ? "Cloud models are paused for the rest of the month. Change the cap in frog's settings on your Mac."
                         : "At each provider's list prices. A monthly cap is set in frog's settings on your Mac.")
                }

                Section {
                    NavigationLink {
                        EnergySettings().navigationTitle("Energy")
                    } label: {
                        Label("Energy", systemImage: "leaf")
                    }
                } footer: {
                    Text("What frog's turns used: measured by your Mac's power sensor, plus an estimate for a cloud model's data center.")
                }

                Section {
                    Toggle(isOn: $sounds) { Label("Frog sounds", systemImage: "speaker.wave.2") }
                }

                Section {
                    TextField("wss://your-mac.tailnet.ts.net", text: $watchURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { WatchLink.shared.directChanged() }
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text("Where your watch reaches your Mac when your phone isn't around: a secure WebSocket to frog's bridge, like `tailscale serve` in front of port 8913. Leave empty to go through your phone.")
                }

                Section {
                    if case .connected(let host) = remote.state {
                        LabeledContent("Connected to", value: host)
                    }
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                        dismiss()
                        remote.disconnect(forget: true)
                    }
                } header: {
                    Text("Your Mac")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        WatchLink.shared.directChanged()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The energy history, from a turn's energy card.
struct EnergyHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EnergySettings()
                .navigationTitle("Energy")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
    }
}

/// Account and billing, as the web's Settings and the Mac's Settings › Billing: who's signed
/// in, the plan's allowance windows (or the plans), and credit with Stripe top-ups.
private struct CloudBilling: View {
    @State private var account = CloudAccount.shared
    @State private var amount = 10

    var body: some View {
        Group {
            if let me = account.me {
                Section {
                    LabeledContent(me.name ?? me.handle ?? "Signed in") {
                        Text([me.handle.map { "@\($0)" }, me.email].compactMap { $0 }.joined(separator: " · "))
                    }
                } header: {
                    Text("Account")
                }
                if let sub = me.subscription {
                    Section(sub.name) {
                        ForEach(sub.windows, id: \.self) { WindowBar(window: $0) }
                    }
                } else {
                    Section {
                        ForEach(CloudAccount.plans, id: \.id) { p in
                            Button { Task { await account.subscribe(p.id) } } label: {
                                LabeledContent(p.name, value: "$\(p.price)/mo")
                            }
                        }
                    } header: {
                        Text("Usage pricing · no subscription")
                    } footer: {
                        Text("Subscribe for an included allowance every 5 hours and every week. Past it, you keep going on credit at usage prices.")
                    }
                }
                Section {
                    LabeledContent("Usage credit", value: CloudFormat.dollars(me.credit_cents))
                    Picker("Add credit", selection: $amount) {
                        ForEach(CloudAccount.topUps, id: \.self) { Text("$\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Button("Add $\(amount)") { Task { await account.topUp(amount) } }
                } footer: {
                    Text(me.subscription == nil ? "Each turn pays from credit at the model's prices. Paid through Stripe; credit doesn't expire." : "Used only past your plan's allowance. Paid through Stripe; credit doesn't expire.")
                }
            } else if let e = account.error {
                Section { Text(e).foregroundStyle(.red) }
            } else if account.loading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .task {
            CloudAccount.keyProvider = { CloudPhone.currentKey }
            CloudPhone.currentKey = CloudPhone.shared.key
            await account.reloadKey()
            await account.refresh()
        }
    }
}
