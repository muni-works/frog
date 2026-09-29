import SwiftUI

/// The one list of models, shared by the picker and Settings (docs/models.md): the same
/// sections in the same order, and the same row. Sections say where models run, so rows
/// don't: On this Mac, then your servers, then each cloud provider. A model you'd download
/// is just a model on this Mac in the Not downloaded state.
enum ModelSections {
    /// `usable`: what frog listed (plus the current model, even if it wasn't listed).
    /// `suggested`: what frog recommends downloading.
    static func make(usable: [ModelIdentity], suggested: [ModelIdentity]) -> [(title: String, models: [ModelIdentity])] {
        let order: (ModelIdentity.Place) -> Int = { p in
            switch p { case .mac, .apple: 0; case .server: 1; case .cloud: 2 }
        }
        // By runtime (Apple, tang, Ollama, LM Studio), then ready first, then on their way, then
        // ones that need something, then ones that can't run well here.
        let rank: (ModelIdentity.State) -> Int = { s in
            switch s {
            case .ready: 0
            case .downloading: 1
            case .wontFit, .overCap, .unreachable: 3
            default: 2
            }
        }
        let sorted: ([ModelIdentity]) -> [ModelIdentity] = { list in
            list.enumerated().sorted {
                ($0.element.runtimeRank, rank($0.element.state), $0.offset) < ($1.element.runtimeRank, rank($1.element.state), $1.offset)
            }.map(\.element)
        }
        let have = Set(usable.map(\.spec))
        let all = usable + suggested.filter { !have.contains($0.spec) }
        return Dictionary(grouping: all) { $0.place.label }
            .sorted { a, b in
                let pa = order(a.value[0].place), pb = order(b.value[0].place)
                return pa != pb ? pa < pb : a.key < b.key
            }
            .map { (title: $0.key, models: sorted($0.value)) }
    }
}

/// A model in a list: its name and abilities over one line of detail (speed, cost, or what it
/// needs), then a checkmark if it's the current one, then whatever the list offers for it.
struct ModelListRow<Accessory: View>: View {
    let model: ModelIdentity
    var current = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            ModelLabel(model: model, size: .row, detail: model.stateLine == nil ? model.summary : nil, showsPlace: false)
            Spacer(minLength: 4)
            if current {
                Image(systemName: "checkmark").font(.callout.weight(.semibold)).foregroundStyle(.tint)
            }
            accessory()
        }
        .help(model.details)
    }
}

extension ModelListRow where Accessory == ModelStateAction {
    /// The standard row: what makes the model usable, done in place.
    init(model: ModelIdentity, current: Bool = false) {
        self.init(model: model, current: current) { ModelStateAction(model: model) }
    }
}

extension ModelIdentity {
    /// The row's second line when the model is ready: what's worth knowing to choose it.
    @MainActor
    var summary: String? {
        if place.isCloud {
            return ModelStats.shared.estimatedTurnCost(self).map { "~\(ModelStats.money($0)) a turn" } ?? price
        }
        if let s = ModelStats.shared.speed(spec) { return ModelStats.speedText(s) }
        if place == .apple { return "Built in" }
        if let gb = downloadGB { return String(format: "%.1f GB", gb) }
        if let b = paramsB { return String(format: "%.0fB parameters", b) }
        return variant
    }

    /// The hover tip: where it runs, what it can do, how much it holds, what it costs.
    var details: String {
        var lines = [spoken]
        var can: [String] = []
        if abilities.contains(.usesTools) { can.append("uses tools") }
        if abilities.contains(.seesImages) { can.append("sees images") }
        if abilities.contains(.reasons) { can.append("reasons") }
        if !can.isEmpty { lines.append("It " + can.joined(separator: ", ") + ".") }
        if let c = context { lines.append("Holds \(c.formatted()) tokens.") }
        if let p = price { lines.append(p) }
        lines.append(spec) // advanced: the tip ends with the spec, small print for people who want it
        return lines.joined(separator: "\n")
    }
}
