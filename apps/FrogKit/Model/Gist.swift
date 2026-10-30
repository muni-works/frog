import Foundation
import FoundationModels

/// A long thought in one line, from Apple's on-device model: what the model worked out or
/// decided ("Decided to move to ~/Developer/frog first"). Free and private, so every finished
/// thought on screen can have one. Asked for when a thought's line first shows, one at a time,
/// and kept on disk so a reopened conversation doesn't ask again. Silently absent where the
/// model isn't available.
@MainActor
@Observable
final class Gists {
    static let shared = Gists()

    private(set) var byKey: [String: String] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Enough for a long history; the oldest go first.
    private static let limit = 4_000
    @ObservationIgnored private var order: [String] = []

    private static let file: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "toys.frog")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "gists.json")
    }()

    private init() {
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode([[String]].self, from: data) else { return }
        for pair in saved where pair.count == 2 {
            byKey[pair[0]] = pair[1]
            order.append(pair[0])
        }
    }

    static func key(session: String?, item: String) -> String { "\(session ?? "-")/\(item)" }

    func gist(session: String?, item: String) -> String? { byKey[Self.key(session: session, item: item)] }

    /// Asks for `thought`'s gist unless it's known or already asked for. Requests run one after
    /// another: the on-device model takes one at a time.
    func request(session: String?, item: String, thought: String) {
        let key = Self.key(session: session, item: item)
        guard byKey[key] == nil, !asked.contains(key), SystemLanguageModel.default.availability == .available else { return }
        asked.insert(key)
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let line = await Self.summarize(thought) else { return }
            self?.store(line, for: key)
        }
    }

    private func store(_ line: String, for key: String) {
        byKey[key] = line
        order.append(key)
        if order.count > Self.limit {
            for old in order.prefix(order.count - Self.limit) { byKey[old] = nil }
            order.removeFirst(order.count - Self.limit)
        }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            let pairs = order.compactMap { k in byKey[k].map { [k, $0] } }
            try? JSONEncoder().encode(pairs).write(to: Self.file, options: .atomic)
        }
    }

    /// One line for a thought, or nil. The start says what it set out to do and the end what
    /// it settled on; the middle is dropped to fit the small model's window.
    nonisolated static func summarize(_ thought: String) async -> String? {
        let text = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let excerpt = text.count > 2_400 ? "\(text.prefix(600))\n…\n\(text.suffix(1_800))" : text
        let session = LanguageModelSession(instructions: """
            You sum up an AI assistant's private reasoning for the person it's helping. Reply with \
            one line of at most 14 words: what it worked out or decided. Start with a past-tense \
            verb, like "Decided to…" or "Found that…". Plain words, no preamble, no quotes.
            """)
        guard let reply = try? await session.respond(to: "Reasoning:\n\(excerpt)").content else { return nil }
        let line = reply
            .split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#"))
            ?? ""
        return line.isEmpty || line.count > 140 ? nil : line
    }
}
