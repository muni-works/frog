import AppKit
import SwiftUI

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
