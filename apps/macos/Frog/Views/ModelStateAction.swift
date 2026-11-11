import SwiftUI

/// What makes a model usable, done in place: Get, Stop, Retry, or Add key….
struct ModelStateAction: View {
    let model: ModelIdentity
    @State private var downloads = ModelDownloads.shared
    @Environment(\.addProviderKey) private var addKey
    @Environment(\.askCloudPermission) private var askCloud
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"

    var body: some View {
        switch model.state {
        case .notDownloaded:
            button("Get") { if let r = model.repo { downloads.download(r) } }
        case .downloading(let f):
            HStack(spacing: 6) {
                ProgressView(value: f).frame(width: 60)
                Button { if let r = model.repo { downloads.cancel(r) } } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop downloading")
            }
        case .downloadFailed:
            button("Retry") { if let r = model.repo { downloads.download(r) } }
        case .needsKey:
            if let addKey { button("Add Key…") { addKey(model.providerID) } }
        case .notAllowed:
            if let askCloud { button("Allow…") { askCloud(model) } }
        case .overCap:
            button("Raise Cap…") {
                settingsTab = "models"
                openSettings()
            }
        case .ready, .wontFit, .unreachable:
            EmptyView()
        }
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .controlSize(.small)
    }
}

extension Workspace {
    /// The identity of one of this folder's models, or of any spec.
    func identity(_ spec: String) -> ModelIdentity {
        Self.identity(spec, in: models)
    }

    /// A model's name where no folder is at hand (a sidebar row): from the last model list any
    /// folder loaded, named as the picker names it.
    static func modelName(_ spec: String) -> String {
        identity(spec, in: knownModelList).name
    }

    static func identity(_ spec: String, in models: [ModelEntry]) -> ModelIdentity {
        var m = ModelIdentity.of(spec, in: models)
        // A pooled model (`node/<hash>`) is named by the node that has it, never its hash.
        if spec.hasPrefix("node/") {
            let named = Devices.shared.serving(model: spec).model
            if let pooled = Self.pooledName(spec: spec, named: named) { m.name = pooled; m.variant = nil }
        }
        return m
    }

    /// The display name for a pooled model, when a node reports one; nil leaves the identity's
    /// own name (which, for a bare hash, is what the bug showed).
    nonisolated static func pooledName(spec: String, named: String) -> String? {
        let short = String(spec.split(separator: "/", maxSplits: 1).last ?? "")
        if !named.isEmpty, named != short { return ModelIdentity.cleanName(named).name }
        // No node has said what it is yet: a hash means nothing to a person.
        let hash = short.split(separator: "@").first ?? ""
        let hex = hash.count >= 8 && hash.allSatisfy(\.isHexDigit)
        return hex ? "Shared model" : nil
    }
}

extension ModelListRow where Accessory == ModelStateAction {
    /// The standard row: what makes the model usable, done in place.
    init(model: ModelIdentity, current: Bool = false) {
        self.init(model: model, current: current) { ModelStateAction(model: model) }
    }
}
