import SwiftUI

/// Every conversation. By default (Group By › Org) the attention tree: the chief's tile, what
/// needs you, the org as a started-by tree scoped to Live, Today or All, then yours, with search
/// filtering it in place (`AttentionTree`, docs/design/sidebar-refactor.md). The older views:
/// pinned ones as tiles on top, then one group per project folder
/// (newest activity first), then plain chats, which archive themselves once they go quiet.
/// The view options (the header's filter button) group by project, by date or not at all, and
/// sort by last activity, creation or name. Searching or browsing the archive is by day. Rows show whether a
/// conversation is running, waiting on you, or finished while you were away; a folded group
/// still counts its live ones.
struct SessionList: View {
    @Bindable var workspace: Workspace
    let maxHeight: CGFloat
    var collapse: (() -> Void)?
    @State private var library = Library.shared
    @State private var cloud = CloudSessions.shared
    @State private var query: String

    init(workspace: Workspace, maxHeight: CGFloat, query: String = "", collapse: (() -> Void)? = nil) {
        self.workspace = workspace
        self.maxHeight = maxHeight
        self.collapse = collapse
        _query = State(initialValue: query)
    }
    #if DEBUG
    var body: some View {
        let _ = TranscriptProbe.sidebar()
        listBody
    }
    #else
    var body: some View { listBody }
    #endif

    @State private var showArchived = false
    @State private var showTree = false
    @State private var renaming: SessionInfo?
    @State private var newTitle = ""
    /// Groups showing all their conversations rather than the latest few.
    @State private var expanded: Set<String> = []
    /// Folded branches whose older sessions are disclosed, by the branch's newest session id.
    @State private var openFolds: Set<String> = []
    /// Parents whose finished children are disclosed (their "+N done" row is open).
    @State private var openDone: Set<String> = []
    /// Parents showing only their children's counts ("4 running · 1 waiting"), not the rows.
    @State private var collapsedParents: Set<String> = []
    /// Folded project groups, by folder path (newline-separated).
    @AppStorage("foldedGroups") private var foldedRaw = ""
    /// Org (the attention tree) by default; the older project and date views stay a choice.
    @AppStorage("sidebarGroup") private var grouping = Grouping.date
    @AppStorage("sidebarSort") private var sort = Sort.activity
    /// The tree's scope (Live · Today · All), per window like the grouping.
    @AppStorage("sidebarScope") private var scope = AttentionTree.Scope.live
    @AppStorage("compactSidebar") private var compactSidebar = false

    /// How rows are grouped: by project folder (pins, folders, chats), by day, or not at all.
    enum Grouping: String, CaseIterable {
        case org, project, date, none
        var title: String {
            switch self {
            case .org: "Org"
            case .project: "Project"
            case .date: "Date"
            case .none: "None"
            }
        }
    }

    enum Sort: String, CaseIterable {
        case activity, created, name
        var title: String {
            switch self {
            case .activity: "Last Activity"
            case .created: "Date Created"
            case .name: "Name"
            }
        }
    }

    /// Whether `a` comes before `b` in the chosen order.
    private func before(_ a: SessionInfo, _ b: SessionInfo) -> Bool {
        switch sort {
        case .activity: a.modified > b.modified
        case .created: a.created > b.created
        case .name: a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
        }
    }

    /// The date a row is filed under when grouping by date.
    private func day(_ s: SessionInfo) -> Date {
        sort == .created ? Date(timeIntervalSince1970: Double(s.created) / 1000) : s.modifiedDate
    }
    @Environment(\.openSession) private var openSession
    @Environment(\.openSessionInSplit) private var openInSplit
    @Environment(\.paneNumbers) private var paneNumbers
    @Environment(\.switchFolder) private var switchFolder

    /// Conversations shown per project before "Show more".
    static let groupLimit = 5

    /// The session this window shows. Reads the workspace's *ids* only: a streamed turn
    /// changes `workspace.conversation`'s contents every 30 Hz batch, and a sidebar that
    /// tracked that re-derived the whole list per delta (the workspace's `currentSession`
    /// mirrors the id as the conversation opens and moves).
    private var current: String? { workspace.opening ?? workspace.currentSession }
    private var folded: Set<String> { Set(foldedRaw.split(separator: "\n").map(String.init)) }
    private var filtering: Bool { showArchived || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var active: [SessionInfo] {
        library.sessions.filter { !library.archived.contains($0.id) }
    }

    private var pins: [SessionInfo] {
        active.filter { library.pinned.contains($0.id) && (!FeatureFlags.chief || $0.id != library.chief) }
    }

    private var projects: [(folder: URL, items: [SessionInfo])] {
        let unpinned = active.filter { !$0.isChat && !library.pinned.contains($0.id) && $0.folder != nil }
        let byPath = Dictionary(grouping: unpinned) { home($0).standardizedFileURL.path }
        return byPath.values
            .map { items in
                let sorted = items.sorted(by: before)
                return (home(sorted[0]), sorted)
            }
            // Folders follow their first conversation, or their own name when sorting by name.
            .sorted { a, b in
                sort == .name
                    ? a.folder.lastPathComponent.localizedStandardCompare(b.folder.lastPathComponent) == .orderedAscending
                    : before(a.items[0], b.items[0])
            }
    }

    /// The folder a session is filed under: its own, or (for one started by another session,
    /// say in a worktree) its topmost parent's.
    private func home(_ s: SessionInfo) -> URL {
        var current = s
        var seen: Set<String> = [s.id]
        while let p = library.parents[current.id], !seen.contains(p),
              let parent = library.sessions.first(where: { $0.id == p }), parent.folder != nil, !parent.isChat {
            seen.insert(p)
            current = parent
        }
        return Self.repoRoot(current.folder ?? s.folder!)
    }

    /// A worker worktree (`<repo>/.frog/worktrees/<name>` or `<repo>/.claude/worktrees/<name>`)
    /// files under its repo.
    static func repoRoot(_ folder: URL) -> URL {
        let path = folder.standardizedFileURL.path
        for marker in ["/.frog/worktrees/", "/.claude/worktrees/"] {
            if let r = path.range(of: marker) { return URL(fileURLWithPath: String(path[..<r.lowerBound])) }
        }
        return folder
    }

    /// The worktree name, when a session runs in one under its repo.
    static func worktreeName(_ folder: URL?) -> String? {
        guard let folder, Self.repoRoot(folder) != folder else { return nil }
        return folder.lastPathComponent
    }

    /// A row's state, the same derivation its glyph uses.
    private func rowState(_ s: SessionInfo) -> SessionNesting.State {
        SessionNesting.State(SessionEndGlyph.derive(live: library.live[s.id], end: s.end))
    }

    /// Fold heads in tree order: each followed by the ones it started, settled children
    /// folded under a "+N done" row. A fold's parent is any member's (a resumed worker keeps
    /// its manager), and a parent folded away under its newest session nests under that.
    private func tree(_ folds: [SessionFolds.Fold]) -> [SessionNesting.Entry] {
        var alias: [String: String] = [:]
        for f in folds { for o in f.older { alias[o.id] = f.session.id } }
        var parentOf: [String: String] = [:]
        for f in folds {
            let p = ([f.session] + f.older).lazy.compactMap { self.library.parents[$0.id] }.first
            if let p { parentOf[f.session.id] = alias[p] ?? p }
        }
        return SessionNesting.rows(
            folds.map(\.session), parent: { parentOf[$0] }, state: rowState, before: before,
            openDone: openDone, keep: current.map { [$0] } ?? [], collapsed: collapsedParents)
    }

    private func toggleChildren(_ parent: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if collapsedParents.remove(parent) == nil { collapsedParents.insert(parent) }
        }
    }

