import AppKit
import SwiftUI

/// The app's motion vocabulary: springs for things that move, short fades when the user has
/// asked for less motion.
enum Motion {
    /// Cards docking, folding and morphing.
    static func panel(reduced: Bool) -> Animation {
        reduced ? .easeInOut(duration: 0.15) : .bouncy(duration: 0.42, extraBounce: 0.04)
    }

    /// Small state changes: overlays, bars, rows.
    static func quick(reduced: Bool) -> Animation {
        reduced ? .easeInOut(duration: 0.12) : .snappy(duration: 0.22)
    }
}

/// Force Touch trackpad feedback, used sparingly: where a gesture crosses a boundary.
@MainActor
enum Haptics {
    /// Crossing a detent, e.g. scrubbing from one turn to the next on the timeline.
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Something settled into place, e.g. a card docking or folding away.
    static func settle() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
