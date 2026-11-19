import AppKit
import SwiftUI

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
