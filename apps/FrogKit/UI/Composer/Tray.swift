import SwiftUI

/// The tray's parts (docs/plans/2026-11-12-composer-tray.md): they render `ComposerModel.State`
/// and send intents, nothing else, so the live composer and the parity shots draw the same.

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

    var blurb: String {
        switch self {
        case .auto: "Approves steps that plainly serve your request; asks about the rest"
        case .default: "Asks before edits and commands"
        case .accept_edits: "Edits freely; asks before commands"
        case .yolo: "Never asks. The sandbox still applies"
        }
    }
}

/// The error slot's button titles.
enum TrayWords {
    static func action(_ a: String, local: String?) -> String {
        switch a {
        case "restart_engine": "Restart engine"
        case "sign_in": "Sign in"
        case "add_credit": "Add credit"
        case "use_local": "Use \(local ?? "a local model")"
        case "retry": "Retry"
        case "open_settings": "Open System Settings"
        case "use_checkout": "Use checkout instead"
        case "pull_retry": "Pull & retry"
        case "connect_github": "Connect GitHub"
        case "show_output": "Show output"
        case "resolve_conflicts": "Resolve conflicts"
        default: a
        }
    }
}

struct TrayDot: View {
    let state: ComposerModel.PrState
    var body: some View { Circle().fill(Color.pr(state)).frame(width: 7, height: 7) }
}

