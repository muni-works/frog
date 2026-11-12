import Foundation
import IOKit.ps
import Network
import Observation

/// The machines frog can run models on: this Mac, tang nodes it finds on the network (Bonjour
/// `_frog-node._tcp`, which `tang-llm serve --host` advertises), and Frog Cloud. Each one's
/// card reads the node's `GET /node` (hardware, free memory, loaded model, measured tok/s,
/// queue) about once a second while the Devices window is open.
///
/// A node that wants an API key shows from its Bonjour record alone (name, GPU, memory) until
/// it's paired (docs/node-protocol.md §4); then it's polled with its key, and only while its
/// identity matches the fingerprint pinned at pairing. Paired nodes live in `PairedStore`.
@MainActor
@Observable
final class Devices {
    static let shared = Devices()

    /// This Mac first, then the network's nodes by name, then Frog Cloud.
    private(set) var list: [Device] = []
    /// Why the network can't be searched, when it can't (usually Local Network is off for frog).
    private(set) var browseProblem: String?

    /// Nodes this Mac has paired with (nodes.json; keys in the Keychain).
    private(set) var paired: [PairedNode] = []
    /// Fingerprints the user said "Not now" to, this launch.
    private var dismissed: Set<String> = []
    /// Why a paired node isn't being polled, by node id (its identity changed, it dropped us).
    private var refused: [String: String] = [:]

    @ObservationIgnored var store = PairedStore.shared

    private var local = Device.thisMac()
    private var found: [String: Found] = [:]
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var watchers = 0

    /// A node seen on Bonjour, and what's been learnt about it since.
    private struct Found {
        var device: Device
        var url: URL?
        var resolving = false
    }

    /// Start browsing and polling (balanced by `stop`; the window calls both).
    func start() {
        watchers += 1
        guard watchers == 1 else { return }
        reloadPaired()
        browse()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        publish()
    }

