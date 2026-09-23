import Foundation

/// A diagram as the engine sends it: validated, laid out (in points), with its Mermaid form.
/// Mirrors `kiln_engine::diagram::Diagram`.
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
            var cgPoints: [CGPoint] { points.map { CGPoint(x: $0[0], y: $0[1]) } }
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
    var mermaid: String?

    var isSequence: Bool { kind == .sequence }
    var displayTitle: String { (title?.isEmpty == false) ? title! : (isSequence ? "Sequence" : "Diagram") }

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// Lay out Mermaid source with the engine (`kiln --mermaid --json`).
    static func fromMermaid(_ source: String, cwd: URL) async -> Diagram? {
        guard let binary = Kiln.binary else { return nil }
        return await Task.detached {
            let p = Process()
            p.executableURL = binary
            p.arguments = ["--mermaid", "--json"]
            p.currentDirectoryURL = cwd
            p.environment = Kiln.environment
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

    /// Sessions and their forks in `folder` (`kiln --session-tree --json`).
    static func sessionTree(in folder: URL) async -> Diagram? {
        guard let binary = Kiln.binary else { return nil }
        return await Task.detached {
            let p = Process()
            p.executableURL = binary
            p.arguments = ["--session-tree", "--json"]
            p.currentDirectoryURL = folder
            p.environment = Kiln.environment
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
}
