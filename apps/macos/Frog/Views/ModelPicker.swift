import SwiftUI

/// The composer's model control: the model's short name, opening a searchable list grouped by
/// where models run, with a card describing whichever one the pointer is on.
struct ModelPicker: View {
    let workspace: Workspace
    let conversation: Conversation
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                if let s = conversation.status {
                    ModelLabel(model: workspace.identity(s.model))
                } else {
                    Text("Model")
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .hoverPlate()
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(conversation.status.map { workspace.identity($0.model).spoken } ?? "Choose a model")
        .popover(isPresented: $open, arrowEdge: .top) {
            ModelMenu(workspace: workspace, current: conversation.status?.model) { spec in
                workspace.preferredModel = spec
                conversation.setModel(spec)
                open = false
            } close: {
                open = false
            }
        }
    }
}

/// The model list itself: search, models grouped by where they run, and a card for the one
/// under the pointer. Shared by the composer and the toolbar readout.
struct ModelMenu: View {
    let workspace: Workspace
    let current: String?
    let pick: (String) -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var hovered: String?
    /// Keyboard selection, an index into the flattened, filtered list.
    @State private var selected = 0
    @State private var store = ProviderStore.shared
    @State private var downloads = ModelDownloads.shared
    /// A provider whose key is being added, in a sheet over the list.
    @State private var keyFor: ProviderInfo?
    /// Which lane is showing; starts on the current model's.
    @State private var lane: Lane?
    /// A cloud model waiting on the project's permission.
    @State private var asking: ModelIdentity?

    /// Where code goes: your own hardware, or a provider's.
    enum Lane: String, CaseIterable, Identifiable {
        case devices, cloud
        var id: Self { self }
        var title: String { self == .devices ? "Your Devices" : "Cloud" }
        var symbol: String { self == .devices ? "laptopcomputer" : "cloud" }

        init(_ place: ModelIdentity.Place) {
            self = place.isCloud ? .cloud : .devices
        }
    }

    private var shownLane: Lane {
        lane ?? current.map { Lane(workspace.identity($0).place) } ?? .devices
    }
    @AppStorage("settingsTab") private var settingsTab = "general"
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searching: Bool

    /// Every model to offer: the ones frog can use, then the ones recommended for this Mac that
    /// aren't downloaded yet (a download in progress counts as not yet).
    private var candidates: [ModelIdentity] {
        let usable = workspace.models.map { workspace.allowing(ModelIdentity($0)) }
        let have = Set(usable.map(\.spec))
        return usable + SuggestedModel.all.filter { !have.contains($0.spec) }.map(ModelIdentity.init)
    }

    /// Groups by where models run: this Mac, then your servers, then each cloud provider. Within
    /// a group: ready first, then ones to get, then ones that won't fit.
    private var groups: [(title: String, models: [ModelIdentity])] {
        let words = query.lowercased().split(separator: " ")
        // Searching looks in both lanes.
        let shown = candidates.filter { m in
            let hay = (m.name + " " + m.spec).lowercased()
            return words.allSatisfy { hay.contains($0) } && (!words.isEmpty || Lane(m.place) == shownLane)
        }
        let order: (ModelIdentity.Place) -> Int = { p in
            switch p { case .mac, .apple: 0; case .server: 1; case .cloud: 2 }
        }
        let rank: (ModelIdentity.State) -> Int = { s in
            switch s { case .ready: 0; case .wontFit: 2; default: 1 }
        }
        return Dictionary(grouping: shown) { $0.place.label }
            .sorted { a, b in
                let pa = order(a.value[0].place), pb = order(b.value[0].place)
                return pa != pb ? pa < pb : a.key < b.key
            }
            .map { ($0.key, $0.value.enumerated().sorted { (rank($0.element.state), $0.offset) < (rank($1.element.state), $1.offset) }.map(\.element)) }
    }

    private var flat: [ModelIdentity] { groups.flatMap(\.models) }