    func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        browser?.cancel()
        browser = nil
        poller?.cancel()
        poller = nil
    }

    // MARK: discovery

    private func browse() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_frog-node._tcp", domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] state in
            let problem: String? = switch state {
            case .waiting(let e), .failed(let e):
                if case .dns(let code) = e, code == -65570 || code == -65555 /* PolicyDenied, NoAuth */ {
                    "Turn on Local Network for Frog in System Settings → Privacy & Security to find other machines."
                } else {
                    "Can't search the network: \(e.localizedDescription)"
                }
            default: nil
            }
            NSLog("frog devices: browser %@", "\(state)")
            Task { @MainActor in self?.browseProblem = problem }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        b.start(queue: .main)
        browser = b
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        for r in results {
            guard case .service(let name, _, _, let interface) = r.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = r.metadata { txt = record.dictionary }
            let id = txt["id"] ?? name
            seen.insert(id)
            var f = found[id] ?? Found(device: Device(id: id, role: .node, name: name))
            f.device.name = name
            f.device.chip = txt["gpu"].map(Device.shortGPU) ?? f.device.chip
            f.device.kind = txt["kind"] ?? f.device.kind
            f.device.totalBytes = txt["mem"].flatMap(UInt64.init) ?? f.device.totalBytes
            f.device.unified = txt["unified"] == "1"
            f.device.keyed = txt["key"] == "1"
            f.device.fingerprint = txt["fp"]
            f.device.pairOpen = txt["pair"] == "1"
            // A keyed node can't be polled before pairing; being on Bonjour is all we know.
            if f.device.keyed && !isPaired(id) { f.device.online = true }
            f.device.link = Device.Link(interface: r.interfaces.first ?? interface)
            found[id] = f
            // Keyed nodes resolve too: pairing needs the address.
            if f.url == nil, !f.resolving { resolve(id, r.endpoint) }
        }
        for id in found.keys where !seen.contains(id) { found[id] = nil }
        publish()
    }

    /// The service's host and port, by connecting once (Bonjour gives a name, `/node` wants a URL).
    private func resolve(_ id: String, _ endpoint: NWEndpoint) {
        found[id]?.resolving = true
        // IPv4: a link-local IPv6 answer ("fe80::…%en0") won't go through URLSession.
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let c = NWConnection(to: endpoint, using: params)
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let url: URL? = {
                    guard case .hostPort(let host, let port) = c.currentPath?.remoteEndpoint else { return nil }
                    var h: String
                    switch host {
                    // Network prints the interface scope ("192.168.2.12%en0"); a URL can't carry it.
                    case .ipv4(let a): h = String("\(a)".split(separator: "%").first ?? "")
                    case .ipv6(let a): h = "[\(a)]"
                    case .name(let n, _): h = n
                    @unknown default: return nil
                    }
                    // Scoped link-local addresses ("fe80::1%en0") need the % escaped in a URL.
                    h = h.replacingOccurrences(of: "%", with: "%25")
                    return URL(string: "http://\(h):\(port.rawValue)")
                }()
                c.cancel()
                Task { @MainActor in
                    self?.found[id]?.url = url
                    self?.found[id]?.device.host = url?.host()
                    self?.found[id]?.resolving = false
                    self?.follow(id, to: url)
                }
            case .failed, .cancelled:
                Task { @MainActor in self?.found[id]?.resolving = false }
            default: break
            }
        }
        c.start(queue: .main)
    }

    /// A paired node found at a new address: point nodes.json there (the engine reads it).
    private func follow(_ id: String, to url: URL?) {
        guard let url, var p = paired.first(where: { $0.node_id == id }) else { return }
        let base = url.absoluteString
        guard p.base_url != base else { return }
        p.base_url = base
        try? store.update(p)
        paired = store.load()
    }

    // MARK: pairing

    func reloadPaired() { paired = store.load() }

    func isPaired(_ id: String) -> Bool { paired.contains { $0.node_id == id } }

    /// The first unpaired node on the network the user hasn't waved off: the notice's subject.
    var offer: Device? {
        list.first { d in
            d.role == .node && d.keyed && !d.paired && d.fingerprint != nil && !dismissed.contains(d.fingerprint!)
        }
    }

    func dismiss(_ id: String) {
        if let fp = found[id]?.device.fingerprint { dismissed.insert(fp) }
        publish()
    }

    /// Pair with a found node using the code it shows. Throws `PairError`.
    func pair(_ id: String, code: String) async throws {
        guard let f = found[id], let url = f.url else { throw PairError.network("no address yet") }
        let (node, key) = try await PairClient.pair(
            base: url, code: code, clientID: PairIdentity.clientID, clientName: PairIdentity.clientName,
            expectedFingerprint: f.device.fingerprint)
        do { try store.save(node, key: key) } catch { throw PairError.network(error.localizedDescription) }
        paired = store.load()
        refused[node.node_id] = nil
        if node.node_id != id, var moved = found.removeValue(forKey: id) {
            moved.device = moved.device.renamed(node.node_id)
            found[node.node_id] = moved
        }
        found[node.node_id]?.device.online = false
        publish()
        await poll()
    }

    /// Forget a node: tell it (best effort), drop the key and the nodes.json entry.
    func unpair(_ id: String) async {
        guard let p = paired.first(where: { $0.node_id == id }) else { return }
        if let key = store.key(for: id), let url = found[id]?.url ?? URL(string: p.base_url) {
            await PairClient.unpair(base: url, clientID: PairIdentity.clientID, key: key)
        }
        try? store.remove(nodeID: id)
        paired = store.load()
        refused[id] = nil
        if let fp = found[id]?.device.fingerprint { dismissed.insert(fp) }
        found[id]?.device.apply(nil)
        if found[id]?.device.keyed == true { found[id]?.device.online = true }
        publish()
    }

    // MARK: polling

    func poll() async {
        async let mine = Self.fetch(URL(string: "http://127.0.0.1:8911")!, key: nil)
        // Unpaired keyed nodes can't be read; refused ones aren't, until re-paired.
        var targets: [(String, URL, String?)] = []
        for (id, f) in found where refused[id] == nil {
            guard let url = f.url else { continue }
            if isPaired(id) { targets.append((id, url, store.key(for: id))) }
            else if !f.device.keyed { targets.append((id, url, nil)) }
        }
        // Paired nodes Bonjour hasn't shown (another subnet, Tailscale, mDNS off): their last address.
        for p in paired where found[p.node_id] == nil && refused[p.node_id] == nil {
            if let url = URL(string: p.base_url) { targets.append((p.node_id, url, store.key(for: p.node_id))) }
        }
        var theirs: [(String, Fetched)] = []
        await withTaskGroup(of: (String, Fetched).self) { g in
            for (id, url, key) in targets { g.addTask { (id, await Self.fetch(url, key: key)) } }
            for await r in g { theirs.append(r) }
        }
        if case .report(let r) = await mine { local.apply(r) } else { local.apply(nil) }
        for (id, fetched) in theirs { take(id, fetched) }
        publish()
    }

    private func take(_ id: String, _ fetched: Fetched) {
        if found[id] == nil, let p = paired.first(where: { $0.node_id == id }) {
            var d = Device(id: id, role: .node, name: p.name)
            d.keyed = true
            found[id] = Found(device: d, url: URL(string: p.base_url))
        }
        let name = found[id]?.device.name ?? "it"
        switch fetched {
        case .report(let r):
            if let p = paired.first(where: { $0.node_id == id }) {
                // Pinning: a paired node must still be the machine we paired.
                guard let fp = r.identity?.fingerprint, fp == p.fingerprint else {
                    refused[id] = "This isn't the \(p.name) you paired."
                    found[id]?.device.apply(nil)
                    return
                }
            }
            if let schema = r.schema, schema > 2 {
                refused[id] = "\(name) runs a newer tang. Update frog to use it."
                found[id]?.device.apply(nil)
                return
            }
            found[id]?.device.apply(r)
        case .unauthorized(let why):
            found[id]?.device.apply(nil)
            // The node dropped our key (`tang-llm unpair`): forget it, so it can be paired again.
            if why == "bad key" || why == "not paired", isPaired(id) {
                try? store.remove(nodeID: id)
                paired = store.load()
                refused[id] = "\(name) isn't paired anymore."
                if found[id]?.device.keyed == true { found[id]?.device.online = true }
            }
        case .none:
            found[id]?.device.apply(nil)
        }
    }

    enum Fetched { case report(NodeReport), unauthorized(String), none }

    nonisolated static func fetch(_ base: URL, key: String?) async -> Fetched {
        var req = URLRequest(url: base.appending(path: "node"))
        req.timeoutInterval = 0.8
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode
        else { return .none }
        if status == 401 {
            let why = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "missing key"
            return .unauthorized(why)
        }
        guard status == 200, let r = try? JSONDecoder().decode(NodeReport.self, from: data) else { return .none }
        return .report(r)
    }

    /// Where a session's model runs, from its `provider/model` id: this Mac for on-device
    /// providers, Frog Cloud for `cloud/`, a found node when a custom provider's host is one,
    /// otherwise the provider by name.
    func serving(model: String, ranOn: RanOn? = nil) -> Serving {
        let provider = String(model.split(separator: "/").first ?? "")
        let short = String(model.split(separator: "/", maxSplits: 1).last ?? Substring(model))
        // A pooled model: where the engine says the last call ran, else where it would run.
        if provider == "node" {
            let hash = String(short.split(separator: "@").first ?? "")
            let nodes = found.values.map(\.device)
            let display = nodes.lazy.compactMap { $0.models.first { $0.weightsHash.hasPrefix(hash) }?.name }.first ?? short
            if let ranOn {
                if ranOn.local == true {
                    return Serving(deviceID: "this-mac", name: "this Mac", symbol: local.symbol, model: display)
                }
                let d = nodes.first { $0.id == ranOn.nodeId || $0.name == ranOn.name }
                return Serving(deviceID: d?.id, name: ranOn.name, symbol: "server.rack", model: display)
            }
            if let d = placement(hash: hash) {
                return Serving(deviceID: d.id, name: d.name, symbol: "server.rack", model: display)
            }
            return Serving(deviceID: "this-mac", name: "this Mac", symbol: local.symbol, model: display)
        }
        // `frog-api/` and `tang/` are Frog Cloud's old names.
        if ["cloud", "frog-api", "tang"].contains(provider) {
            return Serving(deviceID: "frog-cloud", name: "Frog Cloud", symbol: "cloud", model: short)
        }
        if ["local", "apple"].contains(provider) {
            return Serving(deviceID: "this-mac", name: "this Mac", symbol: local.symbol, model: short)
        }
        guard let info = ProviderStore.shared.providers.first(where: { $0.id == provider }) else {
            // Before the provider list loads, Ollama and LM Studio are on this Mac, not a cloud.
            if ["ollama", "lmstudio"].contains(provider) {
                return Serving(deviceID: "this-mac", name: "this Mac", symbol: local.symbol, model: short)
            }
            return Serving(deviceID: nil, name: provider, symbol: "cloud", model: short)
        }
        let host = URL(string: info.baseUrl)?.host()?.lowercased() ?? ""
        if info.local || host == "127.0.0.1" || host == "localhost" {
            return Serving(deviceID: "this-mac", name: "this Mac", symbol: local.symbol, model: short)
        }
        let first = host.split(separator: ".").first.map(String.init) ?? host
        if let d = found.values.map(\.device).first(where: {
            $0.host?.lowercased() == host || $0.name.lowercased() == first
        }) {
            return Serving(deviceID: d.id, name: d.name, symbol: "server.rack", model: short)
        }
        return Serving(deviceID: nil, name: info.custom ? first : info.name,
                       symbol: info.custom ? "server.rack" : "cloud", model: short)
    }

    /// The paired node a pooled model would run on (loaded first, then most free memory).
    func placement(hash: String) -> Device? {
        found.values.map(\.device)
            .filter { $0.paired && $0.online && $0.models.contains { $0.weightsHash.hasPrefix(hash) } }
            .max { a, b in
                let la = a.models.contains { $0.loaded && $0.weightsHash.hasPrefix(hash) }
                let lb = b.models.contains { $0.loaded && $0.weightsHash.hasPrefix(hash) }
                if la != lb { return !la }
                return (a.freeBytes ?? 0) < (b.freeBytes ?? 0)
            }
    }

    /// For the picker: "on mew" for a pooled model, nil when no paired node has it.
    func whereRuns(model: String) -> String? {
        guard model.hasPrefix("node/") else { return nil }
        let hash = String(model.dropFirst(5).split(separator: "@").first ?? "")
        return placement(hash: hash).map { "on \($0.name)" }
    }

    // MARK: putting models onto nodes (D6)

    /// Loads this Mac asked for and the node hasn't reported yet, by spec → node name.
    private(set) var asked: [String: String] = [:]
    /// Why the last load of a spec failed, in one line.
    private(set) var loadProblem: [String: String] = [:]

    /// Where a pooled model (`node/<hash>`) stands on your nodes: loaded somewhere, loading,
    /// on a disk where it fits (and what it would replace), or on a disk where it won't.
    func fit(model spec: String) -> NodeFit? {
        guard spec.hasPrefix("node/") else { return nil }
        let hash = String(spec.dropFirst(5).split(separator: "@").first ?? "")
        let holders = found.values.map(\.device).filter { $0.paired && $0.online }
            .compactMap { d in d.models.first { $0.weightsHash.hasPrefix(hash) }.map { (d, $0) } }
        guard !holders.isEmpty else { return nil }
        if let (d, _) = holders.first(where: { $0.1.loaded }) { return .loaded(node: d.name) }
        if let d = holders.first(where: { $0.0.loadingID != nil && $0.0.loadingID == $0.1.id })?.0 {
            return .loading(node: d.name, seconds: Int(d.loadingSecs ?? 0))
        }
        if let name = asked[spec] { return .loading(node: name, seconds: 0) }
        let fits = holders.filter { ($0.1.loadBytes ?? 0) <= $0.0.room }
        // Prefer a node with nothing to replace, then the one with the most room.
        if let (d, _) = fits.max(by: { a, b in
            if (a.0.model == nil) != (b.0.model == nil) { return a.0.model != nil }
            return a.0.room < b.0.room
        }) {
            return .fits(node: d.name, replaces: d.model)
        }
        let (d, m) = holders.max { $0.0.room < $1.0.room }!
        return .wontFit(node: d.name, need: m.loadBytes ?? 0, room: d.room)
    }

    /// The picker's second line for a pooled model.
    func placeLine(model spec: String) -> String? {
        if let why = loadProblem[spec], asked[spec] == nil { return why }
        return fit(model: spec)?.line
    }

    /// Load a pooled model onto the node `fit` chose (`POST /models/load` with the paired
    /// key). Returns when it's loaded; throws a one-line `NodeLoadError` otherwise. Replacing a
    /// loaded model is the caller's question to ask first.
    func load(model spec: String) async throws {
        guard case .fits(let name, _) = fit(model: spec) else { throw NodeLoadError("It doesn't fit on any of your machines.") }
        let hash = String(spec.dropFirst(5).split(separator: "@").first ?? "")
        guard let (id, f) = found.first(where: { $0.value.device.name == name && $0.value.device.paired }),
              let m = f.device.models.first(where: { $0.weightsHash.hasPrefix(hash) }),
              let base = f.url ?? paired.first(where: { $0.node_id == id }).flatMap({ URL(string: $0.base_url) }),
              let key = store.key(for: id)
        else { throw NodeLoadError("Can't reach \(name).") }
        asked[spec] = name
        loadProblem[spec] = nil
        defer { asked[spec] = nil }
        do {
            try await Self.requestLoad(base, key: key, model: m.id)
        } catch {
            let line = (error as? NodeLoadError)?.message ?? error.localizedDescription
            loadProblem[spec] = line
            await poll()
            throw NodeLoadError(line)
        }
        await poll()
    }

    /// `POST /models/load {"model": id}`; tang answers when the load is done (or refused).
    nonisolated static func requestLoad(_ base: URL, key: String, model: String) async throws {
        var req = URLRequest(url: base.appending(path: "models/load"))
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status != 200 else { return }
        let why = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
        let line = switch status {
        case 409: "It's busy with a turn. Try again when it's idle."
        case 507: "It doesn't fit anymore: " + (why ?? "not enough free memory.")
        default: why ?? "The load failed (\(status))."
        }
        throw NodeLoadError(line)
    }

    private func publish() {
        for id in found.keys {
            found[id]?.device.paired = isPaired(id)
            found[id]?.device.refused = refused[id]
        }
        // This Mac serving beyond loopback finds itself on Bonjour: one card, not two.
        let others = found.values.map(\.device)
            .filter { $0.id != local.nodeID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var cloud = Device(id: "frog-cloud", role: .cloud, name: "Frog Cloud")
        cloud.chip = "qwen3-coder-next"
        cloud.online = CloudAccount.shared.signedIn
        cloud.link = .internet
        let next = [local] + others + [cloud]
        if next != list { list = next }
    }
}

