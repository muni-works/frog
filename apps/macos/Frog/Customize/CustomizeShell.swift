import AppKit
import SwiftUI

/// Customize mode (docs/design/app-shell.md › Customize): what the agent knows and can do,
/// beside Settings (how the app behaves). Built the way Settings mode is: the sidebar turns
/// into Back to app and the five sections, the title bar shows "Customize › Skills", and the
/// page draws on Settings' 720 column with Settings' rows.

extension EnvironmentValues {
    /// Puts the window in Customize mode, on a section (by id or an old name) or the last one.
    /// The app sidebar's Customize row calls this.
    @Entry var showCustomize: ((String?) -> Void)?
}

/// A page under a section.
enum CustomizePage: Hashable {
    /// A skill opened from Skills (F2Skill).
    case skill(String)
    /// Find and add (F9Find), from Skills or Connections.
    case add(String)
    /// What a pasted server would be, before it's added (F10Review).
    case review(ServerDraft)
}

/// The sidebar: Settings' own, with Customize's five rows.
struct CustomizeSidebar: View {
    let selected: String
    let maxHeight: CGFloat
    let open: (String) -> Void
    let back: () -> Void

    var body: some View {
        SettingsSidebar(selected: selected, maxHeight: maxHeight, open: open, back: back,
                        catalog: CustomizeCatalog.bundled.asSettingsCatalog)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Customize")
    }
}

/// "Customize › Skills", "Customize › Skills › /release-notes", "Customize › Connections › Add › postgres".
struct CustomizeCrumbs: View {
    let panes: Panes
    private let catalog = CustomizeCatalog.bundled

    var body: some View {
        ShellCrumbs(root: "Customize", trail: Self.trail(section: panes.customizeSection, page: panes.customizePage,
                                                        catalog: catalog) { panes.customizePage = $0 })
    }

    static func trail(section: String, page: CustomizePage?, catalog: CustomizeCatalog = .bundled,
                      go: @escaping (CustomizePage?) -> Void) -> [ShellCrumbs.Step] {
        let top = ShellCrumbs.Step(catalog.label(section)) { go(nil) }
        switch page {
        case nil: return [top]
        case .skill(let name): return [top, .init("/\(name)", mono: true)]
        case .add: return [top, .init("Add")]
        case .review(let d): return [top, .init("Add") { go(.add(section)) }, .init(d.name)]
        }
    }

    /// The window's title for the same place, as plain words.
    static func title(section: String, page: CustomizePage?) -> String {
        (["Customize"] + trail(section: section, page: page) { _ in }.map(\.label)).joined(separator: " › ")
    }
}

/// The header's right side: the page's one figure and one action.
struct CustomizeHeaderTrailing: View {
    let panes: Panes
    private var store: CustomizeStore { panes.customize }

    var body: some View {
        HStack(spacing: 14) {
            if let figure { Text(figure).font(.frog(size: 12.5)).foregroundStyle(Tokens.textSecondary).monospacedDigit() }
            action
        }
        .fixedSize()
    }

