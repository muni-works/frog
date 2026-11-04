import AppKit
import Foundation
import Observation
import SwiftUI

/// One conversation on screen: its workspace and the view state that goes with it (scroll
/// position, find, the changes card).
@MainActor
@Observable
final class Pane: Identifiable {
    let id = UUID()
    var workspace: Workspace
    let ui = WindowState()
    /// The changes card: asked for, and floated over the conversation because it didn't fit.
    var showChanges = false
    var peekChanges = false
    /// Another folder's workspace on its way in (see `Panes.open`).
    @ObservationIgnored var incoming: Workspace?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// The conversation on the canvas (a race has its own view).
    var conversation: Conversation? { workspace.race == nil ? workspace.conversation : nil }
    var changeCount: Int { conversation?.sessionChanges.count ?? 0 }
    /// Terminals and previews open beside the conversation (see `PaneHub`).
    var toolCount: Int { conversation?.panes.panes.count ?? 0 }
    /// Something for the card at this pane's edge: changed files, or a terminal or preview.
    var hasTabs: Bool { changeCount > 0 || toolCount > 0 }
    /// A preview needs room to be useful; changes alone read fine narrower.
    var cardWidth: CGFloat { toolCount > 0 ? PaneArea.minWidth + 60 : WorkspaceView.changesWidth }
    var hasRail: Bool { conversation?.started ?? false }
}

