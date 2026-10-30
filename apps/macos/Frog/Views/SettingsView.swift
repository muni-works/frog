import CoreImage
import SwiftUI

/// ⌘, : General, Models, Energy, Permissions, MCP, Appearance, Shortcuts.
struct SettingsView: View {
    /// The open tab; "Manage models…" in the model picker sets it to "models".
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Models", systemImage: "cpu", value: "models") { ModelSettings() }
            Tab("Billing", systemImage: "creditcard", value: "billing") { BillingSettings() }
            Tab("Energy", systemImage: "leaf", value: "energy") { EnergySettings() }
            Tab("Permissions", systemImage: "hand.raised", value: "permissions") { PermissionSettings() }
            Tab("MCP", systemImage: "puzzlepiece.extension", value: "mcp") { MCPSettings() }
            Tab("Appearance", systemImage: "paintbrush", value: "appearance") { AppearanceSettings() }
            Tab("Shortcuts", systemImage: "keyboard", value: "shortcuts") { ShortcutSettings() }
        }
        .frame(width: 620)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage("editor") private var editor = ""
    @AppStorage("notifyWhenDone") private var notifyWhenDone = true
    @AppStorage("remoteEnabled") private var remote = false
    @AppStorage(RemotePush.secretKey) private var pushSecret = ""
    @State private var code = RemoteBridge.token
    @State private var pond = Pond.shared
    @AppStorage(CalendarSense.key) private var calendarSense = false
    @AppStorage(MorningNotice.key) private var morningNotice = true
    @AppStorage(UpdateDrain.key) private var gracefulUpdates = false
    @AppStorage(UpdateDrain.budgetKey) private var drainBudget = 20.0

    private func setCalendar(_ on: Bool) async {
        guard on else {
            calendarSense = false
            CalendarSense.forget()
            return
        }
        calendarSense = await CalendarSense.requestAccess()
        if calendarSense { await pond.refresh() }
    }

    var body: some View {
        Form {
            Picker("Open files in", selection: $editor) {
                Text(Editor.installed.first.map { "Automatic (\($0.name))" } ?? "Default app").tag("")
                ForEach(Editor.installed) { e in
                    Label {
                        Text(e.name)
                    } icon: {
                        if let icon = e.icon { Image(nsImage: icon) }
                    }
                    .tag(e.id)
                }
            }
            Toggle("Notify me when a turn finishes while I'm in another app", isOn: $notifyWhenDone)
            Section {
                Toggle("Pause agents for app updates and resume them", isOn: $gracefulUpdates)
                if gracefulUpdates {
                    Stepper(value: $drainBudget, in: 5...120, step: 5) {
                        Text("Wait up to \(Int(drainBudget))s for agents to stop")
                    }
                }
            } footer: {
                Text("Off, an update stops working agents where they are and they resume as after a crash. On, an update asks each agent to stop at its next safe point first, waits up to the budget, then installs — agents resume their turns on the model they were running, right where they stopped. Long-running jobs they had are stopped and listed; the agent decides what to re-run.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep the brief fresh while Frog is closed", isOn: Binding(
                    get: { pond.background ?? false },
                    set: { on in Task { await pond.setBackground(on) } }
                ))
                .disabled(pond.background == nil)
                Toggle("Tell me about the brief in the morning", isOn: Binding(
                    get: { morningNotice },
                    set: { on in
                        morningNotice = on
                        if on { Task { if await Notifier.shared.notAskedYet() { await Notifier.shared.ask() } } }
                    }
                ))
                Toggle("Include my calendar", isOn: Binding(
                    get: { calendarSense },
                    set: { on in Task { await setCalendar(on) } }
                ))
            } footer: {
                Text("Looks at GitHub every 15 minutes from login, so the brief is ready when you open Frog. In the morning, one notification when there's something new, never more than once a day. Your calendar is read on this Mac and never leaves it. The brief only reads; nothing is sent or changed for you.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Let frog on iPhone connect", isOn: $remote)
                    .onChange(of: remote) { _, on in
                        on ? RemoteBridge.shared.start() : RemoteBridge.shared.stop()
                    }
                if remote {
                    PairingCard(code: code) {
                        RemoteBridge.newToken()
                        RemoteBridge.shared.stop()
                        RemoteBridge.shared.start()
                        code = RemoteBridge.token
                    }
                    SecureField("Push relay secret", text: $pushSecret)
                }
            } footer: {
                Text("Scan the code with your iPhone's camera, or pick this Mac in frog and type the code. The connection is encrypted with it. A new code signs out every phone. The relay secret lets this Mac wake your phone through frog.toys when frog needs you; without it, you only hear while the app is open.")
            }
        }
        .formStyle(.grouped)
        .task { await pond.loadBackground() }
    }
}

