import Foundation

/// Customize's five sections and each list page's explainer (design/customize.json, bundled
/// like design/settings.json). Settings is how the app behaves; Customize is what the agent
/// knows and can do. docs/design/app-shell.md › Customize has the rules.
struct CustomizeCatalog: Decodable {
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

    struct Section: Decodable, Identifiable, Hashable {
        let id: String
        let label: String
        var aliases: [String]? = nil
        let explainer: Explainer
    }

    let version: Int
    let sections: [Section]

    static let bundled: CustomizeCatalog = {
        guard let url = Bundle.main.url(forResource: "customize", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(CustomizeCatalog.self, from: data) else {
            return CustomizeCatalog(version: 1, sections: [])
        }
        return c
    }()

    /// A section by its id or an old name (mcp → connections, instructions → rules).
    func section(named name: String?) -> String? {
        guard let name = name?.lowercased() else { return nil }
        return sections.first { $0.id == name || ($0.aliases ?? []).contains(name) }?.id
    }

    /// `frog://customize/<section>` (`frog-dev://` for a Debug build): the section it opens, the
    /// first one for a section this build doesn't draw. The web's "Open in Frog for Mac" uses it.
    func section(for url: URL) -> String? {
        guard url.scheme == "frog" || url.scheme == "frog-dev", url.host() == "customize" else { return nil }
        let first = url.pathComponents.first { $0 != "/" }
        return section(named: first) ?? sections.first?.id
    }

    func label(_ id: String) -> String { sections.first { $0.id == id }?.label ?? "Customize" }

    func explainer(_ id: String) -> Explainer? { sections.first { $0.id == id }?.explainer }

    /// The sidebar's rows, in the shape Settings' sidebar draws.
    var asSettingsCatalog: SettingsCatalog {
        SettingsCatalog(version: version, sections: sections.map { .init(id: $0.id, label: $0.label) }, rows: [])
    }
}