/// How a window's panes are arranged: a tree of rows and columns with a pane at each leaf.
/// Each split gives its children shares of its space (`weights`, summing to 1); dragging a
/// divider moves share between the two children beside it.
indirect enum PaneLayout: Equatable {
    case leaf(Pane.ID)
    /// `.horizontal`: side by side; `.vertical`: stacked.
    case split(Axis, [PaneLayout], weights: [CGFloat])

    /// Children sharing the space evenly.
    static func even(_ axis: Axis, _ children: [PaneLayout]) -> PaneLayout {
        .split(axis, children, weights: Array(repeating: 1 / CGFloat(children.count), count: children.count))
    }

    var leaves: [Pane.ID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, let children, _): children.flatMap(\.leaves)
        }
    }

    /// Without `id`, its share going to the rest and splits left with one child collapsing.
    /// Nil if nothing is left.
    func removing(_ id: Pane.ID) -> PaneLayout? {
        switch self {
        case .leaf(let leaf):
            return leaf == id ? nil : self
        case .split(let axis, let children, let weights):
            let kept = zip(children, weights).compactMap { c, w in c.removing(id).map { ($0, w) } }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0].0 }
            return PaneLayout.split(axis, kept.map(\.0), weights: Self.normalized(kept.map(\.1))).flattened
        }
    }

    /// `id` placed on one side of `target`, taking half the target's space: it joins the
    /// target's row or column if that runs the same way, else makes a new one with it.
    func inserting(_ id: Pane.ID, beside target: Pane.ID, on edge: PaneEdge) -> PaneLayout {
        switch self {
        case .leaf(let leaf):
            guard leaf == target else { return self }
            return .even(edge.axis, edge.leading ? [.leaf(id), self] : [self, .leaf(id)])
        case .split(let axis, var children, let weights):
            if axis == edge.axis, let i = children.firstIndex(of: .leaf(target)) {
                children.insert(.leaf(id), at: edge.leading ? i : i + 1)
                // A new pane evens out the row: halving one share left three panes at 50/25/25.
                return .even(axis, children)
            }
            return PaneLayout.split(axis, children.map { $0.inserting(id, beside: target, on: edge) }, weights: weights).flattened
        }
    }

    /// The same layout with two leaves exchanged.
    func swapping(_ a: Pane.ID, _ b: Pane.ID) -> PaneLayout {
        switch self {
        case .leaf(let id): id == a ? .leaf(b) : id == b ? .leaf(a) : self
        case .split(let axis, let children, let weights): .split(axis, children.map { $0.swapping(a, b) }, weights: weights)
        }
    }

    /// The divider after child `index` of the split at `path`, moved to `t` (0...1 along that
    /// split). Neither neighbor gets less than `minimum` of it — and never more than a quarter
    /// of the pair, so a drag can always take a pane to twice even-share even on a narrow
    /// canvas (where an absolute floor for both panes would pin them at nearly even shares).
    func moving(divider index: Int, at path: [Int], to t: CGFloat, minimum: CGFloat) -> PaneLayout {
        guard case .split(let axis, var children, var weights) = self else { return self }
        if let first = path.first {
            children[first] = children[first].moving(divider: index, at: Array(path.dropFirst()), to: t, minimum: minimum)
            return .split(axis, children, weights: weights)
        }
        guard index + 1 < weights.count else { return self }
        let before = weights[..<index].reduce(0, +)
        let pair = weights[index] + weights[index + 1]
        let lo = min(minimum, pair / 4), hi = pair - lo
        weights[index] = min(max(t - before, lo), hi)
        weights[index + 1] = pair - weights[index]
        return .split(axis, children, weights: weights)
    }

    /// The split at `path` (the divider's parent), if the path lands on one.
    func navigating(_ path: [Int]) -> PaneLayout? {
        var here = self
        for i in path {
            guard case .split(_, let children, _) = here, children.indices.contains(i) else { return nil }
            here = children[i]
        }
        return here
    }

    /// The split at `path` with its children sharing evenly again.
    func equalizing(at path: [Int]) -> PaneLayout {
        guard case .split(let axis, var children, let weights) = self else { return self }
        if let first = path.first {
            children[first] = children[first].equalizing(at: Array(path.dropFirst()))
            return .split(axis, children, weights: weights)
        }
        return .even(axis, children)
    }

    /// Rows directly inside rows (and columns in columns) merged into one, keeping sizes.
    private var flattened: PaneLayout {
        guard case .split(let axis, let children, let weights) = self else { return self }
        var c: [PaneLayout] = [], w: [CGFloat] = []
        for (child, weight) in zip(children, weights) {
            if case .split(let a, let inner, let innerWeights) = child, a == axis {
                c += inner
                w += innerWeights.map { $0 * weight }
            } else {
                c.append(child)
                w.append(weight)
            }
        }
        return .split(axis, c, weights: w)
    }

    private static func normalized(_ w: [CGFloat]) -> [CGFloat] {
        let total = w.reduce(0, +)
        return total > 0 ? w.map { $0 / total } : w
    }

    /// Each child's rectangle within a split's.
    private static func slices(_ rect: CGRect, _ axis: Axis, _ weights: [CGFloat]) -> [CGRect] {
        let total = max(weights.reduce(0, +), .ulpOfOne)
        var at: CGFloat = 0
        return weights.map { w in
            let f = w / total
            defer { at += f }
            return axis == .horizontal
                ? CGRect(x: rect.minX + rect.width * at, y: rect.minY, width: rect.width * f, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY + rect.height * at, width: rect.width, height: rect.height * f)
        }
    }

    /// Each leaf's rectangle within `rect`. With `maximized`, the leaf it names (anywhere in
    /// the tree) takes all of `rect` and its siblings nothing — a view over the layout, so
    /// restoring is just passing nil again.
    func frames(in rect: CGRect, maximizing maximized: Pane.ID? = nil) -> [Pane.ID: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: rect]
        case .split(let axis, let children, let weights):
            var out: [Pane.ID: CGRect] = [:]
            if let maximized, leaves.contains(maximized) {
                for child in children {
                    out.merge(child.frames(in: child.leaves.contains(maximized) ? rect : .zero, maximizing: maximized)) { a, _ in a }
                }
                return out
            }
            for (child, r) in zip(children, Self.slices(rect, axis, weights)) {
                out.merge(child.frames(in: r, maximizing: maximized)) { a, _ in a }
            }
            return out
        }
    }

    /// A draggable line between two children of a split.
    struct Divider: Identifiable {
        /// Child indices from the root to the split.
        let path: [Int]
        /// It follows this child.
        let index: Int
        let axis: Axis
        /// The split's rectangle, to turn a drag into a share of it.
        let parent: CGRect
        /// Where the line is, across the split.
        let position: CGFloat
        var id: String { path.map(String.init).joined(separator: ".") + "/\(index)" }
    }

    func dividers(in rect: CGRect, path: [Int] = [], maximizing maximized: Pane.ID? = nil) -> [Divider] {
        guard case .split(let axis, let children, let weights) = self else { return [] }
        // Nothing to drag while a pane of this split is maximized (its siblings are empty).
        if let maximized, leaves.contains(maximized) { return [] }
        let slices = Self.slices(rect, axis, weights)
        var out: [Divider] = []
        for i in children.indices {
            if i + 1 < children.count {
                let pos = axis == .horizontal ? slices[i].maxX : slices[i].maxY
                out.append(Divider(path: path, index: i, axis: axis, parent: rect, position: pos))
            }
            out += children[i].dividers(in: slices[i], path: path + [i], maximizing: maximized)
        }
        return out
    }
}

