import Foundation

/// What widgets, controls and the share sheet know about the Mac: the conversations that need you
/// or are running, as of the app's last look. Written by the app into the shared group.
struct Snapshot: Codable, Equatable {
    struct Row: Codable, Hashable, Identifiable {
        var id: String
        var title: String
        /// "waiting", "running", "unread" or "".
        var live: String
        var activity: String?
        var question: String?
        var permission: String?
        var local: Bool
        /// Open in a window on the Mac, so it can take messages.
        var open: Bool = false
    }

    var rows: [Row]
    var host: String?
    var at: Date

    static let group = "group.eco.frog.remote"
    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }

    var waiting: [Row] { rows.filter { $0.live == "waiting" } }
    var running: [Row] { rows.filter { $0.live == "running" } }

    static func load() -> Snapshot? {
        defaults.data(forKey: "snapshot").flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
    }

    func save() {
        Self.defaults.set(try? JSONEncoder().encode(self), forKey: "snapshot")
    }

    /// Where the Mac is and the code it wants, for extensions that talk to it themselves.
    static var connection: (host: String, code: String)? {
        guard let code = defaults.string(forKey: "code"), !code.isEmpty else { return nil }
        return (defaults.string(forKey: "host") ?? "127.0.0.1:8913", code)
    }

    static func remember(host: String, code: String) {
        defaults.set(host, forKey: "host")
        defaults.set(code, forKey: "code")
    }
}
