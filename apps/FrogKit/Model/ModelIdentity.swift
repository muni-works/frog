import Foundation

/// A model as people see it: a name, where it runs, and what it can do. Built in one place from
/// what frog reports (`ModelEntry`, the provider catalog), so every surface names and marks a
/// model the same way. See docs/models.md.
struct ModelIdentity: Hashable, Sendable {
    /// Where the model runs, which is where code goes.
    enum Place: Hashable, Sendable {
        /// frog's engine, Ollama or LM Studio on this Mac.
        case mac
        /// Apple's on-device model.
        case apple
        /// A server you run elsewhere, by its name.
        case server(String)
        /// A cloud provider, by its name.
        case cloud(String)

        /// "This Mac", "On mew (RTX 3090)", "frog cloud", "Cloud · Anthropic".
        var label: String {
            switch self {
            case .mac, .apple: ProviderID.localName
            case .server(let name): "On \(name)"
            case .cloud(let name): name == ProviderID.cloudName ? name : "Cloud · \(name)"
            }
        }

        /// frog cloud: frog's own hosted models.
        static let frogCloud = Place.cloud(ProviderID.cloudName)
        var isFrogCloud: Bool { self == .frogCloud }

        var symbol: String {
            switch self {
            case .mac: "laptopcomputer"
            case .apple: "apple.intelligence"
            case .server: "server.rack"
            case .cloud: "cloud"
            }
        }

        var isCloud: Bool { if case .cloud = self { true } else { false } }
    }

    struct Abilities: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let usesTools = Abilities(rawValue: 1 << 0)
        static let seesImages = Abilities(rawValue: 1 << 1)
        static let reasons = Abilities(rawValue: 1 << 2)
    }

    /// Whether it can be used now, and if not, what would make it usable. See the States
    /// table in docs/models.md.
    enum State: Hashable, Sendable {
        case ready
        /// Recommended for this Mac, not downloaded yet.
        case notDownloaded(gb: Double)
        case downloading(fraction: Double)
        case downloadFailed(String)
        /// A cloud model whose provider has no key.
        case needsKey(provider: String)
        /// Too big for this Mac's memory.
        case wontFit(needsGB: Int, hasGB: Int)
        /// A cloud model, in a project that keeps its code on your devices.
        case notAllowed(project: String)
        /// A cloud model, with this month's spending cap reached.
        case overCap
        /// Its app or server isn't answering ("Ollama isn't running").
        case unreachable(String)

        var isReady: Bool { self == .ready }
    }

    /// For the engine, ⌥-hover and the detail card only. Never shown as a name.
    let spec: String

    /// Order among models on this Mac: Apple's, then frog's own engine (tang, built in), then
    /// the servers you'd install (Ollama, LM Studio), then anything else.
    var runtimeRank: Int {
        switch ProviderID.of(spec: spec) {
        case "apple": 0
        case ProviderID.local: 1
        case "ollama": 2
        case "lmstudio": 3
        default: 4
        }
    }
    /// "Qwen3 8B", "Claude Sonnet 5", "Apple Intelligence".
    let name: String
    /// "4-bit", when the model id says so. Shown only in details.
    let variant: String?
    let place: Place
    let abilities: Abilities
    /// Billions of parameters, when known.
    let paramsB: Double?
    /// Tokens the model can hold, when known.
    let context: UInt64?
    /// The provider's price line ("$3 / $15 per M"), for cloud models.
    let price: String?
    /// Dollars per million tokens, in and out, when the provider says.
    var costIn: Double? = nil
    var costOut: Double? = nil
    var state: State = .ready
    /// The provider id (the spec's first part), for adding a key.
    var providerID: String { String(spec.split(separator: "/", maxSplits: 1).first ?? "") }
    /// A model frog downloads itself: its Hugging Face repo, and its size.
    var repo: String? = nil
    var downloadGB: Double? = nil

    /// What VoiceOver and hover tips say: "Qwen3 8B, on this Mac", "Claude Sonnet 5, cloud, Anthropic".
    var spoken: String {
        switch place {
        case .mac, .apple: "\(name), on this Mac"
        case .server(let n): "\(name), on \(n)"
        case .cloud(let n): "\(name), cloud, \(n)"
        }
    }
}

extension ModelIdentity {
    /// The identity of a model frog listed.
    @MainActor
    init(_ entry: ModelEntry) {
        let provider = String(entry.spec.split(separator: "/", maxSplits: 1).first ?? "")
        let place: Place = switch entry.source {
        case "apple": .apple
        case "tang", ProviderID.local, "ollama": .mac
        case _ where ProviderID.canonical(provider) == ProviderID.cloud: .frogCloud
        case "server": .server(ModelContext.name(of: provider))
        case "remote": .cloud(ModelContext.name(of: provider))
        // config.toml profiles can point anywhere: trust the provider's own flag, and call
        // anything unknown cloud (the conservative answer for where code goes).
        default: ModelContext.provider(provider).map { $0.local ? .mac : .cloud($0.name) } ?? .cloud(ModelContext.name(of: provider))
        }
        var abilities: Abilities = []
        if let c = entry.caps, c.nativeTools || c.textTools { abilities.insert(.usesTools) }
        if let i = entry.info {
            if i.tools { abilities.insert(.usesTools) }
            if i.vision { abilities.insert(.seesImages) }
            if i.reasoning { abilities.insert(.reasons) }
        }
        let cleaned = Self.cleanName(entry.model)
        self.init(
            spec: entry.spec,
            name: entry.spec == "codex/default" ? "Codex (ChatGPT)" : (entry.source == "apple" ? "Apple Intelligence" : (entry.info?.name ?? cleaned.name)),
            variant: cleaned.variant,
            place: place,
            abilities: abilities,
            paramsB: entry.caps?.paramsB,
            context: entry.info?.context,
            price: entry.info?.price
        )
        costIn = entry.info?.costIn
        costOut = entry.info?.costOut
        if entry.source == "tang" || entry.source == ProviderID.local {
            repo = entry.spec.split(separator: "/", maxSplits: 1).last.map(String.init)
            downloadGB = repo.flatMap(ModelContext.suggestedGB) ?? entry.caps?.paramsB.map { $0 * 0.56 }
        }
        state = Self.state(place: place, provider: providerID, repo: repo, gb: downloadGB, installed: true)
    }