/// Where a pane or a conversation is dropped on a pane: beside it, or in its place.
enum PaneEdge: Equatable {
    case left, right, top, bottom

    var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    var leading: Bool { self == .left || self == .top }
}

enum PaneDrop: Equatable {
    case edge(PaneEdge)
    /// Swap with a dragged pane, or show a dragged conversation here.
    case center
}

/// A window's conversations, in rows and columns. One is focused: the sidebar, menus, toolbar
/// and palette act on it. The first pane's folder is the window's, for state restoration.
@MainActor
@Observable
final class Panes {
    static let maxPanes = 4

    /// In reading order (the layout's leaves), which is how they're numbered.
    private(set) var items: [Pane]
    private(set) var layout: PaneLayout
    var focusedID: Pane.ID
    /// The pane filling the canvas, if any. The layout is untouched while it's up (its weights
    /// come back exactly on restore); the frames just resolve to the maximized pane's rect.
    private(set) var maximized: Pane.ID?
    /// The layout as it was when the pane was maximized, put back on restore.
    private(set) var savedLayout: PaneLayout?
    /// Tells the window its first pane moved to another folder (restored on relaunch).
    @ObservationIgnored var onPrimaryFolder: ((URL) -> Void)?

    init(_ workspace: Workspace) {
        let first = Pane(workspace: workspace)
        items = [first]
        layout = .leaf(first.id)
        focusedID = first.id
    }

    var focused: Pane { items.first { $0.id == focusedID } ?? items[0] }
    var isSplit: Bool { items.count > 1 }

    func index(of pane: Pane) -> Int? { items.firstIndex { $0 === pane } }

    /// The pane showing this session, if any.
    func paneShowing(_ id: String) -> Pane? {
        items.first { $0.workspace.conversation?.sessionID == id }
    }

    /// Focus a session already on screen, cancelling any navigation that would replace it.
    @discardableResult
    func focusSession(_ id: String) -> Bool {
        guard let pane = paneShowing(id) else { return false }
        pane.incoming?.stop(reason: "open superseded")
        pane.incoming = nil
        pane.workspace.open(id)
        focus(pane)
        return true
    }

    /// Pane numbers (1-based) by the session each shows, for the sidebar. Empty unless split.
    var numbers: [String: Int] {
        guard isSplit else { return [:] }
        var out: [String: Int] = [:]
        for (i, p) in items.enumerated() {
            if let id = p.workspace.conversation?.sessionID { out[id] = i + 1 }
        }
        return out
    }

    func focus(_ pane: Pane) {
        if focusedID != pane.id { focusedID = pane.id }
    }

    func focus(step delta: Int) {
        guard let i = index(of: focused) else { return }
        focusedID = items[(i + delta + items.count) % items.count].id
        focused.ui.focusComposer()
    }

    // MARK: Changing what a pane shows

    func setWorkspace(_ workspace: Workspace, in pane: Pane) {
        guard workspace !== pane.workspace else { return }
        // Anything else on its way in has been overtaken.
        if pane.incoming !== workspace { pane.incoming?.stop(reason: "open superseded") }
        pane.incoming = nil
        pane.workspace.stop(reason: "pane switched folder")
        pane.workspace = workspace
        pane.peekChanges = false
        Recents.add(workspace.folder)
        if pane === items.first { onPrimaryFolder?(workspace.folder) }
    }

