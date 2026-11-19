import Charts
import SwiftUI

/// Models and Usage (design/settings.json): the default model, your machines (each opens as a
/// page), Frog Cloud, other clouds and servers; spend, the monthly cap and energy.

extension EnvironmentValues {
    /// Opens a machine's page inside Settings › Models.
    @Entry var openMachine: ((String) -> Void)?
    /// The machine whose page is drawing its rows.
    @Entry var settingsMachine: String?
}

// MARK: - Models

/// New conversations use: the last model you used, or one every time.
struct DefaultModelRow: View {
    let row: SettingsCatalog.Row
    @AppStorage("defaultModel") private var defaultModel = ""
    @State private var models: [ModelEntry] = []

    private var ready: [ModelIdentity] { models.map(ModelIdentity.init).filter(\.state.isReady) }
    private var lastLabel: String {
        Workspace.lastUsed.map { "The last model I used (\(ModelIdentity.of($0, in: models).name))" } ?? "The last model I used"
    }

    var body: some View {
        SettingsRow(row) {
            FrogPillMenu(title: defaultModel.isEmpty ? "The last model I used" : ModelIdentity.of(defaultModel, in: models).name,
                         help: "The model a new conversation starts on; the composer can still change it") {
                Button(lastLabel) { defaultModel = "" }
                Divider()
                ForEach(ready, id: \.spec) { m in Button(m.name) { defaultModel = m.spec } }
            }
        }
        .task { guard SettingsBindings.loads else { return }; models = await Models.load() }
    }
}

/// Your machines, This Mac included, each a row that opens its page.
struct MachinesRows: View {
    @State private var devices = SettingsBindings.devices
    @Environment(\.openMachine) private var openMachine

    var body: some View {
        Group {
            ForEach(devices.machines) { d in
                Button { openMachine?(d.id) } label: {
                    SettingsRow(d.name + (d.role == .thisMac ? ", This Mac" : ""), description: d.hardwareLine) {
                        HStack(spacing: 8) {
                            Text(d.runningLine).font(.frog(size: 12)).foregroundStyle(d.model != nil ? Tokens.text : Tokens.textTertiary).lineLimit(1)
                            Circle().fill(Tokens.placeLocal.opacity(d.online ? 1 : 0.25)).frame(width: 7, height: 7)
                            Image(systemName: "chevron.right").font(.frog(size: 10, weight: .semibold)).foregroundStyle(Tokens.textTertiary)
                        }
                        .monospacedDigit()
                    }
                    .contentShape(.rect)
                    .hoverPlate(h: 8, v: 0, radius: 8)
                }
                .buttonStyle(.plain)
                .help("Open \(d.name)'s page: its memory, models and name")
            }
            if let problem = devices.browseProblem {
                SettingsRow("Can't look for machines", description: problem) { EmptyView() }
            }
        }
        .onAppear { devices.start() }
        .onDisappear { devices.stop() }
    }
}

struct PairMachineRow: View {
    let row: SettingsCatalog.Row
    @State private var pairing = false
    var body: some View {
        SettingsRow(row) {
            Button("Pair") { pairing = true }.buttonStyle(SettingsButtonStyle())
                .help("Find machines on your network to pair with this Mac")
        }
            .sheet(isPresented: $pairing) { PairMachineSheet() }
    }
}

/// Frog Cloud: who's signed in and the credit; Add credit is in Billing.
struct FrogCloudRows: View {
    @State private var account = CloudAccount.shared
    @Environment(\.showSettings) private var showSettings

    var body: some View {
        Group {
            if !account.signedIn {
                SignInRows()
            } else {
                SettingsRow("Account") {
                    SettingsValue(account.me.map { [$0.name, $0.email].compactMap { $0 }.joined(separator: ", ") } ?? "Signed in")
                }
            }
            if let me = account.me {
                SettingsRow("Credit", description: "Prices per model are in Billing.") {
                    HStack(spacing: 10) {
                        SettingsValue(CloudFormat.dollars(me.credit_cents))
                        Button("Add credit") { showSettings?("billing") }.buttonStyle(SettingsButtonStyle())
                            .help("Opens Billing")
                    }
                }
            }
        }
        .task { guard SettingsBindings.loads else { return }; await account.ensureKey(); await account.refresh() }
    }
}

