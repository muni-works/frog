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
        /// Dollars spent per day (yyyy-MM-dd).
        var spend: [String: Double] = [:]
        /// Prices learned from the catalog, dollars per million tokens: spec → [in, out].
        var prices: [String: [Double]] = [:]
        /// Watt-hours per model per hour (yyyy-MM-dd HH): spec → hour → [this Mac, data center].
        /// Optional so defaults saved before it existed still decode.
        var energy: [String: [String: [Double]]]?
        /// How a cloud model's data center energy is estimated: spec → [basis, source].
        var estimates: [String: [String]]?
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

    // MARK: Mirror

    /// Everything recorded here, to hand to a phone: it only shows what the Mac recorded.
    var exported: Data? { try? JSONEncoder().encode(store) }

    /// The Mac's record, in place of this one's (the phone's side of `exported`); kept, so the
    /// numbers are there before the Mac is.
    func adopt(_ data: Data, cap: Double) {
        guard let s = try? JSONDecoder().decode(Store.self, from: data) else { return }
        store = s
        save()
        monthlyCap = cap
    }

    /// Remember what the models frog lists cost, so turns can be priced when they end.
    func learnPrices(_ models: [ModelEntry]) {
        var changed = false
        for m in models {
            guard let info = m.info, let i = info.costIn, let o = info.costOut else { continue }
            // [in, out] or [in, out, cache read, cache write]; -1 is "not listed".
            var p = [i, o]
            if info.costCacheRead != nil || info.costCacheWrite != nil {
                p += [info.costCacheRead ?? -1, info.costCacheWrite ?? -1]
            }
            guard store.prices[m.spec] != p else { continue }
            store.prices[m.spec] = p
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
            store.spend[Self.day(date), default: 0] += c
        }
        recordEnergy(usage, at: date)
        save()
    }

    private func recordEnergy(_ usage: TurnUsage, at date: Date) {
        if let spec = usage.model, let e = usage.energy {
            var byHour = store.energy?[spec] ?? [:]
            let old = byHour[Self.hour(date)] ?? [0, 0]
            byHour[Self.hour(date)] = [old[0] + max(e.localWh, 0), old[1] + (e.remoteWh ?? 0)]
            // Ten days is all the charts show.
            let cutoff = Self.hour(date.addingTimeInterval(-10 * 86_400))
            store.energy = (store.energy ?? [:]).merging([spec: byHour.filter { $0.key >= cutoff }]) { $1 }
            if let basis = e.remoteBasis, let source = e.remoteSource {
                store.estimates = (store.estimates ?? [:]).merging([spec: [basis, source]]) { $1 }
            }
        }
    }

    // MARK: Energy history

    /// One bar of the energy chart: a model's watt-hours in an hour or a day.
    struct EnergyBucket: Identifiable, Hashable {
        let spec: String
        let start: Date
        let mac: Double
        let dataCenter: Double
        var id: String { "\(spec) \(start.timeIntervalSince1970)" }
    }

    /// Models with any energy on record, most used first.
    var energyModels: [String] {
        (store.energy ?? [:]).map { ($0.key, $0.value.values.reduce(0) { $0 + $1[0] + $1[1] }) }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Bars for the last 24 hours (by hour) or 10 days (by day), per model, optionally one model.
    func energyBuckets(days: Bool, spec only: String? = nil, now: Date = .now) -> [EnergyBucket] {
        let cal = Calendar.current
        let from = days ? cal.startOfDay(for: now.addingTimeInterval(-9 * 86_400)) : now.addingTimeInterval(-24 * 3600)
        var out: [String: EnergyBucket] = [:]
        for (spec, byHour) in store.energy ?? [:] where only == nil || only == spec {
            for (key, wh) in byHour {
                guard let at = Self.hourFormatter.date(from: key), at >= cal.dateInterval(of: .hour, for: from)!.start else { continue }
                let start = days ? cal.startOfDay(for: at) : at
                let id = "\(spec) \(start.timeIntervalSince1970)"
                let prev = out[id]
                out[id] = EnergyBucket(spec: spec, start: start, mac: (prev?.mac ?? 0) + wh[0], dataCenter: (prev?.dataCenter ?? 0) + wh[1])
            }
        }
        return out.values.sorted { $0.start < $1.start }
    }

    /// Fill the energy history from session logs (the last ten days), once: turns measured before
    /// the history existed, or while this copy of the app wasn't running.
    func backfillEnergy(from dir: URL = FrogPaths.sessions) async {
        let flag = "energyBackfilled"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        let cutoff = Date.now.addingTimeInterval(-10 * 86_400)
        let found: [(TurnUsage, Date)] = await Task.detached {
            struct Record: Decodable { let env: Envelope? }
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            var out: [(TurnUsage, Date)] = []
            for f in files where f.pathExtension == "jsonl" {
                let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard modified >= cutoff, let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") where line.contains("\"turn_ended\"") && line.contains("\"energy\"") {
                    guard let env = (try? JSONDecoder.frog.decode(Record.self, from: Data(line.utf8)))?.env,
                          case .turnEnded(_, _, let usage) = env.event else { continue }
                    let at = Date(timeIntervalSince1970: Double(env.created) / 1000)
                    if at >= cutoff { out.append((usage, at)) }
                }
            }
            return out
        }.value
        // The logs hold every turn of the last ten days, including any recorded live: rebuild
        // from them rather than add to what's there.
        store.energy = [:]
        for (usage, at) in found { recordEnergy(usage, at: at) }
        save()
    }

    /// Reprice this month's spend from session logs, once: turns recorded before cache reads
    /// were priced at their own rate were counted at the full input rate.
    func repriceSpend(from dir: URL = FrogPaths.sessions, now: Date = .now) async {
        let flag = "spendRepricedForCache"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        let cal = Calendar(identifier: .iso8601)
        guard let month = cal.dateInterval(of: .month, for: now) else { return }
        let found: [(TurnUsage, Date)] = await Task.detached {
            struct Record: Decodable { let env: Envelope? }
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            var out: [(TurnUsage, Date)] = []
            for f in files where f.pathExtension == "jsonl" {
                let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                guard modified >= month.start, let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") where line.contains("\"turn_ended\"") {
                    guard let env = (try? JSONDecoder.frog.decode(Record.self, from: Data(line.utf8)))?.env,
                          case .turnEnded(_, _, let usage) = env.event else { continue }
                    let at = Date(timeIntervalSince1970: Double(env.created) / 1000)
                    if month.contains(at) { out.append((usage, at)) }
                }
            }
            return out
        }.value
        guard !found.isEmpty else { return }
        var spend: [String: Double] = [:]
        for (usage, at) in found {
            if let c = cost(of: usage), c > 0 { spend[Self.day(at), default: 0] += c }
        }
        // Only lower a day: a day the logs don't fully cover (a deleted session) keeps the most
        // it could have been.
        let (from, to) = (Self.day(month.start), Self.day(month.end))
        for (day, old) in store.spend where day >= from && day < to {
            store.spend[day] = min(old, spend[day] ?? old)
        }
        save()
    }

    /// How a cloud model's data center energy is estimated, and the source, once a turn said so.
    func estimate(_ spec: String) -> (basis: String, source: URL?)? {
        guard let e = store.estimates?[spec], e.count == 2 else { return nil }
        return (e[0], URL(string: e[1]))
    }

    /// A model's list prices, dollars per million tokens.
    struct Prices: Equatable {
        var input: Double
        var output: Double
        /// Input read from the provider's cache, and input written to it.
        var cacheRead: Double
        var cacheWrite: Double

        /// When the list leaves the cache rates out: Anthropic reads at a tenth of input and
        /// writes at 1.25×; frog cloud reads at a tenth ($0.06 against $0.60); OpenAI-style
        /// caches at half, with no charge for writing.
        init(spec: String, input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
            let anthropic = spec.contains("anthropic/") || spec.contains("claude")
            let cloud = spec.hasPrefix("cloud/")
            self.input = input
            self.output = output
            self.cacheRead = cacheRead ?? input * (anthropic || cloud ? 0.1 : 0.5)
            self.cacheWrite = cacheWrite ?? input * (anthropic ? 1.25 : 1)
        }

        /// The cost of each part of a turn: fresh input, cache reads, cache writes, output.
        func parts(_ u: TurnUsage) -> (fresh: Double, cached: Double, written: Double, output: Double) {
            let m = 1_000_000.0
            return (Double(u.fresh - u.cacheWritten) * input / m, Double(u.cached) * cacheRead / m,
                    Double(u.cacheWritten) * cacheWrite / m, Double(u.outputTokens) * output / m)
        }

        func cost(_ u: TurnUsage) -> Double {
            let p = parts(u)
            return p.fresh + p.cached + p.written + p.output
        }
    }

    /// A model's list prices, with the cache rates filled in when the list didn't give them.
    func prices(_ spec: String) -> Prices? {
        guard let p = store.prices[spec], p.count >= 2 else { return nil }
        let listed = { (i: Int) in p.count > i && p[i] >= 0 ? p[i] : nil }
        return Prices(spec: spec, input: p[0], output: p[1], cacheRead: listed(2), cacheWrite: listed(3))
    }

    /// Dollars a turn cost, if its model has a price: cache reads and writes at their own rates.
    func cost(of usage: TurnUsage, spec: String? = nil) -> Double? {
        guard let spec = spec ?? usage.model, let p = prices(spec) else { return nil }
        return p.cost(usage)
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

    var spentThisWeek: Double { spent(in: .weekOfYear) }
    var spentThisMonth: Double { spent(in: .month) }

    private func spent(in period: Calendar.Component, at date: Date = .now) -> Double {
        let cal = Calendar(identifier: .iso8601)
        guard let range = cal.dateInterval(of: period, for: date) else { return 0 }
        let (from, to) = (Self.day(range.start), Self.day(range.end))
        return store.spend.filter { $0.key >= from && $0.key < to }.values.reduce(0, +)
    }

    // MARK: Cap

    static let capKey = "monthlyCloudCap"

    /// Dollars a month cloud models may spend; 0 means no cap.
    var monthlyCap: Double {
        get { defaults.double(forKey: Self.capKey) }
        set { defaults.set(newValue, forKey: Self.capKey) }
    }

    /// Cloud models pause for the rest of the month once the cap is reached.
    var overCap: Bool { monthlyCap > 0 && spentThisMonth >= monthlyCap }

    private static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH"
        return f
    }()

    private static func hour(_ date: Date) -> String { hourFormatter.string(from: date) }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: Words

    /// "38 words/s".
    static func speedText(_ wordsPerSec: Double) -> String { "\(Int(wordsPerSec.rounded())) words/s" }

    /// An amount spent: "$0", "4¢", "$1.84".
    static func spent(_ dollars: Double) -> String { dollars <= 0 ? "$0" : money(dollars) }

    // MARK: Energy

    /// Show each turn's watt-hours (Settings › Appearance). Engines always measure; this only
    /// shows it, and it's off by default.
    nonisolated static let energyKey = "showEnergy"

    /// "0.4 Wh", "0.04 Wh", "<0.01 Wh", "12 Wh"; "~" when part of it is a cloud estimate.
    nonisolated static func energy(_ wh: Double, estimated: Bool = false) -> String {
        let n = wh < 0.01 ? "<0.01" : wh < 0.1 ? String(format: "%.2f", wh) : wh < 10 ? String(format: "%.1f", wh) : "\(Int(wh.rounded()))"
        return (estimated ? "~" : "") + n + " Wh"
    }

    /// Friendly money: "Free", "<1¢", "4¢", "$1.84".
    static func money(_ dollars: Double) -> String {
        if dollars <= 0 { return "Free" }
        if dollars < 0.01 { return "<1¢" }
        if dollars < 1 { return "\(Int((dollars * 100).rounded()))¢" }
        return String(format: "$%.2f", dollars)
    }
}