    /// Point a pane at another folder (nil: a plain chat), starting a fresh conversation there.
    /// A folder whose worktree another engine holds still switches (the pane shows the reason
    /// and a way to the owner, see `Workspace.worktreeOwner`), so this never silently does
    /// nothing when the user picked it.
    func switchFolder(_ url: URL?, in pane: Pane) {
        setWorkspace(Workspace(folder: url ?? Frog.chatFolder, fresh: true), in: pane)
    }

    /// A fresh conversation in `url` (nil: a plain chat) that opens with `prompt`.
    func start(_ prompt: String, in url: URL?, pane: Pane) {
        let workspace = Workspace(folder: url ?? Frog.chatFolder, fresh: true)
        setWorkspace(workspace, in: pane)
        workspace.conversation?.submit(prompt)
    }

    /// The agent moved this pane's conversation to another folder (`UseFolder`): reopen it there,
    /// so the pane, the sidebar and the git bar follow. The old engine lets go of the session
    /// file first; resuming a session another process holds would start a new one instead.
    func move(_ pane: Pane, to url: URL) {
        guard let id = pane.workspace.conversation?.sessionID else { return }
        pane.incoming?.stop(reason: "open superseded")
        pane.incoming = nil
        let old = pane.workspace
        old.stop(reason: "session moved folder")
        Task {
            await Frog.released(session: id, within: .seconds(3))
            // Something else took the pane meanwhile.
            guard pane.workspace === old, pane.incoming == nil else { return }
            let workspace = Workspace(folder: url, resume: id)
            pane.incoming = workspace
            await workspace.settled(within: .seconds(2))
            guard pane.incoming === workspace else { return }
            Motion.cut { setWorkspace(workspace, in: pane) }
        }
    }

    /// Show a session in a pane. If a pane already shows it, focus that one; if another window
    /// does, bring that window forward.
    func open(_ s: SessionInfo, in pane: Pane, window: NSWindow?) {
        if focusSession(s.id) { return }
        guard let url = s.folder, pane.incoming?.conversation?.sessionID != s.id else { return }
        if Library.shared.focusSession(s.id, excluding: window) { return }
        pane.incoming?.stop(reason: "open superseded")
        pane.incoming = nil
        if pane.workspace.folder.standardizedFileURL.path == url.standardizedFileURL.path {
            pane.workspace.open(s.id)
        } else {
            // The new folder takes the pane once its conversation is in, so the pane cuts from
            // one conversation to the next instead of emptying and filling in.
            let workspace = Workspace(folder: url, resume: s.id)
            pane.workspace.opening = s.id
            pane.incoming = workspace
            Task {
                await workspace.settled(within: .milliseconds(300))
                guard pane.incoming === workspace else { return }
                Motion.cut { setWorkspace(workspace, in: pane) }
            }
        }
        focus(pane)
    }

    // MARK: Splitting

    var canSplit: Bool { items.count < Self.maxPanes }

    /// A new pane beside the focused one (or `target`): a session from the sidebar, or a fresh
    /// conversation in that pane's folder.
    func split(_ s: SessionInfo? = nil, beside target: Pane? = nil, on edge: PaneEdge = .right, window: NSWindow? = nil) {
        if let s, focusSession(s.id) { return }
        guard canSplit else { return }
        let target = target ?? focused
        let workspace: Workspace
        if let s, let url = s.folder {
            if Library.shared.focusSession(s.id, excluding: window) { return }
            workspace = Workspace(folder: url, resume: s.id)
        } else {
            workspace = Workspace(folder: target.workspace.folder, fresh: true)
        }
        let pane = Pane(workspace: workspace)
        items.append(pane)
        setLayout(layout.inserting(pane.id, beside: target.id, on: edge))
        focusedID = pane.id
        pane.ui.focusComposer()
    }