/// A small flat chip: the tray's one shape for the top line's controls.
struct TrayChip<Label: View>: View {
    var outlined = false
    var strong = false
    /// The line's one emphatic control (Open PR when the work is done): filled with the
    /// accent, the same green the send button uses for "this is the next thing".
    var accent = false
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { label }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(accent ? Tokens.accent : Color.primary.opacity(strong ? 0.1 : 0.06),
                            in: .rect(cornerRadius: 6, style: .continuous))
                .overlay {
                    if outlined { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tokens.fail, lineWidth: 1) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The session's top line: repo · ⎇ branch · worktree · diff · PR pill or stack · one action.
struct TrayGitLine: View {
    let state: ComposerModel.State
    let session: ComposerModel.Session
    let send: (ComposerModel.Intent) -> Void
    var openDiff: () -> Void = {}
    var reveal: (String) -> Void = { _ in }
    var copy: (String) -> Void = { _ in }

    var body: some View {
        let d = ComposerModel.derive(state)
        HStack(spacing: 10) {
            if let repo = session.repo {
                Button { reveal(repo) } label: {
                    Text(repo.split(separator: "/").last.map(String.init) ?? repo).foregroundStyle(Tokens.textSecondary)
                }
                .buttonStyle(.plain)
                .help(repo)
            }
            branchMenu(canSwitch: d.canSwitchBranch)
            if session.worktree {
                Button { if let p = session.worktreePath { reveal(p) } } label: {
                    Text("worktree")
                        .font(.frog(size: 10.5, weight: .medium))
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(Color.primary.opacity(0.07), in: .capsule)
                        .foregroundStyle(Tokens.textSecondary)
                }
                .buttonStyle(.plain)
                .help(session.worktreePath ?? "A worktree")
            }
            if session.dirty || session.diff.add + session.diff.del > 0 {
                Button(action: openDiff) {
                    HStack(spacing: 4) {
                        Text("+\(session.diff.add)").foregroundStyle(Tokens.placeCloud)
                        Text("−\(session.diff.del)").foregroundStyle(Tokens.fail)
                    }
                    .monospacedDigit()
                }
                .buttonStyle(.plain)
                .help("\(session.diff.files) file\(session.diff.files == 1 ? "" : "s") changed: open the diff")
            }
            Spacer(minLength: 6)
            if let summary = d.prSummary { prPill(summary) }
            if let a = d.gitAction {
                // Open PR, when the work is done and opening one is wanted, is the line's one
                // emphatic control: the setting's `ask` made visible, in the place the action
                // already was (docs/plans/2026-11-13-open-pr-when-done.md).
                TrayChip(outlined: state.error?.control == "git_action", strong: true, accent: d.openPR, action: { send(.gitAction) }) {
                    Text(a.label)
                        .font(.frog(size: 12, weight: d.openPR ? .semibold : .medium))
                        .foregroundStyle(d.openPR ? Color.black : Tokens.text)
                }
                .disabled(state.busy == .sending)
                .help(d.openPR ? "The work is done: push this branch and open a pull request" : "")
            }
        }
        .font(.frog(size: 12))
        .foregroundStyle(Tokens.textSecondary)
        .lineLimit(1)
    }

    private func branchMenu(canSwitch: Bool) -> some View {
        Menu {
            Button("Copy Branch Name") { copy(session.branch) }
            if canSwitch {
                Button("Switch Branch…") { send(.switchBranch("")) }
            } else {
                Text("Commit or stash first")
            }
            if let repo = session.repo {
                Button("Open on GitHub") { reveal("https://github.com/\(repo)/tree/\(session.branch)") }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.frog(size: 10))
                Text(session.branch)
            }
            .foregroundStyle(Tokens.textTertiary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func prPill(_ s: ComposerModel.Derived.Summary) -> some View {
        if s.count == 1, let pr = session.prs.first {
            TrayChip(action: { send(.prClick(0, alt: Self.optionDown)) }) {
                TrayDot(state: pr.state)
                Text(s.label).monospacedDigit().foregroundStyle(Tokens.text)
            }
            .help("\(pr.title) · \(pr.state.word). ⌥-click copies the link")
        } else {
            TrayChip(action: { send(.openStack) }) {
                TrayDot(state: s.worst)
                Text(s.label).foregroundStyle(Tokens.text)
                Image(systemName: "chevron.down").font(.frog(size: 8, weight: .semibold))
            }
            .popover(isPresented: Binding(get: { state.stackOpen }, set: { if !$0 { send(.closeStack) } }), arrowEdge: .bottom) {
                TrayStack(prs: session.prs, send: send)
            }
        }
    }

    static var optionDown: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
    }
}

/// The stack popover: each bound PR with its state, and "Bind a PR…".
struct TrayStack: View {
    let prs: [ComposerModel.Pr]
    let send: (ComposerModel.Intent) -> Void
    @State private var binding = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(prs.enumerated()), id: \.offset) { i, pr in
                Button { send(.prClick(i, alt: TrayGitLine.optionDown)) } label: {
                    HStack(spacing: 8) {
                        TrayDot(state: pr.state)
                        Text("\(pr.repo.split(separator: "/").last.map(String.init) ?? pr.repo)#\(pr.number)")
                            .monospacedDigit()
                            .foregroundStyle(Tokens.textSecondary)
                        Text(pr.title).foregroundStyle(Tokens.text).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(pr.access == false ? "no access" : pr.state.word)
                            .foregroundStyle(pr.access == false ? Tokens.textTertiary : Color.pr(pr.state))
                    }
                    .font(.frog(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(.rect)
                    .hoverPlate(h: 0, v: 0)
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 4)
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(Tokens.textTertiary)
                TextField("Bind a PR… (URL or #n)", text: $binding)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        send(.bindPr(binding))
                        binding = ""
                    }
            }
            .font(.frog(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 26)
        }
        .padding(6)
        .frame(width: 380)
    }
}

/// The new-session top line: folder or cloud repo · ⎇ branch · New worktree.
struct TrayWhereLine: View {
    let state: ComposerModel.State
    let send: (ComposerModel.Intent) -> Void
    /// The folder menu's rows (recent folders), and its other choices.
    var recent: [String] = []
    /// Repos the Frog GitHub App reaches, for a Frog Cloud session.
    var cloudRepos: [String] = []
    var branches: [String] = []
    var choose: () -> Void = {}
    var cloneRepo: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            switch state.where {
            case .folder(let folder, let branch, let worktree, let git, _):
                placeMenu(icon: "folder", name: (folder as NSString).lastPathComponent, tint: Tokens.textSecondary)
                if git {
                    branchMenu(branch)
                    Spacer(minLength: 6)
                    Toggle(isOn: Binding(get: { worktree }, set: { _ in send(.toggleWorktree) })) {
                        Text("New worktree")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .overlay {
                        if state.error?.control == "worktree" {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(Tokens.fail, lineWidth: 1).padding(-3)
                        }
                    }
                } else {
                    Spacer(minLength: 6)
                }
            case .cloud(let repo, let branch):
                placeMenu(icon: "cloud", name: repo, tint: Tokens.placeCloud)
                branchMenu(branch)
                Spacer(minLength: 6)
            default:
                EmptyView()
            }
        }
        .font(.frog(size: 12))
        .foregroundStyle(Tokens.textSecondary)
        .lineLimit(1)
    }

    private func placeMenu(icon: String, name: String, tint: Color) -> some View {
        Menu {
            ForEach(recent, id: \.self) { f in
                Button((f as NSString).lastPathComponent, systemImage: "folder") {
                    send(.chooseFolder(folder: f, branch: "", git: true, dirty: false))
                }
            }
            if !recent.isEmpty { Divider() }
            if !cloudRepos.isEmpty {
                Section("Frog Cloud") {
                    ForEach(cloudRepos, id: \.self) { r in
                        Button(r, systemImage: "cloud") { send(.chooseCloud(repo: r, branch: "main")) }
                    }
                }
            }
            Button("Choose…", systemImage: "folder.badge.plus", action: choose)
            Button("Clone a GitHub Repo…", systemImage: "square.and.arrow.down", action: cloneRepo)
            Divider()
            Button("Just Chat", systemImage: "bubble.left") { send(.justChat) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.frog(size: 11))
                Text(name).foregroundStyle(Tokens.text)
                Image(systemName: "chevron.down").font(.frog(size: 8, weight: .semibold))
            }
            .foregroundStyle(tint)
            .overlay {
                if state.error?.control == "where" {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Tokens.fail, lineWidth: 1).padding(-3)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where this session works")
    }

    private func branchMenu(_ branch: String) -> some View {
        Menu {
            ForEach(branches, id: \.self) { b in Button(b) { send(.pickBranch(b)) } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.frog(size: 10))
                Text(branch)
            }
            .foregroundStyle(Tokens.textTertiary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(branches.isEmpty)
    }
}

/// One inline error above the rail: a sentence, one or two buttons, ×. Never a modal.
struct TrayErrorSlot: View {
    let error: ComposerModel.Failure
    var localModel: String?
    let send: (ComposerModel.Intent) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Tokens.fail)
            Text(error.message + (error.retryIn.map { " · retrying in \($0)s" } ?? ""))
                .foregroundStyle(Tokens.text)
                .lineLimit(2)
            Spacer(minLength: 4)
            ForEach(error.actions, id: \.self) { a in
                Button(TrayWords.action(a, local: localModel)) { send(.errorAction(a)) }
                    .buttonStyle(.plain)
                    .font(.frog(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 6, style: .continuous))
            }
            Button { send(.dismissError) } label: { Image(systemName: "xmark").font(.frog(size: 10, weight: .semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textTertiary)
                .help("Dismiss")
        }
        .font(.frog(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Tokens.fail.opacity(0.08), in: .rect(cornerRadius: 9, style: .continuous))
    }
}

/// The rail's one action button: mic → send → stop (queue while working with text).
struct TrayActionButton: View {
    let state: ComposerModel.State
    let send: (ComposerModel.Intent) -> Void
    /// Dictation is live: the mic shows its level instead.
    var listening = false

    var body: some View {
        let d = ComposerModel.derive(state)
        Button { send(.action) } label: {
            ZStack {
                switch d.action {
                case .dictate:
                    Image(systemName: listening ? "waveform" : "mic")
                        .font(.frog(size: 14, weight: .medium))
                        .foregroundStyle(listening ? Tokens.fail : Tokens.textSecondary)
                case .send:
                    Circle().fill(d.sendDisabled ? Color.primary.opacity(0.12) : Tokens.placeCloud)
                    if state.busy == .sending {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.up").font(.frog(size: 13, weight: .bold)).foregroundStyle(.white)
                    }
                case .stop:
                    Circle().fill(Color.primary.opacity(0.1))
                    if state.busy == .loading_model {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "stop.fill").font(.frog(size: 10)).foregroundStyle(Tokens.text)
                    }
                case .queue:
                    Circle().fill(Color.primary.opacity(0.14))
                    Image(systemName: "text.append").font(.frog(size: 11, weight: .semibold)).foregroundStyle(Tokens.text)
                }
            }
            .frame(width: 26, height: 26)
            .overlay {
                if state.error?.control == "action" { Circle().strokeBorder(Tokens.fail, lineWidth: 1.5) }
            }
            .overlay(alignment: .topTrailing) {
                if state.queued > 0 {
                    Text("\(state.queued)")
                        .font(.frog(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Tokens.textSecondary, in: .capsule)
                        .offset(x: 4, y: -4)
                }
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(d.action == .send && d.sendDisabled)
        .help(help(d.action))
        .accessibilityLabel(help(d.action))
    }

    private func help(_ a: ComposerModel.Action) -> String {
        switch a {
        case .dictate: "Dictate (⌥⌘V)"
        case .send: "Send (↩)"
        case .stop: state.busy == .loading_model ? "Stop loading the model (Esc)" : "Stop (Esc)"
        case .queue: "Queue a follow-up (↩)"
        }
    }
}

/// The rail's mode menu, each with its one-line description.
struct TrayModeMenu: View {
    let mode: ComposerModel.Mode
    let send: (ComposerModel.Intent) -> Void

    var body: some View {
        Menu {
            ForEach(ComposerModel.Mode.allCases, id: \.self) { m in
                Button { send(.setMode(m)) } label: {
                    Text(m.label + (m == .auto ? " (default)" : ""))
                    Text(m.blurb)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(mode.label)
                Image(systemName: "chevron.down").font(.frog(size: 8, weight: .semibold))
            }
            .foregroundStyle(mode == .yolo ? Tokens.signal : Tokens.textSecondary)
            .hoverPlate()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Permission mode (⌘.)")
    }
}

/// The surface: one rounded tray holding the top line, the error slot, the field and the rail.
struct TraySurface<Top: View, Field: View, Rail: View>: View {
    var showTop = true
    var error: ComposerModel.Failure?
    var notice: String?
    var localModel: String?
    let send: (ComposerModel.Intent) -> Void
    @ViewBuilder let top: Top
    @ViewBuilder let field: Field
    @ViewBuilder let rail: Rail

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showTop {
                top
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 8) {
                field
                if let notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.frog(size: 11.5))
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1)
                }
                if let error { TrayErrorSlot(error: error, localModel: localModel, send: send) }
                rail
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 9)
        }
        .background(Tokens.raised, in: Self.shape)
        .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

/// The whole tray from a state alone, with a static model chip: the parity shots, and anything
/// that shows the composer without a live conversation.
struct TrayPreview: View {
    let state: ComposerModel.State
    var send: (ComposerModel.Intent) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TraySurface(showTop: showTop, error: state.error, notice: state.notice, localModel: state.defaults.local?.name, send: send) {
                switch state.where {
                case .session(let s): TrayGitLine(state: state, session: s, send: send)
                default: TrayWhereLine(state: state, send: send)
                }
            } field: {
                Group {
                    if state.draft.text.isEmpty {
                        Text(state.busy == .working ? "Working… Esc interrupts · Return queues a follow-up" : "Reply to Frog, @ a file, ! a command")
                            .foregroundStyle(Tokens.textTertiary)
                    } else {
                        Text(state.draft.text).foregroundStyle(Tokens.text)
                    }
                }
                .font(.frog(size: 13.5))
                .lineLimit(3)
                .padding(.leading, 5)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .topLeading)
            } rail: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.frog(size: 15, weight: .medium)).frame(width: 22, height: 22)
                    TrayModeMenu(mode: state.mode, send: send)
                    HStack(spacing: 5) {
                        Circle().fill(state.model.place == .cloud ? Tokens.placeCloud : Tokens.placeLocal).frame(width: 6, height: 6)
                        Text(state.model.name)
                        Image(systemName: "chevron.down").font(.frog(size: 8, weight: .semibold))
                    }
                    Spacer(minLength: 0)
                    TrayActionButton(state: state, send: send)
                }
                .font(.frog(size: 12))
                .foregroundStyle(Tokens.textSecondary)
            }
            if state.stackOpen, case .session(let s) = state.where {
                TrayStack(prs: s.prs, send: send)
                    .background(Tokens.raised, in: .rect(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var showTop: Bool {
        if case .chat = state.where { return false }
        return true
    }
}
