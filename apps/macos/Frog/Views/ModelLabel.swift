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
    /// Extra detail for `.row` (fit, speed, price); the place is always included.
    var detail: String? = nil

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.spoken)
    }

    @ViewBuilder
    private var content: some View {
        switch size {
        case .pill:
            HStack(spacing: 5) {
                PlaceIcon(place: model.place)
                Text(model.name).lineLimit(1)
            }
        case .caption:
            HStack(spacing: 5) {
                PlaceIcon(place: model.place)
                Text("\(model.name) · \(model.place.label)").lineLimit(1)
            }
            .foregroundStyle(.secondary)
        case .menu:
            // Menus draw a title and subtitle from two texts.
            Label {
                Text(model.name)
                Text(model.place.label)
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
                    Text([model.place.label, detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
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
}

extension Workspace {
    /// The identity of one of this folder's models, or of any spec.
    func identity(_ spec: String) -> ModelIdentity {
        ModelIdentity.of(spec, in: models)
    }
}
