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
        ModelIdentity.of(spec, in: models)
    }
}

extension ModelListRow where Accessory == ModelStateAction {
    /// The standard row: what makes the model usable, done in place.
    init(model: ModelIdentity, current: Bool = false) {
        self.init(model: model, current: current) { ModelStateAction(model: model) }
    }
}
