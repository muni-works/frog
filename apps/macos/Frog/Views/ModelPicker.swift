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
                workspace.use(spec)
                open = false
            } close: {
                open = false
            }
        }
    }
}

/// The model list as a menu: the shared sections and rows (`ModelList.swift`), a search field
/// that appears when you type or when the list is long, and Manage Models. Ready models are
/// picked; the rest do what makes them ready. Shared by the composer and the toolbar readout.
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
    /// A cloud model waiting on the project's permission.
    @State private var asking: ModelIdentity?
    /// A model waiting on its provider's key, picked once the key is saved.
    @State private var awaitingKey: ModelIdentity?
    @AppStorage("settingsTab") private var settingsTab = "general"
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searching: Bool
    @FocusState private var listFocused: Bool

    /// What frog can use here, plus the current model even if frog didn't list it.
    private var usable: [ModelIdentity] {
        var list = workspace.models.map { workspace.allowing(ModelIdentity($0)) }
        if let current, !list.contains(where: { $0.spec == current }) {
            list.insert(workspace.identity(current), at: 0)
        }
        return list
    }

    private var sections: [(title: String, models: [ModelIdentity])] {
        let words = query.lowercased().split(separator: " ")
        let match = { (m: ModelIdentity) in words.allSatisfy { (m.name + " " + m.spec).lowercased().contains($0) } }
        return ModelSections.make(usable: usable.filter(match), suggested: SuggestedModel.all.map(ModelIdentity.init).filter(match))
    }

    private var flat: [ModelIdentity] { sections.flatMap(\.models) }

    /// No cloud model set up yet: the list offers adding a key instead.
    private var noCloud: Bool { query.isEmpty && !usable.contains { $0.place.isCloud } }

    private var showsSearch: Bool { !query.isEmpty || usable.count > 10 }

    /// Any model can be picked: the list does whatever it needs first. Only a spending cap
    /// stops it, since picking would override the cap.
    private func choose(_ m: ModelIdentity) {
        switch m.state {
        case .ready where m.place.isCloud && workspace.mustAskForCloud: asking = m
        case .ready, .wontFit, .unreachable: pick(m.spec)
        case .notDownloaded, .downloadFailed, .downloading:
            workspace.useWhenReady(m)
            close()
        case .needsKey:
            awaitingKey = m
            addKey(m.providerID)
        case .notAllowed: asking = m
        case .overCap:
            settingsTab = "models"
            close()
            openSettings()
        }
    }

    private func addKey(_ provider: String) {
        keyFor = store.providers.first { $0.id == provider }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsSearch {
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
            }
            HuggingScroll(maxHeight: 440) {
                VStack(alignment: .leading, spacing: 0) {
                    if flat.isEmpty {
                        Text("No models match.").foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(sections, id: \.title) { section in
                        header(section.title)
                        ForEach(section.models, id: \.spec) { m in row(m) }
                    }
                    if noCloud {
                        header("Cloud")
                        cloudSetup
                    }
                }
                .padding(6)
            }
            Divider()
            Button {
                settingsTab = "models"
                close()
                openSettings()
            } label: {
                Label("Manage Models…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hoverPlate(h: 8, v: 6)
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .frame(width: 340)
        // Opened from inside the canvas, it would inherit its scroll margins.
        .contentMargins(0, for: .scrollContent)
        .environment(\.addProviderKey) { addKey($0) }
        .environment(\.askCloudPermission) { asking = $0 }
        .sheet(item: $keyFor) { p in KeySheet(provider: p) }
        .sheet(item: Binding(get: { asking.map(AskingCloud.init) }, set: { if $0 == nil { asking = nil } })) { a in
            CloudPermissionSheet(workspace: workspace, model: a.model) { allowed in
                asking = nil
                if allowed { pick(a.model.spec) }
            }
        }
        // Typing anywhere searches.
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(characters: .alphanumerics) { press in
            query += press.characters
            searching = true
            return .handled
        }
        .onKeyPress(.return) { if let m = flat[safe: selected] { choose(m) }; return .handled }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(flat.count - 1, 0)); hovered = nil; return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); hovered = nil; return .handled }
        .onAppear {
            listFocused = true
            selected = flat.firstIndex { $0.spec == current } ?? 0
        }
        .task {
            await store.load()
            await workspace.reloadModels()
            await store.probe()
        }
        // A finished download, or a key added, makes more models usable.
        .onChange(of: downloads.states) { Task { await workspace.reloadModels() } }
        .onChange(of: store.generation) {
            Task {
                await workspace.reloadModels()
                // The key it was waiting on is in: pick it (asking first, if it's cloud).
                if let m = awaitingKey, let now = usable.first(where: { $0.spec == m.spec }), now.state.isReady {
                    awaitingKey = nil
                    choose(now)
                }
            }
        }
        .onChange(of: query) { selected = 0 }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func row(_ m: ModelIdentity) -> some View {
        let lit = hovered == m.spec || (hovered == nil && flat[safe: selected]?.spec == m.spec)
        // Picking does what a model needs, so the only button is Stop while it downloads.
        return ModelListRow(model: m, current: m.spec == current) {
            if case .downloading = m.state { ModelStateAction(model: m) }
        }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(lit ? 0.08 : 0), in: .rect(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
            .onTapGesture { choose(m) }
            .onHover { inside in
                if inside { hovered = m.spec } else if hovered == m.spec { hovered = nil }
            }
    }

    /// Cloud with nothing set up yet: one row, and a key away.
    private var cloudSetup: some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloud models")
                Text("Add a key to use them").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu("Add Key…") {
                ForEach(store.providers.filter { !$0.local && !$0.custom }) { p in
                    Button(p.name) { keyFor = p }
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
