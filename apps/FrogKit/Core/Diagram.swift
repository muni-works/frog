import Foundation

/// A diagram as the engine sends it: validated, laid out (in points), with its Mermaid form.
/// Mirrors `frog_engine::diagram::Diagram`.
struct Diagram: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case flow, sequence }
    enum Shape: String, Codable, Sendable { case box, rounded, store, actor, decision, external }
    enum EdgeStyle: String, Codable, Sendable { case solid, dashed, thick }

    struct Node: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var label: String
        var shape: Shape?
        var group: String?
        var file: String?
        var line: UInt32?
        var detail: String?
        /// 0...1 recent activity (code maps).
        var heat: Double?
    }

    struct Edge: Codable, Hashable, Sendable {
        var from: String
        var to: String
        var label: String?
        var style: EdgeStyle?
    }

    struct Group: Codable, Hashable, Sendable {
        var id: String
        var label: String?
    }

    struct Layout: Codable, Hashable, Sendable {
        struct NodeBox: Codable, Hashable, Sendable {
            var id: String
            var x: Double, y: Double, w: Double, h: Double
            var rank: Int
            var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
        }
        struct EdgePath: Codable, Hashable, Sendable {
            var edge: Int
            var points: [[Double]]
            var labelAt: [Double]?
            /// A bundle row: several consecutive messages folded into one (folded sequences).
            var bundle: Bundle?
            var cgPoints: [CGPoint] { points.map { CGPoint(x: $0[0], y: $0[1]) } }
        }
        /// A run of consecutive messages folded into one row. Lossy on structure, lossless on
        /// numbers: `label` carries the numbers hoisted out of the folded messages.
        struct Bundle: Codable, Hashable, Sendable {
            var lane: Int
            var count: Int
            var label: String
        }
        struct GroupBox: Codable, Hashable, Sendable {
            var id: String
            var x: Double, y: Double, w: Double, h: Double
            var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
        }
        var width: Double
        var height: Double
        var nodes: [NodeBox]
        var edges: [EdgePath]
        var groups: [GroupBox]?
        var lifelineEnd: Double?
    }

    var kind: Kind?
    var title: String?
    var nodes: [Node]
    var edges: [Edge]
    var groups: [Group]?
    var layout: Layout?
    /// The compact form for the transcript column, when the full layout is too wide to read at
    /// the scale floor. Draw it inline; draw `layout` when expanded, in the window and exports.
    var inline: Layout?
    var mermaid: String?

    var isSequence: Bool { kind == .sequence }
    var hasHeat: Bool { nodes.contains { ($0.heat ?? 0) > 0 } }
    var displayTitle: String { (title?.isEmpty == false) ? title! : (isSequence ? "Sequence" : "Diagram") }

    /// What the transcript column draws: the compact form when the engine made one.
    var inlineLayout: Layout? { inline ?? layout }

    /// The layout a drawing call should use for `expanded` state.
    func layout(expanded: Bool) -> Layout? { expanded ? layout : inlineLayout }

    /// The source edge behind a path, or nil for a folded bundle row.
    func edge(of path: Layout.EdgePath) -> Edge? {
        guard path.bundle == nil, path.edge >= 0, path.edge < edges.count else { return nil }
        return edges[path.edge]
    }

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    #if os(macOS)
    /// Lay out Mermaid source with the engine (`frog --mermaid --json`). Views go through
    /// `DiagramLayout.mermaid`, which is this on the Mac and a request to the Mac on a phone.
    static func fromMermaid(_ source: String, cwd: URL) async -> Diagram? {
        guard let binary = Frog.binary else { return nil }
        return await Task.detached {
            let p = Process()
            p.executableURL = binary
            p.arguments = ["--mermaid", "--json"]
            p.currentDirectoryURL = cwd
            p.environment = Frog.environment
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            input.fileHandleForWriting.write(Data(source.utf8))
            try? input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            return try? d.decode(Diagram.self, from: data)
        }.value
    }

    /// The project's structure from its code (`frog --map --json`).
    static func codeMap(in folder: URL) async -> Diagram? {
        await run(["--map", "--json"], in: folder)
    }

    /// Sessions and their forks in `folder` (`frog --session-tree --json`).
    static func sessionTree(in folder: URL) async -> Diagram? {
        await run(["--session-tree", "--json"], in: folder)
    }

    private static func run(_ args: [String], in folder: URL) async -> Diagram? {
        guard let binary = Frog.binary else { return nil }
        return await Task.detached {
            let p = Process()
            p.executableURL = binary
            p.arguments = args
            p.currentDirectoryURL = folder
            p.environment = Frog.environment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let d = JSONDecoder()
            d.keyDecodingStrategy = .convertFromSnakeCase
            return try? d.decode(Diagram.self, from: data)
        }.value
    }
    #endif
}

/// Where Mermaid gets laid out: the engine on the Mac; on a phone, the Mac's engine over the
/// bridge. Nil means it couldn't be, and the code shows instead.
@MainActor
enum DiagramLayout {
    static var mermaid: (_ source: String, _ cwd: URL?) async -> Diagram? = { _, _ in nil }
}
