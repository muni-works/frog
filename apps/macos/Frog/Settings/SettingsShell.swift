import AppKit
import SwiftUI

/// Settings mode (docs/design/app-shell.md): ⌘, turns the front window's sidebar into the
/// section list, with Back to app and esc, and the main area shows one section, drawn from
/// design/settings.json. No second window.

extension EnvironmentValues {
    /// Puts the window in Settings mode, on a section (by id or an old tab name) or the last one.
    @Entry var showSettings: ((String?) -> Void)?
}

/// A request to show Settings that arrives outside a window: a `frog://settings/<section>`
/// link, or ⌘, with no window open. The front window takes it; a window that opens next takes
/// one left waiting.
enum SettingsRequest {
    static let name = Notification.Name("toys.frog.settingsRequest")
    @MainActor static var pending: String?

    @MainActor static func post(_ section: String) {
        pending = section
        NotificationCenter.default.post(name: name, object: section)
    }

    /// The waiting request, once.
    @MainActor static func take() -> String? {
        defer { pending = nil }
        return pending
    }
}

/// Theme: System follows the Mac; Light or Dark pins every window.
enum AppTheme {
    static let key = "appearance"

    @MainActor static func apply(_ raw: String? = UserDefaults.standard.string(forKey: key)) {
        switch raw {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// The sidebar in Settings mode: Back to app, then one row per section, in three runs (how
/// the app behaves; what the agent knows and can do; usage and the account) with a small gap
/// between them and no labels.
struct SettingsSidebar: View {
    let selected: String
    let maxHeight: CGFloat
    let open: (String) -> Void
    let back: () -> Void
    var catalog = SettingsCatalog.bundled

    /// The space between two runs of sections.
    static let runGap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: back) {
                ShellRow(symbol: "arrow.left", title: "Back to app", key: "esc")
            }
            .buttonStyle(.plain)
            .help("Back to your threads (Esc)")
            .padding(.bottom, 6)
            ForEach(Array(catalog.sections.enumerated()), id: \.element.id) { i, s in
                Button { open(s.id) } label: {
                    ShellRow(symbol: nil, title: s.label, selected: s.id == selected)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(s.id == selected ? .isSelected : [])
                .padding(.top, i > 0 && catalog.sections[i - 1].run != s.run ? Self.runGap : 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .frame(maxHeight: maxHeight, alignment: .top)
    }
}

/// Where you are in Settings, in the window's title bar: "Settings › Models › mew". The page
/// itself has no title; a parent you can go back to is a link.
struct SettingsCrumbs: View {
    let section: String
    /// The open machine's name, on its page.
    var machine: String? = nil
    var backToSection: () -> Void = {}
    var catalog = SettingsCatalog.bundled

    private var label: String { catalog.sections.first { $0.id == section }?.label ?? "Settings" }

    var body: some View {
        if let machine {
            ShellCrumbs(root: "Settings", trail: [.init(label, back: backToSection), .init(machine)])
        } else {
            ShellCrumbs(root: "Settings", trail: [.init(label)])
        }
    }
}

/// A mode's breadcrumbs in the title bar (Settings): the mode, then the way down to
/// the page. Every step but the last is a link back to it.
struct ShellCrumbs: View {
    struct Step {
        let label: String
        var mono = false
        var back: (() -> Void)? = nil
        init(_ label: String, mono: Bool = false, back: (() -> Void)? = nil) {
            self.label = label
            self.mono = mono
            self.back = back
        }
    }

    let root: String
    let trail: [Step]

    var body: some View {
        HStack(spacing: 6) {
            Text(root).foregroundStyle(Tokens.textSecondary)
            ForEach(Array(trail.enumerated()), id: \.offset) { i, step in
                chevron
                if i < trail.count - 1, let back = step.back {
                    CrumbLink(step: step, back: back)
                } else {
                    text(step).foregroundStyle(Tokens.text)
                }
            }
        }
        .font(.frog(size: 13, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
        // A container, so the links back stay their own buttons for VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Breadcrumb")
    }

    private func text(_ step: Step) -> Text {
        step.mono ? Text(step.label).font(.frog(size: 12.5, design: .monospaced)) : Text(step.label)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.frog(size: 9, weight: .semibold)).foregroundStyle(Tokens.textTertiary)
    }

    private struct CrumbLink: View {
        let step: Step
        let back: () -> Void
        @State private var hovering = false
        var body: some View {
            Button(action: back) {
                Text(step.label).underline(hovering).foregroundStyle(Tokens.textSecondary)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Back to \(step.label)")
        }
    }
}

/// One section: its rows under their group labels, from the list (the title bar names it).
struct SettingsSectionView: View {
    let section: String
    /// Models › a machine's page, if one is open.
    var machine: Binding<String?> = .constant(nil)
    var catalog = SettingsCatalog.bundled

    private var title: String { catalog.sections.first { $0.id == section }?.label ?? "Settings" }

    /// Consecutive rows of one group, each run under its label when the page has several groups.
    private var runs: [(group: String?, rows: [SettingsCatalog.Row])] {
        var out: [(group: String?, rows: [SettingsCatalog.Row])] = []
        for r in catalog.macRows(in: section) where SettingsBindings.drawnBy[r.id] == nil {
            if let last = out.last, last.group == r.group { out[out.count - 1].rows.append(r) } else { out.append((r.group, [r])) }
        }
        return out
    }

    var body: some View {
        if section == "models", let id = machine.wrappedValue {
            MachineSettingsPage(deviceID: id) { machine.wrappedValue = nil }
                .id(id)
        } else {
            let runs = runs
            let labelled = Set(runs.map(\.group)).count > 1
            SettingsPage(title: title) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    if labelled, let g = run.group, !run.rows.allSatisfy({ SettingsBindings.ownLabel.contains($0.id) }) {
                        SettingsGroupLabel(text: g)
                    }
                    if run.rows.allSatisfy({ SettingsBindings.ownLayout.contains($0.id) }) {
                        ForEach(run.rows) { r in SettingsBindings.view(for: r) }
                    } else {
                        SettingsRows {
                            ForEach(run.rows) { r in SettingsBindings.view(for: r) }
                        }
                    }
                }
            }
            .id(section)
            .environment(\.openMachine) { machine.wrappedValue = $0 }
        }
    }
}
