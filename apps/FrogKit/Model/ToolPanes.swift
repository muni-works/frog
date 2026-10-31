import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation

/// One pane the engine and the app share: a shell the engine runs and the user can type into,
/// or a web preview the engine can read and drive. Ids are minted by the engine; a pane the app
/// asked for but hasn't heard back about yet has a placeholder id until `paneOpened` arrives.
struct ToolPane: Identifiable, Equatable {
    let id: String
    var kind: PaneKind
    var title: String
    var cwd: String?
    var url: String?
    /// The latest terminal grid.
    var screen: PaneScreen?
    /// Set once the engine closed it (a shell that exited keeps its last screen).
    var exit: Int?
    var closed = false

    /// Still waiting for the engine to answer `paneOpen`.
    var pending: Bool { id.hasPrefix(PaneHub.pendingPrefix) }
}

/// What the timeline can show for a turn: the preview as it was when the turn ended.
struct Checkpoint: Equatable {
    var turn: UInt64
    var image: PlatformImage
}

/// The panes of one conversation, fed by its engine's events. Views register here to answer
/// `paneRequest`s (the preview does the reading, clicking and screenshots), and everything the
/// preview reports goes back out through `send`.
@MainActor
@Observable
final class PaneHub {
    nonisolated static let pendingPrefix = "pending:"

    private(set) var panes: [ToolPane] = []
    /// The tab in front: Changes, or a pane by id.
    var selected: Tab?
    /// Per-turn preview screenshots, for before/after in the timeline.
    private(set) var checkpoints: [UInt64: Checkpoint] = [:]
    /// The turn whose checkpoint the preview is comparing against, if any.
    var comparing: UInt64?
    /// The mention token last inserted from the preview, shown as a chip while it's in the composer.
    var mention: String?
    /// What the composer currently holds, so the chip knows when the mention is gone. Not
    /// observed: the composer writes it on every keystroke, and a tracked write there would
    /// re-render every view of the panes (the preview, the terminal, their tabs) per character.
    /// What those views actually read is `draftHasMention`, which changes only when it flips.
    @ObservationIgnored var draft = ""
    /// Whether the mention is still in the draft (see `noteDraft`).
    private(set) var draftHasMention = false
    /// Text the composer should insert at the cursor (a mention picked in the preview).
    var insert: String?
    /// The preview's inspect mode toggle, driven from the menu (⇧⌘I).
    var inspecting = false
    /// Recent reports per pane, for the engine's `console` request.
    private(set) var reports: [String: [PaneReport]] = [:]
    /// The turn the engine is on, so an in-app checkpoint screenshot is filed under it.
    var currentTurn: UInt64?
    /// Where the session's files live, to resolve checkpoint paths.
    var sessionDir: URL?
    /// Bumped when the engine asks a preview for something, so the canvas can bring it forward.
    private(set) var attention = 0
    /// One web view per preview pane, kept here so it outlives tab switches and layout.
    #if os(macOS)
    @ObservationIgnored private var hosts: [String: PreviewHost] = [:]
    #else
    /// Previews are the Mac's (a phone shows the transcript); nothing to keep here.
    @ObservationIgnored private var hosts: [String: AnyObject] = [:]
    #endif

    enum Tab: Hashable {
        case changes
        case pane(String)
    }

    @ObservationIgnored var send: (Op) -> Void = { _ in }
    @ObservationIgnored private var handlers: [String: (PaneRequest, @escaping (JSONValue?, String?) -> Void) -> Void] = [:]
    @ObservationIgnored private var lastReport: [String: (PaneReport, Date)] = [:]
    @ObservationIgnored private var reportTimes: [String: [Date]] = [:]

    var terminals: [ToolPane] { panes.filter { $0.kind == .terminal && !$0.closed } }
    var previews: [ToolPane] { panes.filter { $0.kind == .preview && !$0.closed } }

    func pane(_ id: String) -> ToolPane? { panes.first { $0.id == id } }

    private func index(_ id: String) -> Int? { panes.firstIndex { $0.id == id } }

    // MARK: Opening