/// Where a session's model is running, for the composer's chip.
struct Serving: Equatable {
    /// The device on the map, when it's one of them.
    var deviceID: String?
    var name: String
    var symbol: String
    var model: String

    /// Where it runs, for its color (`Color.place(_:)`): every cloud route names itself "cloud".
    var place: ModelIdentity.Place {
        if symbol == "cloud" { return .cloud(name) }
        return deviceID == "this-mac" ? .mac : .server(name)
    }
}

/// One machine on the canvas.
struct Device: Identifiable, Equatable {
    enum Role: Equatable { case thisMac, node, cloud }

    /// Where a model on it runs, for its color (`Color.place(_:)`).
    var place: ModelIdentity.Place {
        switch role {
        case .thisMac: .mac
        case .node: .server(name)
        case .cloud: .frogCloud
        }
    }
    enum Link: Equatable {
        case thunderbolt, ethernet, wifi, tailscale, internet, network
        init(interface: NWInterface?) {
            guard let i = interface else { self = .network; return }
            if i.name.hasPrefix("bridge") { self = .thunderbolt; return }
            if i.name.hasPrefix("utun") { self = .tailscale; return }
            switch i.type {
            case .wiredEthernet: self = .ethernet
            case .wifi: self = .wifi
            default: self = .network
            }
        }
        var label: String {
            switch self {
            case .thunderbolt: "Thunderbolt"
            case .ethernet: "Ethernet"
            case .wifi: "Wi-Fi"
            case .tailscale: "Tailscale"
            case .internet: "Internet"
            case .network: "Network"
            }
        }
    }

