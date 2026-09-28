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
    @AppStorage("settingsTab") private var settingsTab = "general"
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searching: Bool

    /// Groups by where models run: this Mac, then your servers, then each cloud provider.
    private var groups: [(title: String, models: [ModelEntry])] {
        let words = query.lowercased().split(separator: " ")
        let shown = workspace.models.filter { m in
            let hay = (ModelIdentity(m).name + " " + m.spec).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        var out: [(String, [ModelEntry])] = []
        let order: (ModelIdentity.Place) -> Int = { p in
            switch p { case .mac, .apple: 0; case .server: 1; case .cloud: 2 }
        }
        let byPlace = Dictionary(grouping: shown) { ModelIdentity($0).place.label }
        for (label, rows) in byPlace.sorted(by: { a, b in
            let pa = order(ModelIdentity(a.value[0]).place), pb = order(ModelIdentity(b.value[0]).place)
            return pa != pb ? pa < pb : a.key < b.key
        }) {
            out.append((label, rows))
        }
        return out
    }

    private var flat: [ModelEntry] { groups.flatMap(\.models) }

    private var focus: ModelEntry? {
        if let hovered, let m = workspace.models.first(where: { $0.spec == hovered }) { return m }
        let list = flat
        return list.indices.contains(selected) ? list[selected] : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search models", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searching)
                        .onSubmit { if let m = flat[safe: selected] { pick(m.spec) } }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
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
            .frame(width: 290)
            if let m = focus {
                Divider()
                ModelCard(model: ModelIdentity(m))
                    .frame(width: 250)
            }
        }
        .onAppear { searching = true }
        .task {
            await store.load()
            await workspace.reloadModels()
        }
        .onChange(of: query) { selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(flat.count - 1, 0)); hovered = nil; return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); hovered = nil; return .handled }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if flat.isEmpty {
                        Text(query.isEmpty ? "No models yet." : "No models match.")
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    ForEach(groups, id: \.title) { group in
                        Text(group.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(group.models) { m in
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

    private func row(_ m: ModelEntry) -> some View {
        let lit = hovered == m.spec || (hovered == nil && flat[safe: selected]?.spec == m.spec)
        return Button { pick(m.spec) } label: {
            HStack(spacing: 8) {
                ModelLabel(model: ModelIdentity(m))
                AbilityIcons(abilities: ModelIdentity(m).abilities)
                Spacer(minLength: 4)
                if m.spec == current {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(lit ? 0.08 : 0), in: .rect(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