    // MARK: State

    /// Physical memory, in whole GB.
    static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// Memory a model needs to run well: its weights, a fifth more, and room for context.
    static func neededGB(weights gb: Double) -> Int { Int((gb * 1.2 + 2).rounded(.up)) }

    @MainActor
    static func state(place: Place, provider: String, repo: String?, gb: Double?, installed: Bool) -> State {
        if case .cloud(let name) = place, let p = ModelContext.provider(provider), !p.connected {
            return .needsKey(provider: name)
        }
        if place.isCloud, ModelStats.shared.overCap { return .overCap }
        if let p = ModelContext.provider(provider), p.local, ModelContext.reachable(provider) == false {
            return .unreachable(p.custom ? "\(p.name) isn't responding" : "\(p.name) isn't running")
        }
        if let repo {
            switch ModelContext.download(repo) {
            case .downloading(let f)?: return .downloading(fraction: f)
            case .failed(let e)?: return .downloadFailed(e)
            case .done?: return .ready
            case nil: break
            }
        }
        if let gb, case .mac = place {
            let needs = neededGB(weights: gb), has = memoryGB
            if needs > has { return .wontFit(needsGB: needs, hasGB: has) }
        }
        if !installed, let gb { return .notDownloaded(gb: gb) }
        return .ready
    }

    /// The identity for a spec, from the listed models if it's there, else from the spec alone
    /// (a session's model that's no longer listed).
    @MainActor
    static func of(_ spec: String, in models: [ModelEntry]) -> ModelIdentity {
        if let m = models.first(where: { $0.spec == spec }) { return ModelIdentity(m) }
        let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
        let provider = parts.count == 2 ? parts[0] : ""
        let model = parts.last ?? spec
        let place: Place = switch provider {
        case "apple": .apple
        case "tang", ProviderID.local, "ollama", "lmstudio": .mac
        case _ where ProviderID.canonical(provider) == ProviderID.cloud: .frogCloud
        default: ModelContext.provider(provider).map { p in
            p.custom ? .server(p.name) : p.local ? .mac : .cloud(p.name)
        } ?? .cloud(provider.isEmpty ? "unknown" : ModelContext.name(of: provider))
        }
        let cleaned = cleanName(model)
        var m = ModelIdentity(
            spec: spec,
            name: provider == "apple" ? "Apple Intelligence" : cleaned.name,
            variant: cleaned.variant,
            place: place,
            abilities: [],
            paramsB: nil,
            context: nil,
            price: nil
        )
        m.state = state(place: place, provider: provider, repo: nil, gb: nil, installed: true)
        return m
    }

    // MARK: Names

    /// A readable name from a model id: "mlx-community/Qwen3-8B-4bit" → "Qwen3 8B" (4-bit),
    /// "qwen3:4b" → "Qwen3 4B", "gemma-3-4b-it-4bit" → "Gemma 3 4B".
    static func cleanName(_ id: String) -> (name: String, variant: String?) {
        var base = String(id.split(separator: "/").last ?? Substring(id))
        // Ollama tags: "qwen3:4b" → "qwen3-4b"; "latest" says nothing.
        base = base.replacingOccurrences(of: ":latest", with: "").replacingOccurrences(of: ":", with: "-")
        var variant: String?
        var words: [String] = []
        for raw in base.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init) {
            let w = raw.lowercased()
            if let bits = quantization(w) {
                variant = bits
            } else if Self.dropped.contains(w) || w.hasPrefix("q") && w.count > 1 && w.dropFirst().first?.isNumber == true {
                // Instruction-tuned and packaging suffixes, and GGUF quant names like q4_k_m.
                if w.hasPrefix("q"), w.count > 1 { variant = variant ?? w.uppercased() }
            } else {
                words.append(Self.pretty(raw))
            }
        }
        let name = words.joined(separator: " ")
        return (name.isEmpty ? id : name, variant)
    }

    private static let dropped: Set<String> = ["it", "instruct", "chat", "mlx", "gguf", "hf", "k", "m", "s", "l"]

    private static func quantization(_ w: String) -> String? {
        switch w {
        case "4bit", "4-bit", "int4": "4-bit"
        case "8bit", "8-bit", "int8": "8-bit"
        case "3bit": "3-bit"
        case "6bit": "6-bit"
        case "bf16": "bf16"
        case "fp16", "f16": "fp16"
        default: nil
        }
    }

    /// "4b" → "4B", "qwen3" → "Qwen3", "gpt" → "GPT", "Qwen3" stays.
    private static func pretty(_ w: String) -> String {
        let lower = w.lowercased()
        if let last = lower.last, "bmk".contains(last), lower.dropLast().allSatisfy({ $0.isNumber || $0 == "." }), lower.count > 1 {
            return String(lower.dropLast()) + String(last).uppercased()
        }
        if ["gpt", "glm", "phi"].contains(lower) { return lower.uppercased() }
        if w.first?.isUppercase == true { return w }
        return w.prefix(1).uppercased() + w.dropFirst()
    }
}
