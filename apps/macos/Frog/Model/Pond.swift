import Foundation

/// The brief the engine writes of what needs you (`frog --brief`, see crates/frog-engine/src/pond.rs):
/// read from its file at once, then refreshed in the background when it's gone stale.
@MainActor @Observable
final class Pond {
    static let shared = Pond()

    private(set) var brief: Brief?
    private(set) var refreshing = false
    /// Whether a LaunchAgent keeps the brief fresh while Frog is closed; `nil` until asked.
    private(set) var background: Bool?

    /// A brief older than this is refreshed when the empty page shows it.
    static let stale: TimeInterval = 10 * 60

    private static let file = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".local/share/frog/pond/brief.json")

    /// The saved brief, then a fresh one if it's stale.
    func show() async {
        if brief == nil, let data = try? Data(contentsOf: Self.file) {
            brief = try? JSONDecoder.frog.decode(Brief.self, from: data)
        }
        if (brief?.date).map({ Date.now.timeIntervalSince($0) > Self.stale }) ?? true {
            await refresh()
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        CalendarSense.snapshot()
        if let fresh = try? await Frog.json(Brief.self, args: ["--brief", "--json"], cwd: home) {
            brief = fresh
        }
    }

    func loadBackground() async {
        struct Status: Decodable { var on: Bool }
        let home = FileManager.default.homeDirectoryForCurrentUser
        background = (try? await Frog.json(Status.self, args: ["--background", "--json"], cwd: home))?.on
    }

    /// Runs this app's own engine, so it keeps working after updates.
    func setBackground(_ on: Bool) async {
        background = on
        do {
            try await Frog.command(["--background", on ? "on" : "off"])
        } catch {
            NSLog("frog --background: \(error.localizedDescription)")
        }
        await loadBackground()
    }

    /// Not worth your time: out of the brief, and a little less of its kind in the next one.
    func dismiss(_ line: Brief.Line) {
        brief?.items.removeAll { $0.id == line.id }
        Task { try? await Frog.command(["--dismiss", line.id]) }
    }
}

struct Brief: Codable, Sendable {
    var at: String
    var headline: String
    var items: [Line]
    var also: [Line]
    var receipt: Receipt
    var trouble: [String]?
    var today: [Event]?

    /// The engine writes UTC with nanoseconds ("2026-09-30T17:35:12.123456789Z"); seconds do.
    var date: Date? { try? Date(String(at.prefix(19)) + "Z", strategy: .iso8601) }

    struct Line: Codable, Sendable, Identifiable, Equatable {
        var id: String
        var kind: String
        var title: String
        var url: String
        var place: String
        var who: String?
        var note: String
        var new: Bool

        var link: URL? { URL(string: url) }
    }

    struct Event: Codable, Sendable, Equatable {
        var title: String
        var start: String
        var allDay: Bool?

        /// "10:30", local time; all-day events have none.
        var clock: String? {
            guard allDay != true, let d = try? Date(String(start.prefix(19)) + "Z", strategy: .iso8601) else { return nil }
            return d.formatted(date: .omitted, time: .shortened)
        }
    }

    struct Receipt: Codable, Sendable {
        var read: [Read]
        var model: ModelUse?
        var sent: [Sent]
        var wh: Double?

        struct Read: Codable, Sendable { var source: String; var what: String }
        struct ModelUse: Codable, Sendable {
            var name: String
            var place: String
            var inputTokens: Int
            var outputTokens: Int
        }
        struct Sent: Codable, Sendable {
            var to: String
            var bytes: Int
            var what: String
            var isPrivate: Bool

            enum CodingKeys: String, CodingKey { case to, bytes, what, isPrivate = "private" }
        }

        /// Bytes of what the senses read (your data) that left this Mac.
        var privateBytes: Int { sent.filter(\.isPrivate).reduce(0) { $0 + $1.bytes } }

        /// "github · Qwen3-4B on this Mac · nothing left this Mac · 0.01 Wh"
        var summary: String {
            var parts = [read.map(\.source).joined(separator: ", ")]
            if let model {
                parts.append("\(Self.short(model.name)) \(Self.where(model.place))")
            }
            let left = privateBytes
            parts.append(left == 0 ? "nothing left this Mac" : "\(ByteCountFormatter.string(fromByteCount: Int64(left), countStyle: .file)) left this Mac")
            if let wh, wh >= 0.005 { parts.append(String(format: "%.2f Wh", wh)) }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }

        /// Everything, for the tooltip.
        var detail: String {
            var lines = read.map { "Read \($0.source): \($0.what)" }
            if let model {
                lines.append("Headline by \(model.name) \(Self.where(model.place)), \(model.inputTokens) tokens in, \(model.outputTokens) out")
            } else {
                lines.append("Written from templates, no model")
            }
            for s in sent {
                lines.append("Sent \(ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file)) to \(s.to): \(s.what)")
            }
            return lines.joined(separator: "\n")
        }

        /// "tang/mlx-community/Qwen3-4B-4bit" → "Qwen3-4B".
        private static func short(_ name: String) -> String {
            var s = name.split(separator: "/").last.map(String.init) ?? name
            for suffix in ["-4bit", "-8bit", "-bf16", "-fp16", "-MLX", "-GGUF"] where s.hasSuffix(suffix) {
                s.removeLast(suffix.count)
            }
            return s
        }

        private static func `where`(_ place: String) -> String {
            switch place {
            case "mac": "on this Mac"
            case "server": "on your server"
            default: "in the cloud"
            }
        }
    }
}
