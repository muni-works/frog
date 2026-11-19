import AppKit
import SwiftUI

/// Account and Billing (design/settings.json), the same page as on the web: who you are and your
/// sign-ins, devices and keys; the plan, credit and a code, credit added, prices.

/// Signing in in the browser, cancellable, saying why if it didn't finish.
@MainActor @Observable
final class SignInFlow {
    static let shared = SignInFlow()
    private(set) var task: Task<Void, Never>?
    private(set) var failure: String?

    func start(_ run: @escaping @MainActor () async throws -> Void) {
        failure = nil
        task = Task {
            defer { task = nil }
            do { try await run() } catch { failure = CloudAccount.signInFailure(error) }
        }
    }

    func cancel() { task?.cancel() }
}

/// Signed out: one line and the two ways in.
struct SignInRows: View {
    @State private var flow = SignInFlow.shared

    var body: some View {
        SettingsRow("Sign in to Frog Cloud", description: flow.failure ?? "25¢ of Frog Cloud credit free, $1 when you connect GitHub. Everything on this Mac works without an account.") {
            if flow.task != nil {
                Button("Cancel") { flow.cancel() }.buttonStyle(SettingsButtonStyle())
            } else {
                HStack(spacing: 8) {
                    Button("GitHub") { flow.start { try await CloudAccount.signInAndSave(provider: "github") } }
                        .help("Sign in with GitHub, in your browser")
                    Button("Google") { flow.start { try await CloudAccount.signInAndSave(provider: "google") } }
                        .help("Sign in with Google, in your browser")
                }
                .buttonStyle(SettingsButtonStyle())
            }
        }
    }
}

// MARK: - Account

/// Name, email and Sign out; signed out, the way in.
struct ProfileRows: View {
    @State private var account = CloudAccount.shared

    var body: some View {
        Group {
            if !account.signedIn {
                SignInRows()
            } else if let me = account.me {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow(me.name ?? me.handle ?? "Signed in",
                                description: [me.handle.map { "@\($0)" }, me.email].compactMap { $0 }.joined(separator: ", ")) {
                        Button("Sign out") { Task { await signOut() } }.buttonStyle(SettingsButtonStyle())
                            .help("This Mac forgets its Frog Cloud key. Your sessions stay in your account.")
                    }
                    Text("Cloud sessions belong to your account, so they show up on every device you sign in on.")
                        .font(.frog(size: SettingsLook.description)).foregroundStyle(Tokens.textTertiary)
                }
            } else if let error = account.error {
                SettingsRow("Frog Cloud", description: error) { EmptyView() }
            } else {
                SettingsRow("Frog Cloud") { ProgressView().controlSize(.small) }
            }
        }
        .task { guard SettingsBindings.loads else { return }; await account.refresh() }
    }

    /// Forgets this Mac's Frog Cloud key, as signing out on the web forgets the browser's.
    private func signOut() async {
        await ProviderStore.shared.setKey("", for: "cloud")
        await account.reloadKey()
        await account.refresh()
        await CloudSessions.shared.refresh()
    }
}

/// GitHub and Google: connected, or a Connect that adds it to this account.
struct SignInsRows: View {
    @State private var account = CloudAccount.shared
    @State private var flow = SignInFlow.shared

    var body: some View {
        if let me = account.me {
            login("GitHub", me.handle.map { "@\($0)" }, why: "Adds your repos, and the rest of your first dollar.", provider: "github")
            login("Google", me.google, why: "Sign in with your Google account.", provider: "google")
        }
    }

    private func login(_ name: String, _ who: String?, why: String, provider: String) -> some View {
        SettingsRow(name, description: who ?? "Not connected. \(why)") {
            if who != nil {
                SettingsValue("Connected")
            } else if flow.task != nil {
                Button("Cancel") { flow.cancel() }.buttonStyle(SettingsButtonStyle())
            } else {
                Button("Connect") { flow.start { try await CloudAccount.connect(provider) } }.buttonStyle(SettingsButtonStyle())
                    .help("Adds \(name) to this account, in your browser")
            }
        }
    }
}

enum SettingsDates {
    /// "Nov 17, 2026" from the edge's ISO time.
    static func day(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        return d.map { $0.formatted(.dateTime.month(.abbreviated).day().year()) } ?? iso
    }
}