    /// A pane for `workspace` at the end of the window, beside the last one (restoring).
    func add(_ workspace: Workspace) {
        guard canSplit, let last = items.last else { return }
        let pane = Pane(workspace: workspace)
        items.append(pane)
        setLayout(layout.inserting(pane.id, beside: last.id, on: .right))
    }

    /// Move a pane beside another, or swap the two.
    func move(_ pane: Pane, to target: Pane, _ drop: PaneDrop) {
        guard pane !== target else { return }
        switch drop {
        case .center:
            setLayout(layout.swapping(pane.id, target.id))
        case .edge(let edge):
            guard let without = layout.removing(pane.id) else { return }
            setLayout(without.inserting(pane.id, beside: target.id, on: edge))
        }
        focus(pane)
    }

    /// Something dropped on a pane: another pane, or a conversation from the sidebar.
    func drop(_ payload: PaneDragger.Payload, on target: Pane, _ drop: PaneDrop, window: NSWindow?) {
        switch payload {
        case .pane(let id):
            if let pane = items.first(where: { $0.id == id }) { move(pane, to: target, drop) }
        case .session(let s):
            switch drop {
            case .center: open(s, in: target, window: window)
            case .edge(let edge):
                // Already on screen: move that pane there instead of opening it twice.
                if let p = paneShowing(s.id) { move(p, to: target, drop) } else { split(s, beside: target, on: edge, window: window) }
            }
        }
    }

    /// Drag a divider to `t` (0...1 along its split), keeping each side at least `minimum`
    /// (points, of the split's length `length`).
    func moveDivider(_ d: PaneLayout.Divider, to t: CGFloat, minimum: CGFloat) {
        let length = d.axis == .horizontal ? d.parent.width : d.parent.height
        guard length > 0 else { return }
        layout = layout.moving(divider: d.index, at: d.path, to: t, minimum: minimum / length)
    }

    /// The smallest either pane beside this divider may get. A pane showing tools (terminal or
    /// preview) is useful at 260 — the card is the point of the pane — while a transcript needs
    /// its readable floor; the tighter of the two wins, so one side's floor doesn't pin the
    /// other when the canvas is narrow.
    func minimum(paneWidth floor: CGFloat, forToolPanes toolFloor: CGFloat, beside d: PaneLayout.Divider) -> CGFloat {
        guard case .split(_, let children, _) = layout.navigating(d.path) else { return floor }
        let at = d.index + 1 < children.count ? [children[d.index], children[d.index + 1]] : [children[d.index]]
        let neighbors = at.flatMap(\.leaves).compactMap { id in items.first { $0.id == id } }
        let tools = neighbors.contains { $0.toolCount > 0 }
        return tools ? toolFloor : floor
    }

    func equalize(_ d: PaneLayout.Divider) {
        layout = layout.equalizing(at: d.path)
    }

    // MARK: Maximizing

    var maximizedPane: Pane? { maximized.flatMap { id in items.first { $0.id == id } } }

    /// Toggle a pane between filling the canvas and its share of the layout. The weights go
    /// away and come back exactly: maximizing is a view over the layout, not a change to it.
    func toggleMaximized(_ pane: Pane) {
        if maximized == pane.id {
            maximized = nil
            if let saved = savedLayout { layout = saved; savedLayout = nil }
        } else {
            if maximized == nil { savedLayout = layout }
            maximized = pane.id
        }
        focus(pane)
    }

    /// Maximize the focused pane, or restore when one is up.
    func toggleMaximizedFocused() {
        toggleMaximized(focused)
    }

    /// Keep `items` in the layout's reading order, and the window's folder with the first pane.
    private func setLayout(_ new: PaneLayout) {
        let firstBefore = items.first
        layout = new
        // A pane that left (closed, or its pane replaced by another arrangement) can't stay up.
        if let id = maximized, new.leaves.first(where: { $0 == id }) == nil { maximized = nil; savedLayout = nil }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = new.leaves.compactMap { byID[$0] }
        if let first = items.first, first !== firstBefore { onPrimaryFolder?(first.workspace.folder) }
    }

