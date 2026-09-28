import Foundation
import Observation

/// What frog has seen models do on this Mac: how fast each writes (words/s, measured), how big
/// a typical turn is, and what cloud turns have cost. Feeds the speed and cost shown next to
/// models (docs/models.md, "Cost and speed"). Kept in the app's defaults; tokens stay internal.
@MainActor
@Observable
final class ModelStats {
    static let shared = ModelStats()

    /// Words per token, roughly, for English and code.
    static let wordsPerToken = 0.75
    /// A turn's size before there's any history: 8k in, 1k out.
    static let defaultTurn = (input: 8_000.0, output: 1_000.0)
    /// How many recent turns per model the medians come from.
    static let window = 20

    private struct Record: Codable {
        var speeds: [Double] = []
        var inputs: [Double] = []
        var outputs: [Double] = []
    }

    private struct Store: Codable {
        var models: [String: Record] = [:]
        /// Dollars spent per week, keyed by the week's start (yyyy-MM-dd).
        var spend: [String: Double] = [:]
        /// Prices learned from the catalog, dollars per million tokens: spec → [in, out].
        var prices: [String: [Double]] = [:]
    }

    private var store: Store
    private let defaults: UserDefaults
    private static let key = "modelStats"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        store = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(store) { defaults.set(d, forKey: Self.key) }
    }

    /// Remember what the models frog lists cost, so turns can be priced when they end.
    func learnPrices(_ models: [ModelEntry]) {
        var changed = false
        for m in models {
            guard let i = m.info?.costIn, let o = m.info?.costOut, store.prices[m.spec] != [i, o] else { continue }
            store.prices[m.spec] = [i, o]
            changed = true
        }
        if changed { save() }
    }

    /// A finished turn: its speed and size, and its cost if it ran on a priced model.
    func record(_ usage: TurnUsage, model fallback: String?, at date: Date = .now) {
        guard let spec = usage.model ?? fallback, usage.modelCalls > 0 else { return }
        var r = store.models[spec] ?? Record()
        if let tps = usage.tokensPerSec, tps > 0 { r.speeds = (r.speeds + [tps * Self.wordsPerToken]).suffix(Self.window) }
        r.inputs = (r.inputs + [Double(usage.inputTokens)]).suffix(Self.window)
        r.outputs = (r.outputs + [Double(usage.outputTokens)]).suffix(Self.window)
        store.models[spec] = r
        if let c = cost(of: usage, spec: spec), c > 0 {
            store.spend[Self.week(of: date), default: 0] += c
        }
        save()
    }

    /// Dollars a turn cost, if its model has a price.
    func cost(of usage: TurnUsage, spec: String? = nil) -> Double? {
        guard let spec = spec ?? usage.model, let p = store.prices[spec], p.count == 2 else { return nil }
        return (Double(usage.inputTokens) * p[0] + Double(usage.outputTokens) * p[1]) / 1_000_000
    }

    /// Median words/s on this Mac, once there's a turn to measure.
    func speed(_ spec: String) -> Double? {
        store.models[spec].flatMap { Self.median($0.speeds) }
    }

    /// What a typical turn costs on a model, from this person's recent turn sizes.
    func estimatedTurnCost(_ m: ModelIdentity) -> Double? {
        guard let i = m.costIn, let o = m.costOut else { return nil }
        let r = store.models.values
        let input = Self.median(r.flatMap(\.inputs)) ?? Self.defaultTurn.input
        let output = Self.median(r.flatMap(\.outputs)) ?? Self.defaultTurn.output
        return (input * i + output * o) / 1_000_000
    }

    var spentThisWeek: Double { store.spend[Self.week(of: .now)] ?? 0 }

    private static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func week(of date: Date) -> String {
        let cal = Calendar(identifier: .iso8601)
        let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: start)
    }

    // MARK: Words

    /// "38 words/s".
    static func speedText(_ wordsPerSec: Double) -> String { "\(Int(wordsPerSec.rounded())) words/s" }

    /// Friendly money: "Free", "<1¢", "4¢", "$1.84".
    static func money(_ dollars: Double) -> String {
        if dollars <= 0 { return "Free" }
        if dollars < 0.01 { return "<1¢" }
        if dollars < 1 { return "\(Int((dollars * 100).rounded()))¢" }
        return String(format: "$%.2f", dollars)
    }
}