/// Each signed-in app and each key made for the CLI or a tool: list, create, revoke. A new key
/// shows once. This Mac's own key can't be revoked from here (Sign out does that).
struct DevicesRows: View {
    @State private var account = CloudAccount.shared
    @State private var keys: [CloudAccount.KeyInfo]?
    @State private var name = ""
    @State private var made: String?
    @State private var error: String?

    var body: some View {
        if account.signedIn {
            Group {
                if keys == nil, error == nil { SettingsRow("Loading…") { ProgressView().controlSize(.small) } }
                ForEach((keys ?? []).filter { $0.revoked != true }) { k in
                    SettingsRow(k.name ?? (k.kind == "device" ? "A device" : "API key"),
                                description: "\(k.kind == "device" ? "Signed in" : "API key") \(SettingsDates.day(k.created))\(k.last_used.map { ", last used \(SettingsDates.day($0))" } ?? "")") {
                        if k.current == true {
                            SettingsValue("This Mac", help: "The key this Mac uses. Sign out to forget it.")
                        } else {
                            Button("Revoke") { Task { await revoke(k.id) } }.buttonStyle(SettingsButtonStyle())
                                .help(k.kind == "device" ? "Signs that device out" : "That key stops working")
                        }
                    }
                }
                if let made {
                    SettingsRow("Copy it now: it's only shown once", description: made) {
                        HStack(spacing: 8) {
                            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(made, forType: .string) }
                            Button("Done") { self.made = nil }
                        }
                        .buttonStyle(SettingsButtonStyle())
                    }
                } else {
                    SettingsRow("New API key", description: error ?? "Use it as FROG_API_KEY.") {
                        HStack(spacing: 8) {
                            FrogField(label: "Name (optional)", text: $name, width: 160)
                            Button("Create key") { Task { await create() } }.buttonStyle(SettingsButtonStyle())
                                .help("A key for the CLI or a tool. It's shown once.")
                        }
                    }
                }
            }
            .task { guard SettingsBindings.loads else { return }; await load() }
        }
    }

    private func load() async {
        do { keys = try await account.keys(); error = nil } catch { self.error = "Couldn't load your keys." }
    }

    private func create() async {
        do { made = try await account.createKey(name).key; name = ""; await load() } catch { self.error = "Couldn't make a key. Try again." }
    }

    private func revoke(_ id: String) async {
        do { try await account.revokeKey(id); await load() } catch { self.error = "Couldn't revoke it. Try again." }
    }
}

// MARK: - Billing

/// Bumped when a code goes through, so Credit added reloads.
@MainActor @Observable
final class BillingStamp {
    static let shared = BillingStamp()
    var value = 0
}

/// A card: only Billing uses them, for the plan and credit blocks.
private struct BillCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.raised, in: .rect(cornerRadius: Tokens.Radius.card))
            .padding(.top, 12)
    }
}

/// The plan and its allowance windows, or the plans to pick from. Signed out, the way in.
struct PlanBlock: View {
    @State private var account = CloudAccount.shared

    var body: some View {
        if !account.signedIn {
            SignInRows()
        } else if let me = account.me {
            if let sub = me.subscription {
                BillCard {
                    HStack { Text(sub.name).font(.frog(size: 13, weight: .semibold)); Spacer(); SettingsValue("Included allowance") }
                    ForEach(sub.windows, id: \.self) { WindowBar(window: $0) }
                    Link("Change or cancel your plan", destination: URL(string: "https://frog.toys/?settings=billing")!)
                        .font(.frog(size: 12))
                }
            } else {
                BillCard {
                    HStack { Text("Usage pricing").font(.frog(size: 13, weight: .semibold)); Spacer(); SettingsValue("No subscription") }
                    Text("Subscribe for an included allowance every 5 hours and every week. Past it, you keep going on credit at usage prices.")
                        .font(.frog(size: 12)).foregroundStyle(Tokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ForEach(CloudAccount.plans, id: \.id) { p in
                            Button { Task { await account.subscribe(p.id) } } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(p.name), $\(p.price)/mo").font(.frog(size: 13, weight: .semibold)).foregroundStyle(Tokens.text)
                                    Text(p.blurb).font(.frog(size: 12)).foregroundStyle(Tokens.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 11).padding(.vertical, 9)
                                .background(Tokens.well, in: .rect(cornerRadius: 9))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help("Opens Stripe in your browser to subscribe to \(p.name)")
                        }
                    }
                }
            }
        }
    }
}

