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

        /// "On this Mac", "On mew (RTX 3090)", "Cloud · Anthropic".
        var label: String {
            switch self {
            case .mac, .apple: "On this Mac"
            case .server(let name): "On \(name)"
            case .cloud(let name): "Cloud · \(name)"
            }
        }

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

    /// For the engine, ⌥-hover and the detail card only. Never shown as a name.
    let spec: String
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
        let store = ProviderStore.shared
        let place: Place = switch entry.source {
        case "apple": .apple
        case "tang", "ollama": .mac
        case "server": .server(store.name(of: provider))
        case "remote": .cloud(store.name(of: provider))
        // config.toml profiles can point anywhere: trust the provider's own flag, and call
        // anything unknown cloud (the conservative answer for where code goes).
        default: store.providers.first { $0.id == provider }.map { $0.local ? .mac : .cloud($0.name) } ?? .cloud(store.name(of: provider))
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
            name: entry.source == "apple" ? "Apple Intelligence" : (entry.info?.name ?? cleaned.name),
            variant: cleaned.variant,
            place: place,
            abilities: abilities,
            paramsB: entry.caps?.paramsB,
            context: entry.info?.context,
            price: entry.info?.price
        )
    }

    /// The identity for a spec, from the listed models if it's there, else from the spec alone
    /// (a session's model that's no longer listed).
    @MainActor
    static func of(_ spec: String, in models: [ModelEntry]) -> ModelIdentity {
        if let m = models.first(where: { $0.spec == spec }) { return ModelIdentity(m) }
        let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
        let provider = parts.count == 2 ? parts[0] : ""
        let model = parts.last ?? spec
        let store = ProviderStore.shared
        let place: Place = switch provider {
        case "apple": .apple
        case "tang", "ollama", "lmstudio": .mac
        default: store.providers.first { $0.id == provider }.map { p in
            p.custom ? .server(p.name) : p.local ? .mac : .cloud(p.name)
        } ?? .cloud(provider.isEmpty ? "unknown" : store.name(of: provider))
        }
        let cleaned = cleanName(model)
        return ModelIdentity(
            spec: spec,
            name: provider == "apple" ? "Apple Intelligence" : cleaned.name,
            variant: cleaned.variant,
            place: place,
            abilities: [],
            paramsB: nil,
            context: nil,
            price: nil
        )
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
