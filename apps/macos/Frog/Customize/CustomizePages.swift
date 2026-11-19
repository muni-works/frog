import AppKit
import SwiftUI

// MARK: - Skills (F1Skills)

/// Skills: the weight card (once the engine reports weights), then a row per skill under In
/// <project> and Everywhere. A row opens the skill.
struct SkillsPage: View {
    let store: CustomizeStore
    let open: (String) -> Void

    var body: some View {
        CustomizeListPage(section: "skills") {
            if let skills = store.skills {
                if let card = WeightCard(skills: skills, budget: store.report?.skills.budgetTokens) { card }
                if skills.isEmpty {
                    SettingsRows {
                        SettingsRow("No skills yet", description: "Add one with Add a skill, or put a SKILL.md in a folder under .frog/skills in a project.") { EmptyView() }
                    }
                }
                ForEach(Self.groups(skills, project: store.projectName), id: \.label) { g in
                    SettingsGroupLabel(text: g.label)
                    SettingsRows {
                        ForEach(g.skills) { s in SkillRow(skill: s, change: store.change) { open(s.name) } }
                    }
                }
            } else {
                CustomizeLoading()
            }
        }
    }

    /// In <project> first, then everywhere (the home folder's and Frog's own).
    static func groups(_ skills: [CustomizeSkill], project: String?) -> [(label: String, skills: [CustomizeSkill])] {
        let mine = skills.filter(\.project)
        let all = skills.filter { !$0.project }
        var out: [(String, [CustomizeSkill])] = []
        if !mine.isEmpty { out.append(("In \(project ?? "this project")", mine)) }
        if !all.isEmpty { out.append(("Everywhere", all)) }
        return out
    }
}

/// "Weight on every turn": shown only when the engine has given every skill's weight.
private struct WeightCard: View {
    let parts: [WeightBar.Part]
    let total: Int
    let budget: Int

    /// Nil until the engine gives every skill's weight and use, and the budget they share.
    init?(skills: [CustomizeSkill], budget: Int?) {
        guard let budget, !skills.isEmpty, skills.allSatisfy({ $0.tokensPerTurn != nil && $0.uses != nil }) else { return nil }
        self.budget = budget
        parts = skills.map { .init(name: $0.name, tokens: $0.tokensPerTurn!, idle: ($0.uses ?? []).reduce(0, +) == 0) }
        total = parts.map(\.tokens).reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weight on every turn").font(.frog(size: 13, weight: .semibold))
                Spacer()
                Text("\(total.formatted()) of \(budget.formatted()) tokens").font(.frog(size: 12.5)).foregroundStyle(Tokens.textSecondary).monospacedDigit()
            }
            WeightBar(parts: parts, budget: budget)
            Text("Each bar is one skill's summary. An outlined one hasn't been used in 30 days.")
                .font(.frog(size: 12.5)).foregroundStyle(Tokens.textTertiary)
        }
        .padding(.vertical, 14).padding(.horizontal, 18)
        .background(CustomizeLook.card, in: .rect(cornerRadius: 14))
    }
}

private struct SkillRow: View {
    let skill: CustomizeSkill
    var change: (CustomizeChange) -> Void = { _ in }
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("/\(skill.name)").font(.frog(size: 13, design: .monospaced))
                        .foregroundStyle(idle ? Tokens.textSecondary : Tokens.text)
                    Text(skill.builtIn ? "\(skill.description) Built into Frog." : skill.description)
                        .font(.frog(size: 12.5)).foregroundStyle(Tokens.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let uses = skill.uses {
                    let n = uses.reduce(0, +)
                    // No recorded use: no row of empty ticks, just the word, in the same column.
                    if n > 0 { ActivityMarks(days: uses) } else { Color.clear.frame(width: ActivityMarks.width(uses.count), height: 1) }
                    Text(n == 0 ? "never" : "\(n)").font(.frog(size: 12.5)).monospacedDigit()
                        .foregroundStyle(n == 0 ? Tokens.textTertiary : Tokens.textSecondary)
                        .frame(width: 34, alignment: .trailing)
                }
                if skill.on == nil {
                    Image(systemName: "chevron.right").font(.frog(size: 10, weight: .semibold)).foregroundStyle(Tokens.textTertiary)
                }
            }
            .padding(.vertical, 11)
            .contentShape(.rect)
            .background(alignment: .center) {
                if hovering { RoundedRectangle(cornerRadius: 8).fill(CustomizeLook.hot).padding(.horizontal, -10) }
            }
        }
        .buttonStyle(.plain)
        // Room for the engine's switch, then the switch in it: beside the row's button, not
        // inside it, and never over the count.
        .padding(.trailing, skill.on == nil ? 0 : 52)
        .overlay(alignment: .trailing) {
            if let on = skill.on {
                FrogToggle(label: skill.name, isOn: Binding(get: { on }, set: { change(.skill(name: skill.name, on: $0)) }))
            }
        }
        .onHover { hovering = $0 }
        .help("Open /\(skill.name): its file, and how to try it")
        .accessibilityLabel("/\(skill.name)")
        .accessibilityHint(skill.description)
    }

    private var idle: Bool { skill.uses.map { $0.reduce(0, +) == 0 } ?? false }
}

