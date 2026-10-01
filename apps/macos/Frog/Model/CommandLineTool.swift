import AppKit

/// `frog` in a terminal: a link from /usr/local/bin to the engine inside this app, so the
/// command line and the app are always the same version, and Sparkle updates both.
@MainActor
@Observable
final class CommandLineTool {
    static let shared = CommandLineTool()

    enum State: Equatable {
        /// The link points at this app's frog.
        case installed
        /// Something else is at /usr/local/bin/frog (another copy of Frog, or a cargo build).
        case other(String)
        case missing
    }

    static let link = URL(fileURLWithPath: "/usr/local/bin/frog")
    private(set) var state = State.missing
    private(set) var error: String?

    private var bundled: URL? { Bundle.main.url(forResource: "frog", withExtension: nil) }

    /// Run from the disk image or Downloads, macOS moves the app somewhere random and read-only
    /// (App Translocation); a link there would break as soon as it's ejected or moved.
    var movable: String? {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            return "Move Frog to Applications first."
        }
        return nil
    }

    private init() { refresh() }

    func refresh() {
        let fm = FileManager.default
        if let dest = try? fm.destinationOfSymbolicLink(atPath: Self.link.path) {
            state = dest == bundled?.path ? .installed : .other(dest)
        } else {
            state = fm.fileExists(atPath: Self.link.path) ? .other(Self.link.path) : .missing
        }
    }

    /// Link it, asking for an administrator's password only when /usr/local/bin needs one.
    /// Replaces an old link (a Frog that moved), never a real file someone put there.
    func install() async {
        error = nil
        defer { refresh() }
        guard let bundled else { return error = "This build of Frog has no frog to link." }
        if let movable { return error = movable }
        let fm = FileManager.default
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: Self.link.path)) != nil
        if fm.fileExists(atPath: Self.link.path), !isLink {
            return error = "There's already a frog at \(Self.link.path). Remove it, then try again."
        }
        do {
            try fm.createDirectory(at: Self.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if isLink { try fm.removeItem(at: Self.link) }
            try fm.createSymbolicLink(at: Self.link, withDestinationURL: bundled)
        } catch {
            let sh = "mkdir -p /usr/local/bin && ln -sfn \(quoted(bundled.path)) \(quoted(Self.link.path))"
            let escaped = sh.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(escaped)\" with administrator privileges"
            if let message = await osascript(script) { self.error = message }
        }
    }

    /// The menu's version: says how it went, since there's no settings row to show it.
    func installFromMenu() async {
        await install()
        let alert = NSAlert()
        if let error {
            alert.messageText = "Couldn't install frog"
            alert.informativeText = error
        } else if state == .installed {
            alert.messageText = "frog is installed"
            alert.informativeText = "Open a new terminal and run frog."
        } else {
            return
        }
        alert.runModal()
    }

    private func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// nil on success; the reason otherwise, except when the password prompt was cancelled.
    private func osascript(_ script: String) async -> String? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            do { try p.run() } catch { return error.localizedDescription }
            p.waitUntilExit()
            guard p.terminationStatus != 0 else { return nil }
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return text.contains("-128") ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
