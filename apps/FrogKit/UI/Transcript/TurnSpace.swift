import SwiftUI

/// The transcript's measure and vertical rhythm, in one place. One narrow column of text;
/// a turn is a paragraph of its own (the space between turns is the loudest), the rows within
/// a turn step down from there, and an activity line is a margin note: closer than a paragraph
/// to the prose it follows, but with air of its own.
///
/// Comfortable / compact:
///
/// | gap        | pt    | where                                                      |
/// |------------|-------|------------------------------------------------------------|
/// | line       | 7 / 6 | extra leading under every line (wrapped or last)           |
/// | list       | 7 / 6 | between items of one list                                  |
/// | paragraph  | 18/16 | between a message's paragraphs, and text rows in a turn    |
/// | section    | 30/26 | above a heading                                            |
/// | heading    | 7 / 6 | below a heading: it belongs to what follows                |
/// | activity   | 12/8  | above an activity line that follows prose: a margin note   |
/// | block      | 16/10 | other rows in a turn: prompt, cards, visuals, the tail     |
/// | turn       | 32/16 | between turns                                              |
/// | footer     | 4 / 2 | extra above the model/speed caption, on top of `block`     |
///
/// Inside a message TextKit puts `line` under a paragraph's last line too, so what you see
/// between blocks is `line` + the gap: ≈25 between paragraphs, ≈13 between list items (vs 7
/// for a wrapped line), ≈37 above a heading and ≈13 below it. The line leading is set to the
/// web's read (tokens.css `web-body`, 1.55): at the body's 14pt that's ≈22pt a line, SF's own
/// is ≈17, and 7pt of leading lands there.
///
/// Compact tightens the chrome (rows, turns, the footer), and the prose only a notch: a message
/// is read the same way at either density, and a squeezed list reads as one wrapped paragraph.
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
        /// A line's leading icon (tool rows, thoughts, event lines): one width for all of them,
        /// so their titles line up down the column at `iconColumn`.
        static let icon: CGFloat = 18
        /// Where a line's title starts, and its detail is indented to: past the icon and its gap.
        static let iconColumn: CGFloat = icon + row
    }

    /// Boxes in the column (code, diagrams, subagents, the plan, cards that need you): edges on
    /// the column's edges, one corner, one inner padding, so what's inside any box starts at
    /// the same place. Lines (activity, tool rows, notices, banners) aren't boxes: their content
    /// sits on the column's edge, and a hover plate bleeds outward (see `linePlate`).
    enum Card {
        static let radius: CGFloat = 12
        static let padding: CGFloat = Inset.roomy
        /// A box inside a row or a card (a tool's output, a diff): a smaller corner.
        static let nestedRadius: CGFloat = 8
    }

    /// The values for the density setting (see `Density`).
    struct Scale: Equatable {
        let line: CGFloat
        let list: CGFloat
        let paragraph: CGFloat
        let section: CGFloat
        let heading: CGFloat
        let activity: CGFloat
        let block: CGFloat
        let turn: CGFloat
        let footer: CGFloat
        /// Between two activity groups of one run of work (a long thought's line, then what it
        /// did): a step tighter than the answer's own paragraph gap.
        let rowGroup: CGFloat

        static let comfortable = Scale(line: 7, list: 7, paragraph: 18, section: 30, heading: 7,
                                       activity: 12, block: 16, turn: 32, footer: 4, rowGroup: 8)
        static let compact = Scale(line: 6, list: 6, paragraph: 16, section: 26, heading: 6,
                                   activity: 8, block: 10, turn: 16, footer: 2, rowGroup: 5)

        /// Space above a markdown block, from the block before it in the same message (nil: it's
        /// the first). The only gap between two blocks: nothing is added below a block, so two
        /// gaps never stack (list items once sat further apart than paragraphs that way).
        func gap(_ block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat {
            guard let previous else { return 0 }
            if case .heading = block { return section }
            if case .heading = previous { return heading }
            if case .bullet = block, case .bullet = previous { return list }
            return paragraph
        }

        /// Space above a turn's row, from what's above it in the same turn (nil: it opens the
        /// turn). Worked out once per row list (see `TranscriptView.rows`), not per row view.
        func gap(_ part: TurnPart, after previous: TurnPart?, first: Bool) -> CGFloat {
            guard let previous else { return first ? 0 : turn }
            guard case .segment(let segment) = part else { return block }
            switch segment {
            case .activity:
                // A group that follows prose is a margin note — closer than a paragraph, with
                // air of its own. A group that leads the turn or follows another group is part
                // of the same run of work: tight to it.
                if case .segment(.text) = previous { return activity }
                return rowGroup
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
    /// Tables in a message: a step down, so a wide one fits the measure.
    static let small: CGFloat = body - 2
    /// A list item's marker column: its text starts this far in, whatever the marker ("•", "1.",
    /// "10."), so a list's text lines up; a nested list steps in by one column, putting its
    /// markers under its parent's text.
    static let markerColumn: CGFloat = (body * 1.6).rounded()
    /// Between a marker's right edge and the item's text.
    static let markerGap: CGFloat = TurnSpace.Inset.row

    /// The marker shown for a list item: numbers as written, bullets by depth (disc, circle,
    /// square), like a browser's lists.
    static func marker(_ marker: String, indent: Int) -> String {
        guard marker == "•" else { return marker }
        return ["•", "◦", "▪"][indent % 3]
    }

    /// Headings in a message, by level (1, 2, 3+).
    static func heading(_ level: Int) -> CGFloat {
        level == 1 ? body + 4 : level == 2 ? body + 2 : body
    }
}

extension View {
    /// On the transcript's column: at most `TurnSpace.measure` wide, centered, with the gutter
    /// either side in a narrow window. The transcript, the banners above the composer and the
    /// composer share it, so the page is one column from the first turn to the field you type in.
    func turnColumn() -> some View {
        frame(maxWidth: TurnSpace.measure)
            .padding(.horizontal, TurnSpace.gutter)
            .frame(maxWidth: .infinity)
    }

    /// A line's hover or open plate. It bleeds outward into the gutter rather than padding the
    /// line in, so the line's icon and words stay on the column's edge, under the paragraphs.
    func linePlate(_ opacity: Double) -> some View {
        padding(.horizontal, TurnSpace.Inset.snug)
            .background(.quaternary.opacity(opacity), in: .rect(cornerRadius: TurnSpace.Card.nestedRadius))
            .padding(.horizontal, -TurnSpace.Inset.snug)
    }
}

extension EnvironmentValues {
    /// The transcript's spacing scale, from the density setting, so views inside a turn
    /// share it without each reading `@AppStorage` themselves.
    @Entry var turnSpace = TurnSpace.Scale.comfortable
}
