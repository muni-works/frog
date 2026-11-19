import Foundation

/// Settings' five agent sections (Skills, Connections, Rules, Memory, Automations: run 2 of
/// design/settings.json) and each list page's explainer. Settings' other runs are how the app
/// behaves; these are what the agent knows and can do. docs/design/app-shell.md has the rules.
struct CustomizeCatalog {
    struct Explainer: Decodable, Hashable {
        /// The one bold sentence saying what the thing is.
        let bold: String
        /// One more sentence.
        let rest: String
        /// The docs link's words and where it goes (frog.toys/docs/<section>).
        let link: String
        let href: String
        /// An existing docs page that covers the section, until its own page exists.
        var fallback: String? = nil

        /// Where the link goes: the section's own page once the docs have it, else the page
        /// that covers it, else nowhere (no link to a page that isn't there).
        func url(has: (String) -> Bool) -> URL? {
            guard let own = URL(string: href) else { return nil }
            if has(own.lastPathComponent) { return own }
            guard let fallback, has(fallback) else { return nil }
            return own.deletingLastPathComponent().appending(path: fallback)
        }
    }

    struct Section: Identifiable, Hashable {
        let id: String
        let label: String
        var aliases: [String]? = nil
        let explainer: Explainer
    }

    let version: Int
    let sections: [Section]

    /// The sections of the bundled settings list that carry an explainer.
    static let bundled = CustomizeCatalog(SettingsCatalog.bundled)

    init(version: Int, sections: [Section]) {
        self.version = version
        self.sections = sections
    }

    init(_ settings: SettingsCatalog) {
        self.init(version: settings.version, sections: settings.sections.compactMap { s in
            s.explainer.map { Section(id: s.id, label: s.label, aliases: s.aliases, explainer: $0) }
        })
    }

    /// A section by its id or an old name (mcp → connections, instructions → rules).
    func section(named name: String?) -> String? {
        guard let name = name?.lowercased() else { return nil }
        return sections.first { $0.id == name || ($0.aliases ?? []).contains(name) }?.id
    }

    func label(_ id: String) -> String { sections.first { $0.id == id }?.label ?? "Settings" }

    func explainer(_ id: String) -> Explainer? { sections.first { $0.id == id }?.explainer }
}
