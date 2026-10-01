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

    /// Where the Mac is and the code it wants (from the Keychain), for extensions that talk to it.
    static var connection: (host: String, code: String)? {
        guard let code = PairingCode.read(), !code.isEmpty, let host = defaults.string(forKey: "host") else { return nil }
        return (host, code)
    }

    static func remember(host: String) {
        defaults.set(host, forKey: "host")
    }
}
