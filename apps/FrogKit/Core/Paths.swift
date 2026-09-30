import Foundation

enum FrogPaths {
    /// Plain chats (no project) run in this folder on the Mac.
    static let chatSuffix = "/.local/share/frog/chat"

    /// Whether `url` is the chat folder (by path: a restored URL may carry a trailing slash or a
    /// symlinked prefix, and on a phone it's only a path the Mac reported).
    static func isChat(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasSuffix(chatSuffix) || path.hasSuffix(chatSuffix + "/")
    }
}
