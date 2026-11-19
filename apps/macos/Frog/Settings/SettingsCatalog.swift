import Foundation

/// Every setting the Mac and the web show (design/settings.json, bundled like the local model
/// catalog). Both apps draw their sections from it; the Mac keeps its own bindings and storage
/// (`SettingsBindings`). docs/design/app-shell.md › Settings has the rules.
struct SettingsCatalog: Decodable {
    struct Section: Decodable, Identifiable, Hashable {
        let id: String
        let label: String
        var aliases: [String]? = nil
    }

    struct Option: Decodable, Hashable {
        let id: String
        let label: String
        var description: String? = nil
    }

    struct Row: Decodable, Identifiable, Hashable {
        enum Platform: String, Decodable { case both, invite, mac, web }
        enum Control: String, Decodable { case toggle, segmented, menu, field, button, value, list }
        let id: String
        let section: String
        var group: String? = nil
        let label: String
        var description: String? = nil
        let control: Control
        let platform: Platform
        var options: [Option]? = nil
        /// Shown only while this toggle row is on.
        var when: String? = nil
        /// Drawn on a machine's or provider's page, not the section's.
        var page: String? = nil
        /// Why it can't work yet, per platform ("mac", "web").
        var notYet: [String: String]? = nil
    }

    let version: Int
    let sections: [Section]
    let rows: [Row]

    /// The bundled list. A build without it is broken, not quiet: the tests load it too.
    static let bundled: SettingsCatalog = {
        guard let url = Bundle.main.url(forResource: "settings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(SettingsCatalog.self, from: data) else {
            return SettingsCatalog(version: 1, sections: [], rows: [])
        }
        return c
    }()

    /// The rows the Mac draws, in order: everything but the web's own, minus what can't work
    /// here yet. A section's rows by default; a machine's or provider's page with `page`.
    func macRows(in section: String, page: String? = nil) -> [Row] {
        rows.filter { $0.section == section && $0.page == page && $0.platform != .web && $0.notYet?["mac"] == nil }
    }

    func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    /// A section by its id or an old name (mcp → connections, energy → usage, lend → models).
    func section(named name: String?) -> String? {
        guard let name = name?.lowercased() else { return nil }
        return sections.first { $0.id == name || ($0.aliases ?? []).contains(name) }?.id
    }

    /// `frog://settings/<section>` (`frog-dev://` for a Debug build): the section it opens, if
    /// it's a settings link.
    func section(for url: URL) -> String? {
        guard url.scheme == "frog" || url.scheme == "frog-dev", url.host() == "settings" else { return nil }
        let first = url.pathComponents.first { $0 != "/" }
        // Connections moved to Customize: its names pass through, and showSettings sends them on.
        return section(named: first) ?? CustomizeCatalog.bundled.section(named: first) ?? sections.first(where: { $0.id == "account" })?.id
    }
}