enum Models {
    /// Everything `frog --models` knows, from the home folder.
    static func load() async -> [ModelEntry] {
        (try? await Frog.json([ModelEntry].self, args: ["--models", "--json"],
                               cwd: FileManager.default.homeDirectoryForCurrentUser)) ?? []
    }
}

// MARK: - Models

/// Models, in the order people think about them: which one new conversations use, what's
/// ready (the picker's own list, managed instead of chosen), what else to get, the cloud
/// accounts you've connected (with what they cost), and your servers and apps. Engine details
/// are in Advanced, the one place their words appear.
struct ModelSettings: View {
    @State private var store = ProviderStore.shared
    @State private var stats = ModelStats.shared
    @State private var downloads = ModelDownloads.shared
    @State private var models: [ModelEntry] = []
    @State private var loading = true
    @State private var keyFor: ProviderInfo?
    @State private var addingServer = false
    /// The provider whose catalog is open (nil: closed).
    @State private var choosingFrom: ProviderInfo?
    @AppStorage(ModelStats.capKey) private var cap: Double = 0
    @AppStorage("defaultModel") private var defaultModel = ""
    @AppStorage("newMessageModelPolicy") private var modelPolicy = "last"

    private var usable: [ModelIdentity] { models.map(ModelIdentity.init) }

    private var sections: [(title: String, models: [ModelIdentity])] {
        ModelSections.make(usable: usable, suggested: SuggestedModel.all.map(ModelIdentity.init))
    }

    /// Other clouds, in the shared order. frog cloud has its own fixed card, so it's never
    /// added or removed here.
    private var cloudProviders: [ProviderInfo] { ProviderInfo.sorted(store.providers.filter { !$0.local && !$0.isFrogCloud && $0.connected }) }
    private var unconnected: [ProviderInfo] { ProviderInfo.sorted(store.providers.filter { !$0.local && !$0.isFrogCloud && !$0.connected }) }
    private var frogCloud: ProviderInfo? { store.providers.first(where: \.isFrogCloud) }

    /// Your servers always; Ollama and LM Studio while they're running.
    private var servers: [ProviderInfo] {
        store.providers.filter { $0.local && ($0.custom || store.reachable[$0.id] == true) }
    }

    private func count(_ p: ProviderInfo) -> Int {
        models.filter { $0.spec.hasPrefix(p.id + "/") }.count
    }

