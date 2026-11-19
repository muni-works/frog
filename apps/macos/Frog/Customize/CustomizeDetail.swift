import AppKit
import SwiftUI

// MARK: - A skill (F2Skill)

/// A skill opened: plain Settings rows (Use this skill, Weight, Used, File, Try it), then the
/// text Frog reads when the skill is used.
struct SkillPage: View {
    let store: CustomizeStore
    let name: String
    let tryIt: () -> Void

    var body: some View {
        SettingsPage(title: "/\(name)") {
            if let skill = store.skills?.first(where: { $0.name == name }) {
                SettingsRows {
                    SettingsRow("Use this skill", description: "\(skill.description) \(where_(skill))") {
                        if let on = skill.on {
                            FrogToggle(label: "Use this skill", isOn: Binding(get: { on }, set: { store.change(.skill(name: skill.name, on: $0)) }))
                        } else {
                            SettingsValue("On", help: "Frog uses every skill it finds. This Frog can't switch one off yet.")
                        }
                    }
                    if let t = skill.tokensPerTurn {
                        SettingsRow("Weight", description: skill.fullTokens.map { "Its summary on every turn. The full text, \(CustomizeFormat.tokens($0)), only when it's used." } ?? "Its summary on every turn.") {
                            SettingsValue("\(CustomizeFormat.tokens(t)) a turn")
                        }
                    }
                    if let uses = skill.uses {
                        let n = uses.reduce(0, +)
                        SettingsRow("Used", description: (skill.lastUsed.map { "Last in \u{201C}\($0)\u{201D}. " } ?? "") + "The marks are the last \(uses.count) days.") {
                            HStack(spacing: 16) {
                                ActivityMarks(days: uses)
                                SettingsValue(n == 0 ? "never" : "\(n) time\(n == 1 ? "" : "s")")
                            }
                        }
                    }
                    if let file = skill.file {
                        SettingsRow("File", description: shown(file)) {
                            HStack(spacing: 8) {
                                Button("Open in editor") { CustomizeFiles.open(file) }.buttonStyle(CustomizePillStyle())
                                    .help("Open SKILL.md in the app your Mac opens it with")
                                Button("Show in Finder") { CustomizeFiles.reveal(file) }.buttonStyle(CustomizePillStyle())
                            }
                        }
                    }
                    SettingsRow("Try it", description: "Run it once in a new conversation to see what it does.") {
                        Button("Try it", action: tryIt).buttonStyle(CustomizePillStyle())
                            .help("Start a conversation with /\(name)")
                    }
                }
                if let file = skill.file, let text = Self.body(of: file) {
                    SettingsGroupLabel(text: "What Frog reads")
                    Text(text)
                        .font(.frog(size: 12.5, design: .monospaced))
                        .foregroundStyle(Tokens.textSecondary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 16).padding(.horizontal, 20)
                        .background(Tokens.sidebar, in: .rect(cornerRadius: 12))
                        .padding(.top, 4)
                }
            } else if store.skills == nil {
                CustomizeLoading()
            } else {
                SettingsRows { SettingsRow("There's no /\(name) here any more", description: "It may have been moved or removed.") { EmptyView() } }
            }
        }
    }

    private func where_(_ s: CustomizeSkill) -> String {
        if s.builtIn { return "Built into Frog." }
        return s.project ? "In \(store.projectName ?? "this project")." : "Everywhere."
    }

    private func shown(_ url: URL) -> String {
        if let folder = store.folder, url.path.hasPrefix(folder.path + "/") { return String(url.path.dropFirst(folder.path.count + 1)) }
        let home = store.home.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// The file without its frontmatter: what the model is given.
    static func body(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Find and add (F9Find)

/// Find and add: paste a server's command or link to review it. Searching Frog's catalog has no
/// backend yet, and says so.
struct AddPage: View {
    let store: CustomizeStore
    let section: String
    let review: (ServerDraft) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        SettingsPage(title: "Add") {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tokens.textTertiary)
                TextField("", text: $query, prompt: Text("Search, or paste a server's command or link"))
                    .textFieldStyle(.plain)
                    .font(.frog(size: 14))
                    .focused($focused)
                    .onSubmit { if let d = ServerDraft.parse(query) { review(d) } }
                    .accessibilityLabel("Search for a skill or a connection, or paste a link or command")
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(Tokens.raised, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tokens.lineStrong))
            Text("Paste a server's link (https://…) or the command that starts it (npx -y …), and Frog shows what it would be before adding it. Or say \"connect Postgres\" in any conversation.")
                .font(.frog(size: 12.5)).foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            if let draft = ServerDraft.parse(query) {
                SettingsGroupLabel(text: "What you pasted")
                SettingsRows {
                    SettingsRow(draft.name, description: draft.remote ? "A connection on its own servers: \(draft.shown)" : "A connection that runs on this Mac: \(draft.shown)") {
                        Button("Review") { review(draft) }.buttonStyle(CustomizePillStyle())
                            .help("See what it would be before adding it; nothing runs yet")
                    }
                }
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                CatalogStub()
            }
        }
        .onAppear { focused = true }
    }
}

