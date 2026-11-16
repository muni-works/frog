import Foundation

/// The documentation that ships inside the app: markdown pages under `docs/app/` at the repo
/// root, listed by its `manifest.json` (docs/design/app-shell.md, "One source"). The folder is
/// bundled as `Resources/app`, so the docs in a build describe that build.
struct AppDocs: Equatable {
    /// `docs/app/manifest.json`: `{"version": 1, "sections": [{"title", "pages": [{"slug",
    /// "title", "file"}]}]}`, with `file` relative to the manifest's folder.
    struct Manifest: Decodable, Equatable {
        let version: Int
        let sections: [ManifestSection]
    }

    struct ManifestSection: Decodable, Equatable {
        let title: String
        let pages: [ManifestPage]
    }

    struct ManifestPage: Decodable, Equatable {
        let slug: String
        let title: String
        let file: String
    }

    /// One page as the shell lists it.
    struct Page: Identifiable, Hashable {
        let slug: String
        let title: String
        let section: String
        /// The markdown file, resolved against the docs folder.
        let url: URL
        var id: String { slug }
    }

    struct Section: Identifiable, Hashable {
        let title: String
        let pages: [Page]
        var id: String { title }
    }

    enum LoadError: Error, Equatable {
        case noManifest
        case unsupportedVersion(Int)
    }

    static let supportedVersion = 1

    let root: URL
    /// Sections in manifest order, each with the pages that exist on disk.
    let sections: [Section]

    /// Every page in reading order: what previous and next step through.
    var pages: [Page] { sections.flatMap(\.pages) }

    func page(_ slug: String?) -> Page? {
        guard let slug else { return nil }
        return pages.first { $0.slug == slug }
    }

    /// The page before and after this one, across sections.
    func neighbors(of slug: String) -> (previous: Page?, next: Page?) {
        let all = pages
        guard let i = all.firstIndex(where: { $0.slug == slug }) else { return (nil, nil) }
        return (i > 0 ? all[i - 1] : nil, i + 1 < all.count ? all[i + 1] : nil)
    }

    /// Reads the manifest in `root`. A page whose file is missing, whose path leaves the docs
    /// folder, or whose slug repeats an earlier one is left out rather than failing the rest;
    /// a section left with no pages is dropped.
    static func load(root: URL) throws -> AppDocs {
        let manifestURL = root.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw LoadError.noManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == supportedVersion else { throw LoadError.unsupportedVersion(manifest.version) }
        let base = root.standardizedFileURL.path
        var seen: Set<String> = []
        let sections: [Section] = manifest.sections.compactMap { section in
            let pages: [Page] = section.pages.compactMap { p in
                let url = root.appending(path: p.file).standardizedFileURL
                guard url.path.hasPrefix(base + "/"), FileManager.default.fileExists(atPath: url.path),
                      seen.insert(p.slug).inserted
                else { return nil }
                return Page(slug: p.slug, title: p.title, section: section.title, url: url)
            }
            return pages.isEmpty ? nil : Section(title: section.title, pages: pages)
        }
        return AppDocs(root: root, sections: sections)
    }

    /// The docs bundled with this build, or nil if the bundle has none.
    static let bundled: AppDocs? = {
        guard let root = Bundle.main.resourceURL?.appending(path: "app") else { return nil }
        return try? load(root: root)
    }()

    /// A page's markdown as this platform shows it: other platforms' blocks out, and the
    /// leading `# Title` dropped (the shell draws the manifest's title above the page).
    func body(of page: Page, for platform: DocsPlatform = .mac) -> String {
        guard let source = try? String(contentsOf: page.url, encoding: .utf8) else { return "" }
        return Self.stripTitle(DocsFilter.filter(source, for: platform))
    }

    /// Sections whose pages match the query by title or by a heading on the page (as this
    /// platform shows it). An empty query keeps everything.
    func search(_ query: String, for platform: DocsPlatform = .mac) -> [Section] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sections }
        return sections.compactMap { section in
            let hits = section.pages.filter { page in
                page.title.localizedStandardContains(q)
                    || Self.headings(body(of: page, for: platform)).contains { $0.localizedStandardContains(q) }
            }
            return hits.isEmpty ? nil : Section(title: section.title, pages: hits)
        }
    }

    /// The text of every markdown heading outside code fences.
    static func headings(_ markdown: String) -> [String] {
        var inFence = false
        var out: [String] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, t.hasPrefix("#") else { continue }
            let text = t.drop(while: { $0 == "#" })
            guard text.first == " " else { continue }
            out.append(text.trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    /// The markdown without its first line when that line is a level-one heading (blank lines
    /// before it, and after it, go too).
    static func stripTitle(_ markdown: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard let first = lines.first, first.hasPrefix("# ") else { return markdown }
        lines.removeFirst()
        while let next = lines.first, next.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }
}

/// Where a page is being read. A page can mark blocks for some of these; unmarked text shows
/// everywhere.
enum DocsPlatform: String, CaseIterable {
    case mac, web, terminal
}

/// Platform blocks: the lines between `<!-- only: mac -->` (or `web`, `terminal`, several
/// comma-separated) and `<!-- end -->`, each marker on its own line. Blocks don't nest; a new
/// `only` marker starts a new block. Markers inside a code fence are text, and a block left
/// open runs to the end of the page.
enum DocsFilter {
    static func filter(_ markdown: String, for platform: DocsPlatform) -> String {
        var out: [Substring] = []
        /// The platforms of the block being read; nil outside a block.
        var block: Set<String>?
        var inFence = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !inFence {
                if let platforms = only(t) { block = platforms; continue }
                if isEnd(t) { block = nil; continue }
            }
            let shown = block.map { $0.contains(platform.rawValue) } ?? true
            if t.hasPrefix("```") { inFence.toggle() }
            if shown { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// The platforms an `<!-- only: … -->` marker names, or nil for any other line.
    static func only(_ line: String) -> Set<String>? {
        guard line.hasPrefix("<!--"), line.hasSuffix("-->") else { return nil }
        let inner = line.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("only:") else { return nil }
        let names = inner.dropFirst(5).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return Set(names)
    }

    static func isEnd(_ line: String) -> Bool {
        guard line.hasPrefix("<!--"), line.hasSuffix("-->") else { return false }
        return line.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces) == "end"
    }
}