    /// Show a terminal: the one that's open, or ask the engine for one in `cwd`.
    func openTerminal(cwd: URL) {
        if let t = terminals.first {
            selected = .pane(t.id)
            return
        }
        let id = Self.pendingPrefix + "terminal"
        panes.append(ToolPane(id: id, kind: .terminal, title: "Terminal", cwd: cwd.path))
        selected = .pane(id)
        send(.paneOpen(kind: .terminal, cwd: cwd.path, url: nil, cols: 80, rows: 24))
    }

    /// Show the preview: the one that's open, or ask the engine for one (at `url`, if any).
    func openPreview(url: String? = nil) {
        if let p = previews.first, let i = index(p.id) {
            selected = .pane(p.id)
            if let url { panes[i].url = url }
            return
        }
        let id = Self.pendingPrefix + "preview"
        panes.append(ToolPane(id: id, kind: .preview, title: "Preview", url: url))
        selected = .pane(id)
        send(.paneOpen(kind: .preview, cwd: nil, url: url, cols: nil, rows: nil))
    }

    func close(_ id: String) {
        guard let i = index(id) else { return }
        if !panes[i].pending { send(.paneClose(id: id)) }
        panes.remove(at: i)
        handlers[id] = nil
        hosts[id] = nil
        if comparing != nil, previews.isEmpty { comparing = nil }
        if selected == .pane(id) { selected = panes.last.map { .pane($0.id) } }
    }

    // MARK: Terminal

    func input(_ id: String, _ data: String) {
        guard let p = pane(id), !p.pending else { return }
        send(.paneInput(id: id, data: data))
    }

    func resize(_ id: String, cols: Int, rows: Int) {
        guard let p = pane(id), !p.pending, p.screen.map({ $0.cols != cols || $0.rows != rows }) ?? true else { return }
        send(.paneResize(id: id, cols: cols, rows: rows))
    }

    // MARK: Preview

    #if os(macOS)
    /// The web view behind a preview pane, made on first use.
    func previewHost(_ id: String) -> PreviewHost {
        if let h = hosts[id] { return h }
        let h = PreviewHost()
        h.hub = self
        h.paneID = id
        hosts[id] = h
        return h
    }
    #endif

    /// The preview view answers the engine's requests for this pane.
    func register(_ id: String, _ handler: @escaping (PaneRequest, @escaping (JSONValue?, String?) -> Void) -> Void) {
        handlers[id] = handler
    }

    func unregister(_ id: String) {
        handlers[id] = nil
    }

    /// Note the URL a preview is showing (so a reopened pane and the engine agree).
    func navigated(_ id: String, to url: String?) {
        guard let i = index(id) else { return }
        panes[i].url = url
    }

    func retitle(_ id: String, _ title: String) {
        guard let i = index(id), !title.isEmpty else { return }
        panes[i].title = title
    }

    /// Send a report, at most ~10 a second per pane and never the same line twice in a row.
    func report(_ r: PaneReport) {
        let now = Date()
        if let (last, at) = lastReport[r.id], last == r, now.timeIntervalSince(at) < 2 { return }
        var recent = (reportTimes[r.id] ?? []).filter { now.timeIntervalSince($0) < 1 }
        guard recent.count < 10 else { return }
        recent.append(now)
        reportTimes[r.id] = recent
        lastReport[r.id] = (r, now)
        reports[r.id, default: []].append(r)
        if reports[r.id]!.count > 200 { reports[r.id]!.removeFirst(reports[r.id]!.count - 200) }
        send(.paneReport(r))
    }

    /// The user picked an element in inspect mode: tell the engine, and put it in the composer.
    func mention(_ id: String, token: String, context: String?) {
        send(.paneMention(id: id, mention: token, context: context))
        mention = token
        insert = token + " "
        inspecting = false
        noteDraft(draft)
    }

    /// Is the mention still in what's being typed?
    var mentionInDraft: Bool { draftHasMention }

    /// The composer's text changed: keep it, and say whether the mention is still in it. Only
    /// the answer is observed, so typing re-renders the chip when it should and nothing else.
    func noteDraft(_ text: String) {
        draft = text
        let has = mention.map { text.contains($0) } ?? false
        if has != draftHasMention { draftHasMention = has }
    }