// MARK: - Connections (F3Connections)

/// Connections: each server with its tools as squares, the sign-in it wants, and the old
/// Settings page's Refresh and config.toml under them.
struct ConnectionsPage: View {
    let store: CustomizeStore

    var body: some View {
        CustomizeListPage(section: "connections") {
            if let list = store.connections {
                if list.isEmpty {
                    SettingsRows {
                        SettingsRow("No connections yet", description: "Add one with Add a connection. A project can bring its own in a .mcp.json file.") { EmptyView() }
                    }
                } else {
                    SettingsRows {
                        ForEach(list) { c in ConnectionRow(connection: c, store: store) }
                    }
                    ConnectionsKey(squares: list.flatMap(\.squares))
                }
                if let problem = store.changeProblem {
                    Text(problem).font(.frog(size: 12.5)).foregroundStyle(Tokens.warn).padding(.top, 8)
                }
            } else {
                SettingsRows { SettingsRow("Connecting…") { ProgressView().controlSize(.small) } }
            }
            SettingsGroupLabel(text: "Servers")
            SettingsRows {
                SettingsRow("Ask each server again", description: "Connections are checked when Customize opens.") {
                    Button("Refresh") { Task { await store.loadServers() } }.buttonStyle(SettingsButtonStyle())
                        .help("Ask each server again")
                }
                SettingsRow("Servers in config.toml", description: "Add or change a server by hand.") { OpenConfigButton() }
            }
        }
    }

    /// A server's tools from `frog --mcp`: the ones it offers, then the ones withheld.
    nonisolated static func squares(_ s: MCPStatus) -> [ToolSquares.Square] {
        s.tools.map { .init(tool: shortName($0, server: s.name), state: .on) }
            + s.quarantined.map { .init(tool: shortName($0.tool, server: s.name), state: .withheld, reason: $0.reason) }
    }

    /// `mcp__github__list_issues` → `list_issues`.
    nonisolated static func shortName(_ tool: String, server: String) -> String {
        let prefix = "mcp__\(server)__"
        return tool.hasPrefix(prefix) ? String(tool.dropFirst(prefix.count)) : tool
    }

    /// The line under a connection's squares.
    static func say(_ c: CustomizeConnection, project: String?) -> (lead: String?, rest: String) {
        var rest: [String] = []
        var lead: String?
        let held = c.squares.filter { $0.state == .withheld }.count
        let usable = c.squares.count - held
        let on = c.squares.filter { $0.state == .on }.count
        switch c.state {
        case .connected:
            let anyOff = c.squares.contains { $0.state == .off }
            lead = anyOff ? "\(on) of \(usable) tools on." : "\(usable) tool\(usable == 1 ? "" : "s")."
            if held > 0 {
                rest.append("\(held) \(held == 1 ? "is" : "are") withheld: \(held == 1 ? "its description reads" : "their descriptions read") like instructions to the model.")
            }
            if let n = c.calls { rest.append(n == 0 ? "Never called." : "\(n) call\(n == 1 ? "" : "s") in the last 30 days.") }
        case .needsSignIn, .declined:
            rest.append("Wants you to sign in. Frog can't see its tools until you do.")
            if c.state == .declined { rest.append("You declined before.") }
        case .off:
            rest.append("Off. Its tools aren't offered to Frog.")
        case .connecting, .unknown:
            rest.append("Connecting.")
        case .failed:
            rest.append(c.error ?? "Not connected.")
        }
        if c.fromProject { rest.append("Came with \(project ?? "the project")'s .mcp.json.") }
        return (lead, rest.joined(separator: " "))
    }
}

private struct ConnectionRow: View {
    let connection: CustomizeConnection
    let store: CustomizeStore

