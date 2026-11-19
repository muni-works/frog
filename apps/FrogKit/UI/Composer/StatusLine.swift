import SwiftUI

/// The composer's optional top row (docs/design/composer/spec.md, "The status line"): the first
/// of an error, a question, a notice or the session's git state. One line; text is never red.
struct ComposerStatusLine: View {
    let state: ComposerModel.State
    let send: (ComposerModel.Intent) -> Void
    /// The notice's dismiss (the reducer clears notices itself only on a new place).
    var dismissNotice: () -> Void = {}
    /// The git line's +a −d.
    var openDiff: () -> Void = {}

    var body: some View {
        let d = ComposerModel.derive(state)
        HStack(spacing: 8) {
            switch d.status {
            case .error: if let e = state.error { error(e) }
            case .confirm: if let c = state.confirm { confirm(c) }
            case .notice:
                Text(state.notice ?? "").foregroundStyle(Tokens.text).truncationMode(.tail)
                Spacer(minLength: 4)
                StatusDismiss(action: dismissNotice)
            case .git: if case .session(let s) = state.where { ComposerGitLine(state: state, session: s, derived: d, send: send, openDiff: openDiff) }
            case .none: EmptyView()
            }
        }
    }

    @ViewBuilder
    private func error(_ e: ComposerModel.Failure) -> some View {
        ComposerIcon("exclamationmark.triangle", color: Tokens.notice)
        Text(e.message).foregroundStyle(Tokens.text).truncationMode(.tail)
        Spacer(minLength: 4)
        if e.actions.isEmpty {
            StatusDismiss { send(.dismissError) }
        } else {
            // The most direct fix is last and has the plate; the other is quiet text.
            ForEach(e.actions.dropFirst().reversed(), id: \.self) { a in
                StatusButton(title: TrayWords.action(a, retryIn: e.retryIn), quiet: true) { send(.errorAction(a)) }
            }
            StatusButton(title: TrayWords.action(e.actions[0], retryIn: e.retryIn)) { send(.errorAction(e.actions[0])) }
        }
    }

    @ViewBuilder
    private func confirm(_ c: ComposerModel.Confirm) -> some View {
        Text(Self.question(c, state)).foregroundStyle(Tokens.text).truncationMode(.tail)
        Spacer(minLength: 4)
        StatusButton(title: "Cancel", quiet: true) { send(.cancelConfirm) }
        StatusButton(title: Self.confirmButton(c)) { send(.confirm) }
    }

    static func question(_ c: ComposerModel.Confirm, _ s: ComposerModel.State) -> String {
        switch c {
        case .yolo: return "Yolo runs every step without asking"
        case .merge:
            guard case .session(let w) = s.where, let top = ComposerModel.worst(w.prs) else { return "Merge this PR?" }
            return "Merge #\(top.number)?"
        case .archive: return "Archive and delete the worktree's uncommitted changes?"
        }
    }

    static func confirmButton(_ c: ComposerModel.Confirm) -> String {
        switch c {
        case .yolo: "Use Yolo"
        case .merge: "Merge"
        case .archive: "Archive"
        }
    }
}

/// `[folder] repo  branch  +a −d` at the left, the PR and one action at the right.
struct ComposerGitLine: View {
    let state: ComposerModel.State
    let session: ComposerModel.Session
    let derived: ComposerModel.Derived
    let send: (ComposerModel.Intent) -> Void
    var openDiff: () -> Void = {}

    var body: some View {
        ComposerIcon("folder", color: Tokens.textSecondary)
        if let repo = session.repo {
            Text((repo as NSString).lastPathComponent).foregroundStyle(Tokens.text).layoutPriority(1)
                .help(repo)
        }
        Text(session.branch).foregroundStyle(Tokens.textSecondary).truncationMode(.middle)
        if session.dirty || session.diff.add + session.diff.del > 0 {
            Button(action: openDiff) {
                HStack(spacing: 4) {
                    Text("+\(session.diff.add)").foregroundStyle(Tokens.placeCloud)
                    Text("−\(session.diff.del)").foregroundStyle(Tokens.warn)
                }
                .font(.frog(size: 11, design: .monospaced))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("\(session.diff.files) file\(session.diff.files == 1 ? "" : "s") changed: open the diff")
        } else if session.ahead > 0 {
            Text("\(session.ahead) ahead").fixedSize()
        }
        Spacer(minLength: 4)
        if let summary = derived.prSummary { pr(summary) }
        if let a = derived.gitAction {
            StatusButton(title: a.label, urged: derived.openPr, marked: state.error?.control == "git_action") { send(.gitAction) }
                .disabled(state.busy == .sending)
                .help(derived.openPr ? "The work is done: push this branch and open a pull request" : "")
        }
    }

    @ViewBuilder
    private func pr(_ s: ComposerModel.Derived.Summary) -> some View {
        if s.count == 1, let pr = session.prs.first {
            Button { send(.prClick(0, alt: ComposerGitLine.optionDown)) } label: {
                HStack(spacing: 6) {
                    TrayDot(state: pr.state)
                    Text("#\(pr.number) \(pr.state.short)").monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("\(pr.title). ⌥-click copies the link")
        } else {
            Button { send(state.stackOpen ? .closeStack : .openStack) } label: {
                HStack(spacing: 6) {
                    TrayDot(state: s.worst)
                    Text(s.label)
                    ComposerIcon("chevron.up", color: Tokens.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .fixedSize()
            .composerMenu(state.stackOpen, trailing: true, close: { send(.closeStack) }) {
                PrStackMenu(prs: session.prs, send: send)
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

/// Several PRs, opening upward: dot, number, title, state and checks; last, bind one.
struct PrStackMenu: View {
    let prs: [ComposerModel.Pr]
    let send: (ComposerModel.Intent) -> Void
    @State private var binding = ""

    var body: some View {
        ComposerMenuPanel(width: 440) {
            ForEach(Array(prs.enumerated()), id: \.offset) { i, pr in
                ComposerMenuButton(action: { send(.prClick(i, alt: ComposerGitLine.optionDown)) }) {
                    HStack(spacing: 8) {
                        TrayDot(state: pr.state)
                        Text("#\(pr.number)").monospacedDigit().foregroundStyle(Tokens.text)
                        Text(pr.title).foregroundStyle(Tokens.text).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.detail(pr)).font(.frog(size: 12)).foregroundStyle(Tokens.textSecondary)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("", text: $binding, prompt: Text("Bind a PR by URL or number…").foregroundStyle(Tokens.textSecondary))
                    .textFieldStyle(.plain)
                    .onSubmit {
                        send(.bindPr(binding))
                        binding = ""
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
    }

    static func detail(_ pr: ComposerModel.Pr) -> String {
        if pr.access == false { return "no access" }
        switch pr.state {
        case .failing, .checks: return "\(pr.state.short), \(pr.checks.ok) of \(pr.checks.total)"
        default: return pr.state.short
        }
    }
}
