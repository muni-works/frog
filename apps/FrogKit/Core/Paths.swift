import Foundation

enum FrogPaths {
    /// Under ~/Documents, ~/Desktop or ~/Downloads, which macOS guards per app (TCC): the
    /// first touch shows an "access files in your Documents folder" prompt.
    static func isPrivacyProtected(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return ["Documents", "Desktop", "Downloads"].contains { path == "\(home)/\($0)" || path.hasPrefix("\(home)/\($0)/") }
    }

    /// Plain chats (no project) run in this folder on the Mac.
    static let chatSuffix = "/.local/share/frog/chat"

    /// Where the engine keeps session logs (on the Mac).
    static let sessions = URL.homeDirectory.appending(path: ".local/share/frog/sessions")

    /// Whether `url` is the chat folder (by path: a restored URL may carry a trailing slash or a
    /// symlinked prefix, and on a phone it's only a path the Mac reported).
    static func isChat(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasSuffix(chatSuffix) || path.hasSuffix(chatSuffix + "/")
    }
}