    var body: some View {
        let c = connection
        let say = ConnectionsPage.say(c, project: store.projectName)
        HStack(alignment: .top, spacing: 22) {
            HStack(spacing: 8) {
                if c.wantsSignIn { NeedsYouDot() }
                Text(c.name).font(.frog(size: 14, weight: .semibold)).lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if !c.squares.isEmpty {
                    ToolSquares(squares: c.squares) { sq, on in
                        if let key = sq.exposed { store.change(.tool(exposed: key, on: on)) }
                    }
                    .padding(.top, 5)
                }
                (Text(say.lead.map { $0 + " " } ?? "").foregroundStyle(Tokens.textSecondary) + Text(say.rest).foregroundStyle(Tokens.textTertiary))
                    .font(.frog(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, c.squares.isEmpty ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(c.name)
    }

    @ViewBuilder
    private var control: some View {
        let c = connection
        HStack(spacing: 12) {
            if let t = c.tokens, c.state == .connected {
                Text(CustomizeFormat.tokens(t)).font(.frog(size: 12.5)).foregroundStyle(Tokens.textSecondary).monospacedDigit()
                    .help("About this much on every turn, for the tools that are on")
            }
            if c.wantsSignIn {
                if store.signingIn.contains(c.name) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Sign in") { store.signIn(c.name) }.buttonStyle(CustomizePillStyle()).fixedSize()
                        .help(c.state == .declined ? "Opens \(c.name)'s sign-in in your browser (you declined before)" : "Opens \(c.name)'s sign-in in your browser")
                }
            } else if let on = c.on {
                FrogToggle(label: c.name, isOn: Binding(get: { on }, set: { store.change(.connection(name: c.name, on: $0)) }))
                    .help(on ? "Stop offering \(c.name)'s tools to Frog" : "Offer \(c.name)'s tools to Frog")
            } else if c.state != .connected {
                SettingsValue("Not connected")
            }
        }
        .fixedSize()
    }
}

/// What the squares mean.
private struct ConnectionsKey: View {
    let squares: [ToolSquares.Square]
    var body: some View {
        HStack(spacing: 18) {
            key(ToolSquares.Square(tool: "", state: .on), "a tool Frog can use")
            if squares.contains(where: { $0.state == .off }) { key(.init(tool: "", state: .off), "off") }
            if squares.contains(where: { $0.state == .withheld }) { key(.init(tool: "", state: .withheld), "withheld") }
            Text("Select a square to see the tool.")
        }
        .font(.frog(size: 12))
        .foregroundStyle(Tokens.textTertiary)
        .padding(.top, 14)
        .accessibilityHidden(true)
    }

    private func key(_ s: ToolSquares.Square, _ words: String) -> some View {
        HStack(spacing: 6) {
            ToolSquares(squares: [s]).allowsHitTesting(false).fixedSize()
            Text(words)
        }
    }
}

// MARK: - Rules (F4Instructions, titled Rules)

/// Rules: one flat card per rules file, under In <project> and Everywhere. A card shows its
/// first lines and opens in place to the rest, where Edit and Remove wait on each line and a
/// line can be added at the foot. A project with many files reads as a short stack to scan.
struct RulesPage: View {
    let store: CustomizeStore

    var body: some View {
        CustomizeListPage(section: "rules") {
            if let files = store.rules {
                ForEach(Self.groups(files, project: store.projectName), id: \.label) { g in
                    SettingsGroupLabel(text: g.label)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(g.files) { f in RuleCard(store: store, file: f) }
                    }
                }
            } else {
                CustomizeLoading()
            }
        }
    }

    static func groups(_ files: [RuleFile], project: String?) -> [(label: String, files: [RuleFile])] {
        let mine = files.filter { $0.scope == .project }
        let all = files.filter { $0.scope == .everywhere }
        var out: [(String, [RuleFile])] = []
        if !mine.isEmpty { out.append(("In \(project ?? "this project")", mine)) }
        if !all.isEmpty { out.append(("Everywhere", all)) }
        return out
    }
}

private struct RuleCard: View {
    let store: CustomizeStore
    let file: RuleFile
    /// Lines a closed card shows.
    static let preview = 6
    @State private var expanded = false
    @State private var editing: Int?
    @State private var draft = ""
    @State private var adding = ""
    @State private var problem: String?

    private var lines: [RuleLine] { RuleText.lines(file.text) }
    private var scopeName: String { file.scope == .project ? (store.projectName ?? "this project") : "everywhere" }
    /// Short enough to show whole, or opened.
    private var open: Bool { expanded || lines.count <= Self.preview }

    var body: some View {
        let lines = lines
        VStack(alignment: .leading, spacing: 0) {
            head
            if !file.exists || lines.isEmpty {
                Text(file.exists ? "Nothing in it yet." : "Not made yet. Adding a line makes it.")
                    .font(.frog(size: 12.5)).foregroundStyle(Tokens.textTertiary)
                    .padding(.vertical, 5)
            }
            ForEach(open ? lines : Array(lines.prefix(Self.preview))) { l in
                RuleLineRow(line: l, editing: editing == l.index, draft: $draft,
                            edit: { draft = l.text; editing = l.index },
                            commit: { change(expect: l) { RuleText.replacing($0, at: l.index, with: draft) }; editing = nil },
                            cancel: { editing = nil },
                            remove: { change(expect: l) { RuleText.removing($0, at: l.index) } })
            }
            if lines.count > Self.preview {
                Button(expanded ? "Show fewer" : "Show all \(lines.count) lines") {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                }
                .buttonStyle(CustomizeLinkStyle())
                .padding(.top, 6)
                .padding(.bottom, open ? 4 : 0)
            }
            if open {
                TextField("Add a line for \(scopeName)", text: $adding)
                    .textFieldStyle(.plain)
                    .font(.frog(size: 14))
                    .onSubmit {
                        let words = adding
                        change(expect: nil) { RuleText.appending($0, words) }
                        adding = ""
                    }
                    .accessibilityLabel("Add a line to \(file.url.lastPathComponent)")
                    .padding(.vertical, 6)
            }
            if let problem {
                Text(problem).font(.frog(size: 12)).foregroundStyle(Tokens.warn).padding(.top, 4)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CustomizeLook.card, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(file.url.lastPathComponent)
    }

    /// The file's name, whose it is, where it applies and its weight, and the file itself.
    private var head: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(file.url.lastPathComponent).font(.frog(size: 13.5, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if file.fromClaudeCode {
                    Text("Read in place from Claude Code").font(.frog(size: 12)).foregroundStyle(Tokens.textTertiary)
                        .help("Frog reads this file where Claude Code keeps it and never copies it")
                }
                Spacer(minLength: 12)
                if file.exists {
                    Button("Open in editor") { CustomizeFiles.open(file.url) }
                        .buttonStyle(CustomizeLinkStyle())
                        .help("Open \(file.url.lastPathComponent) in the app your Mac opens it with")
                    Button("Show in Finder") { CustomizeFiles.reveal(file.url) }
                        .buttonStyle(CustomizeLinkStyle())
                        .help("Show \(file.url.lastPathComponent) in Finder")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // The path when it says more than the name: a subfolder, or the home folder.
                if shownPath != file.url.lastPathComponent {
                    Text(shownPath).font(.frog(size: 11.5, design: .monospaced)).foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(file.appliesText).font(.frog(size: 12)).foregroundStyle(Tokens.textTertiary).lineLimit(1)
                Spacer(minLength: 12)
                if let weight = file.weightText {
                    Text(weight).font(.frog(size: 12)).foregroundStyle(Tokens.textSecondary).monospacedDigit()
                }
            }
        }
        .padding(.bottom, 10)
    }

    private var shownPath: String {
        if file.scope == .project, let folder = store.folder, file.url.path.hasPrefix(folder.path + "/") {
            return String(file.url.path.dropFirst(folder.path.count + 1))
        }
        let home = store.home.path
        return file.url.path.hasPrefix(home + "/") ? "~" + file.url.path.dropFirst(home.count) : file.url.path
    }

    /// Reads the file as it is on disk now, checks the line is still the one on screen, applies
    /// the change and writes it. If someone changed the file meanwhile, nothing is written.
    private func change(expect line: RuleLine?, _ apply: (String) -> String) {
        problem = nil
        let disk = file.exists ? ((try? String(contentsOf: file.url, encoding: .utf8)) ?? file.text) : ""
        if let line, !RuleText.lines(disk).contains(line) {
            problem = "\(file.url.lastPathComponent) changed since it was read. Nothing was written; here it is again."
            Task { await store.loadRules() }
            return
        }
        let next = apply(disk)
        guard next != disk else { return }
        do { try store.write(file, next) } catch { problem = "Couldn't write \(file.url.lastPathComponent): \(error.localizedDescription)" }
    }
}

private struct RuleLineRow: View {
    let line: RuleLine
    let editing: Bool
    @Binding var draft: String
    let edit: () -> Void
    let commit: () -> Void
    let cancel: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if editing {
                TextField("Rule", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.frog(size: 14))
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .accessibilityLabel("Edit this rule")
                Button("Save", action: commit).buttonStyle(CustomizeLinkStyle())
                Button("Cancel", action: cancel).buttonStyle(CustomizeLinkStyle())
            } else {
                text.frame(maxWidth: .infinity, alignment: .leading)
                if line.editable {
                    HStack(spacing: 12) {
                        Button("Edit", action: edit).buttonStyle(CustomizeLinkStyle())
                        Button("Remove", action: remove).buttonStyle(CustomizeLinkStyle())
                            .help("Take this line out of the file")
                    }
                    .opacity(hovering ? 1 : 0)
                    // Still reachable without a pointer.
                    .accessibilityHidden(false)
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(hovering || editing ? CustomizeLook.hot : .clear, in: .rect(cornerRadius: 8))
        .padding(.horizontal, -10)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var text: some View {
        switch line.kind {
        case .heading:
            Text(line.text).font(.frog(size: 12.5, weight: .semibold)).foregroundStyle(Tokens.textSecondary).padding(.top, 6)
        case .code:
            Text(line.text).font(.frog(size: 12.5, design: .monospaced)).foregroundStyle(Tokens.textSecondary)
        case .item, .plain:
            Text(line.text).font(.frog(size: 14)).foregroundStyle(Tokens.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A quiet underlined link-button (Open in editor, Edit, Remove).
struct CustomizeLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.frog(size: 12.5))
            .foregroundStyle(Tokens.textSecondary)
            .underline(color: Tokens.lineStrong)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(.rect)
    }
}

// MARK: - Memory (F5Memory)

/// Memory: a dated rail of the notes Frog kept, newest at the top, each with where it applies;
/// hover one to Forget it.
struct MemoryPage: View {
    let store: CustomizeStore

    var body: some View {
        CustomizeListPage(section: "memory") {
            if let notes = store.notes {
                if notes.isEmpty {
                    SettingsRows {
                        SettingsRow("No notes yet", description: "Say \"remember this\" in any conversation and Frog keeps a note here.") { EmptyView() }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(notes.enumerated()), id: \.element.url) { i, n in
                            MemoryEvent(note: n, newest: i == 0, project: store.projectName) { store.forget(n) }
                        }
                    }
                    .background(alignment: .topLeading) {
                        Rectangle().fill(Tokens.line).frame(width: 1).padding(.leading, 83).padding(.vertical, 10)
                    }
                }
            } else {
                CustomizeLoading()
            }
        }
    }
}

private struct MemoryEvent: View {
    let note: MemoryNote
    let newest: Bool
    let project: String?
    let forget: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(note.created.map { CustomizeFormat.day.string(from: $0) } ?? "")
                .font(.frog(size: 12)).foregroundStyle(Tokens.textTertiary).monospacedDigit()
                .frame(width: 64, alignment: .trailing)
                .padding(.top, 2)
            Circle()
                .fill(newest ? Tokens.text : (hovering ? CustomizeLook.card : FrogCanvas.color))
                .overlay { if !newest { Circle().strokeBorder(Tokens.textTertiary, lineWidth: 1.5) } }
                .frame(width: 9, height: 9)
                .padding(.top, 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.body)
                    .font(.frog(size: 14))
                    .foregroundStyle(Tokens.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let from = note.from {
                    Text("from \u{201C}\(from)\u{201D}").font(.frog(size: 12.5)).foregroundStyle(Tokens.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                Text(note.scope == .project ? (project ?? "this project") : "everywhere")
                    .font(.frog(size: 12)).foregroundStyle(Tokens.textTertiary)
                    .opacity(hovering ? 0 : 1)
                Button("Forget", action: forget).buttonStyle(CustomizePillStyle())
                    .help("Move this note to the Trash. Sessions open now keep it until they start again.")
                    .opacity(hovering ? 1 : 0)
            }
            .fixedSize()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, hovering ? 12 : 0)
        .background(hovering ? CustomizeLook.card : .clear, in: .rect(cornerRadius: 10))
        .padding(.horizontal, hovering ? -12 : 0)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note.created.map { "Noted \(CustomizeFormat.day.string(from: $0))" } ?? "Note")
    }
}

// MARK: - Automations (F6Automations)

/// Automations: there's no engine for them yet, so the page says how one will be made and
/// shows no week grid and no made-up runs.
struct AutomationsPage: View {
    var body: some View {
        CustomizeListPage(section: "automations") {
            VStack(alignment: .leading, spacing: 6) {
                Text("No automations yet")
                    .font(.frog(size: 14, weight: .semibold))
                Text("Frog can't repeat a task on its own yet. When it can, you'll make an automation by doing the task once in a conversation and saying \"keep doing this\". Each one's week shows here: every run, what it cost in dollars, and any run that waits on you.")
                    .font(.frog(size: 12.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)
        }
    }
}
