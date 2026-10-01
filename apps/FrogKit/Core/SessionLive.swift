import Foundation

/// Whether a conversation is running, waiting on you, or finished unseen: a dot in every list.
enum SessionLive: String, Equatable, Sendable {
    case running, waiting, unread
}
