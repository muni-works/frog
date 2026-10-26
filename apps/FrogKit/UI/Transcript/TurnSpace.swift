import SwiftUI

/// The transcript's measure and vertical rhythm, in one place. One narrow column of text;
/// a turn is a paragraph of its own (the space between turns is the loudest), the rows within
/// a turn step down from there, and an activity line hangs close under the text it follows.
///
/// Comfortable / compact:
///
/// | gap        | pt    | where                                                      |
/// |------------|-------|------------------------------------------------------------|
/// | line       | 5 / 2 | extra leading between a paragraph's wrapped lines          |
/// | list       | 6 / 3 | between bullets of one list                                |
/// | paragraph  | 14/ 8 | between a message's paragraphs, and text rows in a turn    |
/// | activity   | 6 / 4 | above an activity line: tight to the paragraph before it   |
/// | block      | 16/10 | other rows in a turn: prompt, cards, visuals, the tail     |
/// | turn       | 32/16 | between turns                                              |
/// | footer     | 4 / 2 | extra above the model/speed caption, on top of `block`     |
enum TurnSpace {
    /// The text column's widest, and the room kept either side of it in a narrow window.
    /// About 90 characters of body text: a reading measure, with room left for code.
    static let measure: CGFloat = 720
    static let gutter: CGFloat = 32
    /// Above the first turn and below the last.
    static let top: CGFloat = 20
    static let bottom: CGFloat = 12
    /// What you asked, as a bubble: at most this wide, so it never reads as a second column.
    static let promptWidth: CGFloat = 540

    /// Small fixed steps for the insides of rows and cards (padding, icon gaps), so they snap
    /// to one scale instead of 5s, 7s and 9s. Not density-dependent.
    enum Inset {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 6
        static let row: CGFloat = 8
        static let card: CGFloat = 10
        static let roomy: CGFloat = 12
    }

    /// The values for the density setting (see `Density`).
    struct Scale: Equatable {
        let line: CGFloat
        let list: CGFloat
        let paragraph: CGFloat
        let activity: CGFloat
        let block: CGFloat
        let turn: CGFloat
        let footer: CGFloat

        static let comfortable = Scale(line: 5, list: 6, paragraph: 14, activity: 6, block: 16, turn: 32, footer: 4)
        static let compact = Scale(line: 2, list: 3, paragraph: 8, activity: 4, block: 10, turn: 16, footer: 2)

        /// Space above a turn's row, from what's above it in the same turn (nil: it opens the
        /// turn). Worked out once per row list (see `TranscriptView.rows`), not per row view.
        func gap(_ part: TurnPart, after previous: TurnPart?, first: Bool) -> CGFloat {
            guard let previous else { return first ? 0 : turn }
            guard case .segment(let segment) = part else { return block }
            switch segment {
            case .activity:
                return activity
            case .text:
                if case .segment(.text) = previous { return paragraph }
                if case .segment(.activity) = previous { return paragraph }
                return block
            case .visual, .notice:
                return block
            }
        }
    }

    /// The scale for a raw density value (an `@AppStorage` string, not the enum).
    static func scale(_ raw: String) -> Scale {
        raw == Density.compact.rawValue ? .compact : .comfortable
    }

    /// The density setting's scale, read from defaults: for `MessageStyle`, which builds text on
    /// AppKit's text queue at times, away from the environment.
    static var current: Scale {
        scale(UserDefaults.standard.string(forKey: "density") ?? "")
    }
}

/// The transcript's type sizes. The answer reads a step larger than the system's 13pt UI text
/// on the Mac, like a document; activity and captions stay at UI sizes, so they recede.
enum TurnType {
    #if os(macOS)
    static let body: CGFloat = 14
    #else
    static let body: CGFloat = 17
    #endif
    /// Headings in a message, by level (1, 2, 3+).
    static func heading(_ level: Int) -> CGFloat {
        level == 1 ? body + 4 : level == 2 ? body + 2 : body
    }
}

extension EnvironmentValues {
    /// The transcript's spacing scale, from the density setting, so views inside a turn
    /// share it without each reading `@AppStorage` themselves.
    @Entry var turnSpace = TurnSpace.Scale.comfortable
}
