import Foundation

/// When the composer offers to open a pull request, and when it must not.
///
/// The setting is `[git] open_pr_when_done` in config.toml: `off`, `ask` (the default) or
/// `auto`. `auto` is parsed and documented but **deliberately not wired** — it reads as `ask`
/// until `ask` has been used enough to say what opening one unattended should do.
///
/// `ask` is what the composer already does by hand: the git line's Open PR action, which
/// `ComposerModel.derive` produces from "commits ahead, no PR yet". This file adds the part
/// that has to be right before `auto` can exist: a predicate strict enough that turning it on
/// would not open a pull request per session per night.
///
/// Pure: no git, no session store, no filesystem. The composer builds an `Input` from what it
/// already knows and asks.
enum OpenPR {
    /// `[git] open_pr_when_done`.
    enum Setting: String, Codable, Equatable, Sendable, CaseIterable {
        /// Nothing is offered.
        case off
        /// Offer Open PR once the work is done. The default.
        case ask
        /// Open it unattended. **Not implemented**: `effective` maps it to `.ask`.
        case auto

        /// What the setting does now. The one place `auto` stops being `auto`.
        var effective: Setting { self == .auto ? .ask : self }

        /// Whether the composer may offer Open PR at all under this setting.
        var offers: Bool { effective == .ask }
    }

    /// Everything the decision depends on. Each one is a reason not to open a PR on its own.
    struct Input: Equatable, Sendable {
        /// The session was started with `worktree: true`: its own branch off the base.
        var worktree: Bool
        /// Commits on that branch its base doesn't have.
        var ahead: Int
        /// A PR is already bound to the session (open, draft, merged — any of them).
        var hasPR: Bool
        /// How deep the session sits in the sidebar's started-by tree (0 = top level).
        var depth: Int
        /// It has sessions under it: it is a manager.
        var hasChildren: Bool
        /// A read-only session (an investigation, a review): it never writes, so never opens.
        var readOnly: Bool
        /// This session opted out (see `optedOut(in:)`).
        var optedOut: Bool

        init(
            worktree: Bool,
            ahead: Int,
            hasPR: Bool = false,
            depth: Int = 0,
            hasChildren: Bool = false,
            readOnly: Bool = false,
            optedOut: Bool = false
        ) {
            self.worktree = worktree
            self.ahead = ahead
            self.hasPR = hasPR
            self.depth = depth
            self.hasChildren = hasChildren
            self.readOnly = readOnly
            self.optedOut = optedOut
        }

        /// A manager: a top-level session with sessions under it. Managers and their workers
        /// produce a branch per session, so opening a PR for each would be dozens a day into
        /// one repo. This one line is why `auto` is not built yet.
        var isManager: Bool { depth == 0 && hasChildren }
    }

    /// The whole decision, in one place: the session has its own branch with commits on it, no
    /// PR yet, is not a manager, is not read-only, and did not opt out.
    ///
    /// Note what this does **not** know: whether the session was started by an agent
    /// (`--worker`). That exclusion is a separate decision (see the PR body), so it is not
    /// smuggled in here.
    static func shouldOpenPR(_ s: Input) -> Bool {
        s.worktree
            && s.ahead > 0
            && !s.hasPR
            && !s.isManager
            && !s.readOnly
            && !s.optedOut
    }

    /// Whether the composer should offer (or, later, take) Open PR for this session under this
    /// setting. `off` never offers; `auto` offers exactly as `ask` does today.
    static func offers(_ setting: Setting, _ s: Input) -> Bool {
        setting.offers && shouldOpenPR(s)
    }

    /// The first-prompt marker that turns the offer off for one session:
    ///
    ///     open-pr: off
    ///
    /// A line of its own, case-insensitive, with either `off` or `never` after the colon. It
    /// lives in the prompt so it is in the session's log — visible, greppable, and true after a
    /// resume, which a per-session default in the app's preferences would not be.
    static func optedOut(in firstPrompt: String?) -> Bool {
        guard let firstPrompt else { return false }
        return firstPrompt.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let l = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard l.hasPrefix("open-pr:") else { return false }
            let value = l.dropFirst("open-pr:".count).trimmingCharacters(in: .whitespaces)
            return value == "off" || value == "never"
        }
    }
}