    let id: String
    let role: Role
    var name: String
    var symbol = "server.rack"
    var chip = ""
    var kind = ""
    var unified = true
    var totalBytes: UInt64 = 0
    var freeBytes: UInt64?
    var keyed = false
    /// The identity fingerprint from Bonjour's `fp` (v2 nodes).
    var fingerprint: String?
    /// The node is showing a pairing code right now (`pair=1`).
    var pairOpen = false
    var paired = false
    /// Why frog stopped talking to this paired node, in one line.
    var refused: String?
    /// What it holds, for pooling by `weights_hash`.
    var models: [PooledModel] = []
    var online = false
    var link: Link = .network
    var nodeID: String?
    /// The address it was reached at, for matching a provider's base URL to it.
    var host: String?
    var model: String?
    var loading: String?
    /// The repo id being loaded, and for how long so far.
    var loadingID: String?
    var loadingSecs: Double?
    /// Device memory the loaded model holds (weights and KV pool).
    var footprint: UInt64 = 0
    var decode: Double?
    var prefill: Double?
    var running = 0
    var waiting = 0

    /// Memory in use, when the node has said how much is free.
    var usedFraction: Double? {
        guard let free = freeBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, 1 - Double(free) / Double(totalBytes)))
    }

    struct PooledModel: Equatable {
        var name: String
        var weightsHash: String
        var quant: String?
        var loaded: Bool
        /// What `/models/load` takes (the repo id or directory the node listed).
        var id: String = ""
        /// Device memory loading it takes, by the node's own estimate (`load_bytes`).
        var loadBytes: UInt64?
    }

    /// Memory a load could use: what's free plus what the loaded model gives back (tang
    /// swaps one model per process and never takes memory other processes hold).
    var room: UInt64 { (freeBytes ?? 0) + footprint }

    /// The same machine under another id (a node whose Bonjour id isn't its node_id).
    func renamed(_ id: String) -> Device {
        var d = Device(id: id, role: role, name: name)
        d.symbol = symbol; d.chip = chip; d.kind = kind; d.unified = unified; d.totalBytes = totalBytes
        d.keyed = keyed; d.fingerprint = fingerprint; d.link = link; d.host = host
        return d
    }

    mutating func apply(_ r: NodeReport?) {
        guard let r else {
            online = false
            models = []
            model = nil; loading = nil; loadingID = nil; loadingSecs = nil; footprint = 0; decode = nil; prefill = nil; running = 0; waiting = 0
            if role != .thisMac { freeBytes = nil }
            return
        }
        online = true
        nodeID = r.node_id
        if totalBytes == 0 || role == .node { totalBytes = r.hardware.total_bytes }
        freeBytes = r.hardware.free_bytes
        if role == .node {
            kind = r.hardware.kind
            unified = r.hardware.unified_memory
            if !r.hardware.name.isEmpty { chip = Self.shortGPU(r.hardware.name) }
        }
        let m = r.models.loaded.first
        model = m.map { Self.shortModel($0.id) }
        loading = r.models.loading.map { Self.shortModel($0.id) }
        loadingID = r.models.loading?.id
        loadingSecs = r.models.loading.map { Double($0.elapsed_ms ?? 0) / 1000 }
        footprint = r.models.loaded.reduce(0) { $0 + ($1.memory?.weights_bytes ?? 0) + ($1.memory?.kv_bytes ?? 0) }
        decode = m?.rates.decode_tok_s.flatMap { $0 > 0 ? $0 : nil }
        prefill = m?.rates.prefill_tok_s.flatMap { $0 > 0 ? $0 : nil }
        running = r.queue.running.count
        waiting = r.queue.waiting.count
        if let n = r.name, !n.isEmpty, role == .node { name = n }
        var pooled: [PooledModel] = []
        for l in r.models.loaded { if let h = l.weights_hash { pooled.append(.init(name: Self.shortModel(l.id), weightsHash: h, quant: l.quant, loaded: true, id: l.id)) } }
        for l in r.models.on_disk ?? [] where !pooled.contains(where: { $0.weightsHash == l.weights_hash }) {
            if let h = l.weights_hash { pooled.append(.init(name: Self.shortModel(l.id), weightsHash: h, quant: l.quant, loaded: false, id: l.id, loadBytes: l.load_bytes)) }
        }
        models = pooled
    }

    static func thisMac() -> Device {
        var d = Device(id: "this-mac", role: .thisMac, name: Host.current().localizedName ?? "This Mac")
        d.symbol = hasBattery ? "laptopcomputer" : "desktopcomputer"
        d.chip = sysctl("machdep.cpu.brand_string").replacingOccurrences(of: "Apple ", with: "")
        d.kind = "metal"
        d.totalBytes = ProcessInfo.processInfo.physicalMemory
        d.link = .network
        return d
    }

    private static var hasBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return !list.isEmpty
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }

    /// "NVIDIA GeForce RTX 3090" → "RTX 3090"; "Apple M4 Max" → "M4 Max".
    static func shortGPU(_ s: String) -> String {
        s.replacingOccurrences(of: "NVIDIA ", with: "")
            .replacingOccurrences(of: "GeForce ", with: "")
            .replacingOccurrences(of: "Apple ", with: "")
    }

    /// "Qwen/Qwen3-4B-MLX-4bit" or a path → "Qwen3-4B-MLX-4bit".
    static func shortModel(_ s: String) -> String {
        String(s.split(separator: "/").last ?? Substring(s))
    }
}

