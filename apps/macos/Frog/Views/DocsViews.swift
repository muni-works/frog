import AppKit
import SwiftUI

/// Documentation mode (docs/design/app-shell.md): the left sidebar lists the pages by section
/// and the main area shows one. Frog-drawn from `Tokens`, in the sidebar's row style, so it
/// reads as the same shell as the thread list.

extension EnvironmentValues {
    /// Puts the window in Documentation mode (the sidebar's Documentation row).
    @Entry var showDocs: (() -> Void)?
}

enum DocsLinks {
    /// The public copy of a page, for sharing: the web app's Documentation mode at
    /// frog.toys/docs/<slug>. (A docs.frog.toys host is in the shell spec but doesn't exist.)
    static func web(_ slug: String) -> URL {
        URL(string: "https://frog.toys/docs/")!.appending(path: slug)
    }

    /// "Frog 0.6.0": the build the bundled pages describe.
    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return ["Frog", v].compactMap { $0 }.joined(separator: " ")
    }
}

/// A sidebar row: icon and label at the thread list's size, the quiet hover and selected fill.
struct ShellRow: View {
    let symbol: String?
    let title: String
    var key: String = ""
    var selected = false

    var body: some View {
        HStack(spacing: 9) {
            if let symbol {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(Tokens.textSecondary)
            }
            Text(title)
                .lineLimit(1)
                .foregroundStyle(Tokens.text.opacity(selected ? 1 : 0.82))
            Spacer(minLength: 4)
            if !key.isEmpty {
                Text(key).font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary)
            }
        }
        .font(.frog(size: Tokens.Size.secondary))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(selected ? Tokens.hover : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .hoverPlate(h: 0, v: 0, radius: 8)
    }
}

/// The sidebar in Documentation mode: Back to app, a title search, the pages by section, and
/// the build's version at the foot.
struct DocsSidebar: View {
    let docs: AppDocs?
    let selected: String?
    let maxHeight: CGFloat
    let open: (String) -> Void
    let back: () -> Void
    var collapse: (() -> Void)?
    /// Its own title row (the frog, collapse); in the window it's the title bar's.
    var titleRow = true
    @State private var query: String
    @FocusState private var searching: Bool

    init(docs: AppDocs?, selected: String?, maxHeight: CGFloat, query: String = "", titleRow: Bool = true,
         open: @escaping (String) -> Void, back: @escaping () -> Void, collapse: (() -> Void)? = nil) {
        self.docs = docs
        self.selected = selected
        self.maxHeight = maxHeight
        self.titleRow = titleRow
        self.open = open
        self.back = back
        self.collapse = collapse
        _query = State(initialValue: query)
    }

    private var sections: [AppDocs.Section] { docs?.search(query) ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let list = sections
                    if list.isEmpty {
                        Text(docs == nil ? "No documentation in this build" : "No pages match")
                            .font(.frog(size: 12))
                            .foregroundStyle(Tokens.textTertiary)
                            .padding(.horizontal, 10).padding(.top, 12)
                    }
                    ForEach(list) { section in
                        Text(section.title)
                            .font(.frog(size: 12, weight: .semibold))
                            .foregroundStyle(Tokens.textSecondary)
                            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.pages) { page in
                            Button { open(page.slug) } label: {
                                ShellRow(symbol: nil, title: page.title, selected: page.slug == selected)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            Text(DocsLinks.version)
                .font(.frog(size: 11))
                .monospacedDigit()
                .foregroundStyle(Tokens.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .frame(maxHeight: maxHeight)
    }

    private var header: some View {
        VStack(spacing: 2) {
            if titleRow {
                HStack(spacing: 6) {
                    FrogFace(mood: .waiting, size: 20)
                    Text("Frog").font(.frog(size: 13.5, weight: .semibold))
                    Spacer(minLength: 4)
                    if let collapse {
                        Button(action: collapse) {
                            Image(systemName: "sidebar.left").frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.textSecondary)
                        .help("Collapse sidebar (⌃⌘S)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            Button(action: back) {
                ShellRow(symbol: "arrow.left", title: "Back to app", key: "esc")
            }
            .buttonStyle(.plain)
            .help("Back to your threads (Esc)")
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").frame(width: 16).foregroundStyle(Tokens.textSecondary)
                TextField("Search docs", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit { if let first = sections.first?.pages.first { open(first.slug) } }
                    // Esc clears a search first, then leaves, as it does anywhere else here.
                    .onExitCommand { if query.isEmpty { back() } else { query = "" } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.textTertiary)
                }
            }
            .font(.frog(size: Tokens.Size.secondary))
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .padding(.horizontal, 6)
        .padding(.top, titleRow ? 10 : 4)
        .padding(.bottom, 8)
    }
}


/// One page in the main area: on the transcript's column, a muted section label, the title,
/// the page as the transcript renders markdown, then previous and next.
struct DocsPageView: View {
    let docs: AppDocs?
    let page: AppDocs.Page?
    let open: (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let docs, let page {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(page.section)
                            .font(.frog(size: 12, weight: .semibold))
                            .foregroundStyle(Tokens.textSecondary)
                        Spacer(minLength: 12)
                        Button { openURL(DocsLinks.web(page.slug)) } label: {
                            Label("Open on the web", systemImage: "arrow.up.right")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(InspectorButtonStyle(kind: .plain))
                        .help(DocsLinks.web(page.slug).absoluteString)
                    }
                    Text(page.title)
                        .font(.frog(size: TurnType.heading(1), weight: .semibold))
                        .foregroundStyle(Tokens.text)
                        .padding(.top, 6)
                        .padding(.bottom, 14)
                        .accessibilityAddTraits(.isHeader)
                    MarkdownView(text: docs.body(of: page))
                        // A new page is a new text, not a stream: its own view, from the top.
                        .id(page.slug)
                    footer(docs.neighbors(of: page.slug))
                        .padding(.top, 40)
                }
                .padding(.top, 56)
                .padding(.bottom, 48)
                .turnColumn()
            }
            .id(page.slug)
            .scrollIndicators(.automatic)
        } else {
            InspectorEmpty(symbol: "book", title: "Documentation",
                           detail: docs == nil ? "This build has no documentation." : "Pick a page.")
        }
    }

    /// Under a rule: previous on the left, next on the right, each a muted label over the
    /// page's title, as on the web.
    private func footer(_ n: (previous: AppDocs.Page?, next: AppDocs.Page?)) -> some View {
        VStack(spacing: 16) {
            Rectangle().fill(Tokens.line).frame(height: 1)
            HStack(alignment: .top, spacing: 12) {
                if let p = n.previous { link(p, label: "Previous", trailing: false) }
                Spacer(minLength: 0)
                if let p = n.next { link(p, label: "Next", trailing: true) }
            }
        }
    }

    private func link(_ page: AppDocs.Page, label: String, trailing: Bool) -> some View {
        Button { open(page.slug) } label: {
            VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
                Text(label)
                    .font(.frog(size: Tokens.Size.meta))
                    .foregroundStyle(Tokens.textTertiary)
                Text(page.title)
                    .font(.frog(size: Tokens.Size.body))
                    .foregroundStyle(Tokens.text)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .hoverPlate(h: 0, v: 0, radius: 8)
        }
        .buttonStyle(.plain)
        .help("\(label): \(page.title)")
    }
}
