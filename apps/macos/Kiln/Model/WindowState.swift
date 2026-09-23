import Foundation
import Observation

/// Per-window UI state that menu commands and the canvas share: where to scroll, what's on
/// screen, find, and one-shot requests (focus the composer, open the race sheet).
@MainActor
@Observable
final class WindowState {
    /// Set to scroll a turn into view.
    var jumpTo: TurnState.ID?
    var visibleTurns: Set<TurnState.ID> = []

    var paletteShown = false
    var confirmUndo = false

    var findShown = false
    var findQuery = ""
    var findIndex = 0

    /// Bumped to ask the composer to take focus / open the race popover.
    private(set) var focusComposerRequest = 0
    private(set) var raceRequest = 0

    func focusComposer() { focusComposerRequest += 1 }
    func requestRace() { raceRequest += 1 }

    /// The top-most turn on screen, as an index into `turns`.
    func topVisible(in turns: [TurnState]) -> Int? {
        turns.firstIndex { visibleTurns.contains($0.id) }
    }

    /// Scroll one turn up (-1) or down (+1) from the top-most visible one.
    func step(_ delta: Int, in turns: [TurnState]) {
        guard !turns.isEmpty else { return }
        let from = topVisible(in: turns) ?? turns.count - 1
        let to = min(turns.count - 1, max(0, from + delta))
        jumpTo = turns[to].id
    }

    // MARK: Find

    /// Turns whose prompt or output contains the query, in order.
    func matches(in turns: [TurnState]) -> [TurnState.ID] {
        let q = findQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return turns.filter { t in
            t.input.localizedCaseInsensitiveContains(q)
                || t.items.contains { $0.text.localizedCaseInsensitiveContains(q) || $0.output.localizedCaseInsensitiveContains(q) }
        }.map(\.id)
    }

    func find(_ delta: Int, in turns: [TurnState]) {
        let m = matches(in: turns)
        guard !m.isEmpty else { return }
        findIndex = ((findIndex + delta) % m.count + m.count) % m.count
        jumpTo = m[findIndex]
    }
}
