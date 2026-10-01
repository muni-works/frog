import AppKit
import SwiftUI

/// What the focused window offers the menu bar.
struct FrogWindow {
    let workspace: Workspace
    let state: WindowState
    let toggleSessions: () -> Void
    let toggleChanges: () -> Void
    let showTerminal: () -> Void
    let showPreview: () -> Void
    let toggleInspect: () -> Void
    let sessionsShown: Bool
    let changesShown: Bool
    /// Start a plain chat in the focused pane.
    let newChat: () -> Void
    /// Nil when the window can't split further, or has nothing to close or cycle through.
    let split: ((Axis) -> Void)?
    let closePane: (() -> Void)?
    let focusPane: ((Int) -> Void)?
}

extension FocusedValues {
    @Entry var frogWindow: FrogWindow?
}

/// The menu bar. Everything the app can do lives here with its shortcut, acting on the
/// focused window, so the app is fully drivable from the keyboard and the menus are the
/// reference for what exists.
struct FrogCommands: Commands {
    @FocusedValue(\.frogWindow) private var window
    @Environment(\.openWindow) private var openWindow

    private var conversation: Conversation? { window?.workspace.conversation }

    /// This conversation's detail level: its own, or nil for the app's default.
    private var detail: Binding<Verbosity?> {
        Binding(
            get: { conversation?.sessionID.flatMap { VerbosityOverrides.shared.bySession[$0] } },
            set: { level in
                if let id = conversation?.sessionID { VerbosityOverrides.shared.set(level, for: id) }
            })
    }

    /// The latest finished turn that changed files: what "Undo Last Turn" reverts.
    private var undoableTurn: TurnState? {
        guard let c = conversation, !c.busy else { return nil }
        return c.turns.last { $0.finished && $0.number != nil && !TurnParts($0).changes.isEmpty }
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if Updates.shared.enabled {
                Button("Check for Updates…") { Updates.shared.check() }
                    .disabled(!Updates.shared.canCheck)
            }
            Button("Install Command Line Tool…") { Task { await CommandLineTool.shared.installFromMenu() } }
                .disabled(CommandLineTool.shared.state == .installed || CommandLineTool.shared.movable != nil)
        }

        // ⌘N starts a chat where you are; windows and tabs are ⌘T and ⌥⌘N.
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                if let window { window.newChat() } else { newWindow() }
            }
            .keyboardShortcut("n")
            Button("New Tab") { newTab() }
                .keyboardShortcut("t")
            Button("New Window") { newWindow() }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }

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
            Button("Terminal") { window?.showTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(conversation == nil)
            Button("Preview") { window?.showPreview() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(conversation == nil)
            Button("Inspect Element in Preview") { window?.toggleInspect() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(conversation == nil)
            Divider()
            Button("Split Right") { window?.split?(.horizontal) }
                .keyboardShortcut("\\")
                .disabled(window?.split == nil)
            Button("Split Down") { window?.split?(.vertical) }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(window?.split == nil)
            Button("Close Pane") { window?.closePane?() }
                .keyboardShortcut("w", modifiers: [.command, .control])
                .disabled(window?.closePane == nil)
            Button("Next Pane") { window?.focusPane?(1) }
                .keyboardShortcut("]")
                .disabled(window?.focusPane == nil)
            Button("Previous Pane") { window?.focusPane?(-1) }
                .keyboardShortcut("[")
                .disabled(window?.focusPane == nil)
            Divider()
            Button("Command Palette") { window?.state.paletteShown.toggle() }
                .keyboardShortcut("k")
                .disabled(window == nil)
            Divider()
        }

        CommandMenu("Session") {
            Button("Focus Composer") { window?.state.focusComposer() }
                .keyboardShortcut("l")
            Button("Start or Stop Dictation") { window?.state.toggleDictation() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(conversation == nil)
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
            Picker("Detail", selection: detail) {
                Text("Default (\(Verbosity.standard.label))").tag(Verbosity?.none)
                ForEach(Verbosity.allCases) { Text($0.label).tag(Optional($0)) }
            }
            .disabled(conversation?.sessionID == nil)
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
                        window?.workspace.use(spec)
                    }
                )) {
                    ForEach(window?.workspace.models ?? []) { m in
                        ModelLabel(model: ModelIdentity(m), size: .menu).tag(m.spec)
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

    /// A new window as a tab of the key window (what the tab bar's + does).
    private func newTab() {
        guard NSApp.keyWindow != nil else { return newWindow() }
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
    }

    /// A new window on its own. SwiftUI only makes new windows through the tab action (asking
    /// for a window by value would bring back one already showing a chat), so make a tab and
    /// move it out.
    private func newWindow() {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        guard NSApp.keyWindow != nil else {
            openWindow(value: Frog.chatFolder)
            return
        }
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        DispatchQueue.main.async {
            guard let new = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) }) else { return }
            new.moveTabToNewWindow(nil)
            new.makeKeyAndOrderFront(nil)
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
    /// Set by a window: start a conversation in this folder (nil: a plain chat) with this prompt.
    @Entry var startConversation: ((URL?, String) -> Void)?
    /// Set by a window: show this session, in this window (switching folders if needed) unless
    /// another window already has it open.
    @Entry var openSession: ((SessionInfo) -> Void)?
    /// Set by a window: show this session in a new pane beside the focused one.
    @Entry var openSessionInSplit: ((SessionInfo) -> Void)?
    /// Which pane (1-based) shows which session, when the window is split.
    @Entry var paneNumbers: [String: Int] = [:]
}
