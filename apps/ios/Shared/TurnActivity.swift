import ActivityKit
import Foundation

/// A turn running on the Mac, on the lock screen and in the Dynamic Island. Updated by the app
/// while it's awake and by the Mac's pushes while it's not (the same fields, by name).
struct TurnActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// A `FrogMood`, by name: thinking, reading, working, waiting, done, sad.
        var mood: String
        /// The step in hand, in words ("Running cargo test"), or the question, or the outcome.
        var activity: String
        var steps: Int
        /// Frog is waiting on you.
        var waiting: Bool? = nil
        /// The question's id, so it can be answered right from the activity.
        var permission: String? = nil
    }

    var session: String
    var title: String
    /// Blue for your own hardware, green for the cloud, as in the thread.
    var local: Bool
    var startedAt: Date
}
