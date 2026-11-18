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

/// The sidebar in Settings mode: Back to app, then one row per section.
struct SettingsSidebar: View {
    let selected: String
    let maxHeight: CGFloat
    let open: (String) -> Void
    let back: () -> Void
    var catalog = SettingsCatalog.bundled

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: back) {
                ShellRow(symbol: "arrow.left", title: "Back to app", key: "esc")
            }
            .buttonStyle(.plain)
            .help("Back to your threads (Esc)")
            .padding(.bottom, 6)
            ForEach(catalog.sections) { s in
                Button { open(s.id) } label: {
                    ShellRow(symbol: nil, title: s.label, selected: s.id == selected)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(s.id == selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .frame(maxHeight: maxHeight, alignment: .top)
    }
}

/// One section: its title, then its rows under their group labels, from the list.
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
