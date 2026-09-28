import SwiftUI

/// A model, drawn the one way frog draws models: where it runs as an icon, then its name. Every
/// surface picks a size; none formats a model itself. See docs/models.md.
struct ModelLabel: View {
    enum Size {
        /// Icon and name: the composer's picker, the activity capsule.
        case pill
        /// Icon, name, abilities and one line of detail: pickers and Settings.
        case row
        /// Name with the place as a subtitle, for menus and pickers.
        case menu
        /// Icon and name in secondary text: the empty conversation, footers.
        case caption
    }

    let model: ModelIdentity
    var size: Size = .pill
    /// Extra detail for `.row` (fit, speed, price).
    var detail: String? = nil
    /// Whether `.row` names the place. Lists grouped by place leave it to the section.
    var showsPlace = true

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([model.spoken, model.stateLine].compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder
    private var content: some View {
        switch size {
        case .pill:
            HStack(spacing: 5) {
                PlaceIcon(place: model.place)
                Text(model.name).lineLimit(1)
                StateBadge(state: model.state)
            }
        case .caption:
            HStack(spacing: 5) {
                PlaceIcon(place: model.place)
                Text("\(model.name) · \(model.stateLine ?? model.place.label)").lineLimit(1)
            }
            .foregroundStyle(.secondary)
        case .menu:
            // Menus draw a title and subtitle from two texts.
            Label {
                Text(model.name)
                Text(model.stateLine ?? model.place.label)
            } icon: {
                Image(systemName: model.place.symbol)
            }
        case .row:
            HStack(spacing: 10) {
                PlaceIcon(place: model.place)
                    .font(.body)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name).lineLimit(1)
                        AbilityIcons(abilities: model.abilities)
                    }
                    Group {
                        if let line = model.stateLine {
                            let text = [line, detail].compactMap { $0 }.joined(separator: " · ")
                            if let symbol = model.state.symbol {
                                Label(text, systemImage: symbol).labelStyle(StateLineStyle())
                            } else {
                                Text(text)
                            }
                        } else {
                            Text([showsPlace ? model.place.label : nil, detail].compactMap { $0 }.joined(separator: " · "))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .opacity(model.state.dimmed ? 0.5 : 1)
        }
    }
}

/// A state's icon before its line, when it has one.
private struct StateLineStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// A model that isn't ready, as a small mark after its name: a ring while it downloads, a key
/// when it needs one.
struct StateBadge: View {
    let state: ModelIdentity.State

    var body: some View {
        switch state {
        case .downloading(let f):
            ProgressView(value: f)
                .progressViewStyle(.circular)
                .controlSize(.mini)
        case .ready:
            EmptyView()
        default:
            if let symbol = state.symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

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

/// Where a model runs, as its icon. Cloud carries a faint tint; everything that stays on your
/// own hardware is neutral, like Safari's lock: small, always in the same place, never loud.
struct PlaceIcon: View {
    let place: ModelIdentity.Place

    var body: some View {
        Image(systemName: place.symbol)
            .foregroundStyle(place.isCloud ? AnyShapeStyle(Color.cyan.opacity(0.85)) : AnyShapeStyle(.secondary))
            .imageScale(.small)
            .help(place.label)
    }
}

/// What a model can do beyond text: uses tools, sees images, reasons.
struct AbilityIcons: View {
    let abilities: ModelIdentity.Abilities

    var body: some View {
        HStack(spacing: 3) {
            if abilities.contains(.usesTools) { icon("wrench.and.screwdriver", "Uses tools") }
            if abilities.contains(.seesImages) { icon("photo", "Sees images") }
            if abilities.contains(.reasons) { icon("brain", "Reasons") }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func icon(_ symbol: String, _ help: String) -> some View {
        Image(systemName: symbol).help(help).accessibilityLabel(help)
    }
}

extension EnvironmentValues {
    /// The models a view's folder can use, for views that name one without a workspace.
    @Entry var models: [ModelEntry] = []
    /// Ask for a provider's key (by provider id), in a sheet over whatever asked.
    @Entry var addProviderKey: ((String) -> Void)?
    /// Ask whether this project may use a cloud model.
    @Entry var askCloudPermission: ((ModelIdentity) -> Void)?
}

extension ModelIdentity {
    /// One line saying why a model isn't ready, or nil when it is.
    var stateLine: String? {
        switch state {
        case .ready: nil
        case .notDownloaded(let gb): "\(Self.gb(gb)) download"
        case .downloading(let f):
            downloadGB.map { "\(Self.gb($0 * f)) of \(Self.gb($0))" } ?? "Downloading, \(Int(f * 100))%"
        case .downloadFailed: "Download failed"
        case .needsKey(let p): "Add \(p.first.map { "AEIOU".contains($0) } == true ? "an" : "a") \(p) key to use it"
        case .wontFit(let needs, let has): "Needs \(needs) GB, this Mac has \(has)"
        case .notAllowed(let project): "\(project) keeps code on your devices"
        case .overCap: "This month's cloud cap is reached"
        case .unreachable(let why): why
        }
    }

    private static func gb(_ v: Double) -> String { String(format: "%.1f GB", v) }
}

extension ModelIdentity.State {
    var symbol: String? {
        switch self {
        case .ready, .downloading: nil
        case .notDownloaded: "arrow.down.circle"
        case .downloadFailed: "exclamationmark.triangle"
        case .needsKey: "key"
        case .wontFit: "memorychip"
        case .notAllowed: "lock"
        case .overCap: "pause.circle"
        case .unreachable: "bolt.slash"
        }
    }

    /// Shown, but not something you can pick.
    var dimmed: Bool {
        switch self {
        case .wontFit, .notAllowed, .overCap, .unreachable: true
        default: false
        }
    }
}

extension Workspace {
    /// The identity of one of this folder's models, or of any spec.
    func identity(_ spec: String) -> ModelIdentity {
        ModelIdentity.of(spec, in: models)
    }
}
