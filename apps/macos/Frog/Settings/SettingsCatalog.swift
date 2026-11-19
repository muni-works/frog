import Foundation

/// Every setting the Mac and the web show (design/settings.json, bundled like the local model
/// catalog). Both apps draw their sections from it; the Mac keeps its own bindings and storage
/// (`SettingsBindings`). docs/design/app-shell.md › Settings has the rules.
struct SettingsCatalog: Decodable {
    struct Section: Decodable, Identifiable, Hashable {
        let id: String
        let label: String
        var aliases: [String]? = nil
        /// The sidebar's run: 1 how the app behaves, 2 what the agent knows and can do (Skills,
        /// Connections, Rules, Memory, Automations), 3 usage and the account. A gap between runs.
        var run: Int = 1
        /// A run-2 section's opening card. Those sections draw their own page (`CustomizeView`),
        /// not rows from this list.
        var explainer: CustomizeCatalog.Explainer? = nil

        private enum CodingKeys: String, CodingKey { case id, label, aliases, run, explainer }

        init(id: String, label: String, aliases: [String]? = nil, run: Int = 1, explainer: CustomizeCatalog.Explainer? = nil) {
            self.id = id
            self.label = label
            self.aliases = aliases
            self.run = run
            self.explainer = explainer
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = try c.decode(String.self, forKey: .label)
            aliases = try c.decodeIfPresent([String].self, forKey: .aliases)
            run = try c.decodeIfPresent(Int.self, forKey: .run) ?? 1
            explainer = try c.decodeIfPresent(CustomizeCatalog.Explainer.self, forKey: .explainer)
        }
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

    /// A section that draws its own page (Skills, Connections, Rules, Memory, Automations).
    func drawsOwnPage(_ id: String) -> Bool { sections.first { $0.id == id }?.explainer != nil }

    /// The rows the Mac draws, in order: everything but the web's own, minus what can't work
    /// here yet. A section's rows by default; a machine's or provider's page with `page`. None
    /// for a section that draws its own page.
    func macRows(in section: String, page: String? = nil) -> [Row] {
        guard !drawsOwnPage(section) else { return [] }
        return rows.filter { $0.section == section && $0.page == page && $0.platform != .web && $0.notYet?["mac"] == nil }
    }

    func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    /// A section by its id or an old name (mcp → connections, energy → usage, lend → models).
    func section(named name: String?) -> String? {
        guard let name = name?.lowercased() else { return nil }
        return sections.first { $0.id == name || ($0.aliases ?? []).contains(name) }?.id
    }

    /// `frog://settings/<section>` (`frog-dev://` for a Debug build): the section it opens, if
    /// it's a settings link. The old `frog://customize/<section>` (the web's invitations may still
    /// send it) opens the same section; with no section, Skills.
    func section(for url: URL) -> String? {
        guard url.scheme == "frog" || url.scheme == "frog-dev" else { return nil }
        let first = url.pathComponents.first { $0 != "/" }
        switch url.host() {
        case "settings": return section(named: first) ?? sections.first(where: { $0.id == "account" })?.id
        case "customize": return section(named: first) ?? sections.first(where: { $0.explainer != nil })?.id
        default: return nil
        }
    }
}
