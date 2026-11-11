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
/// pairing exists; one without a key is polled like this Mac.
@MainActor
@Observable
final class Devices {
    static let shared = Devices()

    /// This Mac first, then the network's nodes by name, then Frog Cloud.
    private(set) var list: [Device] = []
    /// Why the network can't be searched, when it can't (usually Local Network is off for frog).
    private(set) var browseProblem: String?

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
            // A keyed node can't be polled before pairing; being on Bonjour is all we know.
            if f.device.keyed { f.device.online = true }
            f.device.link = Device.Link(interface: r.interfaces.first ?? interface)
            found[id] = f
            if f.url == nil, !f.resolving, !f.device.keyed { resolve(id, r.endpoint) }
        }
        for id in found.keys where !seen.contains(id) { found[id] = nil }
        publish()
    }

    /// The service's host and port, by connecting once (Bonjour gives a name, `/node` wants a URL).
    private func resolve(_ id: String, _ endpoint: NWEndpoint) {
        found[id]?.resolving = true
        let c = NWConnection(to: endpoint, using: .tcp)
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let url: URL? = {
                    guard case .hostPort(let host, let port) = c.currentPath?.remoteEndpoint else { return nil }
                    var h: String
                    switch host {
                    case .ipv4(let a): h = "\(a)"
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
                    self?.found[id]?.resolving = false
                }
            case .failed, .cancelled:
                Task { @MainActor in self?.found[id]?.resolving = false }
            default: break
            }
        }
        c.start(queue: .main)
    }

    // MARK: polling

    private func poll() async {
        async let mine = Self.fetch(URL(string: "http://127.0.0.1:8911")!)
        let targets = found.compactMap { id, f in f.url.map { (id, $0) } }
        var theirs: [(String, NodeReport?)] = []
        await withTaskGroup(of: (String, NodeReport?).self) { g in
            for (id, url) in targets { g.addTask { (id, await Self.fetch(url)) } }
            for await r in g { theirs.append(r) }
        }
        local.apply(await mine)
        for (id, report) in theirs { found[id]?.device.apply(report) }
        publish()
    }

    nonisolated private static func fetch(_ base: URL) async -> NodeReport? {
        var req = URLRequest(url: base.appending(path: "node"))
        req.timeoutInterval = 0.8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(NodeReport.self, from: data)
    }

    private func publish() {
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

/// One machine on the canvas.
struct Device: Identifiable, Equatable {
    enum Role: Equatable { case thisMac, node, cloud }
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
    var online = false
    var link: Link = .network
    var nodeID: String?
    var model: String?
    var loading: String?
    var decode: Double?
    var prefill: Double?
    var running = 0
    var waiting = 0

    /// Memory in use, when the node has said how much is free.
    var usedFraction: Double? {
        guard let free = freeBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, 1 - Double(free) / Double(totalBytes)))
    }

    mutating func apply(_ r: NodeReport?) {
        guard let r else {
            online = false
            model = nil; loading = nil; decode = nil; prefill = nil; running = 0; waiting = 0
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
        decode = m?.rates.decode_tok_s.flatMap { $0 > 0 ? $0 : nil }
        prefill = m?.rates.prefill_tok_s.flatMap { $0 > 0 ? $0 : nil }
        running = r.queue.running.count
        waiting = r.queue.waiting.count
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

/// The part of tang's `GET /node` the canvas draws (schema 1).
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
    struct Loaded: Decodable {
        var id: String
        var rates: Rates
    }
    struct Loading: Decodable { var id: String }
    struct Models: Decodable {
        var loaded: [Loaded]
        var loading: Loading?
    }
    struct Job: Decodable {}
    struct Queue: Decodable {
        var running: [Job]
        var waiting: [Job]
    }
    var node_id: String
    var hardware: Hardware
    var models: Models
    var queue: Queue
}
