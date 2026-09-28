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
    /// Folded project groups, by folder path (newline-separated).
    @AppStorage("foldedGroups") private var foldedRaw = ""
    @AppStorage("sidebarGrouping") private var grouping = Grouping.project
    @AppStorage("sidebarSort") private var sort = Sort.activity

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
        let byPath = Dictionary(grouping: unpinned) { $0.folder!.standardizedFileURL.path }
        return byPath.values
            .map { items in
                let sorted = items.sorted(by: before)
                return (sorted[0].folder!, sorted)
            }
            // Folders follow their first conversation, or their own name when sorting by name.
            .sorted { a, b in
                sort == .name
                    ? a.folder.lastPathComponent.localizedStandardCompare(b.folder.lastPathComponent) == .orderedAscending
                    : before(a.items[0], b.items[0])
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
            ForEach(shown) { row($0, showPlace: false) }
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
        let cal = Calendar.current
        let now = Date()
        var out: [(String, [SessionInfo])] = []
        func add(_ title: String, _ items: [SessionInfo]) { if !items.isEmpty { out.append((title, items.sorted(by: before))) } }
        add("Today", list.filter { cal.isDateInToday(day($0)) })
        add("Yesterday", list.filter { cal.isDateInYesterday(day($0)) })
        let week = cal.date(byAdding: .day, value: -7, to: now)!
        let month = cal.date(byAdding: .day, value: -30, to: now)!
        let older = list.filter { !cal.isDateInToday(day($0)) && !cal.isDateInYesterday(day($0)) }
        add("Previous 7 Days", older.filter { day($0) >= week })
        add("Previous 30 Days", older.filter { day($0) < week && day($0) >= month })
        add("Older", older.filter { day($0) < month })
        return out
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

    private func row(_ s: SessionInfo, showPlace: Bool) -> some View {
        ConversationRow(
            session: s,
            selected: s.id == current,
            pinned: library.pinned.contains(s.id),
            live: library.live[s.id],
            pane: paneNumbers[s.id],
            showPlace: showPlace
        ) {
            open(s)
        } menu: {
            rowMenu(s)
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
        Divider()
        if library.archived.contains(s.id) {
            Button("Unarchive") { library.setArchived(s.id, false) }
        } else {
            Button("Archive") { library.setArchived(s.id, true) }
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
struct Monogram: View {
    let session: SessionInfo
    let size: CGFloat
    let selected: Bool
    let live: Library.Live?

    var body: some View {
        let tint = session.isChat ? Color.secondary : FolderTint.color(session.folder)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(tint.opacity(0.16))
            RoundedRectangle(cornerRadius: size * 0.28)
                .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), lineWidth: selected ? 1.5 : 0.5)
            if session.isChat {
                Image(systemName: "bubble.left").font(.system(size: size * 0.38))
            } else {
                Text(initial).font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if live != nil {
                LiveGlyph(live: live)
                    .padding(2)
                    .background(.background, in: .circle)
                    .offset(x: 4, y: -4)
            }
        }
    }

    private var initial: String {
        // "/no_think …" reads as N, not a slash.
        session.displayTitle.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }
}

/// Running, waiting on you, or finished unseen.
struct LiveGlyph: View {
    let live: Library.Live?

    var body: some View {
        switch live {
        case .running: ProgressView().controlSize(.mini)
        case .waiting:
            Image(systemName: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
        case .unread: Circle().fill(.tint).frame(width: 7, height: 7)
        case nil: EmptyView()
        }
    }
}

/// A project's color, the same on every launch (`hashValue` is seeded per process).
enum FolderTint {
    static func color(_ url: URL?) -> Color {
        guard let path = url?.standardizedFileURL.path else { return .secondary }
        var h: UInt64 = 5381
        for b in path.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.5, brightness: 0.72)
    }
}

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
    let open: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var hovering = false

    var body: some View {
        // The menu sits beside the open button, not inside it, so clicking it doesn't also open
        // the conversation.
        HStack(alignment: .center, spacing: 8) {
            Button(action: open) {
                HStack(spacing: 0) {
                    label
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let pane {
                    Text("\(pane)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(.tint, in: .rect(cornerRadius: 4))
                }
                if session.forkedFrom != nil {
                    Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                }
                Text(session.displayTitle)
                    .lineLimit(1)
                    .fontWeight(live == .unread ? .semibold : .regular)
            }
            if showPlace {
                HStack(spacing: 4) {
                    Image(systemName: session.isChat ? "bubble.left" : "folder")
                    Text(session.isChat ? "Chat" : session.folder?.lastPathComponent ?? "")
                        .lineLimit(1)
                    Text("·")
                    Text(Self.ago(session.modifiedDate))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
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
        if live != nil {
            LiveGlyph(live: live)
        } else if !showPlace {
            Text(Self.ago(session.modifiedDate))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        } else if pinned {
            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
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

    /// "now", "5m", "3h", "2d", "4w", then a date.
    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        case ..<(86400 * 7): return "\(s / 86400)d"
        case ..<(86400 * 30): return "\(s / (86400 * 7))w"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