    private var focus: ModelIdentity? {
        if let hovered, let m = flat.first(where: { $0.spec == hovered }) { return m }
        let list = flat
        return list.indices.contains(selected) ? list[selected] : nil
    }

    /// Ready models are picked; the rest do what makes them ready.
    private func choose(_ m: ModelIdentity) {
        switch m.state {
        case .ready where m.place.isCloud && workspace.mustAskForCloud: asking = m
        case .ready: pick(m.spec)
        case .notDownloaded, .downloadFailed: if let r = m.repo { downloads.download(r) }
        case .needsKey: addKey(m.providerID)
        case .notAllowed: asking = m
        case .downloading, .wontFit, .overCap: break
        }
    }

    /// Measured speed on your devices, estimated cost in the cloud.
    private func hint(_ m: ModelIdentity) -> String? {
        if m.place.isCloud {
            return ModelStats.shared.estimatedTurnCost(m).map { "~\(ModelStats.money($0)) a turn" }
        }
        return ModelStats.shared.speed(m.spec).map(ModelStats.speedText)
    }

    private func addKey(_ provider: String) {
        keyFor = store.providers.first { $0.id == provider }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search models", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searching)
                        .onSubmit { if let m = flat[safe: selected] { choose(m) } }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
                if query.isEmpty {
                    lanePicker
                }
                list
                Divider()
                Button {
                    settingsTab = "models"
                    close()
                    openSettings()
                } label: {
                    Label("Manage models", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hoverPlate(h: 8, v: 6)
                }
                .buttonStyle(.plain)
                .padding(6)
            }
            .frame(width: 310)
            if let m = focus {
                Divider()
                ModelCard(model: m)
                    .frame(width: 250)
            }
        }
        .environment(\.addProviderKey) { addKey($0) }
        .environment(\.askCloudPermission) { asking = $0 }
        .sheet(item: $keyFor) { p in KeySheet(provider: p) }
        .sheet(item: Binding(get: { asking.map(AskingCloud.init) }, set: { if $0 == nil { asking = nil } })) { a in
            CloudPermissionSheet(workspace: workspace, model: a.model) { allowed in
                asking = nil
                if allowed { pick(a.model.spec) }
            }
        }
        .onAppear { searching = true }
        .task {
            await store.load()
            await workspace.reloadModels()
        }
        // A finished download, or a key added, makes more models usable.
        .onChange(of: downloads.states) { Task { await workspace.reloadModels() } }
        .onChange(of: store.generation) { Task { await workspace.reloadModels() } }
        .onChange(of: query) { selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(flat.count - 1, 0)); hovered = nil; return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); hovered = nil; return .handled }
    }

    /// The two lanes, and what choosing one means.
    private var lanePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Where models run", selection: Binding(get: { shownLane }, set: { lane = $0; selected = 0 })) {
                ForEach(Lane.allCases) { l in
                    Label(l.title, systemImage: l.symbol).tag(l)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(shownLane == .devices
                 ? "Private and free: nothing leaves your devices. This Mac has \(ModelIdentity.memoryGB) GB."
                 : "Code you send is processed by the provider. " + cloudLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    /// The project's answer, under the Cloud lane.
    private var cloudLine: String {
        let name = workspace.policyName
        switch workspace.cloud {
        case .allow: return "\(name) allows cloud models."
        case .deny: return "\(name) keeps code on your devices."
        case .ask: return workspace.cloudForThisConversation
            ? "Allowed for this conversation."
            : "You'll be asked before \(name)'s code goes to the cloud."
        }
    }

    /// Cloud with nothing set up yet: the providers you could add a key for.
    private var cloudSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a key to use a provider's models.")
                .foregroundStyle(.secondary)
            ForEach(store.providers.filter { !$0.local && !$0.custom && !$0.connected }) { p in
                HStack {
                    Label(p.name, systemImage: "cloud")
                    Spacer()
                    Button("Add Key…") { keyFor = p }.controlSize(.small)
                }
            }
        }
        .font(.callout)
        .padding(12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if flat.isEmpty {
                        if query.isEmpty && shownLane == .cloud {
                            cloudSetup
                        } else {
                            Text(query.isEmpty ? "No models yet." : "No models match.")
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(group.models, id: \.spec) { m in
                            row(m).id(m.spec)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(height: 340)
            .onChange(of: selected) { if let m = flat[safe: selected] { proxy.scrollTo(m.spec) } }
        }
    }

    private func row(_ m: ModelIdentity) -> some View {
        let lit = hovered == m.spec || (hovered == nil && flat[safe: selected]?.spec == m.spec)
        return HStack(spacing: 8) {
            Button { choose(m) } label: {
                HStack(spacing: 8) {
                    if m.state.isReady {
                        ModelLabel(model: m)
                        AbilityIcons(abilities: m.abilities)
                        Spacer(minLength: 4)
                        if let hint = hint(m) {
                            Text(hint).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    } else {
                        ModelLabel(model: m, size: .row)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if m.spec == current {
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            }
            ModelStateAction(model: m)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(lit ? 0.08 : 0), in: .rect(cornerRadius: 7, style: .continuous))
        .onHover { inside in
            if inside { hovered = m.spec } else if hovered == m.spec { hovered = nil }
        }
    }
}

/// What's worth knowing to pick a model: where it runs, what it can do, how much it holds,
/// and what it costs. The spec is here, small, for people who want it.
private struct ModelCard: View {
    let model: ModelIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.name)
                .font(.headline)
                .lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { label, value in
                    GridRow {
                        Text(label).foregroundStyle(.secondary)
                        Text(value).lineLimit(2)
                    }
                }
            }
            .font(.callout)
            Text(model.spec) // advanced: the detail card shows the spec, small
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rows: [(String, String)] {
        var out: [(String, String)] = [("Runs", model.place.label)]
        var can: [String] = []
        if model.abilities.contains(.usesTools) { can.append("Uses tools") }
        if model.abilities.contains(.seesImages) { can.append("Sees images") }
        if model.abilities.contains(.reasons) { can.append("Reasons") }
        if !can.isEmpty { out.append(("Can", can.joined(separator: ", "))) }
        if let b = model.paramsB { out.append(("Size", String(format: "%.1fB parameters", b))) }
        if let v = model.variant { out.append(("Variant", v)) }
        if let c = model.context { out.append(("Context", "\(c.formatted()) tokens")) }
        if let p = model.price { out.append(("Price", p)) }
        return out
    }
}

/// A cloud model waiting on permission, as a sheet item.
private struct AskingCloud: Identifiable {
    let model: ModelIdentity
    var id: String { model.spec }
}

/// The one question frog asks before a project's code goes to the cloud: once per project, with
/// the answer kept (and enforced) by frog, or just for this conversation.
struct CloudPermissionSheet: View {
    let workspace: Workspace
    let model: ModelIdentity
    /// Whether the model may be used now.
    let done: (Bool) -> Void

    private var provider: String {
        if case .cloud(let p) = model.place { return p }
        return "the provider"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Use cloud models in \(workspace.policyName)?", systemImage: "cloud")
                .font(.headline)
            Text("\(model.name) runs at \(provider). The files you mention, the commands frog runs and their output are sent there to answer you.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can change this anytime from the conversation's title menu.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            HStack {
                Button("Keep It on Your Devices") {
                    Task { await workspace.setCloud(.deny) }
                    done(false)
                }
                Spacer()
                Button("Just This Conversation") {
                    Task {
                        // Enforced by frog: a folder that said no has to be asked again.
                        if workspace.cloud == .deny { await workspace.setCloud(.ask) }
                        workspace.cloudForThisConversation = true
                        done(true)
                    }
                }
                Button("Always Allow") {
                    Task {
                        await workspace.setCloud(.allow)
                        done(true)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