    /// Tests only: set the layout and keep `items` in its reading order, as `setLayout` does
    /// but without touching the maximized state (the tests arrange first, maximize after).
    func reorderForTesting(_ new: PaneLayout) {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        layout = new
        items = new.leaves.compactMap { byID[$0] }
    }

    func close(_ pane: Pane) {
        guard isSplit, let rest = layout.removing(pane.id) else { return }
        let wasFirst = pane === items.first
        pane.incoming?.stop(reason: "pane closed")
        pane.workspace.stop(reason: "pane closed")
        items.removeAll { $0 === pane }
        setLayout(rest)
        if focusedID == pane.id { focusedID = items[0].id }
        if wasFirst { onPrimaryFolder?(items[0].workspace.folder) }
    }

    /// Keep `items` in the layout's reading order, and the window's folder with the first pane.
    func stopAll() {
        Library.shared.register(window: nil, panes: self)
        items.forEach {
            $0.incoming?.stop(reason: "window closed")
            $0.workspace.stop(reason: "window closed")
        }
    }
}

/// A drag in progress within a window: a pane by its header, or a conversation from the
/// sidebar, on its way to a pane's edge (split there) or middle (swap, or show it there).
/// In-window, so it's a plain gesture rather than system drag and drop: the window draws the
/// preview and decides the drop.
@MainActor
@Observable
final class PaneDragger {
    enum Payload: Equatable {
        case pane(Pane.ID)
        case session(SessionInfo)
    }

    private(set) var payload: Payload?
    private(set) var title = ""
    /// The pointer, in global coordinates.
    private(set) var location: CGPoint = .zero
    @ObservationIgnored var onDrop: ((Payload, CGPoint) -> Void)?

    var active: Bool { payload != nil }

    func move(_ payload: Payload, title: String, to location: CGPoint) {
        if self.payload != payload {
            self.payload = payload
            self.title = title
        }
        self.location = location
    }

    func end(at location: CGPoint) {
        guard let payload else { return }
        self.payload = nil
        onDrop?(payload, location)
    }
}

extension PaneDrop {
    /// The part of a pane's frame a drop takes: a half for an edge, all of it for a swap.
    func rect(in f: CGRect) -> CGRect {
        switch self {
        case .center: f
        case .edge(.left): CGRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height)
        case .edge(.right): CGRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height)
        case .edge(.top): CGRect(x: f.minX, y: f.minY, width: f.width, height: f.height / 2)
        case .edge(.bottom): CGRect(x: f.minX, y: f.midY, width: f.width, height: f.height / 2)
        }
    }

    /// Nearest edge within a band around the border, else the middle.
    init(at p: CGPoint, in f: CGRect, band: CGFloat = 0.3) {
        guard f.width > 0, f.height > 0 else { self = .center; return }
        let x = (p.x - f.minX) / f.width, y = (p.y - f.minY) / f.height
        let edges: [(CGFloat, PaneEdge)] = [(x, .left), (1 - x, .right), (y, .top), (1 - y, .bottom)]
        let nearest = edges.min { $0.0 < $1.0 }!
        self = nearest.0 < band ? .edge(nearest.1) : .center
    }
}

extension EnvironmentValues {
    @Entry var paneDragger: PaneDragger?
}

extension View {
    /// Drag this onto a pane to move it there (a pane's header) or open it there (a
    /// conversation). Clicks still reach the view: it only starts after the pointer moves.
    func paneDraggable(_ payload: PaneDragger.Payload, title: String) -> some View {
        modifier(PaneDraggable(payload: payload, title: title))
    }
}

private struct PaneDraggable: ViewModifier {
    let payload: PaneDragger.Payload
    let title: String
    @Environment(\.paneDragger) private var dragger

    func body(content: Content) -> some View {
        // Ahead of the buttons inside (a row, the activity capsule), which would otherwise keep
        // the mouse; a click that doesn't move still reaches them.
        content.highPriorityGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { dragger?.move(payload, title: title, to: $0.location) }
                .onEnded { dragger?.end(at: $0.location) }
        )
    }
}
