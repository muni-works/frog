import Foundation

/// How much of the model's work a conversation shows. The app has a default (Settings); a
/// conversation can override it (Session › Detail), remembered by session.
enum Verbosity: String, CaseIterable, Identifiable {
    /// The answer, and one line for what was done. No thinking.
    case quiet
    /// Lines for what was done and thought, each opening to the details. A thought streams as a
    /// one-line subtitle and settles into its gist.
    case normal
    /// Everything open: thoughts and steps expanded, a thought streaming in full.
    case verbose

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var detail: String {
        switch self {
        case .quiet: "The answer, and a line for what was done."
        case .normal: "Lines for what was done and thought, with a one-line gist of each thought."
        case .verbose: "Every thought and step, open."
        }
    }

    var showsThinking: Bool { self != .quiet }

    static let key = "verbosity"

    /// The app's default. Before this setting, thinking was on or off: off reads as quiet.
    static var standard: Verbosity {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: key), let v = Verbosity(rawValue: raw) { return v }
        return defaults.object(forKey: "showThinking") as? Bool == false ? .quiet : .normal
    }
}

/// Per-conversation overrides of the default, by session id.
@MainActor
@Observable
final class VerbosityOverrides {
    static let shared = VerbosityOverrides()

    private static let key = "verbosityBySession"
    private(set) var bySession: [String: Verbosity]

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        bySession = raw.compactMapValues(Verbosity.init(rawValue:))
    }

    /// What `session` shows: its override, else `fallback` (the app's default).
    func level(for session: String?, default fallback: Verbosity) -> Verbosity {
        session.flatMap { bySession[$0] } ?? fallback
    }

    /// Nil goes back to the app's default.
    func set(_ level: Verbosity?, for session: String) {
        bySession[session] = level
        UserDefaults.standard.set(bySession.mapValues(\.rawValue), forKey: Self.key)
    }
}