    private func toggleDone(_ parent: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if openDone.remove(parent) == nil { openDone.insert(parent) }
        }
    }

    private var chats: [SessionInfo] {
        active.filter { $0.isChat && !library.pinned.contains($0.id) }.sorted(by: before)
    }

    /// Everything that isn't pinned, for grouping by date or not at all.
    private var unpinned: [SessionInfo] {
        active.filter { !library.pinned.contains($0.id) }
    }

    private var listBody: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if showArchived {
                        flat
                    } else if grouping == .org {
                        attention
                    } else if filtering {
                        flat
                    } else {
                        chiefTile
                        // Compact is density, not grouping: by date stays by date (as on the web).
                        if compactSidebar, grouping == .project || grouping == .org {
                            compactTabs
                        } else {
                            switch grouping {
                            case .org, .project: tabs
                            case .date: pinTiles; dated(unpinned)
                            case .none:
                                pinTiles
                                ForEach(unpinned.sorted(by: before)) { listRow($0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            // A git hover card is anchored to its badge: scrolling the list closes it.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, new in
                if abs(new - old) > 1 { GitCardController.shared.close() }
            }
            footer
            UserFooter()
        }
        .frame(maxHeight: maxHeight)
        .onAppear {
            library.refresh()
            cloud.start()
            // Once: the calm, web-like list (by date) becomes the view; the tree stays a choice.
            if !UserDefaults.standard.bool(forKey: "calmSidebar") {
                UserDefaults.standard.set(true, forKey: "calmSidebar")
                grouping = .date
            }
        }
        .alert("Rename Conversation", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let s = renaming {
                    if library.isCloud(s.id), let gateway = cloud.gateway {
                        CloudLink.rename(s.id, to: newTitle, gateway: gateway)
                        Task { try? await Task.sleep(for: .seconds(9)); await cloud.refresh() }
                    } else {
                        Task { await library.rename(s.id, to: newTitle) }
                    }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .popover(isPresented: $showTree, arrowEdge: .trailing) {
            SessionTree(workspace: workspace) { showTree = false }
        }
    }

    /// The chief of staff, always first: a wide tile with what it's doing or asking, like a
    /// pinned chat at the top of Messages. Shown in every grouping; hidden while searching;
    /// hidden with the flag off entirely (a pinned session is the home base instead).
    @ViewBuilder
    private var chiefTile: some View {
        if FeatureFlags.chief, let s = library.chiefSession {
            Button { open(s) } label: {
                ChiefTile(session: s, selected: s.id == current, live: library.live[s.id], library: library)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let openInSplit, paneNumbers[s.id] == nil {
                    Button("Open in New Pane") { openInSplit(s) }
                }
                Button("Rename…") {
                    newTitle = s.displayTitle
                    renaming = s
                }
                Button("Remove Chief") { library.removeChief() }
                Divider()
                if let f = s.folder, !s.isChat {
                    Button("Reveal Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                }
                if s.id == current {
                    Button("Session Tree…") { showTree = true }
                }
            }
            .paneDraggable(.session(s), title: s.displayTitle)
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
    }

    // MARK: Attention tree


    /// The org tree as the sidebar draws it, and each fold head's older branch sessions.
    /// Shared with the quick-switch shortcuts (`WorkspaceView.sidebarOrder`), so ⌘1…9 count
    /// the rows on screen.
    static func attention(_ library: Library, sort: Sort, scope: AttentionTree.Scope, current: String?,
                          openDone: Set<String> = [], collapsed: Set<String> = [],
                          query: String = "") -> (layout: AttentionTree.Layout, folds: [String: SessionFolds.Fold],
                                                  parentOf: [String: String], heads: [SessionInfo]) {
        var active = library.sessions.filter { !library.archived.contains($0.id) }
        var scope = scope
        if !query.isEmpty {
            active = AttentionTree.matching(active, parent: { library.parents[$0] }) { AttentionTree.matches($0, query) }
            scope = .all
        }
        let chief = FeatureFlags.chief ? library.chief : nil
        let others = active.filter { $0.id != chief }
        let folds = SessionFolds.group(others, parent: { library.parents[$0] })
        // A fold's parent is any member's (a resumed worker keeps its manager); a parent folded
        // away under its newest session nests under that.
        var alias: [String: String] = [:]
        for f in folds { for o in f.older { alias[o.id] = f.session.id } }
        var parentOf: [String: String] = [:]
        for f in folds {
            if let p = ([f.session] + f.older).lazy.compactMap({ library.parents[$0.id] }).first {
                parentOf[f.session.id] = alias[p] ?? p
            }
        }
        let heads = folds.map(\.session) + active.filter { $0.id == chief }
        let pinned = library.pinned
        let order = Self.order(sort)
        let layout = AttentionTree.layout(
            heads, parent: { parentOf[$0] }, chief: chief,
            state: { SessionNesting.State(SessionEndGlyph.derive(live: library.live[$0.id], end: $0.end)) },
            // Pins float to the top of their level.
            before: { a, b in
                let (pa, pb) = (pinned.contains(a.id), pinned.contains(b.id))
                return pa != pb ? pa : order(a, b)
            },
            scope: scope,
            recent: { Calendar.current.isDateInToday($0.modifiedDate) },
            openDone: openDone,
            keep: current.map { [alias[$0] ?? $0] } ?? [],
            collapsed: collapsed)
        return (layout, Dictionary(folds.map { ($0.session.id, $0) }, uniquingKeysWith: { a, _ in a }), parentOf, heads)
    }

    /// `before`, without the view.
    static func order(_ sort: Sort) -> (SessionInfo, SessionInfo) -> Bool {
        switch sort {
        case .activity: { $0.modified > $1.modified }
        case .created: { $0.created > $1.created }
        case .name: { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        }
    }

    /// The search text as the tree matches it.
    private var needle: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    @ViewBuilder
    private var attention: some View {
        let q = needle
        let built = Self.attention(library, sort: sort, scope: scope, current: current,
                                   openDone: openDone, collapsed: collapsedParents, query: q)
        let git = GitTreeBadges.build(built.layout.org + built.layout.yours, heads: built.heads, parentOf: built.parentOf,
                                      folds: built.folds, chief: FeatureFlags.chief ? library.chief : nil, state: rowState) { open($0) }
        if FeatureFlags.chief, q.isEmpty || library.chiefSession.map({ AttentionTree.matches($0, q) }) == true {
            chiefTile
        }
        // A lens, not a move: each also keeps its place in the tree, with its orange dot.
        if q.isEmpty, !built.layout.needsYou.isEmpty {
            treeLabel("Needs you", count: built.layout.needsYou.count, tint: .orange)
            ForEach(built.layout.needsYou) { s in
                NeedsYouRow(session: s, ask: library.asking(s.id) ?? "Waiting on you", selected: s.id == current) {
                    open(s)
                } menu: { rowMenu(s) }
            }
        }
        // Searching filters the tree in place (scope set aside): matches keep their ancestors.
        if !built.layout.org.isEmpty {
            treeLabel("Org") { if q.isEmpty { scopePicker } }
            treeEntries(built.layout.org, folds: built.folds, git: git, highlight: q)
        }
        if !built.layout.yours.isEmpty {
            treeLabel("Yours") {
                if q.isEmpty, built.layout.org.isEmpty { scopePicker }
            }
            treeEntries(built.layout.yours, folds: built.folds, git: git, highlight: q)
        }
        if !q.isEmpty {
            let archived = archiveMatches(q)
            if !archived.isEmpty {
                treeLabel("In archive", count: archived.count)
                ForEach(archived) { s in
                    TreeRow(session: s, depth: 0, counts: .init(), collapsed: false, state: rowState(s),
                            selected: s.id == current, highlight: q, monogram: false) { open(s) } menu: { rowMenu(s) }
                }
            }
            if built.layout.org.isEmpty && built.layout.yours.isEmpty && archived.isEmpty {
                empty("No matches")
            }
        } else if built.layout.org.isEmpty && built.layout.yours.isEmpty && (FeatureFlags.chief ? library.chiefSession : nil) == nil {
            empty("No conversations yet")
        }
    }

    /// Archived sessions the search matches, newest first.
    private func archiveMatches(_ q: String) -> [SessionInfo] {
        library.sessions.filter { library.archived.contains($0.id) && AttentionTree.matches($0, q) }.sorted(by: before)
    }

    /// Return in the search field: open the first match, the tree's then the archive's.
    private func jumpToFirstMatch() {
        let q = needle
        guard !q.isEmpty, grouping == .org else { return }
        let built = Self.attention(library, sort: sort, scope: scope, current: current, query: q)
        let rows = (built.layout.org + built.layout.yours).compactMap { e -> SessionInfo? in
            if case .row(let s, _, _, _) = e { return s } else { return nil }
        }
        let first = rows.first { AttentionTree.matches($0, q) } ?? archiveMatches(q).first
        guard let first else { return }
        open(first)
        query = ""
    }

    /// Live · Today · All: how much settled work the tree shows.
    private var scopePicker: some View {
        Picker("Scope", selection: $scope.animation(.snappy(duration: 0.2))) {
            ForEach(AttentionTree.Scope.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .fixedSize()
        .help("Live: settled work folds away · Today: and what finished today · All: everything")
    }

    /// A section's small caps label, with an accessory (the scope switch) on the right.
    private func treeLabel<T: View>(_ title: String, count: Int? = nil, tint: Color = .secondary,
                                    @ViewBuilder trailing: () -> T = { EmptyView() }) -> some View {
        HStack(spacing: 5) {
            Text(title.uppercased()).tracking(0.6)
            if let count { Text("\(count)") }
            Spacer(minLength: 4)
            trailing()
        }
        .font(.frog(size: 10, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.top, 12)
        .padding(.bottom, 3)
    }

    private func treeEntries(_ entries: [SessionNesting.Entry], folds: [String: SessionFolds.Fold],
                             git: GitTreeBadges, highlight: String = "") -> some View {
        ForEach(entries) { entry in
            switch entry {
            case .row(let s, let depth, let counts, let collapsed):
                TreeRow(
                    session: s, depth: depth, counts: counts, collapsed: collapsed,
                    state: rowState(s), selected: s.id == current,
                    pinned: library.pinned.contains(s.id), pane: paneNumbers[s.id], highlight: highlight,
                    onToggle: { toggleNode(s.id, collapsed: collapsed, counts: counts) },
                    git: git.rows[s.id], line: library.rowLine(s)
                ) { open(s) } menu: { rowMenu(s, older: folds[s.id]?.older ?? [], git: git.rows[s.id]) }
                if let c = library.conversation(s.id), !collapsed {
                    // Its own view: only it watches the conversation's turns as they stream.
                    SessionAgents(conversation: c, depth: depth + 1) { open(s) }
                }
            case .done(let parent, let depth, let count, let failed, let open):
                foldRow(parent: parent, depth: depth, count: count, failed: failed, open: open, git: git.folds[parent])
            }
        }
    }

    /// A row's disclosure: a quiet manager (folded by the scope) opens its done row; one
    /// opened that way folds back; anything else collapses to its counts or shows them again.
    private func toggleNode(_ id: String, collapsed: Bool, counts: SessionNesting.Counts) {
        let live = counts.waiting + counts.running + counts.unread
        if collapsed && !collapsedParents.contains(id) {
            toggleDone(id)
        } else if !collapsed && live == 0 && scope != .all && openDone.contains(id) {
            toggleDone(id)
        } else {
            toggleChildren(id)
        }
    }

    /// Settled work folded into one line: "18 done · 1 failed", "12 earlier", "4 done by chief".
    private func foldRow(parent: String, depth: Int, count: Int, failed: Int, open: Bool,
                         git: GitRowBadge? = nil) -> some View {
        let what = parent == AttentionTree.chiefFold ? "done by chief"
            : scope == .today && parent != AttentionTree.yoursFold ? "earlier" : "done"
        return HStack(spacing: 0) {
            Button { toggleDone(parent) } label: {
                HStack(spacing: 0) {
                    Color.clear.frame(width: AttentionMetrics.leading(depth))
                    Image(systemName: "chevron.right").font(.frog(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: AttentionMetrics.disclosure)
                    Text("\(count) \(what)")
                    if failed > 0 {
                        Text(" · \(failed) failed").foregroundStyle(.red.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                }
                .font(.frog(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
                .frame(height: 22)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(open ? "Hide finished sessions" : "Show \(count) finished session\(count == 1 ? "" : "s")")
            // Did the finished work land? The fold's sum, without opening it.
            if let git {
                GitBadgeView(display: git.display, muted: true, help: git.help, card: git.card)
                    .padding(.trailing, 26)
            }
        }
    }

    // MARK: Tabs

    @ViewBuilder
    private var compactTabs: some View {
        compactPins
        ForEach(projects, id: \.folder) { folder, items in
            let key = folder.standardizedFileURL.path
            let isFolded = folded.contains(key)
            HStack(spacing: 5) {
                Text(folder.lastPathComponent)
                    .lineLimit(1)
                    .font(.frog(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                repoBadge(folder, items)
                Button { switchFolder?(folder) } label: {
                    Image(systemName: "plus").font(.caption2.weight(.semibold))
                        .frame(width: 20, height: 20).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("New conversation here")
                Button { withAnimation(.snappy(duration: 0.2)) { toggleFold(key) } } label: {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                        .frame(width: 14, height: 20).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help(isFolded ? "Expand project" : "Collapse project")
            }
            .padding(.leading, 6).padding(.top, 8)
            if !isFolded { compactProjectRows(items) }
        }
        if !chats.isEmpty {
            compactHeader("Chats")
            ForEach(chats) { compactRow($0, depth: 0) }
        }
        if projects.isEmpty && chats.isEmpty && pins.isEmpty && (FeatureFlags.chief ? library.chiefSession : nil) == nil { empty("No conversations yet") }
    }

    private var compactPins: some View {
        Group {
            if !pins.isEmpty {
                compactHeader("Pinned")
                ForEach(pins) { compactRow($0, depth: 0) }
            }
        }
    }

    private func compactHeader(_ title: String) -> some View {
        Text(title).font(.frog(size: 10)).foregroundStyle(.secondary)
            .padding(.leading, 6).padding(.top, 5).padding(.bottom, 1)
    }

    /// A day's rows, branches folded: one row for each fold's newest session, older sessions
    /// behind the row's disclosure, and other nesting (started-by) applied on top.
    /// A project's rows: branches and redone tasks folded and the started-by tree built over
    /// the whole project, then each top-level row (with everything under it) filed under the
    /// day of its newest activity. Folding per day split a branch resumed the next day, or a
    /// manager from its workers, into separate rows.
    @ViewBuilder
    private func compactProjectRows(_ items: [SessionInfo]) -> some View {
        let folds = SessionFolds.group(items, parent: { library.parents[$0] })
        let byId = Dictionary(uniqueKeysWithValues: folds.map { ($0.session.id, $0) })
        let blocks = SessionNesting.blocks(tree(folds))
        let newest = Dictionary(uniqueKeysWithValues: blocks.map { b in
            (b.root.id, b.entries.compactMap { e -> Date? in
                if case .row(let s, _, _, _) = e { return s.modifiedDate } else { return nil }
            }.max() ?? b.root.modifiedDate)
        })
        let entries = Dictionary(uniqueKeysWithValues: blocks.map { ($0.root.id, $0.entries) })
        ForEach(SessionDays.group(blocks.map(\.root), day: { sort == .created ? day($0) : newest[$0.id] ?? day($0) }), id: \.0) { title, roots in
            compactHeader(title)
            compactEntries(roots.flatMap { entries[$0.id] ?? [] }, byId: byId)
        }
    }

    private func compactEntries(_ list: [SessionNesting.Entry], byId: [String: SessionFolds.Fold]) -> some View {
        ForEach(list) { entry in
            switch entry {
            case .row(let s, let depth, let counts, let collapsed):
                compactBranchRow(s, depth: depth, counts: counts, collapsed: collapsed, fold: byId[s.id])
            case .done(let parent, let depth, let count, let failed, let open):
                // Lined up with its siblings' titles (rail, then the fold slot).
                doneRow(parent: parent, count: count, failed: failed, open: open)
                    .padding(.leading, CGFloat(max(depth - 1, 0)) * 8 + 12)
            }
        }
    }

    /// A parent's finished children folded into one line: "+3 done", with how many failed.
    private func doneRow(parent: String, count: Int, failed: Int, open: Bool) -> some View {
        Button { toggleDone(parent) } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right").font(.frog(size: 8, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text("+\(count) done")
                if failed > 0 {
                    Text("· \(failed) failed").foregroundStyle(.red.opacity(0.8))
                }
                Spacer(minLength: 0)
            }
            .font(.frog(size: 11))
            .foregroundStyle(.tertiary)
            .frame(height: 22)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(open ? "Hide finished sessions" : "Show \(count) finished session\(count == 1 ? "" : "s")")
    }

    /// One fold's row (its newest session) plus, when disclosed, the older ones indented.
    @ViewBuilder
    private func compactBranchRow(_ session: SessionInfo, depth: Int, counts: SessionNesting.Counts,
                                  collapsed: Bool, fold: SessionFolds.Fold?) -> some View {
        let fold = fold ?? SessionFolds.Fold(session: session, older: [])
        let isOpen = openFolds.contains(session.id)
        compactRow(session, depth: depth, folded: fold.older.count, foldOpen: isOpen, counts: counts,
                   collapsed: collapsed, onFold: fold.folded ? { toggleFoldBranch(session.id) } : nil)
        if fold.folded, isOpen {
            ForEach(fold.older) { older in
                compactRow(older, depth: depth + 1)
            }
        }
    }

    private func toggleFoldBranch(_ id: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if openFolds.remove(id) == nil { openFolds.insert(id) }
        }
    }

    private func compactRow(_ session: SessionInfo, depth: Int, folded: Int = 0, foldOpen: Bool = false,
                            counts: SessionNesting.Counts = .init(), collapsed: Bool = false,
                            onFold: (() -> Void)? = nil) -> some View {
        CompactSessionRow(
            session: session, selected: session.id == current,
            live: library.live[session.id], depth: depth,
            git: GitTreeBadges.leaf(session, members: [session], settled: GitTreeBadges.settled(rowState(session))) { open($0) },
            folded: folded, foldOpen: foldOpen, counts: counts, collapsed: collapsed, onFold: onFold,
            onCollapse: counts.total > 0 ? { toggleChildren(session.id) } : nil
        ) { open(session) } menu: { rowMenu(session) }
    }

    @ViewBuilder
    private var tabs: some View {
        pinTiles
        ForEach(projects, id: \.folder) { folder, items in
            projectGroup(folder, items)
        }
        if !chats.isEmpty {
            sectionHeader {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                Text("Chats")
            } trailing: {
                if Library.autoArchiveChats {
                    Text("archive after 12h").foregroundStyle(.tertiary)
                }
            }
            ForEach(chats) { row($0, showPlace: false) }
        }
        if projects.isEmpty && chats.isEmpty && pins.isEmpty && (FeatureFlags.chief ? library.chiefSession : nil) == nil {
            empty("No conversations yet")
        }
    }

    /// Pinned conversations, as tiles above everything else in every grouping.
    @ViewBuilder
    private var pinTiles: some View {
        if !pins.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(pins) { s in
                    Button { open(s) } label: {
                        Monogram(session: s, size: 38, selected: s.id == current, live: library.live[s.id])
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { rowMenu(s) }
                    .paneDraggable(.session(s), title: s.displayTitle)
                    .help(s.displayTitle)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func projectGroup(_ folder: URL, _ items: [SessionInfo]) -> some View {
        let key = folder.standardizedFileURL.path
        let isFolded = folded.contains(key)
        let liveCount = items.count(where: { library.live[$0.id] != nil })
        Button {
            withAnimation(.snappy(duration: 0.25)) { toggleFold(key) }
        } label: {
            sectionHeader {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                Image(systemName: "folder.fill").foregroundStyle(FolderTint.color(folder))
                Text(folder.lastPathComponent).lineLimit(1)
            } trailing: {
                if isFolded && liveCount > 0 {
                    Text("\(liveCount) active").foregroundStyle(.secondary)
                }
                repoBadge(folder, items)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("New Conversation Here") { switchFolder?(folder) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
        if !isFolded {
            let all = expanded.contains(key)
            // The latest few, plus anything live or on screen further down.
            let shown = all ? items : items.enumerated().filter { i, s in
                i < Self.groupLimit || library.live[s.id] != nil || s.id == current
            }.map(\.element)
            let folds = SessionFolds.group(shown, parent: { library.parents[$0] })
            let byId = Dictionary(uniqueKeysWithValues: folds.map { ($0.session.id, $0) })
            ForEach(tree(folds)) { entry in
                switch entry {
                case .row(let s, let depth, let counts, let collapsed):
                    let summary = collapsed ? counts.summary : nil
                    if let fold = byId[s.id], fold.folded {
                        branchRow(s, depth: depth, fold: fold, summary: summary)
                    } else {
                        row(s, showPlace: false, nested: depth > 0, summary: summary)
                            .padding(.leading, CGFloat(depth) * 10)
                    }
                case .done(let parent, let depth, let count, let failed, let open):
                    doneRow(parent: parent, count: count, failed: failed, open: open)
                        .padding(.leading, CGFloat(depth) * 10 + 10)
                }
            }
            if items.count > shown.count || (all && items.count > Self.groupLimit) {
                Button(all ? "Show less" : "Show \(items.count - shown.count) more") {
                    withAnimation(.snappy(duration: 0.25)) {
                        if all { expanded.remove(key) } else { expanded.insert(key) }
                    }
                }
                .buttonStyle(.plain)
                .font(.frog(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
    }

    /// A project header's git badge: the sum over its sessions' trees.
    @ViewBuilder
    private func repoBadge(_ folder: URL, _ items: [SessionInfo]) -> some View {
        if let git = GitTreeBadges.group(items, id: "git:repo:" + folder.path, title: folder.lastPathComponent,
                                         settled: { GitTreeBadges.settled(rowState($0)) }, open: { open($0) }) {
            GitBadgeView(display: git.display, muted: true, help: git.help, card: git.card)
        }
    }

    private func toggleFold(_ key: String) {
        var f = folded
        if f.remove(key) == nil { f.insert(key) }
        foldedRaw = f.sorted().joined(separator: "\n")
    }

    /// "Move to…": re-file a session under another (the sidebar's own MoveSession), or back
    /// to top level. Candidates are the sessions that head a nesting today — current parents
    /// and pinned/manager rows — alphabetical, never the session itself (the cycle guard
    /// refuses its descendants anyway; the menu just doesn't offer them).
    @ViewBuilder
    private func moveMenu(_ s: SessionInfo) -> some View {
        let current = library.parents[s.id]
        let parents = Set(library.parents.values)
        let heads = active
            .filter { $0.id != s.id && (parents.contains($0.id) || library.pinned.contains($0.id)) }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        if !heads.isEmpty || current != nil {
            Menu("Move to…") {
                ForEach(heads) { head in
                    Button(head.displayTitle) {
                        _ = Library.shared.move(s.id, to: head.id)
                    }
                    .disabled(head.id == current)
                }
                if current != nil {
                    Divider()
                    Button("Top Level") {
                        _ = Library.shared.move(s.id, to: nil)
                    }
                }
            }
        }
    }

    // MARK: Search and archive

    private var visible: [SessionInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return library.sessions.filter { s in
            guard library.archived.contains(s.id) == showArchived else { return false }
            guard !q.isEmpty else { return true }
            let hay = [s.title, s.firstInput, s.folder?.lastPathComponent].compactMap { $0?.lowercased() }
            return hay.contains { $0.contains(q) }
        }
    }

    private func byDay(_ list: [SessionInfo]) -> [(String, [SessionInfo])] {
        SessionDays.group(list, day: day).map { ($0.0, $0.1.sorted(by: before)) }
    }

    /// Rows under day headings.
    @ViewBuilder
    private func dated(_ list: [SessionInfo]) -> some View {
        ForEach(byDay(list), id: \.0) { title, items in
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 3)
            // The started-by tree within the day: a child right under its parent, indented.
            let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let nested = SessionNesting.indented(items.map(\.id)) { library.parents[$0] }
            ForEach(nested, id: \.id) { node in
                if let s = byId[node.id] { listRow(s, depth: node.depth) }
            }
        }
    }

    /// A row of a flat list: one line when compact, two otherwise; a child indented.
    @ViewBuilder
    private func listRow(_ s: SessionInfo, depth: Int = 0) -> some View {
        if compactSidebar {
            compactRow(s, depth: depth)
        } else {
            row(s, showPlace: depth == 0, nested: depth > 0)
                .padding(.leading, AttentionMetrics.leading(depth))
        }
    }

    @ViewBuilder
    private var flat: some View {
        dated(visible)
        if visible.isEmpty {
            empty(query.isEmpty ? "Nothing archived" : "No matches")
        }
    }

    /// How the list is grouped, sorted and filtered, like Finder's View menu.
    private var viewOptions: some View {
        Menu {
            Toggle("Compact", isOn: $compactSidebar)
                .disabled(grouping == .org)
            Divider()
            Picker("Show", selection: $showArchived) {
                Text("Active").tag(false)
                Text("Archived").tag(true)
            }
            Divider()
            Picker("Group By", selection: $grouping) {
                ForEach(Grouping.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Sort By", selection: $sort) {
                ForEach(Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease").frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Group and sort conversations")
    }

    // MARK: Pieces

    private func row(_ s: SessionInfo, showPlace: Bool, nested: Bool = false, summary: String? = nil) -> some View {
        ConversationRow(
            session: s,
            selected: s.id == current,
            pinned: library.pinned.contains(s.id),
            live: library.live[s.id],
            pane: paneNumbers[s.id],
            showPlace: showPlace,
            nested: nested,
            summary: summary,
            line: library.rowLine(s)
        ) {
            open(s)
        } menu: {
            rowMenu(s)
        }
    }

    /// A folded branch's row: its newest session as the row, a chevron disclosing the older
    /// ones (indented beneath).
    @ViewBuilder
    private func branchRow(_ session: SessionInfo, depth: Int, fold: SessionFolds.Fold, summary: String? = nil) -> some View {
        let isOpen = openFolds.contains(session.id)
        let indent = CGFloat(depth) * 10
        HStack(spacing: 0) {
            Button { toggleFoldBranch(session.id) } label: {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 14, height: 20).contentShape(.rect)
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
            .help("\(fold.older.count) older on this branch")
            row(session, showPlace: false, nested: depth > 0, summary: summary)
        }
        .padding(.leading, indent)
        if isOpen {
            ForEach(fold.older) { older in
                row(older, showPlace: false, nested: true).padding(.leading, indent + 12)
            }
        }
    }

    /// ⌘-click opens beside the focused pane instead of in it.
    private func open(_ s: SessionInfo) {
        // Frog Cloud's rows share the list; they open through the gateway, not frog here.
        if library.isCloud(s.id) { return workspace.openCloud(s.id) }
        if NSEvent.modifierFlags.contains(.command), let openInSplit {
            openInSplit(s)
        } else {
            openSession?(s)
        }
    }

    private func sectionHeader<L: View, T: View>(@ViewBuilder _ leading: () -> L, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 6) {
            leading()
            Spacer(minLength: 4)
            trailing()
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 3)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.frog(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }

    /// Calm, as on the web: the frog and its name with the view options and collapse, then
    /// New session and Search as rows of their own.
    private var header: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                FrogFace(mood: .waiting, size: 20)
                Text("Frog").font(.frog(size: 13.5, weight: .semibold))
                Spacer(minLength: 4)
                viewOptions
                if let collapse {
                    Button(action: collapse) {
                        Image(systemName: "sidebar.left").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Collapse conversations (⌃⌘S)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            Button { switchFolder?(nil) } label: {
                navRow("square.and.pencil", "New session", key: "⌘N")
            }
            .buttonStyle(.plain)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").frame(width: 16).foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(jumpToFirstMatch)
                    .onExitCommand { query = "" }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.frog(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func navRow(_ symbol: String, _ title: String, key: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(title)
            Spacer(minLength: 4)
            Text(key).font(.frog(size: 11)).foregroundStyle(.tertiary)
        }
        .font(.frog(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .contentShape(.rect)
        .hoverPlate(h: 0, v: 0, radius: 8)
    }

    private var footer: some View {
        let count = library.archived.count
        // The org view counts what's live across the tree (running or waiting on you).
        let liveCount = grouping == .org && !showArchived
            ? active.count(where: { [.running, .waiting].contains(rowState($0)) }) : 0
        return HStack {
            if showArchived {
                Button { showArchived = false } label: { Label("Back to conversations", systemImage: "chevron.left") }
            } else if count > 0 {
                Button { showArchived = true } label: { Label("Archived (\(count))", systemImage: "archivebox") }
            }
            Spacer()
            if liveCount > 0 {
                Text("\(liveCount) live").monospacedDigit().foregroundStyle(.tertiary)
                    .help("\(liveCount) session\(liveCount == 1 ? "" : "s") running or waiting on you")
            }
        }
        .buttonStyle(.plain)
        .font(.frog(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, count > 0 || showArchived || liveCount > 0 ? 9 : 0)
    }

    @ViewBuilder
    private func rowMenu(_ s: SessionInfo, older: [SessionInfo] = [], git: GitRowBadge? = nil) -> some View {
        if let openInSplit, paneNumbers[s.id] == nil {
            Button("Open in New Pane") { openInSplit(s) }
            Divider()
        }
        // The tree shows a branch's newest session; the older ones stay a click away.
        if !older.isEmpty {
            Menu("Older on This Branch") {
                ForEach(older) { o in
                    Button("\(o.displayTitle) · \(SessionAgeShort.age(o.modifiedDate))") { open(o) }
                }
            }
            Divider()
        }
        Button("Rename…") {
            newTitle = s.displayTitle
            renaming = s
        }
        Button(library.pinned.contains(s.id) ? "Unpin" : "Pin") { library.togglePin(s.id) }
        if FeatureFlags.chief {
            Button("Make Chief") { library.makeChief(s.id) }
                .disabled(library.chief == s.id)
            if library.chief == s.id {
                Button("Remove Chief") { library.removeChief() }
            }
        }
        if let folder = s.folder, !s.isChat {
            Button("Reveal Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
        // The network, for badges, only from here or the card: fetch the base, ask GitHub.
        if let card = git?.card {
            Button("Refresh Git") { card.refresh() }
        }
        if s.id == current {
            Button("Session Tree…") { showTree = true }
        }
        if library.parents.values.contains(s.id) {
            Button(collapsedParents.contains(s.id) ? "Show Started Sessions" : "Collapse Started Sessions") {
                toggleChildren(s.id)
            }
        }
        moveMenu(s)
        Divider()
        if library.archived.contains(s.id) {
            Button("Unarchive") { library.setArchived(s.id, false) }
        } else {
            Button("Archive") { library.setArchived(s.id, true) }
        }
    }
}

/// The chief of staff as a wide tile at the top of the sidebar: its monogram, title, and the
/// line every other session reports through — what it's doing now, what it's waiting on, or
/// where its last word left off. iMessage's pinned chats, but one, and live.
private struct ChiefTile: View {
    let session: SessionInfo
    let selected: Bool
    let live: Library.Live?
    @Bindable var library: Library

    var body: some View {
        HStack(spacing: 8) {
            Monogram(session: session, size: 30, selected: selected, live: live)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.displayTitle).lineLimit(1).fontWeight(.semibold)
                    if session.isChat {
                        Image(systemName: "bubble.left").font(.frog(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                Text(preview)
                    .font(.frog(size: 10))
                    .foregroundStyle(previewTint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            status
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .help(helpText)
    }

    /// What the chief is saying right now: its question while it waits, the step in hand while
    /// it works, else the end of its last word. (An idle chief outside a window shows its
    /// place; there's nothing to say.)
    private var preview: String {
        if let c = library.conversation(session.id) {
            if let q = c.question { return q.question }
            if c.permission != nil || c.elicitation != nil { return "Waiting on you" }
            if let line = c.liveActivity { return line }
            if let last = c.turns.last, let summary = Conversation.summaryIfEnded(last) {
                return summary
            }
            return session.folder.map { "Here: \($0.lastPathComponent)" } ?? "Idle"
        }
        switch live {
        case .running: return "Working…"
        case .waiting: return "Waiting on you"
        case .unread: return "Finished — take a look"
        case nil: return "Here: \(session.folder?.lastPathComponent ?? "")"
        }
    }

    private var previewTint: Color {
        if let c = library.conversation(session.id), c.question != nil || c.permission != nil || c.elicitation != nil {
            return .orange
        }
        return .secondary
    }

    /// The working indicator, like every session's: a spinner while it runs, a hand while it
    /// waits, a dot when it finished unseen.
    @ViewBuilder
    private var status: some View {
        switch live {
        case .running:
            ProgressView().controlSize(.mini)
        case .waiting:
            Image(systemName: "ellipsis.bubble").foregroundStyle(.orange).symbolEffect(.pulse, options: .repeat(3))
        case .unread:
            Circle().fill(.tint).frame(width: 7, height: 7)
        case nil:
            EmptyView()
        }
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(.tint.opacity(0.22)) }
        return AnyShapeStyle(.quaternary.opacity(0.7))
    }

    private var helpText: String {
        var parts = [session.displayTitle, "Chief of staff"]
        if let f = session.folder, !session.isChat { parts.append(f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        if !session.model.isEmpty { parts.append(Workspace.modelName(session.model)) }
        return parts.joined(separator: "\n")
    }
}

/// Compact, title-only sidebar row, with its state glyph, trailing meta (age, commits ahead)
/// and cached GitHub pull request indicator.
private struct CompactSessionRow<Menu: View>: View {
    let session: SessionInfo
    let selected: Bool
    let live: Library.Live?
    let depth: Int
    /// Its git badge (the attention tree's, from the same index).
    let git: GitRowBadge?
    /// How many older sessions of this branch are folded behind the row's disclosure.
    var folded: Int = 0
    /// Whether the row's disclosure is open (its older sessions are listed).
    var foldOpen = false
    /// How the sessions this one started (a manager's workers) stand.
    var counts = SessionNesting.Counts()
    /// Whether those children are collapsed into this row (it shows their counts).
    var collapsed = false
    var onFold: (() -> Void)? = nil
    /// Collapse or show the children, when there are any.
    var onCollapse: (() -> Void)? = nil
    let open: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var hovering = false
    /// Hovered a moment: the title wraps to show all of itself and the meta steps aside.
    @State private var expandTitle = false

    /// Nested under the session that started it: the row gives its width to the title.
    private var nested: Bool { depth > 0 }

    /// The worktree branch name, when it isn't just the slugged title.
    private var suffix: String? {
        RowSuffix.visible(SessionList.worktreeName(session.folder), title: session.displayTitle)
    }

    /// Squeezed nested rows keep the suffix out of the way: hover or selection shows it.
    private var showSuffix: Bool { hovering || selected }

    /// The row's state, combining live tracking with the listing's last-turn end. A turn
    /// that finished ok keeps a green check for ten seconds, then settles to nothing.
    private var glyph: SessionEndGlyph {
        SessionEndGlyph.derive(live: live, end: session.end)
    }

    /// Whether the last turn ended recently enough to still show its green check.
    private var freshComplete: Bool {
        session.end == .complete && abs(Date().timeIntervalSince(session.modifiedDate)) < 10
    }

    var body: some View {
        // The tick re-checks the 30 s activity rule so the indicator and the title
        // emphasis fade together.
        content(working: live == nil && SidebarClock.shared.now.timeIntervalSince(session.modifiedDate) < 30)
        .padding(.vertical, expandTitle ? 4 : 0)
        .frame(minHeight: 28)
        .padding(.trailing, 3)
        .background(selected || hovering ? Tokens.hover : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .contextMenu { DeferredMenu(make: menu) }
        .paneDraggable(.session(session), title: session.displayTitle)
        .help(helpText)
        .onHover { hovering = $0 }
        // A pass of the pointer doesn't reflow the list; resting on a row does.
        .task(id: hovering) {
            guard hovering else { expandTitle = false; return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, hovering else { return }
            withAnimation(.snappy(duration: 0.15)) { expandTitle = true }
        }
        // Queued off the main thread (at most once a minute); no gh, no git in the row.
        .task(id: session.id) { GitIndex.shared.wantStatus(session) }
    }

    private func content(working: Bool) -> some View {
        // A working row keeps its title at full opacity, like the selected row.
        let running = working || live == .running
        return HStack(spacing: 0) {
            if nested {
                // Nested rows keep their width for the title: 8 pt per level, one rail.
                RoundedRectangle(cornerRadius: 1).fill(.quaternary)
                    .frame(width: 1, height: 18)
                    .padding(.leading, CGFloat(depth - 1) * Self.indent + 4).padding(.trailing, 5)
            } else {
                Color.clear.frame(width: 6)
            }
            if folded > 0 {
                Button { onFold?() } label: {
                    Image(systemName: "chevron.right").font(.frog(size: 8, weight: .bold))
                        .rotationEffect(.degrees(foldOpen ? 90 : 0))
                        .frame(width: 12, height: 20).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .help("\(folded) older on this branch")
            } else {
                Color.clear.frame(width: nested ? 2 : 6)
            }
            // The title takes the width it has; a branch suffix only when it says something
            // the title doesn't (a slugged title never repeats itself). The child badge is its
            // own button, so the open target is a tap on the rest rather than a wrapping button.
            HStack(spacing: 5) {
                Text(session.displayTitle).lineLimit(expandTitle ? 3 : 1).truncationMode(.tail)
                    .font(.frog(size: 13))
                    .foregroundStyle(Color.primary.opacity(selected || running ? 1 : 0.82))
                if let suffix, showSuffix {
                    Text(suffix).lineLimit(1)
                        .font(.frog(size: 11)).foregroundStyle(.tertiary)
                        .help(suffix)
                }
                if counts.total > 0 { childBadge }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture(perform: open)
            .accessibilityAddTraits(.isButton)
            // Resting on the row, the meta steps aside for the title; nested rows leave the
            // age and commit count to the tooltip.
            if let git, !expandTitle {
                GitBadgeView(display: git.display, muted: !running && !selected, help: git.help, card: git.card)
                    .padding(.leading, 5)
            }
            if !expandTitle, !nested {
                let now = SidebarClock.shared.now
                Group {
                    // Running shows the spinner whether the app knows it live (a conversation
                    // open here, following a worker included) or only from recent activity.
                    if live == .running || live == nil, now.timeIntervalSince(session.modifiedDate) < 30 {
                        Text(SessionAgeShort.age(session.modifiedDate, now: now))
                            .font(.system(size: 11, design: .rounded).monospacedDigit())
                            .foregroundStyle(.tertiary).padding(.leading, 5).padding(.trailing, 2)
                    } else {
                        Text(SessionAgeShort.age(session.modifiedDate, now: now))
                            .font(.system(size: 11, design: .rounded).monospacedDigit())
                            .foregroundStyle(.tertiary).padding(.leading, 5).padding(.trailing, 2)
                    }
                }
            }
            glyphView.padding(.leading, 5)
            // Nested rows show the menu button only under the pointer (the context menu is
            // always there).
            if !nested || hovering {
                SwiftUI.Menu { menu() } label: {
                    Image(systemName: "ellipsis").font(.frog(size: 10)).frame(width: 14, height: 20)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).foregroundStyle(.secondary)
            }
        }
    }

    /// Indent per nesting level (computed: a generic type can't store statics).
    static var indent: CGFloat { 8 }

    /// The title, with the worktree name (when there is one) underneath in the tooltip.
    private var helpText: String {
        var lines = [session.displayTitle]
        if let wt = SessionList.worktreeName(session.folder) { lines.append(wt) }
        if nested {
            // The row leaves its age to the tooltip: "active 5m ago", "active now".
            let age = SessionAgeShort.age(session.modifiedDate, now: .now)
            lines.append(age == "now" || age.contains(" ") ? "active \(age)" : "active \(age) ago")
        }
        return lines.joined(separator: "\n")
    }

    /// The children's count; collapsed, how they stand ("· 4 running · 1 waiting"). Clicking
    /// it folds the children into the row or shows them again.
    private var childBadge: some View {
        let n = counts.total
        return Button { onCollapse?() } label: {
            Group {
                if collapsed, let summary = counts.summary {
                    Text("· " + summary).foregroundStyle(.secondary)
                } else {
                    Text("\(n)").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10, design: .rounded).monospacedDigit())
            .lineLimit(1).fixedSize()
            .padding(.leading, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show the \(n) session\(n == 1 ? "" : "s") this one started"
                        : "Collapse the \(n) session\(n == 1 ? "" : "s") this one started")
    }


    /// The state glyph: a spinner while running, an amber dot waiting on you, red for a turn
    /// that ended in error, tinted for unseen, nothing for idle.
    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12).help("working")
        case .waiting:
            Circle().fill(.orange).frame(width: 6, height: 6).help("waiting on you")
        case .failed:
            Circle().fill(.red).frame(width: 6, height: 6).help("ended with an error")
        case .unread:
            Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("finished while you were away")
        case .idle:
            // A finished worker keeps a quiet check so it never reads as live work; a
            // top-level row only flashes it.
            if freshComplete || (depth > 0 && session.end == .complete) {
                Image(systemName: "checkmark.circle.fill").font(.frog(size: 11))
                    .foregroundStyle(.green.opacity(freshComplete ? 1 : 0.6)).help("done")
            } else {
                EmptyView()
            }
        }
    }
}

/// The conversation list folded to a strip: new, pins, and whatever is live or on screen, as
/// tiles with their status. Enough to watch every running agent without giving up the width.
struct SessionRail: View {
    @Bindable var workspace: Workspace
    let maxHeight: CGFloat
    let expand: () -> Void
    @State private var library = Library.shared
    @Environment(\.openSession) private var openSession
    @Environment(\.openSessionInSplit) private var openInSplit
    @Environment(\.switchFolder) private var switchFolder

    static let width: CGFloat = 52

    private var current: String? { workspace.opening ?? workspace.conversation?.cloudSession ?? workspace.conversation?.sessionID }

    private var pins: [SessionInfo] {
        library.sessions.filter { library.pinned.contains($0.id) && !library.archived.contains($0.id) }
    }

    /// Live conversations and the one on screen, newest first.
    private var hot: [SessionInfo] {
        library.sessions.filter { s in
            !library.pinned.contains(s.id) && !library.archived.contains(s.id)
                && (library.live[s.id] != nil || s.id == current)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            icon("sidebar.left", help: "Expand conversations (⌃⌘S)", action: expand)
            icon("square.and.pencil", help: "New conversation") { switchFolder?(nil) }
            HuggingScroll(maxHeight: max(40, maxHeight - 100)) {
                VStack(spacing: 8) {
                    if !pins.isEmpty {
                        Divider().padding(.horizontal, 8)
                        ForEach(pins) { tile($0) }
                    }
                    if !hot.isEmpty {
                        Divider().padding(.horizontal, 8)
                        ForEach(hot) { tile($0) }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.vertical, 10)
        .frame(width: Self.width)
        .onAppear { library.refresh() }
    }

    private func tile(_ s: SessionInfo) -> some View {
        Button {
            if NSEvent.modifierFlags.contains(.command), let openInSplit { openInSplit(s) } else { openSession?(s) }
        } label: {
            Monogram(session: s, size: 34, selected: s.id == current, live: library.live[s.id])
        }
        .buttonStyle(.plain)
        .paneDraggable(.session(s), title: s.displayTitle)
        .help(s.displayTitle)
    }

    private func icon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).frame(width: 30, height: 26).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// A conversation as a tile: its initial over its folder's tint (a bubble for chats), outlined
/// when it's on screen, with its live status in the corner.
/// One conversation: its title, where it lives and when, and whether it's live. Inside a
/// project group the place is the group, so the row is a single line.
struct ConversationRow<Menu: View>: View {
    let session: SessionInfo
    let selected: Bool
    let pinned: Bool
    let live: Library.Live?
    /// The pane showing it, when the window is split.
    var pane: Int? = nil
    var showPlace = true
    /// Nested under the session that started it: a finished one keeps its check.
    var nested = false
    /// Its collapsed children's counts ("4 running · 1 waiting"), shown after the title.
    var summary: String? = nil
    var line = RowLine()
    let open: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var hovering = false

    var body: some View {
        // The menu sits beside the open button, not inside it, so clicking it doesn't also open
        // the conversation.
        HStack(alignment: .center, spacing: 8) {
            Button(action: open) {
                HStack(spacing: 6) {
                    label
                    if let summary {
                        Text(summary).font(.frog(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize().help(summary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, showPlace ? 6 : 5)
        .background(background, in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
        .contextMenu { DeferredMenu(make: menu) }
        // Onto a pane: its edge opens this beside it, its middle shows it there.
        .paneDraggable(.session(session), title: session.displayTitle)
        .help(helpText)
    }

    private var label: some View {
        ConversationRowLabel(session: session, live: live, end: session.end, pane: pane, showPlace: showPlace,
                             detail: line.text, detailTint: line.tint, pr: line.pr, turns: line.turns,
                             hideStatus: hovering)
    }

    /// Status and the hover menu share one slot sized to the larger of the two, so the row
    /// doesn't change size as the pointer passes over it.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            if pinned && !hovering {
                Image(systemName: "pin.fill").font(.frog(size: 10)).foregroundStyle(Tokens.textTertiary)
            }
            SwiftUI.Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis").frame(width: 18, height: 14).contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .frame(height: 14)
    }

    /// As on the web: the row you're on and the row under the pointer share one quiet fill.
    private var background: AnyShapeStyle {
        AnyShapeStyle(selected || hovering ? Tokens.hover : .clear)
    }

    private var helpText: String {
        var parts = [session.displayTitle]
        if let f = session.folder, !session.isChat { parts.append(f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        if !session.model.isEmpty { parts.append(Workspace.modelName(session.model)) }
        return parts.joined(separator: "\n")
    }
}

/// A row's context menu, built when it opens: `.contextMenu { menu() }` ran every row's menu
/// (its "Move to…" list sorts every session) on each sidebar redraw, nearly a second of a
/// session switch with ~1,000 sessions.
private struct DeferredMenu<Content: View>: View {
    let make: () -> Content
    var body: some View { make() }
}

/// The sidebar's one clock for its age labels and 30 s activity rule. A `TimelineView` per row
/// was re-checked on every frame anything else animated (~50 rows × 30 a second while a session
/// worked); rows that read this redraw only when it ticks.
@MainActor
@Observable
final class SidebarClock {
    static let shared = SidebarClock()
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { SidebarClock.shared.now = Date() }
        }
    }
}

