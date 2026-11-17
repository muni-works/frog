import SwiftUI

/// The composer's model chip (docs/design/composer/spec.md): a place icon then the name — a
/// laptop for this Mac, a server for your own nodes, a cloud for Frog Cloud, in the place
/// colours. What you pick is what runs: picking a model on one of your machines puts it there,
/// and the chip says "Loading" until the machine says it's ready. Its menu opens upward,
/// frog-drawn.
struct ModelPicker: View {
    let workspace: Workspace
    let conversation: Conversation
    var open = false
    var narrow = false
    /// A local model is downloading or starting: the chip says so.
    var loading = false
    var toggle: () -> Void = {}
    var close: () -> Void = {}
    @State private var devices = Devices.shared

    var body: some View {
        let pill = ModelPill.of(workspace.selectedModel, workspace: workspace, devices: devices)
        ComposerChip(open: open, help: pill.help, action: toggle) {
            ModelChipLabel(name: pill.model, place: pill.icon, narrow: narrow && !(loading || pill.waiting != nil),
                           loading: loading || pill.waiting == "loading")
        }
        .fixedSize()
        .accessibilityLabel("Model: \(pill.model)")
        .composerMenu(open, trailing: true, close: close) {
            ModelMenu(workspace: workspace, current: workspace.selectedModel, conversationID: conversation.sessionID) { spec in
                workspace.use(spec)
                close()
            } close: {
                close()
            }
            .background(Tokens.raised, in: .rect(cornerRadius: Tokens.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous).strokeBorder(Tokens.lineStrong, lineWidth: 1))
        }
        .onAppear { devices.start() }
        .onDisappear { devices.stop() }
    }
}

/// What the chip says: the model, where it runs, and whether it's on its way.
enum ModelPill {
    struct State: Equatable {
        var model: String
        var place: String?
        var cloud: Bool
        /// "loading", or "swaps after this turn": the machine isn't serving it yet.
        var waiting: String?
        /// One of your own nodes (not this Mac).
        var node = false

        var icon: ModelPlaceIcon { cloud ? .cloud : node ? .node : .mac }
        var help: String { [model, place, waiting].compactMap { $0 }.joined(separator: " · ") }
    }

    @MainActor
    static func of(_ spec: String?, workspace: Workspace, devices: Devices) -> State {
        guard let spec else { return State(model: "Model", place: nil, cloud: false) }
        if spec.hasPrefix("node/") {
            let row = devices.machineModels().first { $0.spec == spec }
            let name = row?.name ?? workspace.identity(spec).name
            let running = row?.holds.filter { $0.action == .running }.map(\.name) ?? []
            let waiting: String? = devices.waitingSwap[spec] != nil ? "swaps after this turn"
                : devices.asked[spec] != nil ? "loading" : nil
            let place = running.isEmpty ? (devices.waitingSwap[spec] ?? devices.asked[spec] ?? row?.holds.first?.name) : running.joined(separator: ", ")
            return State(model: name, place: place, cloud: false, waiting: waiting, node: true)
        }
        let m = workspace.identity(spec)
        switch m.place {
        case .mac, .apple: return State(model: m.name, place: "This Mac", cloud: false)
        case .server(let n): return State(model: m.name, place: n, cloud: false, node: true)
        case .cloud(let n): return State(model: m.name, place: n, cloud: m.place.isCloud)
        }
    }
}

/// The model list: "Your machines" (each model once, with the machines that hold it and what
/// picking it does there), then "Frog Cloud" (with its price per million output tokens) unless
/// Settings turned cloud models off. The footer only opens Settings › Models.
/// Shared by the composer and the toolbar readout.
struct ModelMenu: View {
    let workspace: Workspace
    let current: String?
    var conversationID: String? = nil
    let pick: (String) -> Void
    let close: () -> Void
    @State private var hovered: String?
    @State private var selected = 0
    @State private var store = ProviderStore.shared
    @State private var devices = Devices.shared
    @State private var problem: String?
    /// A cloud model waiting on the project's permission.
    @State private var asking: ModelIdentity?
    @AppStorage(ModelMenu.showCloudKey) private var showCloud = true
    @AppStorage("settingsTab") private var settingsTab = "general"
    @Environment(\.openSettings) private var openSettings
    @State private var filter = ""

    static let showCloudKey = "showCloudModels"

    private enum Row: Identifiable {
        case machine(MachineModel)
        case cloud(ModelIdentity)
        var id: String { switch self { case .machine(let m): m.spec; case .cloud(let m): m.spec } }
    }

