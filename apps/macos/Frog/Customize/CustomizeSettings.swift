import AppKit

/// The settings a conversation may change through Customize (docs/customize-events.md): the
/// `setting_change` the engine sends lands here, on the same keys Settings writes, and the current
/// values go to the engine (`Op::Settings`) so a card can quote the old one. Ids are
/// `design/settings.json`'s; only the rows marked `agent: apply` arrive without a card.
enum CustomizeSettings {
    /// Each id's key in UserDefaults, and how its value is stored.
    private enum Stored { case choice(String, [String]), toggle(String, Bool) }
    private static let rows: [String: Stored] = [
        "theme": .choice(AppTheme.key, ["system", "light", "dark"]),
        "density": .choice("density", Density.allCases.map(\.rawValue)),
        "detail": .choice(Verbosity.key, Verbosity.allCases.map(\.rawValue)),
        "playful": .toggle("playfulFrog", true),
        "sounds": .toggle("playfulSounds", false),
        "notifications": .toggle("notifyWhenDone", true),
        "show-energy": .toggle(ModelStats.energyKey, false),
    ]

    /// A `setting_change`: written where Settings keeps it, and applied (the theme at once; the
    /// rest are read through `@AppStorage`). False for an id or value the Mac doesn't have.
    @MainActor @discardableResult
    static func apply(_ id: String, _ value: JSONValue, defaults: UserDefaults = .standard) -> Bool {
        switch (rows[id], value) {
        case (.choice(let key, let options), .string(let v)) where options.contains(v):
            defaults.set(v, forKey: key)
            if id == "theme" { AppTheme.apply(v) }
            return true
        case (.toggle(let key, _), .bool(let v)):
            defaults.set(v, forKey: key)
            return true
        default:
            return false
        }
    }

    /// The current values, as the engine names them.
    nonisolated static func current(_ defaults: UserDefaults = .standard) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (id, stored) in rows {
            switch stored {
            case .choice(let key, let options): out[id] = .string(defaults.string(forKey: key) ?? options[0])
            case .toggle(let key, let fallback): out[id] = .bool(defaults.object(forKey: key) as? Bool ?? fallback)
            }
        }
        return out
    }
}
