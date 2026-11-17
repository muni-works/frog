import SwiftUI

/// The composer's words and the preview (docs/design/composer/spec.md). The parts live in
/// Card.swift, StatusLine.swift and WhereMenu.swift: they render `ComposerModel.State` and send
/// intents, so the live composer, the parity shots and the snapshots draw the same.

extension Color {
    /// A PR's dot (the `pr.*` tokens).
    static func pr(_ state: ComposerModel.PrState) -> Color {
        switch state {
        case .failing: Tokens.prFailing
        case .checks: Tokens.prChecks
        case .draft: Tokens.prDraft
        case .approved: Tokens.prApproved
        case .closed: Tokens.prClosed
        case .merged: Tokens.prMerged
        }
    }
}

extension ComposerModel.PrState {
    var word: String {
        switch self {
        case .failing: "Failing"
        case .checks: "Checks running"
        case .draft: "Draft"
        case .approved: "Approved"
        case .closed: "Closed"
        case .merged: "Merged"
        }
    }
}

extension ComposerModel.GitAction {
    var label: String {
        switch self {
        case .commit: "Commit"
        case .open_pr: "Open PR"
        case .push: "Push"
        case .fix: "Fix"
        case .merge: "Merge"
        case .archive: "Archive"
        case .reopen: "Reopen"
        }
    }
}

extension ComposerModel.Mode {
    var label: String {
        switch self {
        case .auto: "Auto"
        case .default: "Ask"
        case .accept_edits: "Accept edits"
        case .yolo: "Yolo"
        }
    }

}

/// The status line's button titles (board 5).
enum TrayWords {
    static func action(_ a: String, retryIn: Int? = nil) -> String {
        switch a {
        case "restart_engine": "Restart engine"
        case "sign_in": "Sign in"
        case "add_credit": "Add credit"
        case "use_local": "Use local model"
        case "retry": retryIn.map { "Retry in \($0)s" } ?? "Retry"
        case "open_settings": "Open Settings"
        case "use_checkout": "Use checkout"
        case "pull_retry": "Pull and retry"
        case "connect_github": "Connect GitHub"
        case "show_output": "Show output"
        case "resolve_conflicts": "Resolve conflicts"
        default: a
        }
    }

    /// The field's three placeholders.
    static func placeholder(_ s: ComposerModel.State) -> String {
        if s.busy == .working { return "Add a follow-up" }
        if case .session = s.where { return "Reply to Frog" }
        return "What should we work on?"
    }
}

struct TrayDot: View {
    let state: ComposerModel.PrState
    var body: some View { Circle().fill(Color.pr(state)).frame(width: 7, height: 7) }
}

/// Where a model runs, as the model chip's icon: a laptop for this Mac, a server for your own
/// nodes, a cloud for Frog Cloud. In the place colours; no dots.
enum ModelPlaceIcon {
    case mac, node, cloud

    var symbol: String {
        switch self {
        case .mac: "laptopcomputer"
        case .node: "server.rack"
        case .cloud: "cloud"
        }
    }

    var color: Color { self == .cloud ? Tokens.placeCloud : Tokens.placeLocal }
}

/// The model chip: its place icon, then the name. Narrow: the icon alone, the name kept as
/// the accessibility label. Loading: a small ring and "Loading <name>".
struct ModelChipLabel: View {
    let name: String
    let place: ModelPlaceIcon
    var narrow = false
    var loading = false

    var body: some View {
        if loading {
            ProgressView().controlSize(.mini).frame(width: ComposerMetrics.icon, height: ComposerMetrics.icon)
            Text("Loading \(name)").foregroundStyle(Tokens.text)
        } else {
            ComposerIcon(place.symbol, color: place.color)
            if !narrow { Text(name) }
        }
    }
}

/// The plus: the ways to add something, and where the @ and ! shortcuts are taught.
struct AttachMenu: View {
    var chat = false
    var attachFile: () -> Void = {}
    var pasteScreenshot: () -> Void = {}
    var mention: () -> Void = {}
    var command: () -> Void = {}
    /// Kept from the old plus menu: a skill, and racing attempts. Nil: not offered.
    var skill: (() -> Void)?
    var race: (() -> Void)?
    var close: () -> Void = {}

    var body: some View {
        ComposerMenuPanel(width: 240) {
            row("Attach a file…", icon: "paperclip", run: attachFile)
            row("Paste a screenshot", icon: "camera.viewfinder", run: pasteScreenshot)
            if !chat {
                row("Mention a file", key: "@", run: mention)
                row("Run a command", key: "!", run: command)
            }
            if let skill { row("Use a skill", key: "/", run: skill) }
            if let race {
                ComposerMenuRule()
                row("Race attempts…", icon: "square.stack.3d.up", run: race)
            }
        }
    }

    private func row(_ title: String, icon: String? = nil, key: String? = nil, run: @escaping () -> Void) -> some View {
        ComposerMenuRow(icon: icon, title: title, key: key) {
            close()
            run()
        }
    }
}

/// Which menu is open in a preview.
enum ComposerMenuID: Equatable {
    case attach, place, mode, model
}

/// The whole composer from a state alone, with a static model chip: the snapshots, the parity
/// shots, and anything that shows the composer without a live conversation.
struct TrayPreview: View {
    let state: ComposerModel.State
    var send: (ComposerModel.Intent) -> Void = { _ in }
    var lists = WhereLists()
    var menu: ComposerMenuID?
    var narrow = false
    var focused = false

    var body: some View {
        let d = ComposerModel.derive(state)
        ComposerCard(
            showStatus: d.status != .none,
            showAbove: !state.queued.isEmpty || !state.draft.attachments.isEmpty,
            focused: focused
        ) {
            ComposerStatusLine(state: state, send: send)
        } above: {
            ComposerPending(queued: state.queued, attachments: state.draft.attachments, send: send)
        } field: {
            Group {
                if state.draft.text.isEmpty {
                    Text(TrayWords.placeholder(state)).foregroundStyle(Tokens.textTertiary)
                } else {
                    Text(state.draft.text).foregroundStyle(state.busy == .sending ? Tokens.textSecondary : Tokens.text)
                }
            }
            .font(.system(size: 13))
            .lineLimit(10)
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .topLeading)
        } controls: {
            HStack(spacing: 2) {
                ComposerChip(open: menu == .attach, action: {}) { ComposerIcon("plus") }
                    .composerMenu(menu == .attach, close: {}) { AttachMenu(skill: {}) }
                if Self.choosing(state.where) {
                    ComposerChip(open: menu == .place, marked: state.error?.control == "where", action: {}) {
                        WhereChipLabel(place: state.where, narrow: narrow)
                    }
                    .composerMenu(menu == .place, close: {}) { WhereMenu(state: state, lists: lists, send: send) }
                }
                Spacer(minLength: 4)
                ComposerChip(open: menu == .mode, action: {}) { ModeChipLabel(mode: state.mode) }
                    .composerMenu(menu == .mode, trailing: true, close: {}) { ModeMenu(mode: state.mode, send: send) }
                ComposerChip(action: {}) {
                    ModelChipLabel(name: state.model.name, place: state.model.place == .cloud ? .cloud : state.model.node == nil ? .mac : .node,
                                   narrow: narrow, loading: state.busy == .loading_model)
                }
                .accessibilityLabel("Model: \(state.model.name)")
                ComposerAction(state: state, send: send).padding(.leading, 4)
            }
        }
        .composerMenuHost()
    }

    /// The where chip shows only before a session starts.
    static func choosing(_ w: ComposerModel.Where) -> Bool {
        if case .session = w { return false }
        return true
    }
}