    private func matches(_ name: String) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || name.localizedCaseInsensitiveContains(q)
    }

    private var machineRows: [Row] { devices.machineModels().filter { matches($0.name) }.map(Row.machine) }

    private var cloudRows: [Row] {
        guard showCloud else { return [] }
        var list = workspace.models.map { workspace.allowing(ModelIdentity($0)) }.filter(\.place.isFrogCloud)
        if let current, current.hasPrefix("cloud/"), !list.contains(where: { $0.spec == current }) {
            list.insert(workspace.identity(current), at: 0)
        }
        return list.filter { matches($0.name) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(Row.cloud)
    }

    private var flat: [Row] { machineRows + cloudRows }

    private func choose(_ row: Row) {
        switch row {
        case .machine(let m):
            let pick = pick
            let by = conversationID
            pick(m.spec)
            guard !m.running else { return }
            Task {
                do { try await Devices.shared.switchTo(m.spec, by: by) } catch { problem = error.localizedDescription }
            }
        case .cloud(let m):
            switch m.state {
            // Picking a cloud model is the answer: it goes, with nothing to click through
            // (Cam, 2026-11-13). The folder still has a policy — `keep it on your devices`
            // leaves cloud models shown as not-allowed in the list, and picking one there
            // opens the sheet to change that policy, because that is the one case where the
            // person said no and the question is real.
            case .notAllowed: asking = m
            case .overCap:
                settingsTab = "billing"
                close()
                openSettings()
            default: pick(m.spec)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ComposerMenuFilter(
                placeholder: "Search models",
                text: $filter,
                move: { d in
                    selected = min(max(selected + d, 0), max(flat.count - 1, 0))
                    hovered = nil
                },
                pick: { if let r = flat[safe: selected] { choose(r) } },
                close: close
            )
            .padding(.horizontal, 4)
            .padding(.top, 4)
            HuggingScroll(maxHeight: 440) {
                VStack(alignment: .leading, spacing: 0) {
                    header("Your machines")
                        .onChange(of: filter) { selected = 0 }
                    if machineRows.isEmpty {
                        Text("No models on your machines yet.")
                            .font(.frog(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    ForEach(machineRows) { row($0) }
                    if !cloudRows.isEmpty {
                        header(ProviderID.cloudName)
                        ForEach(cloudRows) { row($0) }
                    }
                    if let problem {
                        Text(problem).font(.frog(size: 11)).foregroundStyle(Tokens.signal)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }
                .padding(6)
            }
            Rectangle().fill(Tokens.line).frame(height: 1)
            Button {
                settingsTab = "models"
                close()
                openSettings()
            } label: {
                Text("Manage…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hoverPlate(h: 8, v: 6)
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .frame(width: 320)
        .contentMargins(0, for: .scrollContent)
        .sheet(item: Binding(get: { asking.map(AskingCloud.init) }, set: { if $0 == nil { asking = nil } })) { a in
            CloudPermissionSheet(workspace: workspace, model: a.model) { allowed in
                asking = nil
                if allowed { pick(a.model.spec) }
            }
        }
        .onAppear {
            devices.start()
            selected = flat.firstIndex { $0.id == current } ?? 0
        }
        .task {
            await store.load()
            await workspace.reloadModels()
        }
        .onDisappear { devices.stop() }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.frog(size: Tokens.Size.label))
            .foregroundStyle(Tokens.textSecondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func row(_ r: Row) -> some View {
        let lit = hovered == r.id || (hovered == nil && flat[safe: selected]?.id == r.id)
        return MachineMenuRow(content: content(r), current: r.id == current)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(Color.primary.opacity(lit ? 0.08 : 0), in: .rect(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
            .onTapGesture { choose(r) }
            .onHover { inside in
                if inside { hovered = r.id } else if hovered == r.id { hovered = nil }
            }
    }

    private func content(_ r: Row) -> MachineMenuRow.Content {
        switch r {
        case .machine(let m):
            let tag = devices.waitingSwap[m.spec] != nil ? "swaps after this turn" : devices.asked[m.spec] != nil ? "loading" : m.tag
            return .init(name: m.name, detail: m.places, tag: tag, cloud: false, spinning: devices.asked[m.spec] != nil, node: m.spec.hasPrefix("node/"))
        case .cloud(let m):
            return .init(name: m.name, detail: ModelMenu.outputPrice(m.spec), tag: nil, cloud: true, spinning: false)
        }
    }

    /// "$0.80/M out": a cloud model's price per million output tokens.
    ///
    /// `Prices` is already dollars per **million** (`ModelStats.Prices`, filled from the
    /// engine's `cost_out`, which `catalog::per_million` converted at parse time), so there is
    /// nothing to scale here. This used to multiply by 1,000,000 and showed
    /// "$1440000.00/M out" for a model that costs $1.44.
    @MainActor
    static func outputPrice(_ spec: String) -> String? {
        guard let p = ModelStats.shared.prices(spec) else { return nil }
        return priceLine(p.output)
    }

    /// The one formatting of a per-million output price, so a test can pin it without an
    /// engine, a gateway or the shared stats store.
    static func priceLine(_ perMillionOutput: Double) -> String? {
        guard perMillionOutput > 0 else { return nil }
        return String(format: "$%.2f/M out", perMillionOutput)
    }
}

/// One row of the picker: a dot in the place's color, the model, where it is (or its price),
/// and what picking it does ("swaps", "loads").
struct MachineMenuRow: View {
    struct Content: Equatable {
        var name: String
        var detail: String?
        var tag: String?
        var cloud: Bool
        var spinning: Bool
        /// One of your nodes rather than this Mac (the server icon).
        var node = false
    }
    let content: Content
    var current = false

    var body: some View {
        HStack(spacing: 8) {
            let place: ModelPlaceIcon = content.cloud ? .cloud : content.node ? .node : .mac
            ComposerIcon(place.symbol, color: place.color)
            Text(content.name).font(.frog(size: 13)).foregroundStyle(Tokens.text).lineLimit(1)
            if let d = content.detail {
                Text(d).font(.frog(size: 12)).foregroundStyle(Tokens.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if content.spinning { ProgressView().controlSize(.mini) }
            if let t = content.tag {
                Text(t).font(.frog(size: 11)).foregroundStyle(Tokens.textSecondary)
            }
            if current {
                Image(systemName: "checkmark").font(.frog(size: 11, weight: .semibold)).foregroundStyle(Tokens.text)
            }
        }
        .monospacedDigit()
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
                .font(.frog(size: 13, weight: .semibold))
            Text("\(model.name) runs at \(provider). The files you mention, the commands Frog runs and their output are sent there to answer you.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can change this anytime from the conversation's title menu.")
                .font(.frog(size: 12))
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
