import SwiftUI

/// The transcript's vertical rhythm, in one place. A turn is a paragraph of its own: the
/// space between turns is larger than the space within one, so each reads as a unit, and
/// the answer's footer sits a step further from the text than the text's own lines.
enum TurnSpace {
    /// Between turns: the loudest gap. A comfortable reading room by default, tighter when
    /// the density setting asks for it.
    static let betweenTurns: CGFloat = 28
    static let betweenTurnsCompact: CGFloat = 14

    /// Within a turn: between the prompt, activity lines, the answer and its cards.
    /// Never larger than the space between turns.
    static let inTurn: CGFloat = 12
    static let inTurnCompact: CGFloat = 8

    /// A markdown message's own lines: extra leading between wrapped lines (line height),
    /// and between its paragraphs, list items and other blocks.
    static let lineHeight: CGFloat = 4
    static let lineHeightCompact: CGFloat = 2
    static let block: CGFloat = 12
    static let blockCompact: CGFloat = 8
    /// Between bullets of one list, tighter than between blocks.
    static let listItem: CGFloat = 5
    static let listItemCompact: CGFloat = 3

    /// The footer (model, speed, cost) set off from the answer above it.
    static let beforeFooter: CGFloat = 16
    static let beforeFooterCompact: CGFloat = 10

    /// The values for the density setting (see `Density`).
    struct Scale: Equatable {
        let betweenTurns: CGFloat
        let inTurn: CGFloat
        let lineHeight: CGFloat
        let block: CGFloat
        let listItem: CGFloat
        let beforeFooter: CGFloat

        static let comfortable = Scale(
            betweenTurns: TurnSpace.betweenTurns,
            inTurn: TurnSpace.inTurn,
            lineHeight: TurnSpace.lineHeight,
            block: TurnSpace.block,
            listItem: TurnSpace.listItem,
            beforeFooter: TurnSpace.beforeFooter
        )

        static let compact = Scale(
            betweenTurns: TurnSpace.betweenTurnsCompact,
            inTurn: TurnSpace.inTurnCompact,
            lineHeight: TurnSpace.lineHeightCompact,
            block: TurnSpace.blockCompact,
            listItem: TurnSpace.listItemCompact,
            beforeFooter: TurnSpace.beforeFooterCompact
        )
    }

    /// The scale for a raw density value (an `@AppStorage` string, not the enum).
    static func scale(_ raw: String) -> Scale {
        raw == Density.compact.rawValue ? .compact : .comfortable
    }
}

extension EnvironmentValues {
    /// The transcript's spacing scale, from the density setting, so views inside a turn
    /// share it without each reading `@AppStorage` themselves.
    @Entry var turnSpace = TurnSpace.Scale.comfortable
}
