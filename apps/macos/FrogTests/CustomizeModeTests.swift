import AppKit
import SwiftUI
import XCTest
@testable import Frog

/// Customize as a mode of the shell (docs/design/app-shell.md › Customize): five sections from
/// design/customize.json, Connections moved in from Settings, rules files edited a line at a
/// time without touching the rest, servers added without running them, and no figure the
/// engine hasn't given. Also renders each page, dark and light (`$FROG_SNAPSHOT_DIR` or
/// `$TMPDIR/frog-snapshots`, `mac-customize-<page>-<look>.png`).
@MainActor
final class CustomizeModeTests: XCTestCase {
    private let catalog = CustomizeCatalog.bundled

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var outDir: URL {
        if let dir = ProcessInfo.processInfo.environment["FROG_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "frog-customize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    // MARK: The list and the mode

    func testFiveSectionsEachWithAnExplainerAndADocsLink() {
        XCTAssertEqual(catalog.sections.map(\.label), ["Skills", "Connections", "Rules", "Memory", "Automations"])
        for s in catalog.sections {
            XCTAssertEqual(s.explainer.href, "https://frog.toys/docs/\(s.id)")
            XCTAssertTrue(s.explainer.link.hasPrefix("How "), s.id)
            XCTAssertFalse(s.explainer.bold.isEmpty)
            XCTAssertFalse(s.explainer.rest.isEmpty)
        }
        XCTAssertFalse(catalog.sections.map(\.label).contains("Instructions"), "the name Instructions is retired")
    }

    func testConnectionsLeftSettings() {
        let settings = SettingsCatalog.bundled
        XCTAssertNil(settings.sections.first { $0.id == "connections" })
        XCTAssertFalse(settings.rows.contains { $0.section == "connections" })
        XCTAssertFalse(settings.rows.contains { $0.id.hasPrefix("mcp-") })
    }

    func testModeRemembersItsSectionAndTakesOldNames() {
        let panes = Panes(Workspace(folder: URL(fileURLWithPath: "/tmp/demo"), fresh: true))
        defer { panes.stopAll() }
        CustomizeStore.loads = false
        defer { CustomizeStore.loads = true }
        panes.showCustomize()
        XCTAssertEqual(panes.mode, .customize)
        XCTAssertEqual(panes.customizeSection, "skills", "Skills the first time")
        panes.showCustomize("instructions")
        XCTAssertEqual(panes.customizeSection, "rules")
        panes.customizePage = .skill("commit")
        panes.backToApp()
        XCTAssertEqual(panes.mode, .threads)
        panes.showCustomize()
        XCTAssertEqual(panes.customizeSection, "rules", "the window keeps its last section")
        XCTAssertEqual(panes.customizePage, .skill("commit"), "and the page under it")
        panes.showCustomize("memory")
        XCTAssertNil(panes.customizePage, "another section starts at its list")
        panes.showCustomize("nonsense")
        XCTAssertEqual(panes.customizeSection, "memory")
    }

    /// Everything that used to open Settings › Connections opens Customize › Connections.
    func testOldConnectionsLinksOpenCustomize() throws {
        let panes = Panes(Workspace(folder: URL(fileURLWithPath: "/tmp/demo"), fresh: true))
        defer { panes.stopAll() }
        CustomizeStore.loads = false
        defer { CustomizeStore.loads = true }
        for name in ["mcp", "connections"] {
            panes.backToApp()
            panes.showSettings(name)
            XCTAssertEqual(panes.mode, .customize, name)
            XCTAssertEqual(panes.customizeSection, "connections", name)
        }
        panes.showSettings("billing")
        XCTAssertEqual(panes.mode, .settings, "Settings' own sections stay in Settings")
        let link = try XCTUnwrap(URL(string: "frog://settings/mcp"))
        XCTAssertEqual(SettingsCatalog.bundled.section(for: link), "connections")
    }

    func testBreadcrumbs() {
        XCTAssertEqual(CustomizeCrumbs.title(section: "skills", page: nil), "Customize › Skills")
        XCTAssertEqual(CustomizeCrumbs.title(section: "skills", page: .skill("release-notes")), "Customize › Skills › /release-notes")
        let d = ServerDraft(name: "postgres", command: "npx", args: ["-y", "pg"])
        XCTAssertEqual(CustomizeCrumbs.title(section: "connections", page: .review(d)), "Customize › Connections › Add › postgres")
        var went: CustomizePage?? = .none
        let trail = CustomizeCrumbs.trail(section: "connections", page: .review(d)) { went = .some($0) }
        XCTAssertNotNil(trail[0].back)
        trail[1].back?()
        XCTAssertEqual(went, .some(.add("connections")), "Add goes back to the search")
        XCTAssertNil(trail.last?.back, "the page you're on isn't a link")
    }

    // MARK: Never a made-up number

    func testFiguresStayHiddenUntilTheEngineGivesThem() throws {
        let json = #"[{"name":"commit","description":"Write a commit message.","path":"/x/SKILL.md","project":false}]"#
        let skills = try JSONDecoder().decode([CustomizeSkill].self, from: Data(json.utf8))
        XCTAssertNil(skills[0].tokensPerTurn)
        XCTAssertNil(skills[0].uses)
        XCTAssertNil(CustomizeFormat.totalTokens(skills.map(\.tokensPerTurn)))
        XCTAssertNil(CustomizeFormat.totalTokens([140, nil]), "a sum with a hole in it isn't shown")
        XCTAssertEqual(CustomizeFormat.totalTokens([140, 680]), "820 tokens a turn")
        XCTAssertNil(CustomizeFormat.totalTokens([]))
    }

    func testBuiltInSkillsHaveNoFile() throws {
        let json = #"[{"name":"gh","description":"GitHub CLI.","path":"frog-builtin:gh","project":false}]"#
        let s = try JSONDecoder().decode([CustomizeSkill].self, from: Data(json.utf8))[0]
        XCTAssertTrue(s.builtIn)
        XCTAssertNil(s.file)
    }

    func testSkillGroups() {
        let skills = [CustomizeSkill(name: "a", description: "", path: "/a", project: true),
                      CustomizeSkill(name: "b", description: "", path: "/b", project: false)]
        XCTAssertEqual(SkillsPage.groups(skills, project: "pond").map(\.label), ["In pond", "Everywhere"])
        XCTAssertEqual(SkillsPage.groups([skills[1]], project: nil).map(\.label), ["Everywhere"])
    }

    // MARK: VoiceOver

    func testVoiceOverLabelsForTheBarSquaresAndMarks() {
        let squares: [ToolSquares.Square] = (0..<10).map { .init(tool: "t\($0)", state: .on) }
            + [.init(tool: "x", state: .withheld), .init(tool: "y", state: .withheld)]
        XCTAssertEqual(ToolSquares.label(squares), "12 tools, 2 withheld")
        XCTAssertEqual(ToolSquares.label([.init(tool: "a", state: .on), .init(tool: "b", state: .off)]), "2 tools, 1 on")
        XCTAssertEqual(ToolSquares.label([.init(tool: "a", state: .off)]), "1 tool, none on")
        XCTAssertEqual(ToolSquares.label([]), "No tools")

        var days = Array(repeating: 0, count: 30)
        XCTAssertEqual(ActivityMarks.label(days), "Never used")
        days[3] = 2; days[20] = 1
        XCTAssertEqual(ActivityMarks.label(days), "Used 3 times in the last 30 days")

        let bar = WeightBar.label([.init(name: "commit", tokens: 140, idle: false), .init(name: "pdf", tokens: 210, idle: true)], budget: 1_500)
        XCTAssertTrue(bar.hasPrefix("What each skill adds to a turn: 350 tokens of a 1,500 token budget."), bar)
        XCTAssertTrue(bar.contains("commit 140 tokens"))
    }

    // MARK: Connections

    func testConnectionLines() {
        let figma = MCPStatus(name: "figma", connected: true, error: nil, tools: ["mcp__figma__get_file", "mcp__figma__comment"],
                              quarantined: [.init(tool: "mcp__figma__run", reason: "reads like instructions")], needsAuth: nil, declined: nil)
        let squares = ConnectionsPage.squares(figma)
        XCTAssertEqual(squares.map(\.tool), ["get_file", "comment", "run"])
        XCTAssertEqual(squares.map(\.state), [.on, .on, .withheld])
        let say = ConnectionsPage.say(figma, project: "pond", fromProject: false)
        XCTAssertEqual(say.lead, "2 tools.")
        XCTAssertEqual(say.rest, "1 is withheld: its description reads like instructions to the model.")

        let linear = MCPStatus(name: "linear", connected: false, error: "Signed out", tools: [], quarantined: [], needsAuth: true, declined: true)
        XCTAssertEqual(ConnectionsPage.say(linear, project: nil, fromProject: false).rest,
                       "Wants you to sign in. Frog can't see its tools until you do. You declined before.")
        let db = MCPStatus(name: "pond-db", connected: false, error: "spawn failed", tools: [], quarantined: [], needsAuth: nil, declined: nil)
        XCTAssertEqual(ConnectionsPage.say(db, project: "pond", fromProject: true).rest, "spawn failed Came with pond's .mcp.json.")
    }

    // MARK: Rules files

    private let sample = """
        ---
        title: pond
        ---
        # pond

        Use pnpm in this project, never npm.

        ## Tests
        - Tests live in spec/, one file per module.
          * Run them with pnpm test.
        1. Commit messages start with the area.

        ```sh
        pnpm codegen
        ```
        <!-- a comment -->
        """

    func testRuleLinesSkipFrontmatterBlankLinesAndFences() {
        let lines = RuleText.lines(sample)
        XCTAssertEqual(lines.map(\.text), ["pond", "Use pnpm in this project, never npm.", "Tests",
                                           "Tests live in spec/, one file per module.", "Run them with pnpm test.",
                                           "Commit messages start with the area.", "pnpm codegen"])
        XCTAssertEqual(lines.map(\.kind), [.heading, .plain, .heading, .item, .item, .item, .code])
        XCTAssertEqual(lines.filter(\.editable).count, 4)
        XCTAssertEqual(lines[4].prefix, "  * ")
    }

    func testEditingALineKeepsEveryOtherByte() {
        let lines = RuleText.lines(sample)
        let target = lines[4]
        let edited = RuleText.replacing(sample, at: target.index, with: "Run them with pnpm test --watch.")
        var expected = sample.components(separatedBy: "\n")
        expected[target.index] = "  * Run them with pnpm test --watch."
        XCTAssertEqual(edited, expected.joined(separator: "\n"))
        // Untouched lines are byte for byte the same, and so is the end of the file.
        XCTAssertEqual(edited.components(separatedBy: "\n").count, sample.components(separatedBy: "\n").count)
        XCTAssertEqual(RuleText.replacing(sample, at: 999, with: "x"), sample, "a line that isn't there changes nothing")
        XCTAssertEqual(RuleText.replacing(sample, at: lines[1].index, with: "two\nlines"),
                       sample.replacingOccurrences(of: "Use pnpm in this project, never npm.", with: "two lines"),
                       "an edit stays on its line")
    }

    func testRemovingALineKeepsEveryOtherByte() {
        let lines = RuleText.lines(sample)
        let removed = RuleText.removing(sample, at: lines[1].index)
        XCTAssertEqual(removed, sample.replacingOccurrences(of: "Use pnpm in this project, never npm.\n", with: ""))
    }

    func testCRLFFilesKeepTheirLineEndings() {
        let crlf = "# Rules\r\n- one\r\n- two\r\n"
        let edited = RuleText.replacing(crlf, at: 1, with: "uno")
        XCTAssertEqual(edited, "# Rules\r\n- uno\r\n- two\r\n")
        XCTAssertEqual(RuleText.lines(crlf).map(\.text), ["Rules", "one", "two"])
    }

    func testAddingALineMatchesTheList() {
        XCTAssertEqual(RuleText.appending("", "Be concise."), "- Be concise.\n", "a new file starts a list")
        XCTAssertEqual(RuleText.appending("- one\n", "two"), "- one\n- two\n")
        XCTAssertEqual(RuleText.appending("- one", "two"), "- one\n- two\n", "a missing final newline is supplied, not doubled")
        XCTAssertEqual(RuleText.appending("Plain words.\n", "More."), "Plain words.\nMore.\n")
        XCTAssertEqual(RuleText.appending("- one\n", "   "), "- one\n", "nothing to add, nothing written")
    }

    func testRuleFilesAlwaysOfferAPlaceForEachScope() {
        let home = URL(fileURLWithPath: "/Users/ada")
        let folder = URL(fileURLWithPath: "/tmp/pond")
        let none = CustomizeStore.ruleFiles(found: [], folder: folder, home: home)
        XCTAssertEqual(none.map(\.url.path), ["/tmp/pond/AGENTS.md", "/Users/ada/.config/frog/FROG.md"])
        XCTAssertTrue(none.allSatisfy { !$0.exists })
        let chat = CustomizeStore.ruleFiles(found: [], folder: nil, home: home)
        XCTAssertEqual(chat.map(\.scope), [.everywhere], "a chat has no project file")
        let found = CustomizeStore.ruleFiles(found: [URL(fileURLWithPath: "/Users/ada/.claude/CLAUDE.md"), URL(fileURLWithPath: "/tmp/pond/CLAUDE.md")],
                                             folder: folder, home: home)
        XCTAssertEqual(found.map(\.scope), [.project, .everywhere], "the project's first")
    }

    // MARK: Memory

    func testMemoryProjectKeyMatchesTheEngine() throws {
        XCTAssertEqual(MemoryFiles.key("/Users/me/my app"), "-Users-me-my-app")
        XCTAssertEqual(MemoryFiles.key("/a/b.c_d"), "-a-b.c_d")
        // A worktree's notes are its main checkout's.
        let root = try tempDir()
        let main = root.appending(path: "pond")
        let wt = root.appending(path: "wt")
        try FileManager.default.createDirectory(at: main.appending(path: ".git/worktrees/wt"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wt.appending(path: "src"), withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/wt\n".write(to: wt.appending(path: ".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MemoryFiles.projectRoot(wt.appending(path: "src")).path, main.path)
        XCTAssertEqual(MemoryFiles.projectRoot(main).standardizedFileURL.path, main.standardizedFileURL.path)
    }

    func testMemoryNotesLoadNewestFirst() throws {
        let home = try tempDir()
        let folder = try tempDir()
        let root = MemoryFiles.root(home: home)
        let global = root.appending(path: "global")
        let project = MemoryFiles.projectDir(root: root, folder: folder)
        for d in [global, project] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "---\nid: a\ncreated: 2026-10-21T10:00:00Z\nscope: global\nsource: user\n---\nWorks on a 64 GB Mac.\n".write(to: global.appending(path: "a.md"), atomically: true, encoding: .utf8)
        try "---\nid: b\ncreated: 2026-11-16T09:00:00Z\nscope: project\nsource: user\n---\nThe timer module is being rewritten.\n".write(to: project.appending(path: "b.md"), atomically: true, encoding: .utf8)
        try "A hand-written note.".write(to: global.appending(path: "c.md"), atomically: true, encoding: .utf8)
        try "".write(to: global.appending(path: "empty.md"), atomically: true, encoding: .utf8)
        let notes = MemoryFiles.load(home: home, folder: folder)
        XCTAssertEqual(notes.map(\.firstLine), ["The timer module is being rewritten.", "Works on a 64 GB Mac.", "A hand-written note."])
        XCTAssertEqual(notes.map(\.scope), [.project, .everywhere, .everywhere])
        XCTAssertEqual(MemoryFiles.load(home: home, folder: nil).count, 2, "a chat sees only notes for everywhere")
    }

    // MARK: Adding a connection

    func testPastedLinksAndCommands() throws {
        let link = try XCTUnwrap(ServerDraft.parse("https://mcp.supabase.com/mcp"))
        XCTAssertTrue(link.remote)
        XCTAssertEqual(link.name, "supabase")
        let npx = try XCTUnwrap(ServerDraft.parse("npx -y @modelcontextprotocol/server-postgres postgres://localhost/pond"))
        XCTAssertEqual(npx.command, "npx")
        XCTAssertEqual(npx.args, ["-y", "@modelcontextprotocol/server-postgres", "postgres://localhost/pond"])
        XCTAssertEqual(npx.name, "postgres")
        let env = try XCTUnwrap(ServerDraft.parse(#"GITHUB_TOKEN=abc uvx "mcp-server-git" --repo '/tmp/my repo'"#))
        XCTAssertEqual(env.env, ["GITHUB_TOKEN": "abc"])
        XCTAssertEqual(env.args, ["mcp-server-git", "--repo", "/tmp/my repo"])
        XCTAssertEqual(env.name, "git")
        XCTAssertNil(ServerDraft.parse("postgres"), "one plain word is a search")
        XCTAssertNil(ServerDraft.parse("   "))
        XCTAssertNotNil(ServerDraft.parse("/usr/local/bin/my-server"))
    }

    func testAddingToConfigAppendsAndKeepsEveryByte() throws {
        let dir = try tempDir()
        let config = dir.appending(path: "config.toml")
        let old = "# mine\nmodel = \"local/qwen3-4b\"\n\n[mcp_servers.github]\nurl = \"https://api.githubcopilot.com/mcp/\""
        try old.write(to: config, atomically: true, encoding: .utf8)
        let d = ServerDraft(name: "pg", command: "npx", args: ["-y", "a \"b\""], env: ["K": "v"])
        try d.appendToConfig(config)
        let new = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(new.hasPrefix(old + "\n"), "what was there stays, byte for byte")
        XCTAssertTrue(new.hasSuffix("[mcp_servers.pg]\ncommand = \"npx\"\nargs = [\"-y\", \"a \\\"b\\\"\"]\nenv = { K = \"v\" }\n"), new)
        XCTAssertThrowsError(try ServerDraft(name: "github", url: "https://x").appendToConfig(config)) {
            XCTAssertEqual($0 as? ServerDraft.AddError, .taken("github"))
        }
        // A config that doesn't exist yet is made.
        let fresh = dir.appending(path: "sub/config.toml")
        try ServerDraft(name: "docs", url: "https://docs.example/mcp").appendToConfig(fresh)
        XCTAssertEqual(try String(contentsOf: fresh, encoding: .utf8), "\n[mcp_servers.docs]\nurl = \"https://docs.example/mcp\"\n")
    }

    func testAddingToAProjectKeepsItsOtherServers() throws {
        let folder = try tempDir()
        let file = folder.appending(path: ".mcp.json")
        try #"{"mcpServers":{"fs":{"command":"fs-server"}},"other":1}"#.write(to: file, atomically: true, encoding: .utf8)
        try ServerDraft(name: "docs", url: "https://docs.example/mcp").addToProject(folder)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let servers = try XCTUnwrap(obj["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["fs", "docs"])
        XCTAssertEqual(obj["other"] as? Int, 1)
        XCTAssertEqual((servers["docs"] as? [String: String])?["url"], "https://docs.example/mcp")
        XCTAssertThrowsError(try ServerDraft(name: "fs", command: "x").addToProject(folder))

        try "not json".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ServerDraft(name: "y", command: "x").addToProject(folder)) {
            XCTAssertEqual($0 as? ServerDraft.AddError, .unreadable)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json", "a file Frog can't read is left alone")
    }

    // MARK: Rendering

    /// Made-up data in the shapes today's engine gives: names, descriptions, files, tools and
    /// withheld tools, rules text and notes, and no weights or use counts.
    static func stageFixture(_ store: CustomizeStore, figures: Bool = false) {
        let pond = URL(fileURLWithPath: "/tmp/pond")
        var skills = [
            CustomizeSkill(name: "release-notes", description: "Write release notes in pond's house style from merged pull requests.", path: "/tmp/pond/.frog/skills/release-notes/SKILL.md", project: true),
            CustomizeSkill(name: "db-migrations", description: "How to write and check a migration for pond's Postgres schema.", path: "/tmp/pond/.frog/skills/db-migrations/SKILL.md", project: true),
            CustomizeSkill(name: "commit", description: "Write a commit message from the staged changes.", path: "/Users/ada/.config/frog/skills/commit/SKILL.md", project: false),
            CustomizeSkill(name: "gh", description: "GitHub CLI: PRs, issues, CI checks; valid --json fields.", path: "frog-builtin:gh", project: false),
        ]
        if figures {
            let days = { (s: String) in s.map { Int(String($0)) ?? 0 } }
            let t = [140, 120, 160, 200]
            let u = ["000100010000100110001000120011", "000000000100000000000010000100", "121201221012210122101221012212", "000000000000000000000000000000"]
            for i in skills.indices { skills[i].tokensPerTurn = t[i]; skills[i].fullTokens = t[i] * 3; skills[i].uses = days(u[i]) }
        }
        let servers = [
            MCPStatus(name: "github", connected: true, error: nil, tools: (1...12).map { "mcp__github__tool_\($0)" }, quarantined: [], needsAuth: nil, declined: nil),
            MCPStatus(name: "figma", connected: true, error: nil, tools: (1...21).map { "mcp__figma__tool_\($0)" },
                      quarantined: [.init(tool: "mcp__figma__run_script", reason: "tells the model to ignore its instructions"),
                                    .init(tool: "mcp__figma__setup", reason: "asks the model to run a command")], needsAuth: nil, declined: nil),
            MCPStatus(name: "linear", connected: false, error: "Signed out: this server needs you to sign in.", tools: [], quarantined: [], needsAuth: true, declined: nil),
            MCPStatus(name: "pond-db", connected: true, error: nil, tools: ["mcp__pond-db__query", "mcp__pond-db__schema", "mcp__pond-db__explain"], quarantined: [], needsAuth: nil, declined: nil),
        ]
        let rules = [
            RuleFile(url: pond.appending(path: "AGENTS.md"), scope: .project, text: """
                # pond

                - Use pnpm in this project, never npm.
                - Tests live in spec/, one file per module. Run them with pnpm test.
                - Never edit files under generated/. Change the schema and run pnpm codegen.
                - Commit messages start with the area, then a colon: "timer: fix drift after sleep".
                - Pull requests say what was tested and what was not.
                """, exists: true),
            RuleFile(url: URL(fileURLWithPath: "/Users/ada/.config/frog/FROG.md"), scope: .everywhere, text: """
                - Be concise. Skip explanations I didn't ask for.
                - Never force-push or reset --hard without asking.
                - Prefer early returns to nested conditions.
                """, exists: true),
        ]
        let iso = ISO8601DateFormatter()
        let note = { (id: String, date: String, scope: MemoryNote.Scope, body: String) in
            MemoryNote(id: id, created: iso.date(from: date), scope: scope, body: body, url: URL(fileURLWithPath: "/tmp/notes/\(id).md"))
        }
        let notes = [
            note("timer", "2026-11-16T10:00:00Z", .project, "The timer module is being rewritten in #212; avoid large edits there."),
            note("staging", "2026-11-12T10:00:00Z", .project, "The staging database is reset every Monday; don't rely on data there."),
            note("reviews", "2026-11-09T10:00:00Z", .project, "Reviews happen in the morning; open pull requests before 9."),
            note("langs", "2026-10-28T10:00:00Z", .everywhere, "Prefers Rust and TypeScript; uses npm outside pond."),
            note("mac", "2026-10-21T10:00:00Z", .everywhere, "Works on a 64 GB Mac and a paired GPU box called mew."),
        ]
        store.home = URL(fileURLWithPath: "/Users/ada")
        store.stage(folder: pond, skills: skills, servers: servers, projectServers: ["pond-db"], rules: rules, notes: notes)
    }

    /// The window in Customize mode, one image per page, dark and light.
    func testRenderCustomizeMode() throws {
        CustomizeStore.loads = false
        defer { CustomizeStore.loads = true }
        let pages: [(String, String, CustomizePage?, Bool)] = [
            ("skills", "skills", nil, false),
            ("skills", "skills-with-engine-figures", nil, true),
            ("connections", "connections", nil, false),
            ("rules", "rules", nil, false),
            ("memory", "memory", nil, false),
            ("automations", "automations", nil, false),
            ("skills", "skill", .skill("release-notes"), false),
            ("connections", "add", .add("connections"), false),
            ("connections", "review", .review(ServerDraft.parse("https://mcp.supabase.com/mcp")!), false),
        ]
        for (look, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            for (section, file, page, figures) in pages {
                let panes = Panes(Workspace(folder: URL(fileURLWithPath: "/tmp/pond"), fresh: true))
                defer { panes.stopAll() }
                panes.showCustomize(section)
                Self.stageFixture(panes.customize, figures: figures)
                panes.customizePage = page
                let (w, host) = window(panes, appearance: look)
                pump(0.6)
                try snapshot(host, "mac-customize-\(file)-\(name)")
                w.close()
            }
        }
        print("snapshots: \(outDir.path)")
    }

    /// The title bar's toolbar doesn't draw offscreen, so its two Customize pieces render here:
    /// the breadcrumbs, and the right side's figure and action.
    func testRenderCustomizeHeader() throws {
        CustomizeStore.loads = false
        defer { CustomizeStore.loads = true }
        let cases: [(String, String, CustomizePage?)] = [
            ("memory", "memory", nil), ("connections", "connections", nil), ("skills", "skill", .skill("release-notes")),
            ("connections", "review", .review(ServerDraft.parse("https://mcp.supabase.com/mcp")!)),
        ]
        for (look, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            for (section, file, page) in cases {
                let panes = Panes(Workspace(folder: URL(fileURLWithPath: "/tmp/pond"), fresh: true))
                defer { panes.stopAll() }
                panes.showCustomize(section)
                Self.stageFixture(panes.customize)
                panes.customizePage = page
                let bar = HStack { CustomizeCrumbs(panes: panes); Spacer(); CustomizeHeaderTrailing(panes: panes) }
                    .padding(.horizontal, 20).frame(width: 1030, height: 50).background(FrogCanvas.color)
                let host = NSHostingView(rootView: bar)
                host.frame = CGRect(x: 0, y: 0, width: 1030, height: 50)
                host.appearance = NSAppearance(named: look)
                host.layoutSubtreeIfNeeded()
                pump(0.2)
                try snapshot(host, "mac-customize-header-\(file)-\(name)")
            }
        }
    }

    private func window(_ panes: Panes, size: CGSize = CGSize(width: 1280, height: 800),
                        appearance: NSAppearance.Name = .darkAqua) -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(rootView: WorkspaceView(panes: panes).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: appearance)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(0.6)
        host.layoutSubtreeIfNeeded()
        return (w, host)
    }

    private func snapshot(_ host: NSView, _ name: String) throws {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appending(path: "\(name).png"))
    }
}