    var body: some View {
        Form {
            defaults
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.models, id: \.spec) { m in
                        ModelListRow(model: m, current: m.spec == Workspace.startingModel) { manage(m) }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(section.title)
                        if section.title == ProviderID.localName {
                            Text("powered by tang").font(.frog(size: 10)).foregroundStyle(.tertiary) // advanced: the one place the engine is named
                        }
                    }
                }
            }
            serversAndApps
            cloud
            if let error = store.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            advanced
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
        .environment(\.addProviderKey) { id in keyFor = store.providers.first { ProviderID.same($0.id, id) } }
        .sheet(item: $keyFor) { p in KeySheet(provider: p) }
        .sheet(isPresented: $addingServer) {
            ServerSheet { Task { await reload() } }
        }
        .sheet(item: $choosingFrom) { p in CatalogSheet(provider: p) }
        .task {
            await store.load()
            async let catalog: () = store.loadCatalog()
            async let probe: () = store.probe()
            models = await Models.load()
            loading = false
            _ = await (catalog, probe)
        }
        .onChange(of: store.generation) { Task { await reload() } }
        .onChange(of: downloads.states) { Task { models = await Models.load() } }
    }

    private func reload() async {
        models = await Models.load()
        await store.probe()
    }

    // MARK: Default

    private var defaults: some View {
        Section {
            Picker("New messages use:", selection: $modelPolicy) {
                Text("Last model in this chat").tag("last")
                Text("A fixed default model").tag("fixed")
            }
            Picker("New conversations use", selection: $defaultModel) {
                Text(Workspace.lastUsed.map { "Last Used (\(ModelIdentity.of($0, in: models).name))" } ?? "Last Used").tag("")
                ForEach(usable.filter(\.state.isReady), id: \.spec) { m in
                    ModelLabel(model: m, size: .menu).tag(m.spec)
                }
            }
            .disabled(modelPolicy != "fixed")
        } header: {
            HStack {
                Text("Default")
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
        } footer: {
            Text(modelPolicy == "fixed" ? "New chats and messages use the selected default model." : "Messages continue on the last model used in this chat. New chats use the last model you picked anywhere.")
                .foregroundStyle(.secondary)
        }
    }

    /// What Settings offers for a model: what makes it usable, or taking it away.
    @ViewBuilder
    private func manage(_ m: ModelIdentity) -> some View {
        if m.state.isReady, let repo = m.repo, ModelDownloads.isInstalled(repo) {
            Menu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ModelDownloads.repoDir(repo)]) }
                Button("Remove from This Mac", role: .destructive) {
                    downloads.remove(repo)
                    Task { models = await Models.load() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else if m.state.isReady, m.place.isCloud {
            Button("Hide") { hide(m) }
                .controlSize(.small)
                .help("Stop showing this model in the picker")
        } else {
            ModelStateAction(model: m)
        }
    }

    private func hide(_ m: ModelIdentity) {
        Task { await store.setEnabled(m.spec, false) }
    }

    // MARK: Cloud

    @ViewBuilder
    private var cloud: some View {
        Section {
            FrogCloudCard(provider: frogCloud) { keyFor = $0 }
            if cloudProviders.isEmpty {
                Text("Other clouds: the strongest models, from Anthropic, OpenAI and others. Code you send goes to the provider, and each project asks first.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(cloudProviders) { p in
                HStack(spacing: 10) {
                    Image(systemName: "cloud").foregroundStyle(.cyan.opacity(0.85)).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                        Text(count(p) == 0 ? "No models in the picker yet" : "\(count(p)) model\(count(p) == 1 ? "" : "s") in the picker")
                            .font(.frog(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Models…") { choosingFrom = p }
                        .controlSize(.small)
                    Menu {
                        Button("Change Key…") { keyFor = p }
                        Button("Remove Key", role: .destructive) { Task { await store.setKey("", for: p.id) } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if !unconnected.isEmpty {
                Menu(cloudProviders.isEmpty ? "Add a Provider…" : "Add Another Provider…") {
                    ForEach(unconnected) { p in
                        Button(p.name) { keyFor = p }
                    }
                }
                .fixedSize()
            }
            if !cloudProviders.isEmpty || frogCloud?.connected == true || stats.spentThisMonth > 0 {
                LabeledContent("Spent this week", value: ModelStats.spent(stats.spentThisWeek))
                LabeledContent("Spent this month", value: ModelStats.spent(stats.spentThisMonth))
                Picker("Monthly cap", selection: $cap) {
                    Text("None").tag(0.0)
                    ForEach([5.0, 10, 25, 50, 100, 250], id: \.self) { Text("$\(Int($0))").tag($0) }
                }
            }
        } header: {
            Text("Cloud")
        } footer: {
            if !cloudProviders.isEmpty || frogCloud?.connected == true {
                Text(cap > 0
                     ? "Keys are kept in your Keychain. At the cap, cloud models pause until next month."
                     : "Keys are kept in your Keychain. Spending is estimated from each provider's prices.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Servers and apps

    private var serversAndApps: some View {
        Section {
            ForEach(servers) { p in
                let up = store.reachable[p.id]
                HStack(spacing: 10) {
                    Image(systemName: p.custom ? "server.rack" : "app.connected.to.app.below.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                        HStack(spacing: 5) {
                            Circle().fill(up == true ? Color.green : up == false ? Color.red : Color.secondary.opacity(0.4))
                                .frame(width: 6, height: 6)
                            Text(up == true
                                 ? "Running · \(count(p)) model\(count(p) == 1 ? "" : "s")"
                                 : up == false ? "Not responding" : "Checking…")
                        }
                        .font(.frog(size: 10))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if p.custom {
                        Menu {
                            Button(p.key == nil ? "Set Key…" : "Change Key…") { keyFor = p }
                            Button("Remove Server", role: .destructive) { Task { await store.remove(p.id); await reload() } }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                .help(p.baseUrl)
            }
            Button("Add Server…") { addingServer = true }
        } header: {
            Text("Servers and Apps")
        } footer: {
            Text("A server of your own, like a GPU box, offers every model it serves. Apps on this Mac that serve models show up here while they're running.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        Section {
            DisclosureGroup("Engine details") {
                Text("Models on This Mac run on tang, frog's engine.") // advanced
                    .font(.frog(size: 10))
                    .foregroundStyle(.secondary)
                ForEach(models) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.spec).font(.callout.monospaced()) // advanced
                        Text("\(m.source) · \(m.toolMode) tool calls · \(m.tier) tier") // advanced
                            .font(.frog(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }
}

/// Which cloud models show in the picker: search every connected provider's catalog and turn
/// models on or off.
private struct CatalogSheet: View {
    /// Just this provider's models (nil: every connected provider's).
    var provider: ProviderInfo? = nil
    @State private var store = ProviderStore.shared
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    /// Matches for the search (every word in the name or spec); without one, what's on.
    private var catalog: [CatalogModel] {
        guard let provider else { return store.catalog }
        return store.catalog.filter { $0.provider == provider.id }
    }

    private var matches: [CatalogModel] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return catalog.filter { $0.enabled == true } }
        return catalog.filter { m in
            let hay = (m.name + " " + m.spec).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search \(catalog.count) \(provider?.name ?? "") models", text: $query)
                    .textFieldStyle(.roundedBorder)
                if store.loadingCatalog {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await store.loadCatalog(refresh: true) }
                    }
                    .labelStyle(.iconOnly)
                    .help("Fetch the latest model lists")
                }
            }
            .padding(12)
            Form {
                let list = Array(matches.prefix(150))
                if list.isEmpty {
                    Text(query.isEmpty ? "Search to find models from the providers you've connected, and turn on the ones you want in the picker." : "No models match.")
                        .foregroundStyle(.secondary)
                }
                ForEach(list) { m in
                    CatalogRow(model: m, provider: store.provider(m.provider)) { on in
                        Task { await store.setEnabled(m.spec, on) }
                    }
                }
                if matches.count > list.count {
                    Text("\(matches.count - list.count) more; narrow the search.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .task { await store.loadCatalog() }
    }
}

private struct CatalogRow: View {
    let model: CatalogModel
    let provider: ProviderInfo?
    let toggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { model.enabled ?? false }, set: toggle)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(details).font(.frog(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .disabled(!(provider?.connected ?? false) && model.enabled != true)
        .help(provider?.connected == false ? "Add a \(provider?.name ?? "provider") key to use this model" : model.spec) // advanced
    }

    private var details: String {
        var parts = [provider?.name ?? model.provider]
        if let c = model.contextLabel { parts.append("\(c) context") }
        if model.vision { parts.append("sees images") }
        if model.reasoning { parts.append("reasons") }
        if !model.tools { parts.append("no tools") }
        if let p = model.price { parts.append(p) }
        return parts.joined(separator: " · ")
    }
}

/// frog cloud's fixed card in Settings → Models: always there, never removable. Shows the plan
/// and where the key comes from; signed out, offers adding or getting a key.
struct FrogCloudCard: View {
    /// frog cloud as the engine lists it (nil with an engine that doesn't list it yet).
    let provider: ProviderInfo?
    let addKey: (ProviderInfo) -> Void
    @State private var store = ProviderStore.shared

    static let getKeyURL = URL(string: "https://api.frog.toys/beta")!
    @State private var signingIn = false

    /// GitHub in the browser, back to this Mac with its own key, saved where frog reads it.
    private func signIn() {
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                try await CloudAccount.signInAndSave()
            } catch {
                store.error = error.localizedDescription
            }
        }
    }

    /// Where the key comes from, or nil when there's none. FROG_API_KEY wins over a saved key.
    static func keyLine(_ source: String?) -> String? {
        switch source {
        case "env": "API key · FROG_API_KEY (from your environment; a saved key is ignored here)"
        case "keychain": "API key · Keychain"
        default: nil
        }
    }

    /// The plan badge. A placeholder until the account endpoint says (Pro, API).
    static let plan = "beta"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cloud.fill").foregroundStyle(.green.opacity(0.85)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ProviderID.cloudName)
                    Text(Self.plan)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.18), in: .capsule)
                        .foregroundStyle(.green)
                }
                Text(Self.keyLine(provider?.key) ?? "Fast hosted models from frog. Sign in or add a key to use them.")
                    .font(.frog(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if provider?.key == nil {
                Button(signingIn ? "Signing In…" : "Sign In with GitHub") { signIn() }
                    .controlSize(.small)
                    .disabled(signingIn)
                Link("Get a Key", destination: Self.getKeyURL)
                    .controlSize(.small)
                if let provider {
                    Button("Add a Key") { addKey(provider) }
                        .controlSize(.small)
                }
            } else if let provider {
                Menu {
                    Button("Sign In Again with GitHub") { signIn() }
                    Button("Change Key…") { addKey(provider) }
                    // Only a saved key can be removed here; an environment key is the shell's.
                    if provider.key == "keychain" {
                        Button("Remove Key", role: .destructive) { Task { await store.setKey("", for: provider.id) } }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

/// Paste a provider's API key; it goes to the Keychain through frog, never to disk.
struct KeySheet: View {
    let provider: ProviderInfo
    @State private var key = ""
    @State private var saving = false
    @State private var store = ProviderStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect \(provider.displayName)").font(.frog(size: 13, weight: .semibold))
            SecureField("API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let url = URL(string: provider.keyUrl), !provider.keyUrl.isEmpty {
                Link("Get a key from \(provider.displayName)", destination: url).font(.frog(size: 12))
            }
            Text("Stored in your Keychain. frog sends it only to \(provider.displayName).")
                .font(.frog(size: 10))
                .foregroundStyle(.secondary)
            if let e = store.error { Text(e).font(.frog(size: 10)).foregroundStyle(.red) }
            HStack {
                if provider.key == "keychain" {
                    Button("Remove Key", role: .destructive) {
                        Task { await store.setKey("", for: provider.id); dismiss() }
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        saving = true
        Task {
            await store.setKey(key, for: provider.id)
            saving = false
            if store.error == nil { dismiss() }
        }
    }
}

/// Add a server on your network (a GPU box running Ollama, vLLM, llama.cpp or LM Studio).
private struct ServerSheet: View {
    let added: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var ollama = true
    @State private var saving = false
    @State private var store = ProviderStore.shared
    @Environment(\.dismiss) private var dismiss

    /// "GPU Box" → "gpu-box".
    private var id: String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return slug.split(separator: "-").joined(separator: "-")
    }

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("GPU Box"))
            Picker("Runs", selection: $ollama) {
                Text("Ollama").tag(true) // advanced
                Text("OpenAI-compatible (vLLM, llama.cpp, LM Studio)").tag(false)
            }
            TextField("URL", text: $url, prompt: Text(ollama ? "http://gpu-box.local:11434" : "http://gpu-box.local:8000/v1"))
            if !id.isEmpty {
                LabeledContent("Models appear as", value: "\(id)/<model>")
                    .foregroundStyle(.secondary)
            }
            if let e = store.error { Text(e).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    saving = true
                    Task {
                        let ok = await store.addServer(id: id, name: name, url: url.trimmingCharacters(in: .whitespaces), ollama: ollama)
                        saving = false
                        if ok { added(); dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(id.isEmpty || url.isEmpty || saving)
            }
            .padding()
        }
        .frame(width: 460, height: 300)
    }
}


/// A recommended model with its download state: Download, a progress bar, or Installed.
struct SuggestedModelRow: View {
    let model: SuggestedModel
    var onInstalled: () -> Void = {}
    @State private var downloads = ModelDownloads.shared

    var body: some View {
        ModelListRow(model: ModelIdentity(model))
            .onChange(of: downloads.states[model.repo]) { _, s in if s == .done { onInstalled() } }
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    /// New threads start here; Auto by default (a local classifier plus a read-only
    /// fast path approves plain work; risky steps still ask).
    @AppStorage("defaultMode") private var defaultMode = Mode.auto.rawValue
    @AppStorage("computerUse") private var computerUse = false
    @AppStorage("sandboxShell") private var sandboxShell = true

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/frog/config.toml")
    }

    var body: some View {
        Form {
            Picker("New sessions start in", selection: $defaultMode) {
                ForEach(Mode.allCases) { m in
                    Label(m.label, systemImage: m.symbol).tag(m.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            Section {
                LabeledContent("Ask", value: sandboxShell ? "Edits, and commands leaving the sandbox, ask first" : "Every edit and command asks first")
                LabeledContent("Accept Edits", value: "File edits are allowed; commands still ask")
                LabeledContent("Auto", value: "A local model approves steps that plainly serve your request; risky ones ask")
                LabeledContent("Yolo", value: "Everything runs without asking")
            }
            .foregroundStyle(.secondary)
            Section("Sandbox") {
                Toggle("Run shell commands in a sandbox", isOn: $sandboxShell)
                Text("Sandboxed commands can write only inside the project, temp folders and toolchain caches, and can't read credentials like ~/.ssh or ~/.aws, so they run without asking. A command that needs more asks first. Network access works either way. New sessions pick this up.")
                    .foregroundStyle(.secondary)
            }
            Section("Computer use") {
                Toggle("Let frog see and use other apps", isOn: $computerUse)
                Text("frog reads windows through Accessibility and acts on their buttons and fields, usually without taking over your screen. Every action asks first unless you allow it, and it never types into password fields. New sessions pick this up.")
                    .foregroundStyle(.secondary)
            }
            Section("Always-allowed commands") {
                Text("Command prefixes that never ask (like `cargo check`) live in frog's config file, shared with the terminal app.")
                    .foregroundStyle(.secondary)
                Button("Open config.toml…") {
                    if !FileManager.default.fileExists(atPath: configURL.path) {
                        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? "# frog configuration\n# allow_bash = [\"cargo check\", \"npm test\"]\n".write(to: configURL, atomically: true, encoding: .utf8)
                    }
                    Editor.open([configURL])
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage("density") private var density = Density.comfortable.rawValue
    @AppStorage(Verbosity.key) private var verbosity = Verbosity.standard.rawValue
    @AppStorage("playfulFrog") private var playfulFrog = true
    @AppStorage("playfulSounds") private var playfulSounds = false
    @AppStorage(ModelStats.energyKey) private var showEnergy = false

    var body: some View {
        Form {
            Picker("Density", selection: $density) {
                ForEach(Density.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Picker("Detail", selection: $verbosity) {
                ForEach(Verbosity.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .help("How much of the model's work a conversation shows. Session › Detail changes it for one conversation.")
            Text((Verbosity(rawValue: verbosity) ?? .normal).detail)
                .font(.frog(size: 12))
                .foregroundStyle(.secondary)
            Section {
                Toggle("Playful frog", isOn: $playfulFrog)
                    .help("The frog greets you on a new conversation and hops when you drop a file; the activity line gets playful words.")
                Toggle("Frog sounds", isOn: $playfulSounds)
                    .help("A quiet plip when you send, a ribbit when a turn finishes, a drip when it needs permission.")
            }
            Section {
                Toggle("Show energy use", isOn: $showEnergy)
                    .help("Each turn's watt-hours, from this Mac's power sensor, above what it drew at rest. Cloud models add an estimate for their data center. frog.toys/energy has the method.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    private let groups: [(String, [(String, String)])] = [
        ("Conversation", [
            ("Send", "↩"), ("New line", "⇧↩"), ("Interrupt", "Esc  ·  ⌘."), ("Focus composer", "⌘L"),
            ("Dictate", "⌥⌘V"), ("Mention a file", "@"), ("Run a shell command", "!cmd"),
        ]),
        ("Navigate", [
            ("Previous / next turn", "⌥⌘↑  ⌥⌘↓"), ("Find in conversation", "⌘F"), ("Find next / previous", "⌘G  ⇧⌘G"),
            ("Command palette", "⌘K"),
        ]),
        ("Session", [
            ("New session", "⇧⌘N"), ("Race", "⌥⌘R"), ("Compact", "⇧⌘K"), ("Fork after last turn", "⇧⌘D"),
            ("Undo last turn", "⌥⌘Z"), ("Allow / deny a request", "⌘↩  ·  ⌘."),
        ]),
        ("Window", [
            ("Sessions", "⌃⌘S"), ("Changes", "⌥⌘0"), ("Terminal", "⇧⌘T"), ("Preview", "⇧⌘P"),
            ("Inspect an element in the preview", "⇧⌘I"), ("Permission mode", "⌃⌘1  ⌃⌘2  ⌃⌘3"), ("Open folder", "⌘O"),
        ]),
    ]

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.0) { item in
                        LabeledContent(item.0) {
                            Text(item.1).font(.body.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
    }
}

// MARK: - MCP

struct MCPStatus: Decodable, Identifiable {
    struct Quarantined: Decodable {
        let tool: String
        let reason: String
    }
    let name: String
    let connected: Bool
    let error: String?
    let tools: [String]
    let quarantined: [Quarantined]
    var id: String { name }
}

/// Servers from config.toml (every project) and how they're doing. Projects add their own
/// with a `.mcp.json` (Claude Code's format), which sessions in that folder pick up.
private struct MCPSettings: View {
    @State private var servers: [MCPStatus] = []
    @State private var loading = true

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/frog/config.toml")
    }

    var body: some View {
        Form {
            Section {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
                } else if servers.isEmpty {
                    Text("No servers yet.").foregroundStyle(.secondary)
                }
                ForEach(servers) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: s.connected ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(s.connected ? .green : .red)
                            Text(s.name).fontWeight(.medium)
                            Spacer()
                            if s.connected {
                                Text("\(s.tools.count) tool\(s.tools.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                            }
                        }
                        if let e = s.error {
                            Text(e).font(.frog(size: 10)).foregroundStyle(.red).lineLimit(3)
                        } else if !s.tools.isEmpty {
                            Text(s.tools.joined(separator: " · ")).font(.frog(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                        }
                        ForEach(s.quarantined, id: \.tool) { q in
                            Label("Withheld \(q.tool): its description \(q.reason)", systemImage: "exclamationmark.shield")
                                .font(.frog(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Servers in config.toml")
            } footer: {
                Text("Tools from MCP servers ask before running, like shell commands. Tools whose descriptions look like prompt injection are withheld unless the server has `trust = true`. A project can add servers with a `.mcp.json` file (the same format as Claude Code).")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Open config.toml…") {
                    if !FileManager.default.fileExists(atPath: configURL.path) {
                        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? "# frog configuration\n".write(to: configURL, atomically: true, encoding: .utf8)
                    }
                    Editor.open([configURL])
                }
                Text(example)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Button("Refresh") { Task { await load() } }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        .task { await load() }
    }

    private var example: String {
        """
        [mcp_servers.github]
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-github"]
        env = { GITHUB_TOKEN = "${GITHUB_TOKEN}" }

        [mcp_servers.docs]
        url = "https://example.com/mcp"
        """
    }

    private func load() async {
        loading = true
        servers = (try? await Frog.json([MCPStatus].self, args: ["--mcp", "--json"],
                                         cwd: FileManager.default.homeDirectoryForCurrentUser)) ?? []
        loading = false
    }
}

/// The QR code a phone scans to pair (a `frog://pair` link the Camera app opens in frog), and the
/// code itself for typing.
private struct PairingCard: View {
    let code: String
    let renew: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let qr = Self.qr(RemoteBridge.pairingURL) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 132, height: 132)
                    .padding(8)
                    .background(.white, in: .rect(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(RemoteBridge.name).font(.frog(size: 13, weight: .semibold))
                Text(code).font(.body.monospaced()).textSelection(.enabled)
                Button("New Code", action: renew)
            }
        }
        .padding(.vertical, 4)
        .id(code)
    }

    static func qr(_ url: URL) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