/// Other clouds you've connected (keys in your Keychain), each with its models and key. Adding
/// one is hidden while Frog Cloud serves (ModelSections.providersHidden, 2026-11-12).
struct OtherCloudsRows: View {
    let row: SettingsCatalog.Row
    @State private var store = ProviderStore.shared
    @State private var keyFor: ProviderInfo?
    @State private var choosing: ProviderInfo?

    private var connected: [ProviderInfo] { ProviderInfo.sorted(store.providers.filter { !$0.local && !$0.isFrogCloud && $0.connected }) }
    private var unconnected: [ProviderInfo] { ProviderInfo.sorted(store.providers.filter { !$0.local && !$0.isFrogCloud && !$0.connected }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !connected.isEmpty || !ModelSections.providersHidden { SettingsGroupLabel(text: row.label) }
            SettingsRows {
            ForEach(connected) { p in
                SettingsRow(p.displayName, description: row.description) {
                    HStack(spacing: 8) {
                        Button("Models") { choosing = p }.help("Choose which of \(p.displayName)'s models the picker shows")
                        Button("Key") { keyFor = p }.help("Change the key kept in your Keychain")
                        Button("Remove") { Task { await store.setKey("", for: p.id) } }.help("Forget \(p.displayName)'s key")
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
            }
            if !ModelSections.providersHidden, !unconnected.isEmpty {
                SettingsRow(row) {
                    FrogPillMenu(title: "Connect") { ForEach(unconnected) { p in Button(p.displayName) { keyFor = p } } }
                }
            }
            }
        }
        .task { guard SettingsBindings.loads else { return }; await store.load() }
        .sheet(item: $keyFor) { KeySheet(provider: $0) }
        .sheet(item: $choosing) { CatalogSheet(provider: $0) }
    }
}

/// Servers of your own, and apps on this Mac that serve models while they run.
struct ServersRows: View {
    let row: SettingsCatalog.Row
    @State private var store = ProviderStore.shared
    @State private var adding = false

    private var servers: [ProviderInfo] { store.providers.filter { $0.local && ($0.custom || store.reachable[$0.id] == true) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !servers.isEmpty || !ModelSections.providersHidden { SettingsGroupLabel(text: row.label) }
            SettingsRows {
            ForEach(servers) { p in
                let up = store.reachable[p.id]
                SettingsRow(p.name, description: p.baseUrl) {
                    HStack(spacing: 8) {
                        SettingsValue(up == true ? "Running" : up == false ? "Not responding" : "Checking…")
                        if p.custom {
                            Button("Remove") { Task { await store.remove(p.id) } }.buttonStyle(SettingsButtonStyle(destructive: true))
                        }
                    }
                }
            }
            if !ModelSections.providersHidden {
                SettingsRow(row) { Button("Add") { adding = true }.buttonStyle(SettingsButtonStyle()) }
            }
            }
        }
        .task { guard SettingsBindings.loads else { return }; await store.load(); await store.probe() }
        .sheet(isPresented: $adding) { ServerSheet { Task { await store.probe() } } }
    }
}

/// A machine's page: status and memory, its models, then its name and sharing.
struct MachineSettingsPage: View {
    let deviceID: String
    let back: () -> Void
    var catalog = SettingsCatalog.bundled
    @State private var devices = SettingsBindings.devices

    var body: some View {
        if let d = devices.list.first(where: { $0.id == deviceID }) {
            SettingsPage(title: d.name) {
                // Facts, not controls: no lines between them. Back is the title bar's "Models".
                SettingsRows(divided: false) {
                    SettingsRow("Status") { SettingsValue(d.statusLine) }
                    SettingsRow("Hardware") { SettingsValue(d.hardwareLine) }
                    if d.totalBytes > 0 { MachineMemoryBar(device: d).padding(.vertical, SettingsLook.rowPad) }
                }
                MachineModelsSections(device: d, devices: devices)
                // Its name and sharing, under one label.
                SettingsGroupLabel(text: d.role == .thisMac ? "This Mac" : "This machine")
                SettingsRows { ForEach(catalog.macRows(in: "models", page: "machine")) { SettingsBindings.view(for: $0) } }
            }
            .environment(\.settingsMachine, deviceID)
            // Balanced: Devices counts its watchers.
            .onAppear { devices.start() }
            .onDisappear { devices.stop() }
        } else {
            SettingsPage(title: "Machine") {
                SettingsRow("This machine isn't paired anymore") { Button("Back to Models", action: back).buttonStyle(SettingsButtonStyle()) }
            }
        }
    }
}

/// Rename or unpair the machine whose page this is.
struct MachineNameRow: View {
    let row: SettingsCatalog.Row
    @Environment(\.settingsMachine) private var id
    @State private var devices = SettingsBindings.devices
    @State private var name = ""
    @State private var confirm = false

    var body: some View {
        if let d = devices.list.first(where: { $0.id == id }) {
            SettingsRow("Name", description: d.role == .thisMac ? "What your other machines call this Mac." : "What your machines call \(d.name).") {
                HStack(spacing: 8) {
                    FrogField(label: "Name", text: $name, width: 160) {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty, n != d.name { devices.rename(d.id, to: n) }
                    }
                    if d.role != .thisMac {
                        Button("Unpair") { confirm = true }.buttonStyle(SettingsButtonStyle(destructive: true))
                            .help("This Mac forgets \(d.name)'s key; asks first")
                    }
                }
            }
            .onAppear { name = d.name }
            .confirmationDialog("Unpair \(d.name)?", isPresented: $confirm) {
                Button("Unpair", role: .destructive) { Task { await devices.unpair(d.id) } }
            } message: {
                Text("This Mac forgets its key and \(d.name) drops this Mac. Pair again any time with a new code.")
            }
        }
    }
}

/// Share with my other machines (was "Lend this Mac"): This Mac's switch; another machine always
/// shares itself with what it's paired with.
struct ShareRow: View {
    let row: SettingsCatalog.Row
    @Environment(\.settingsMachine) private var id
    @State private var devices = SettingsBindings.devices
    @ObservedObject private var lender = MacLender.shared

    var body: some View {
        if let d = devices.list.first(where: { $0.id == id }) {
            if d.role == .thisMac {
                SettingsRow(row, description: [row.description, status].compactMap { $0 }.joined(separator: " ")) {
                    FrogToggle(label: row.label, isOn: $lender.enabled)
                }
            } else {
                SettingsRow(row.label, description: "\(d.name) shares itself with every machine you pair it with.") {
                    SettingsValue("Always", help: "Set on \(d.name) itself")
                }
            }
        }
    }

    private var status: String? {
        switch lender.state {
        case .off: nil
        case .starting: "Starting…"
        case .running: "Lending on port \(MacLender.port)."
        case .paused(let why): why
        case .failed(let why): why
        }
    }
}

/// Keep lending on battery, while sharing is on (This Mac only).
struct LendBatteryRow: View {
    let row: SettingsCatalog.Row
    @Environment(\.settingsMachine) private var id
    @State private var devices = SettingsBindings.devices
    @ObservedObject private var lender = MacLender.shared

    var body: some View {
        if lender.enabled, devices.list.first(where: { $0.id == id })?.role == .thisMac {
            SettingsRow(row, description: "Off: lending pauses when you unplug and resumes on power.") {
                FrogToggle(label: row.label, isOn: $lender.onBattery)
            }
        }
    }
}

/// Pair a Mac with this one by a code typed on it, while sharing runs (This Mac only).
struct PairMacRow: View {
    let row: SettingsCatalog.Row
    @Environment(\.settingsMachine) private var id
    @State private var devices = SettingsBindings.devices
    @ObservedObject private var lender = MacLender.shared
    @State private var pairing = false

    var body: some View {
        if lender.enabled, devices.list.first(where: { $0.id == id })?.role == .thisMac {
            SettingsRow(row) {
                Button("Pair a Mac") { pairing = true }.buttonStyle(SettingsButtonStyle()).disabled(lender.state != .running)
                    .help(lender.state == .running ? "Shows a code to type on the other Mac" : "Waits until sharing has started")
            }
            .sheet(isPresented: $pairing) { PairCodeSheet() }
        }
    }
}

// MARK: - Usage

/// Spent this week and this month, at each model's prices.
struct SpentRow: View {
    let row: SettingsCatalog.Row
    @State private var stats = SettingsBindings.stats
    var body: some View {
        SettingsRow(row) {
            SettingsValue("\(ModelStats.spent(stats.spentThisWeek)) this week, \(ModelStats.spent(stats.spentThisMonth)) this month",
                          help: "Estimated on this Mac from each model's prices; Billing has what Frog Cloud charged")
        }
    }
}

/// The monthly cap on cloud spending; at it, cloud models pause until next month.
struct CapRow: View {
    let row: SettingsCatalog.Row
    @AppStorage(ModelStats.capKey) private var cap: Double = 0
    var body: some View {
        let options = row.options ?? []
        SettingsRow(row) {
            FrogPillMenu(title: options.first { Double($0.id) == cap }?.label ?? (cap > 0 ? "$\(Int(cap))" : "None"),
                         help: "Cloud models pause for the rest of the month at this much") {
                ForEach(options, id: \.id) { o in Button(o.label) { cap = Double(o.id) ?? 0 } }
            }
        }
    }
}

/// Energy by period and model: this Mac measured from its power sensor, a cloud model's data
/// center estimated. The chart and the per-model lines from Usage's old Energy tab.
struct EnergyRows: View {
    var stats = ModelStats.shared
    @State private var period = "day"
    @State private var model: String?

    private var days: Bool { period == "days" }
    private var buckets: [ModelStats.EnergyBucket] { stats.energyBuckets(days: days, spec: model) }

    var body: some View {
        let total = buckets.reduce((mac: 0.0, dc: 0.0)) { ($0.mac + $1.mac, $0.dc + $1.dataCenter) }
        VStack(alignment: .leading, spacing: 0) {
            SettingsRows {
                SettingsRow("Period") {
                    FrogSegmented(label: "Period", options: [.init(id: "day", label: "Last 24 hours"), .init(id: "days", label: "Last 10 days")], selection: $period)
                }
                SettingsRow("Model") {
                    FrogPillMenu(title: model.map(name) ?? "All models", help: "Show one model's energy, or all of them") {
                        Button("All models") { model = nil }
                        ForEach(stats.energyModels, id: \.self) { spec in Button(name(spec)) { model = spec } }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                    Text(ModelStats.energy(total.mac + total.dc, estimated: total.dc > 0))
                        .font(.frog(size: 20, weight: .semibold)).monospacedDigit()
                    Text(EnergySettings.summary(days: days, mac: total.mac, dataCenter: total.dc))
                        .font(.frog(size: 12)).foregroundStyle(Tokens.textTertiary)
                    EnergyChart(buckets: buckets, days: days).frame(height: 170)
                    HStack(spacing: 16) {
                        EnergyLegend(hatched: false, text: "This Mac, measured")
                        EnergyLegend(hatched: true, text: "Data center, estimated")
                    }
                    .font(.frog(size: 12)).foregroundStyle(Tokens.textSecondary)
            }
            .padding(.vertical, SettingsLook.rowPad)
            SettingsGroupLabel(text: "By model")
            SettingsRows(divided: false) {
                if stats.energyModels.isEmpty {
                    SettingsRow("Nothing yet", description: "Turns you run with energy measured show up here.") { EmptyView() }
                }
                ForEach(stats.energyModels, id: \.self) { spec in
                    ModelEnergyRow(spec: spec, name: name(spec), days: days, stats: stats).padding(.vertical, 6)
                }
            }
            Link("How it's measured, and every bench run", destination: URL(string: "https://frog.toys/energy")!)
                .font(.frog(size: 12)).padding(.top, 8)
        }
        // The session logs are this Mac's; a snapshot's own stats stay as they were made.
        .task { guard SettingsBindings.loads else { return }; if stats === ModelStats.shared { await stats.backfillEnergy() } }
    }

    private func name(_ spec: String) -> String { ModelIdentity.of(spec, in: []).name }
}
