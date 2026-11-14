import Foundation

/// Whether a conversation is running, waiting on you, or finished unseen: a dot in every list.
enum SessionLive: String, Equatable, Sendable {
    case running, waiting, unread
}

/// A sidebar row's state, from the listing (`end`: how the last turn ended) and the live
/// tracking. An open conversation's live state wins; a session nobody has open is judged by
/// its last recorded turn.
enum SessionEndGlyph: Equatable, Sendable {
    /// The engine is working right now (spinner).
    case running
    /// It stopped for the user: waiting on an answer, a denial, a step or token limit (amber).
    case waiting
    /// The last turn ended with an error (red).
    case failed
    /// The last turn ended cleanly but hasn't been looked at (tinted dot).
    case unread
    /// Ended cleanly and seen, or never ran a turn: no glyph at all.
    case idle

    static func derive(live: SessionLive?, end: SessionInfo.End?, stale: Bool = false) -> SessionEndGlyph {
        // An open conversation's live state wins.
        if let live { return live == .running ? .running : live == .waiting ? .waiting : .unread }
        switch end {
        // An open turn: working — unless it's been quiet so long the engine must have died
        // mid-turn, which reads as idle (the log stopped, but nothing is running).
        case .open: return stale ? .idle : .running
        case .failed: return .failed
        // An untracked session whose turn stopped for the user (perhaps on another screen)
        // still deserves the amber ask, once it's seen.
        case .stopped: return .idle
        case .complete, nil: return .idle
        }
    }
}

/// What a session-list refresh covers: some sessions, or all of them. Refreshes coalesce (a
/// new call replaces the one waiting), so the scopes merge: nothing asked for is dropped.
enum RefreshScope: Equatable, Sendable {
    case ids(Set<String>)
    case full

    /// The ids to re-list; empty means every session.
    var ids: Set<String> {
        if case .ids(let ids) = self { ids } else { [] }
    }

    static func merged(_ a: RefreshScope?, _ b: RefreshScope) -> RefreshScope {
        guard case .ids(let x) = a ?? b, case .ids(let y) = b else { return .full }
        return .ids(x.union(y))
    }
}