    private var figure: String? {
        switch panes.customizePage {
        case .skill(let name):
            return store.skills?.first { $0.name == name }?.tokensPerTurn.map { "\(CustomizeFormat.tokens($0)) a turn" }
        case .add, .review:
            return nil
        case nil:
            let r = store.report
            switch panes.customizeSection {
            case "skills": return CustomizeFormat.perTurn(r?.skills.tokens)
            case "connections": return CustomizeFormat.perTurn(r?.connections.tokens)
            case "rules": return CustomizeFormat.perTurn(r?.rules.tokens)
            case "memory":
                guard let n = store.notes?.count else { return nil }
                let weight = CustomizeFormat.perTurn(r?.memory.tokens).map { ", \($0)" } ?? ""
                return "\(n) note\(n == 1 ? "" : "s")\(weight), kept on this Mac"
            default: return nil
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch panes.customizePage {
        case .review(let draft):
            ReviewActions(panes: panes, draft: draft)
        case .some:
            EmptyView()
        case nil:
            switch panes.customizeSection {
            case "skills": pill("Add a skill") { panes.customizePage = .add("skills") }
            case "connections": pill("Add a connection") { panes.customizePage = .add("connections") }
            default: EmptyView()
            }
        }
    }

    private func pill(_ title: String, _ go: @escaping () -> Void) -> some View {
        Button(title, action: go).buttonStyle(CustomizePillStyle())
    }
}

/// The page under the title bar: a section's list, or a page under it.
struct CustomizeView: View {
    let panes: Panes
    var startConversation: (String) -> Void = { _ in }

    var body: some View {
        let store = panes.customize
        Group {
            switch panes.customizePage {
            // Skills, Rules, Memory and Automations come in the next change; until then the mode
            // has Connections only (CustomizeCatalog.shown).
            case .skill: ConnectionsPage(store: store)
            case .add(let section): AddPage(store: store, section: section) { panes.customizePage = .review($0) }
            case .review(let draft): ReviewPage(panes: panes, draft: draft)
            case nil: ConnectionsPage(store: store)
            }
        }
        .id("\(panes.customizeSection)-\(String(describing: panes.customizePage))")
    }
}

// MARK: - Pieces every page uses

/// A list page's opening card: what the thing is, in one bold sentence and one more, and its
/// docs page on the right. Flat, no stroke.
struct ExplainerCard: View {
    let section: String
    var catalog = CustomizeCatalog.bundled

    var body: some View {
        if let e = catalog.explainer(section) {
            HStack(alignment: .center, spacing: 20) {
                (Text(e.bold).foregroundStyle(Tokens.text).fontWeight(.semibold) + Text(" " + e.rest).foregroundStyle(Tokens.textSecondary))
                    .font(.frog(size: 13))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let url = e.url(has: { AppDocs.bundled?.page($0)?.slug == $0 }) {
                    Link(destination: url) {
                        Text(e.link).font(.frog(size: 12.5)).foregroundStyle(Tokens.text).underline(color: Tokens.lineStrong)
                    }
                    .help(url.absoluteString)
                    .fixedSize()
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(CustomizeLook.card, in: .rect(cornerRadius: 14))
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        }
    }
}

enum CustomizeLook {
    /// A flat card, one step off the canvas.
    static let card = Tokens.raised
    /// A row under the pointer.
    static let hot = Tokens.hover
}

/// The header's bordered pill ("Add a skill").
struct CustomizePillStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.frog(size: 12.5, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Tokens.onAccent : Tokens.text)
            .padding(.horizontal, primary ? 15 : 13).padding(.vertical, primary ? 4 : 3)
            .background(primary ? Tokens.accent : (configuration.isPressed ? Tokens.hover : .clear), in: Capsule())
            .overlay { if !primary { Capsule().strokeBorder(Tokens.lineStrong) } }
            .contentShape(Capsule())
            // Room for the stroke's outer half, which a tight frame clips (as FrogPillMenu).
            .padding(1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The 6px orange dot: the only "needs you" mark.
struct NeedsYouDot: View {
    var body: some View {
        Circle().fill(Tokens.notice).frame(width: 6, height: 6)
            .accessibilityElement()
            .accessibilityLabel("Needs you")
    }
}

/// Numbers as the pages say them.
enum CustomizeFormat {
    static func tokens(_ n: Int) -> String {
        "\(n.formatted(.number.grouping(.automatic))) token\(n == 1 ? "" : "s")"
    }

    /// "about 820 tokens a turn": the engine's figures are estimates, and say so.
    static func perTurn(_ n: Int?) -> String? {
        n.map { "about \(tokens($0)) a turn" }
    }

    /// "820 tokens a turn", only when every part is known: a sum with holes in it would be a
    /// number nobody measured.
    static func totalTokens(_ parts: [Int?]?) -> String? {
        guard let parts, !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return "\(tokens(parts.compactMap { $0 }.reduce(0, +))) a turn"
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()
}

// MARK: - Marks

/// One small square per tool a connection offers: filled for one Frog can use, outlined for
/// one that's off, outlined and struck for one withheld.
struct ToolSquares: View {
    enum State: Hashable { case on, off, withheld }
    struct Square: Hashable, Identifiable {
        let tool: String
        let state: State
        var reason: String? = nil
        /// The engine's key for switching it, nil when it can't be switched.
        var exposed: String? = nil
        var id: String { tool }
    }

    let squares: [Square]
    /// Switch a tool on or off, for a square the engine can switch.
    var onSwitch: ((Square, Bool) -> Void)? = nil

    var body: some View {
        FlowRows(spacing: 4) {
            ForEach(squares) { s in
                ToolSquare(square: s, onSwitch: onSwitch)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(squares))
    }

    /// "12 tools, 4 on, 2 withheld" for VoiceOver.
    static func label(_ squares: [Square]) -> String {
        let n = squares.count
        guard n > 0 else { return "No tools" }
        let on = squares.filter { $0.state == .on }.count
        let held = squares.filter { $0.state == .withheld }.count
        var parts = ["\(n) tool\(n == 1 ? "" : "s")"]
        if squares.contains(where: { $0.state == .off }) { parts.append(on == 0 ? "none on" : "\(on) on") }
        if held > 0 { parts.append("\(held) withheld") }
        return parts.joined(separator: ", ")
    }
}

private struct ToolSquare: View {
    let square: ToolSquares.Square
    var onSwitch: ((ToolSquares.Square, Bool) -> Void)?
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            ZStack {
                switch square.state {
                case .on:
                    RoundedRectangle(cornerRadius: 2.5).fill(Tokens.textSecondary)
                case .off, .withheld:
                    RoundedRectangle(cornerRadius: 2.5).strokeBorder(Tokens.lineStrong, lineWidth: 1)
                    if square.state == .withheld {
                        Rectangle().fill(Tokens.textTertiary).frame(width: 8, height: 1).rotationEffect(.degrees(-45))
                    }
                }
            }
            .frame(width: 10, height: 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Self.tip(square))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(square.tool).font(.frog(size: 12.5, design: .monospaced))
                    Spacer()
                    if let onSwitch, square.exposed != nil, square.state != .withheld {
                        FrogToggle(label: square.tool, isOn: Binding(get: { square.state == .on }, set: { onSwitch(square, $0); showing = false }))
                    }
                }
                Text(Self.tip(square).components(separatedBy: ": ").dropFirst().joined(separator: ": "))
                    .font(.frog(size: 12)).foregroundStyle(Tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 260, alignment: .leading)
        }
    }

    static func tip(_ s: ToolSquares.Square) -> String {
        switch s.state {
        case .on: "\(s.tool): Frog can use it"
        case .off: "\(s.tool): off"
        case .withheld: "\(s.tool): withheld, its description \(s.reason ?? "reads like instructions to the model")"
        }
    }
}

/// A skill's last 30 days, one mark a day: tall for a busy day, short for one use, a dot for none.
struct ActivityMarks: View {
    /// Uses per day, oldest first.
    let days: [Int]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, n in
                RoundedRectangle(cornerRadius: 1)
                    .fill(n > 0 ? Tokens.textSecondary : Tokens.line)
                    .frame(width: 3, height: n > 1 ? 14 : n == 1 ? 8 : 3)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(days))
    }

    /// "Used 14 times in the last 30 days", or "Never used".
    static func label(_ days: [Int]) -> String {
        let n = days.reduce(0, +)
        return n == 0 ? "Never used" : "Used \(n) time\(n == 1 ? "" : "s") in the last \(days.count) days"
    }
}

/// What each skill adds to a turn, one bar each against the budget; an outlined bar is one
/// unused in 30 days.
struct WeightBar: View {
    struct Part: Hashable { let name: String; let tokens: Int; let idle: Bool }
    let parts: [Part]
    let budget: Int

    var body: some View {
        GeometryReader { geo in
            let gaps = CGFloat(max(0, parts.count)) * 3
            let unit = max(0, geo.size.width - gaps) / CGFloat(max(budget, parts.map(\.tokens).reduce(0, +), 1))
            HStack(spacing: 3) {
                ForEach(parts, id: \.self) { p in
                    Group {
                        if p.idle {
                            RoundedRectangle(cornerRadius: 3).strokeBorder(Tokens.lineStrong, lineWidth: 1)
                        } else {
                            RoundedRectangle(cornerRadius: 3).fill(Tokens.textSecondary)
                        }
                    }
                    .frame(width: max(3, CGFloat(p.tokens) * unit))
                    .help("\(p.name): \(CustomizeFormat.tokens(p.tokens))")
                }
                RoundedRectangle(cornerRadius: 3).fill(Tokens.well)
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(parts, budget: budget))
    }

    static func label(_ parts: [Part], budget: Int) -> String {
        let used = parts.map(\.tokens).reduce(0, +)
        let each = parts.map { "\($0.name) \(CustomizeFormat.tokens($0.tokens))" }.joined(separator: ", ")
        return "What each skill adds to a turn: \(CustomizeFormat.tokens(used)) of a \(budget.formatted()) token budget. \(each)"
    }
}

/// Small views laid out in rows that wrap.
struct FlowRows: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .init(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// A list page: the explainer, then the page, on Settings' column.
struct CustomizeListPage<Content: View>: View {
    let section: String
    @ViewBuilder var content: Content

    var body: some View {
        SettingsPage(title: CustomizeCatalog.bundled.label(section)) {
            ExplainerCard(section: section)
            content
        }
    }
}

/// While the engine answers.
struct CustomizeLoading: View {
    var body: some View {
        SettingsRow("Looking…") { ProgressView().controlSize(.small) }
    }
}