/// Usage credit: the balance, the web's five amounts and Add, and "Have a code?".
struct CreditBlock: View {
    @State private var account = CloudAccount.shared
    @State private var amount = "10"
    @State private var code = ""
    @State private var redeeming = false
    @State private var said: (ok: Bool, text: String)?
    @State private var stamp = BillingStamp.shared

    var body: some View {
        if account.signedIn, let me = account.me {
            BillCard {
                HStack {
                    Text("Usage credit").font(.frog(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(CloudFormat.dollars(me.credit_cents)) credit").font(.frog(size: 13, weight: .semibold)).monospacedDigit()
                }
                Text(me.subscription == nil ? "Each turn pays from credit at the model's prices below." : "Used only past your plan's allowance, at the prices below.")
                    .font(.frog(size: 12)).foregroundStyle(Tokens.textSecondary)
                HStack {
                    FrogSegmented(label: "Amount", options: CloudAccount.topUps.map { .init(id: String($0), label: "$\($0)") }, selection: $amount)
                    Spacer()
                    Button("Add $\(amount)") { Task { await account.topUp(Int(amount) ?? 10) } }
                        .buttonStyle(.plain)
                        .font(.frog(size: 12.5, weight: .semibold))
                        .foregroundStyle(Tokens.onAccent)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Tokens.accent, in: Capsule())
                        .help("Opens Stripe Checkout in your browser")
                }
                Text("Paid through Stripe. Credit doesn't expire.").font(.frog(size: 12)).foregroundStyle(Tokens.textTertiary)
                Text("Have a code?").font(.frog(size: 13, weight: .semibold)).padding(.top, 8)
                HStack(spacing: 8) {
                    FrogField(label: "Code", text: $code, width: 220) {}
                    Button(redeeming ? "Redeeming…" : "Redeem") { Task { await redeem() } }
                        .buttonStyle(SettingsButtonStyle())
                        .disabled(redeeming || code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let said {
                    Text(said.text).font(.frog(size: 12)).foregroundStyle(said.ok ? Tokens.accent : Tokens.warn)
                }
            }
        }
    }

    private func redeem() async {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        redeeming = true
        defer { redeeming = false }
        do {
            let r = try await account.redeem(c)
            code = ""
            said = (true, "Added \(CloudFormat.dollars(r.added_cents)) of Frog Cloud credit")
            stamp.value += 1
        } catch let e as CloudAccount.CouponError {
            said = (false, e.message)
        } catch {
            said = (false, "Couldn't redeem it (\(error.localizedDescription)). Try again.")
        }
    }
}

/// Credit added, newest first: top-ups, codes, and anything else the edge lists.
struct CreditHistoryRows: View {
    @State private var stamp = BillingStamp.shared
    @State private var account = CloudAccount.shared
    @State private var rows: [CloudAccount.CreditRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                SettingsGroupLabel(text: "Credit added")
                SettingsRows(divided: false) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        SettingsRow([SettingsDates.day(r.at), r.label].filter { !$0.isEmpty }.joined(separator: ", "),
                                    description: r.status == nil || r.status == "succeeded" ? nil : r.status) {
                            SettingsValue(String(format: "$%.2f", r.dollars))
                        }
                    }
                }
            }
        }
        .task(id: stamp.value) {
            guard SettingsBindings.loads else { return }
            guard account.signedIn else { return }
            rows = (try? await account.history()) ?? []
        }
    }
}

/// Frog Cloud's models and what each costs, per million tokens.
struct PricesRows: View {
    let row: SettingsCatalog.Row
    @State private var store = ProviderStore.shared

    private var models: [CatalogModel] { store.catalog.filter { ProviderID.canonical($0.provider) == ProviderID.cloud } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !models.isEmpty {
                SettingsGroupLabel(text: row.label)
                SettingsRows(divided: false) {
                    ForEach(models) { m in
                        SettingsRow(m.name, description: "Cached \(per(m.costCacheRead)), output \(per(m.costOut))") {
                            SettingsValue("\(per(m.costIn)) in")
                        }
                    }
                }
                Text(row.description ?? "").font(.frog(size: 12)).foregroundStyle(Tokens.textTertiary).padding(.top, 4)
            }
        }
        .task { guard SettingsBindings.loads else { return }; await store.loadCatalog() }
    }

    private func per(_ d: Double?) -> String { d.map { String(format: "$%.2f", $0) } ?? "—" }
}
