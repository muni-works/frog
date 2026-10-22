import SwiftUI

/// Every conversation, as tabs: pinned ones as tiles on top, then one group per project folder
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
    @State private var query = ""
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
    @AppStorage("sidebarGrouping") private var grouping = Grouping.project
    @AppStorage("sidebarSort") private var sort = Sort.activity
    @AppStorage("compactSidebar") private var compactSidebar = false

    /// How rows are grouped: by project folder (pins, folders, chats), by day, or not at all.
    enum Grouping: String, CaseIterable {
        case project, date, none
        var title: String {
            switch self {
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

    private var current: String? { workspace.opening ?? workspace.conversation?.sessionID }
    private var folded: Set<String> { Set(foldedRaw.split(separator: "\n").map(String.init)) }
    private var filtering: Bool { showArchived || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var active: [SessionInfo] {
        library.sessions.filter { !library.archived.contains($0.id) }
    }

    private var pins: [SessionInfo] {
        active.filter { library.pinned.contains($0.id) }
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

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if filtering {
                        flat
                    } else if compactSidebar {
                        compactTabs
                    } else {
                        switch grouping {
                        case .project: tabs
                        case .date: pinTiles; dated(unpinned)
                        case .none:
                            pinTiles
                            ForEach(unpinned.sorted(by: before)) { row($0, showPlace: true) }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(maxHeight: maxHeight)
        .onAppear { library.refresh() }
        .alert("Rename Conversation", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let s = renaming { Task { await library.rename(s.id, to: newTitle) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .popover(isPresented: $showTree, arrowEdge: .trailing) {
            SessionTree(workspace: workspace) { showTree = false }
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
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
            if !isFolded {
                ForEach(compactDated(items), id: \.0) { title, dayItems in
                    compactHeader(title)
                    compactDayRows(dayItems)
                }
            }
        }
        if !chats.isEmpty {
            compactHeader("Chats")
            ForEach(chats) { compactRow($0, depth: 0) }
        }
        if projects.isEmpty && chats.isEmpty && pins.isEmpty { empty("No conversations yet") }
    }

    private var compactPins: some View {
        Group {
            if !pins.isEmpty {
                compactHeader("Pinned")
                ForEach(pins) { compactRow($0, depth: 0) }
            }
        }
    }

    private func compactDated(_ items: [SessionInfo]) -> [(String, [SessionInfo])] {
        SessionDays.group(items, day: day).map { ($0.0, $0.1.sorted(by: before)) }
    }

    private func compactHeader(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
            .padding(.leading, 6).padding(.top, 5).padding(.bottom, 1)
    }

    /// A day's rows, branches folded: one row for each fold's newest session, older sessions
    /// behind the row's disclosure, and other nesting (started-by) applied on top.
    private func compactDayRows(_ dayItems: [SessionInfo]) -> some View {
        let folds = SessionFolds.group(dayItems)
        let byId = Dictionary(uniqueKeysWithValues: folds.map { ($0.session.id, $0) })
        return ForEach(tree(folds)) { entry in
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
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text("+\(count) done")
                if failed > 0 {
                    Text("· \(failed) failed").foregroundStyle(.red.opacity(0.8))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
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
            pr: session.folder.flatMap { CompactPRCache.shared.value(for: $0) },
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
        if projects.isEmpty && chats.isEmpty && pins.isEmpty {
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
            let folds = SessionFolds.group(shown)
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
    }

    private func toggleFold(_ key: String) {
        var f = folded
        if f.remove(key) == nil { f.insert(key) }
        foldedRaw = f.sorted().joined(separator: "\n")
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
            ForEach(items) { row($0, showPlace: true) }
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
            summary: summary
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
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
            viewOptions
            Button {
                switchFolder?(nil)
            } label: {
                Image(systemName: "square.and.pencil").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New conversation")
            if let collapse {
                Button(action: collapse) {
                    Image(systemName: "sidebar.left").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Collapse conversations (⌃⌘S)")
            }
        }
        .padding(10)
    }

    private var footer: some View {
        let count = library.archived.count
        return HStack {
            if showArchived {
                Button { showArchived = false } label: { Label("Back to conversations", systemImage: "chevron.left") }
            } else if count > 0 {
                Button { showArchived = true } label: { Label("Archived (\(count))", systemImage: "archivebox") }
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, count > 0 || showArchived ? 9 : 0)
    }

    @ViewBuilder
    private func rowMenu(_ s: SessionInfo) -> some View {
        if let openInSplit, paneNumbers[s.id] == nil {
            Button("Open in New Pane") { openInSplit(s) }
            Divider()
        }
        Button("Rename…") {
            newTitle = s.displayTitle
            renaming = s
        }
        Button(library.pinned.contains(s.id) ? "Unpin" : "Pin") { library.togglePin(s.id) }
        if let folder = s.folder, !s.isChat {
            Button("Reveal Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
        if s.id == current {
            Button("Session Tree…") { showTree = true }
        }
        if library.parents.values.contains(s.id) {
            Button(collapsedParents.contains(s.id) ? "Show Started Sessions" : "Collapse Started Sessions") {
                toggleChildren(s.id)
            }
        }
        Divider()
        if library.archived.contains(s.id) {
            Button("Unarchive") { library.setArchived(s.id, false) }
        } else {
            Button("Archive") { library.setArchived(s.id, true) }
        }
    }
}

/// Compact, title-only sidebar row, with its state glyph, trailing meta (age, commits ahead)
/// and cached GitHub pull request indicator.
private struct CompactSessionRow<Menu: View>: View {
    let session: SessionInfo
    let selected: Bool
    let live: Library.Live?
    let depth: Int
    let pr: CompactPRCache.Info?
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
    @State private var meta: SessionMetaCache.Meta?
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
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            content(working: live == nil && ctx.date.timeIntervalSince(session.modifiedDate) < 30)
        }
        .padding(.vertical, expandTitle ? 4 : 0)
        .frame(minHeight: 28)
        .padding(.trailing, 3)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .contextMenu { menu() }
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
        .task(id: session.folder?.path) {
            if let folder = session.folder { await CompactPRCache.shared.refresh(folder) }
            meta = SessionMetaCache.shared.value(for: session.folder)
            if meta == nil { await SessionMetaCache.shared.refresh(session.folder); meta = SessionMetaCache.shared.value(for: session.folder) }
        }
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
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
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
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(selected || running ? 1 : 0.82))
                if let suffix, showSuffix {
                    Text(suffix).lineLimit(1)
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
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
            if let pr, !expandTitle {
                Image(systemName: pr.merged ? "arrow.triangle.merge" : "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(pr.merged ? Color.green : Color.purple)
                Text("\(pr.changedFiles)").font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
            }
            if let ahead = meta?.ahead, ahead > 0, !expandTitle, !nested {
                Text("\(ahead)↑").font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary).padding(.leading, 5).help("\(ahead) commit\(ahead == 1 ? "" : "s") ahead of main")
            }
            if !expandTitle, !nested {
                TimelineView(.periodic(from: .now, by: freshComplete ? 5 : 30)) { ctx in
                    Text(SessionAgeShort.age(session.modifiedDate, now: ctx.date))
                        .font(.system(size: 11, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary).padding(.leading, 5).padding(.trailing, 2)
                }
            }
            glyphView.padding(.leading, 5)
            // Nested rows show the menu button only under the pointer (the context menu is
            // always there).
            if !nested || hovering {
                SwiftUI.Menu { menu() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10)).frame(width: 14, height: 20)
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
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                    .foregroundStyle(.green.opacity(freshComplete ? 1 : 0.6)).help("done")
            } else {
                EmptyView()
            }
        }
    }
}

@MainActor
private final class CompactPRCache {
    static let shared = CompactPRCache()
    struct Info { let merged: Bool; let changedFiles: Int }
    private struct Entry { let info: Info?; let refreshed: Date }
    private var entries: [String: Entry] = [:]
    private var branches: [String: String] = [:]
    private var refreshing: Set<String> = []

    func value(for folder: URL) -> Info? { entries[folder.standardizedFileURL.path]?.info }

    func refresh(_ folder: URL) async {
        let path = folder.standardizedFileURL.path
        let branch = await Task.detached(priority: .utility) { () -> String? in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", path, "branch", "--show-current"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        guard let branch, !branch.isEmpty else { return }
        let key = "\(path)::\(branch)"
        if branches[path] == key, let entry = entries[key], Date().timeIntervalSince(entry.refreshed) < 60 { return }
        guard refreshing.insert(key).inserted else { return }
        branches[path] = key
        defer { refreshing.remove(key) }
        let result = await Task.detached(priority: .utility) { () -> Info? in
            let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let gh else { return nil }
            let process = Process(); process.executableURL = URL(fileURLWithPath: gh)
            process.currentDirectoryURL = folder
            process.arguments = ["pr", "view", branch, "--json", "state,number,changedFiles"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? String,
                  let count = json["changedFiles"] as? Int else { return nil }
            return Info(merged: state == "MERGED", changedFiles: count)
        }.value
        entries[key] = Entry(info: result, refreshed: .now)
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

    private var current: String? { workspace.opening ?? workspace.conversation?.sessionID }

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
                        Text(summary).font(.caption).foregroundStyle(.secondary)
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
        .background(background, in: .rect(cornerRadius: 9))
        .onHover { hovering = $0 }
        .contextMenu { menu() }
        // Onto a pane: its edge opens this beside it, its middle shows it there.
        .paneDraggable(.session(session), title: session.displayTitle)
        .help(helpText)
    }

    private var label: some View {
        ConversationRowLabel(session: session, live: live, end: session.end, pane: pane, showPlace: showPlace)
    }

    /// Status and the hover menu share one slot sized to the larger of the two, so the row
    /// doesn't change size as the pointer passes over it.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            status.opacity(hovering ? 0 : 1)
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

    @ViewBuilder
    private var status: some View {
        switch SessionEndGlyph.derive(live: live, end: session.end) {
        case .running: LiveGlyph(live: .running)
        case .waiting: LiveGlyph(live: .waiting)
        case .unread: LiveGlyph(live: .unread)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help("ended with an error")
        case .idle:
            if pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
            } else if nested && session.end == .complete {
                Image(systemName: "checkmark.circle.fill").font(.caption)
                    .foregroundStyle(.green.opacity(0.6)).help("done")
            } else if !showPlace {
                Text(SessionAge.short(session.modifiedDate))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(.tint.opacity(0.22)) }
        if hovering { return AnyShapeStyle(.quaternary.opacity(0.6)) }
        return AnyShapeStyle(.clear)
    }

    private var helpText: String {
        var parts = [session.displayTitle]
        if let f = session.folder, !session.isChat { parts.append(f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        parts.append(session.model)
        return parts.joined(separator: "\n")
    }
}
