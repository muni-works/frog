import XCTest
@testable import Frog

/// The in-app documentation's reader: the manifest (docs/app/manifest.json) and the platform
/// blocks a page can mark (docs/design/app-shell.md, "One source").
final class AppDocsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "frog-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "start"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private let manifest = """
    {
      "version": 1,
      "sections": [
        { "title": "Start", "pages": [
          { "slug": "install", "title": "Install", "file": "start/install.md" },
          { "slug": "first", "title": "Your first session", "file": "start/first.md" }
        ] },
        { "title": "Use", "pages": [
          { "slug": "web", "title": "Web search and fetch", "file": "use/web.md" }
        ] }
      ]
    }
    """

    // MARK: Manifest

    func testManifestReadsSectionsAndPagesInOrder() throws {
        try write("manifest.json", manifest)
        try write("start/install.md", "# Install\n")
        try write("start/first.md", "# Your first session\n")
        try write("use/web.md", "# Web\n")
        let docs = try AppDocs.load(root: root)
        XCTAssertEqual(docs.sections.map(\.title), ["Start", "Use"])
        XCTAssertEqual(docs.pages.map(\.slug), ["install", "first", "web"])
        XCTAssertEqual(docs.page("web")?.title, "Web search and fetch")
        XCTAssertEqual(docs.page("web")?.section, "Use")
        XCTAssertEqual(docs.page("first")?.url.lastPathComponent, "first.md")
    }

    func testNeighborsCrossSections() throws {
        try write("manifest.json", manifest)
        for f in ["start/install.md", "start/first.md", "use/web.md"] { try write(f, "x") }
        let docs = try AppDocs.load(root: root)
        XCTAssertNil(docs.neighbors(of: "install").previous)
        XCTAssertEqual(docs.neighbors(of: "install").next?.slug, "first")
        XCTAssertEqual(docs.neighbors(of: "first").next?.slug, "web")
        XCTAssertEqual(docs.neighbors(of: "web").previous?.slug, "first")
        XCTAssertNil(docs.neighbors(of: "web").next)
        XCTAssertNil(docs.neighbors(of: "nope").next)
    }

    /// A missing file, a repeated slug or a path out of the folder drops that page, not the
    /// docs; a section left empty goes too.
    func testBadPagesAreLeftOut() throws {
        try write("manifest.json", """
        {"version": 1, "sections": [
          {"title": "Start", "pages": [
            {"slug": "install", "title": "Install", "file": "start/install.md"},
            {"slug": "install", "title": "Again", "file": "start/again.md"},
            {"slug": "gone", "title": "Gone", "file": "start/gone.md"},
            {"slug": "out", "title": "Out", "file": "../secret.md"}
          ]},
          {"title": "Empty", "pages": [{"slug": "e", "title": "E", "file": "missing.md"}]}
        ]}
        """)
        try write("start/install.md", "x")
        try write("start/again.md", "x")
        try "secret".write(to: root.deletingLastPathComponent().appending(path: "secret.md"), atomically: true, encoding: .utf8)
        let docs = try AppDocs.load(root: root)
        XCTAssertEqual(docs.pages.map(\.title), ["Install"])
        XCTAssertEqual(docs.sections.map(\.title), ["Start"])
    }

    func testUnsupportedVersionAndMissingManifest() throws {
        XCTAssertThrowsError(try AppDocs.load(root: root)) { XCTAssertEqual($0 as? AppDocs.LoadError, .noManifest) }
        try write("manifest.json", #"{"version": 2, "sections": []}"#)
        XCTAssertThrowsError(try AppDocs.load(root: root)) { XCTAssertEqual($0 as? AppDocs.LoadError, .unsupportedVersion(2)) }
    }

    /// The pages bundled into the app resolve: whatever the docs/app session adds, every listed
    /// page is in the build, and slugs are unique.
    func testBundledDocsResolve() throws {
        let docs = try XCTUnwrap(AppDocs.bundled, "docs/app isn't in the app's resources")
        XCTAssertFalse(docs.pages.isEmpty)
        XCTAssertEqual(Set(docs.pages.map(\.slug)).count, docs.pages.count)
        for page in docs.pages {
            XCTAssertFalse(docs.body(of: page).isEmpty, page.slug)
        }
    }

    // MARK: Platform blocks

    private let page = """
    # Install

    Everyone reads this.

    <!-- only: mac -->
    Mac only.
    <!-- end -->

    <!-- only: web -->
    Web only.
    <!-- end -->

    <!-- only: web, terminal -->
    Not the Mac.
    <!-- end -->

    <!--only:  Terminal ,mac-->
    Terminal and Mac.
    <!-- end -->

    Everyone again.
    """

    func testMacBlockShownWebBlockNot() {
        let mac = DocsFilter.filter(page, for: .mac)
        XCTAssertTrue(mac.contains("Mac only."))
        XCTAssertFalse(mac.contains("Web only."))
        XCTAssertFalse(mac.contains("Not the Mac."))
        XCTAssertTrue(mac.contains("Terminal and Mac."))
        XCTAssertTrue(mac.contains("Everyone reads this."))
        XCTAssertTrue(mac.contains("Everyone again."))
        XCTAssertFalse(mac.contains("<!--"), "markers never show")
    }

    func testWebAndTerminalSeeTheirOwn() {
        let web = DocsFilter.filter(page, for: .web)
        XCTAssertTrue(web.contains("Web only."))
        XCTAssertTrue(web.contains("Not the Mac."))
        XCTAssertFalse(web.contains("Mac only."))
        let terminal = DocsFilter.filter(page, for: .terminal)
        XCTAssertTrue(terminal.contains("Not the Mac."))
        XCTAssertTrue(terminal.contains("Terminal and Mac."))
        XCTAssertFalse(terminal.contains("Web only."))
    }

    /// A marker inside a code fence is the page's text, not a block.
    func testMarkersInCodeAreText() {
        let md = "```html\n<!-- only: web -->\nshown\n<!-- end -->\n```\nafter"
        XCTAssertEqual(DocsFilter.filter(md, for: .mac), md)
    }

    /// A block left open runs to the end; an unrelated comment is just text.
    func testOpenBlockAndOtherComments() {
        XCTAssertEqual(DocsFilter.filter("a\n<!-- only: web -->\nb\nc", for: .mac), "a")
        XCTAssertEqual(DocsFilter.filter("<!-- note -->\na", for: .mac), "<!-- note -->\na")
    }

    func testTitleIsStripped() {
        XCTAssertEqual(AppDocs.stripTitle("\n# Install\n\nFrog runs.\n## More"), "Frog runs.\n## More")
        XCTAssertEqual(AppDocs.stripTitle("## Not a title\nx"), "## Not a title\nx")
    }

    func testSearchMatchesTitlesAndHeadings() throws {
        try write("manifest.json", manifest)
        try write("start/install.md", "# Install\n\n## The terminal\n```sh\n# not a heading\n```\n")
        try write("start/first.md", "# First\n<!-- only: web -->\n## Cloud only\n<!-- end -->\n")
        try write("use/web.md", "# Web\n")
        let docs = try AppDocs.load(root: root)
        XCTAssertEqual(docs.search("").flatMap(\.pages).count, 3)
        XCTAssertEqual(docs.search("search").flatMap(\.pages).map(\.slug), ["web"])
        XCTAssertEqual(docs.search("TERMINAL").flatMap(\.pages).map(\.slug), ["install"])
        XCTAssertTrue(docs.search("not a heading").isEmpty)
        XCTAssertTrue(docs.search("cloud only").isEmpty, "a web block's heading isn't on the Mac's page")
        XCTAssertEqual(docs.search("cloud only", for: .web).flatMap(\.pages).map(\.slug), ["first"])
    }

    func testWebLink() {
        // frog.toys/docs/<slug> is where the web app serves a page; docs.frog.toys doesn't resolve.
        XCTAssertEqual(DocsLinks.web("install").absoluteString, "https://frog.toys/docs/install")
    }
}
