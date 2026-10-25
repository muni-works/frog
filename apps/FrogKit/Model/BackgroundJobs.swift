import Foundation

/// A piece of background work the engine ran (a Task, a shell job, a Monitor, a timer), from
/// its durable `background_started` / `background_done` events.
struct BackgroundJob: Equatable, Sendable {
    var id: String
    var kind: String
    /// The command's first line, the Task's description, or "wake in 60s".
    var label: String
    /// A shell job's output file.
    var log: String?
    /// `running` until it ends: done, failed, stopped, matched, timeout, interrupted_by_update.
    var status: String = "running"
}

/// One background wake the engine handed the model (`<job-done …>`, `<monitor-done …>`,
/// `<wakeup …>`, `<task-done …>`, or a plain notice beside them). A turn the engine started
/// on wakes alone is an event, not something the user said: it renders as one compact row
/// per wake (name, outcome, a link to the log), never as a user bubble.
struct WakeEvent: Equatable, Sendable {
    enum Kind: String, Sendable {
        case job = "job-done"
        case monitor = "monitor-done"
        case timer = "wakeup"
        case task = "task-done"
        /// Plain text the engine left beside the tagged wakes (a job an app update stopped).
        case note
    }

    var kind: Kind
    var id: String
    /// The tag's attributes (`exit=0`, `status=matched`, `after_s=60`, …), in order.
    var attributes: [(String, String)]
    var body: String

    static func == (a: WakeEvent, b: WakeEvent) -> Bool {
        a.kind == b.kind && a.id == b.id && a.body == b.body
            && a.attributes.map { "\($0.0)=\($0.1)" } == b.attributes.map { "\($0.0)=\($0.1)" }
    }

    func attribute(_ key: String) -> String? { attributes.first { $0.0 == key }?.1 }

    /// The outcome in a few words: `exit 0`, `failed (exit 2)`, `matched`, `timed out`, …
    var outcome: String {
        switch kind {
        case .job:
            let code = attribute("exit") ?? "?"
            return code == "0" ? "exit 0" : "failed (exit \(code))"
        case .monitor:
            switch attribute("status") {
            case "matched": return "matched"
            case "timeout": return "timed out"
            case let s?: return s
            case nil: return "done"
            }
        case .timer:
            return attribute("after_s").map { "after \($0)s" } ?? "fired"
        case .task:
            return attribute("status") == "failed" ? "failed" : "reported"
        case .note:
            return ""
        }
    }

    var failed: Bool {
        switch kind {
        case .job: return attribute("exit") != "0"
        case .monitor: return attribute("status") == "timeout"
        case .task: return attribute("status") == "failed"
        case .timer, .note: return false
        }
    }

    /// The wakes `input` is made of, in order, or nil when it isn't only wakes (something the
    /// user typed, a session message).
    static func parse(_ input: String) -> [WakeEvent]? {
        var rest = Substring(input).trimmingCharacters(in: .whitespacesAndNewlines)[...]
        var out: [WakeEvent] = []
        var sawTag = false
        while !rest.isEmpty {
            if let (event, after) = tagged(rest) {
                out.append(event)
                sawTag = true
                rest = after.drop(while: \.isWhitespace)
                continue
            }
            // Plain text up to the next wake (or the end): a note, as long as a tag exists too.
            let next = Kind.tagged.compactMap { rest.range(of: "<\($0.rawValue) ")?.lowerBound }.min()
            // A tag that opens here but doesn't parse (no close): not the engine's wakes.
            if next == rest.startIndex { return nil }
            let text = rest[..<(next ?? rest.endIndex)].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                out.append(WakeEvent(kind: .note, id: "", attributes: [], body: text))
            }
            guard let next else { break }
            rest = rest[next...]
        }
        return sawTag ? out : nil
    }

    /// `<tag id=… k=v …>body</tag>` at the start of `s`, and what follows it.
    private static func tagged(_ s: Substring) -> (WakeEvent, Substring)? {
        for kind in Kind.tagged {
            let open = "<\(kind.rawValue) ", close = "</\(kind.rawValue)>"
            guard s.hasPrefix(open), let headEnd = s.firstIndex(of: ">"),
                  let closeAt = s.range(of: close, range: headEnd..<s.endIndex) else { continue }
            let head = s[s.index(s.startIndex, offsetBy: open.count)..<headEnd]
            let attributes: [(String, String)] = head.split(separator: " ").compactMap { pair -> (String, String)? in
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2 else { return nil }
                return (String(kv[0]), String(kv[1]))
            }
            let body = s[s.index(after: headEnd)..<closeAt.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let id = attributes.first { $0.0 == "id" }?.1 ?? ""
            return (WakeEvent(kind: kind, id: id, attributes: attributes, body: body), s[closeAt.upperBound...])
        }
        return nil
    }
}

extension WakeEvent.Kind {
    static let tagged: [WakeEvent.Kind] = [.job, .monitor, .timer, .task]
}