/// The part of tang's `GET /node` the canvas draws (schema 1, plus schema 2's identity, name
/// and model identity when present).
struct NodeReport: Decodable {
    struct Hardware: Decodable {
        var kind: String
        var name: String
        var unified_memory: Bool
        var total_bytes: UInt64
        var free_bytes: UInt64
    }
    struct Rates: Decodable {
        var prefill_tok_s: Double?
        var decode_tok_s: Double?
    }
    struct Memory: Decodable {
        var weights_bytes: UInt64?
        var kv_bytes: UInt64?
    }
    struct Loaded: Decodable {
        var id: String
        var rates: Rates
        var memory: Memory?
        var weights_hash: String?
        var quant: String?
    }
    struct OnDisk: Decodable {
        var id: String
        var weights_hash: String?
        var quant: String?
        var load_bytes: UInt64?
    }
    struct Identity: Decodable {
        var fingerprint: String
        var public_key: String?
    }
    struct Loading: Decodable {
        var id: String
        var elapsed_ms: UInt64?
    }
    struct Models: Decodable {
        var loaded: [Loaded]
        var loading: Loading?
        var on_disk: [OnDisk]?
    }
    struct Job: Decodable {}
    struct Queue: Decodable {
        var running: [Job]
        var waiting: [Job]
    }
    var schema: Int?
    var node_id: String
    var name: String?
    var identity: Identity?
    var hardware: Hardware
    var models: Models
    var queue: Queue
}

/// Where a pooled model stands on your nodes, for the picker.
enum NodeFit: Equatable {
    case loaded(node: String)
    case loading(node: String, seconds: Int)
    case fits(node: String, replaces: String?)
    case wontFit(node: String, need: UInt64, room: UInt64)

    var line: String {
        switch self {
        case .loaded(let n): "on \(n)"
        case .loading(let n, let s): s > 0 ? "loading on \(n) · \(s) s" : "loading on \(n)"
        case .fits(let n, let r): "on \(n)'s disk · fits" + (r.map { " · replaces \($0)" } ?? "")
        case .wontFit(let n, let need, let room):
            "on \(n)'s disk · won't fit (needs \(Self.gb(need)), \(Self.gb(room)) free)"
        }
    }

    static func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }
}

struct NodeLoadError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
