import Foundation

/// Blocks the model shows instead of prose (the `Present` tool), validated by the engine.
/// Mirrors `frog_engine::present::Present`.
struct Present: Decodable, Hashable, Sendable {
    var title: String?
    var blocks: [Block]

    struct Side: Decodable, Hashable, Sendable {
        var label: String
        var text: String
    }

    enum Tone: String, Decodable, Sendable {
        case info, success, warning, danger
    }

    enum Block: Decodable, Hashable, Sendable {
        case table(columns: [String], rows: [[String]])
        case compare(left: Side, right: Side)
        /// `current` is the step in progress; earlier ones are done.
        case steps(items: [String], current: Int?)
        case callout(tone: Tone, text: String)
        case diagram(Diagram)
        /// A block type from a newer engine.
        case unknown

        private enum Key: String, CodingKey { case type, columns, rows, left, right, items, current, tone, text }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            switch try c.decode(String.self, forKey: .type) {
            case "table":
                self = .table(columns: try c.decode([String].self, forKey: .columns), rows: try c.decode([[String]].self, forKey: .rows))
            case "compare":
                self = .compare(left: try c.decode(Side.self, forKey: .left), right: try c.decode(Side.self, forKey: .right))
            case "steps":
                self = .steps(items: try c.decode([String].self, forKey: .items), current: try c.decodeIfPresent(Int.self, forKey: .current))
            case "callout":
                self = .callout(tone: (try? c.decode(Tone.self, forKey: .tone)) ?? .info, text: try c.decode(String.self, forKey: .text))
            case "diagram":
                self = .diagram(try Diagram(from: decoder))
            default:
                self = .unknown
            }
        }
    }
}
