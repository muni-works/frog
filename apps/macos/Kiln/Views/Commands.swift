import AppKit
import SwiftUI

/// What the focused window offers the menu bar.
struct KilnWindow {
    let workspace: Workspace
    let state: WindowState
    let toggleSessions: () -> Void
    let toggleChanges: () -> Void
    let sessionsShown: Bool
    let changesShown: Bool
}

extension FocusedValues {
    @Entry var kilnWindow: KilnWindow?
}

/// The menu bar. Everything the app can do lives here with its shortcut, acting on the
/// focused window, so the app is fully drivable from the keyboard and the menus are the
/// reference for what exists.
struct KilnCommands: Commands {
    @FocusedValue(\.kilnWindow) private var window
    @Environment(\.openWindow) private var openWindow

    private var conversation: Conversation? { window?.workspace.conversation }

    /// The latest finished turn that changed files: what "Undo Last Turn" reverts.
    private var undoableTurn: TurnState? {
        guard let c = conversation, !c.busy else { return nil }
        return c.turns.last { $0.finished && $0.number != nil && !TurnParts($0).changes.isEmpty }
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Session") { window?.workspace.newSession() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(window == nil)
            Button("Open Folder…") { openFolder() }
                .keyboardShortcut("o")
        }

        CommandGroup(after: .undoRedo) {
            Button(undoableTurn.flatMap(\.number).map { "Undo Turn \($0)…" } ?? "Undo Last Turn…") {
                window?.state.confirmUndo = true
            }
            .keyboardShortcut("z", modifiers: [.command, .option])
            .disabled(undoableTurn == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find in Conversation…") {
                window?.state.findShown = true
            }
            .keyboardShortcut("f")
            .disabled(conversation == nil)
            Button("Find Next") { find(1) }
                .keyboardShortcut("g")
                .disabled(!(window?.state.findShown ?? false))
            Button("Find Previous") { find(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!(window?.state.findShown ?? false))
        }

        CommandGroup(before: .toolbar) {
            Button((window?.sessionsShown ?? false) ? "Hide Sessions" : "Show Sessions") { window?.toggleSessions() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(window == nil)
            Button((window?.changesShown ?? false) ? "Hide Changes" : "Show Changes") { window?.toggleChanges() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(window == nil)
            Divider()
            Button("Command Palette") { window?.state.paletteShown.toggle() }
                .keyboardShortcut("k")
                .disabled(window == nil)
            Divider()
        }

        CommandMenu("Session") {
            Button("Focus Composer") { window?.state.focusComposer() }
                .keyboardShortcut("l")
            // Not while a permission card is up: there ⌘. is Deny.
            Button("Interrupt") { conversation?.interrupt() }
                .keyboardShortcut(".")
                .disabled(!(conversation?.busy ?? false) || conversation?.permission != nil)
            Button("Race…") { window?.state.requestRace() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(conversation?.busy ?? true)
            Button("Map Project") { mapProject() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(window == nil)
            Button("Compact Conversation") { conversation?.compact() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(conversation.map { $0.busy || $0.turns.isEmpty } ?? true)
            Divider()
            Button("Previous Turn") { step(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(conversation?.turns.isEmpty ?? true)
            Button("Next Turn") { step(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(conversation?.turns.isEmpty ?? true)
            Divider()
            Button("Fork After Last Turn") {
                if let n = lastFinished?.number { window?.workspace.fork(afterTurn: n) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(lastFinished?.number == nil)
        }

        CommandMenu("Model") {
            if let c = conversation {
                Picker("Permissions", selection: Binding(
                    get: { c.status?.mode ?? .default },
                    set: { c.setMode($0) }
                )) {
                    ForEach(Array(Mode.allCases.enumerated()), id: \.element) { i, m in
                        Text(m.label).tag(m)
                            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Model", selection: Binding(
                    get: { c.status?.model ?? "" },
                    set: { spec in
                        window?.workspace.preferredModel = spec
                        c.setModel(spec)
                    }
                )) {
                    ForEach(window?.workspace.models ?? []) { m in
                        Text(m.spec).tag(m.spec)
                    }
                }
                .pickerStyle(.inline)
            } else {
                Text("Open a folder to choose a model")
            }
        }
    }

    private var lastFinished: TurnState? {
        guard let c = conversation, !c.busy else { return nil }
        return c.turns.last { $0.finished }
    }

    private func step(_ delta: Int) {
        guard let c = conversation else { return }
        window?.state.step(delta, in: c.turns)
    }

    private func find(_ delta: Int) {
        guard let c = conversation else { return }
        window?.state.find(delta, in: c.turns)
    }

    /// The project's structure from its code, in a diagram window.
    private func mapProject() {
        guard let folder = window?.workspace.folder else { return }
        Task {
            if let d = await Diagram.codeMap(in: folder), !d.nodes.isEmpty {
                openWindow(value: DiagramDocument(diagram: d, folder: folder))
            } else {
                window?.workspace.conversation?.flash("Couldn't map this folder: no source files that depend on each other.", warning: true)
            }
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(value: url)
    }
}

extension EnvironmentValues {
    /// Set by a window: point its (still empty) conversation at another folder, or nil for a
    /// plain chat.
    @Entry var switchFolder: ((URL?) -> Void)?
}