/// Where catalog results will go: plainly not built yet, with no made-up results.
private struct CatalogStub: View {
    var body: some View {
        SettingsGroupLabel(text: "Frog's catalog")
        SettingsRows {
            SettingsRow("Search isn't here yet", description: "A catalog of skills and connections Frog has tested comes later. For now, paste a server's link or command.") {
                Text("Not yet").font(.frog(size: 12.5)).foregroundStyle(Tokens.textTertiary)
            }
        }
    }
}

// MARK: - Review (F10Review)

/// What a pasted server would be, before it's added: where it comes from, where it runs, and
/// where it goes. Its tools are unknown until it's added, since nothing runs before then.
struct ReviewPage: View {
    let panes: Panes
    let draft: ServerDraft
    private var store: CustomizeStore { panes.customize }

    var body: some View {
        @Bindable var store = store
        SettingsPage(title: draft.name) {
            SettingsRows {
                SettingsRow("Name", description: "What Frog and its tools call it.") {
                    FrogField(label: "Name", text: Binding(get: { draft.name }, set: { n in
                        var d = draft
                        d.name = n.trimmingCharacters(in: .whitespaces)
                        if !d.name.isEmpty { panes.customizePage = .review(d) }
                    }))
                }
                SettingsRow("From", description: draft.shown) {
                    SettingsValue(draft.remote ? "A link" : "A command", help: "As you pasted it; nothing has run")
                }
                SettingsRow("Runs", description: draft.remote ? "On its own servers. Your code stays on this Mac, and it sees only what its tools are given."
                                                           : "On this Mac, as its own program, with your permissions. Only add one you trust.") {
                    SettingsValue(draft.remote ? "Remote" : "This Mac")
                }
                if draft.remote {
                    SettingsRow("Sign-in", description: "If it asks, in your browser, after adding.") { SettingsValue("Maybe") }
                }
                if let project = store.projectName {
                    SettingsRow("Where", description: store.reviewEverywhere ? "Every project, from ~/.config/frog/config.toml." : "Only \(project), from its .mcp.json, so the people you share it with get it too.") {
                        FrogSegmented(label: "Where", options: [.init(id: "project", label: project), .init(id: "everywhere", label: "Everywhere")],
                                      selection: Binding(get: { store.reviewEverywhere ? "everywhere" : "project" },
                                                         set: { store.reviewEverywhere = $0 == "everywhere" }))
                    }
                } else {
                    SettingsRow("Where", description: "Every project, from ~/.config/frog/config.toml.") { SettingsValue("Everywhere") }
                }
            }
            SettingsGroupLabel(text: "Tools")
            Text("Frog can't see its tools until it's added: nothing runs before then. Once it's added, Connections shows each one, and withholds any whose description reads like instructions to the model.")
                .font(.frog(size: 12.5)).foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = store.reviewProblem {
                Text(problem).font(.frog(size: 12.5)).foregroundStyle(Tokens.warn).padding(.top, 12)
            }
        }
    }
}

/// The review's header: Cancel, and Add where the page says.
struct ReviewActions: View {
    let panes: Panes
    let draft: ServerDraft
    private var store: CustomizeStore { panes.customize }

    var body: some View {
        HStack(spacing: 8) {
            Button("Cancel") { store.reviewProblem = nil; panes.customizePage = .add(panes.customizeSection) }
                .buttonStyle(CustomizePillStyle())
            Button(addLabel) {
                if store.add(draft) { panes.showCustomize("connections"); panes.customizePage = nil }
            }
            .buttonStyle(CustomizePillStyle(primary: true))
            .help(store.folder == nil || store.reviewEverywhere ? "Adds it to ~/.config/frog/config.toml" : "Adds it to the project's .mcp.json")
        }
    }

    private var addLabel: String {
        guard let p = store.projectName, !store.reviewEverywhere else { return "Add everywhere" }
        return "Add to \(p)"
    }
}