    /// Keep a screenshot of the preview for `turn` (the engine asked with `for: checkpoint`).
    func checkpoint(_ image: PlatformImage, turn: UInt64) {
        checkpoints[turn] = Checkpoint(turn: turn, image: image)
    }

    /// The image behind a checkpoint record, from the session folder.
    private func load(_ path: String, turn: UInt64) {
        let candidates = [URL(fileURLWithPath: path)]
            + [sessionDir?.appending(path: path), sessionDir?.deletingLastPathComponent().appending(path: path)].compactMap { $0 }
        for url in candidates {
            if let image = PlatformImage(contentsOfFile: url.path) {
                checkpoints[turn] = Checkpoint(turn: turn, image: image)
                return
            }
        }
    }

    // MARK: Events

    /// Fold in an engine event; true if it was a pane event.
    @discardableResult
    func apply(_ event: Event) -> Bool {
        switch event {
        case .paneOpened(let id, let kind, let title, let cwd, let url):
            var pane = ToolPane(id: id, kind: kind, title: title.isEmpty ? (kind == .terminal ? "Terminal" : "Preview") : title, cwd: cwd, url: url)
            // The engine answered our own request: swap the placeholder for the real pane.
            if let i = panes.firstIndex(where: { $0.pending && $0.kind == kind }) {
                let placeholder = panes[i].id
                if pane.url == nil { pane.url = panes[i].url }
                panes[i] = pane
                if selected == .pane(placeholder) { selected = .pane(id) }
                #if os(macOS)
                if let h = hosts.removeValue(forKey: placeholder) {
                    handlers[placeholder] = nil
                    hosts[id] = h
                    h.paneID = id
                }
                #endif
            } else if let i = index(id) {
                panes[i] = pane
            } else {
                panes.append(pane)
                if selected == nil { selected = .pane(id) }
            }
        case .paneScreen(let screen):
            if let i = index(screen.id) {
                panes[i].screen = screen
            } else {
                // A pane we never heard opened (a replay): show it anyway.
                panes.append(ToolPane(id: screen.id, kind: .terminal, title: "Terminal", screen: screen))
            }
        case .paneClosed(let id, let exit):
            guard let i = index(id) else { return true }
            panes[i].exit = exit
            if panes[i].kind == .preview || panes[i].screen == nil {
                panes.remove(at: i)
                hosts[id] = nil
                if selected == .pane(id) { selected = panes.last.map { .pane($0.id) } }
            } else {
                panes[i].closed = true
            }
            handlers[id] = nil
        case .paneRequest(let req):
            handle(req)
        case .paneCheckpoint(let turn, let path):
            load(path, turn: turn)
        case .paneNotice:
            return false
        default:
            return false
        }
        return true
    }

    private func handle(_ req: PaneRequest) {
        var answered = false
        let reply: (JSONValue?, String?) -> Void = { [weak self] result, error in
            guard !answered else { return }
            answered = true
            self?.send(.paneReply(call: req.call, result: result, error: error))
        }
        if req.action == "console" {
            let lines = (reports[req.id] ?? []).suffix(100).map { r -> JSONValue in
                var o: [String: JSONValue] = ["kind": .string(r.kind.rawValue), "message": .string(r.message)]
                if let l = r.level { o["level"] = .string(l) }
                if let u = r.url { o["url"] = .string(u) }
                if let s = r.status { o["status"] = .number(Double(s)) }
                return .object(o)
            }
            reply(.array(lines), nil)
            return
        }
        guard let handler = handlers[req.id] ?? (handlers.count == 1 ? handlers.values.first : nil) else {
            reply(nil, "no preview pane \(req.id) is open")
            return
        }
        // The engine is looking at the preview: bring it forward so the user sees what it sees.
        if pane(req.id) != nil { selected = .pane(req.id) }
        attention += 1
        handler(req, reply)
        // Never leave the engine waiting: it gives up at 20s, so answer just before.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(18))
            guard self != nil, !answered else { return }
            reply(nil, "the preview didn't answer in time")
        }
    }
}
