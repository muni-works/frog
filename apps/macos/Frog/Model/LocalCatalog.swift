import Foundation

/// Models Frog offers to run on your machines, and Frog Cloud's with why they don't run
/// locally: `catalog/local-models.json`, bundled (the engine reads the same file,
/// crates/frog-engine/src/local_models.rs, and so can the web).
struct LocalCatalogModel: Decodable, Equatable, Identifiable {
    struct Source: Decodable, Equatable {
        var host: String
        var repo: String
        var file: String?
        var url: URL? { URL(string: "https://huggingface.co/\(repo)") }
    }
    var id: String
    var name: String
    var cloud: String?
    var source: Source
    var format: String
    var download_bytes: UInt64
    var memory_bytes: UInt64
    var context: UInt64?
    var capabilities: [String]
    var runs_on: [String]
    var local: Bool
    var local_note: String?
    var recommend: Int?
    var menu: Bool?
}

enum LocalCatalog {
    private struct File: Decodable { var models: [LocalCatalogModel] }

    static let all: [LocalCatalogModel] = {
        guard let url = Bundle.main.url(forResource: "local-models", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.models
    }()

    static func byRepo(_ repo: String) -> LocalCatalogModel? {
        all.first { $0.source.repo.caseInsensitiveCompare(repo) == .orderedSame }
    }

    /// The name every surface shows for a checkpoint: the catalog's, else one read from the id
    /// ("Qwen/Qwen2.5-7B" → "Qwen2.5 7B").
    static func displayName(_ id: String) -> String {
        byRepo(id)?.name ?? ModelIdentity.cleanName(id).name
    }

    private static let gib: UInt64 = 1 << 30

    /// Memory a machine can give one model: all of a GPU's VRAM; on unified memory what's left
    /// after 16 GB for macOS and your apps, at least half (local_models::usable_bytes).
    static func usable(total: UInt64, unified: Bool) -> UInt64 {
        unified ? max(total / 2, total > 16 * gib ? total - 16 * gib : 0) : total
    }

    static func fits(_ m: LocalCatalogModel, kind: String, total: UInt64, unified: Bool) -> Bool {
        m.local && m.runs_on.contains(kind) && m.memory_bytes <= usable(total: total, unified: unified)
    }

    /// Frog's picks for a machine: Frog Cloud's models it can run, then the best coding model
    /// that fits and at most two smaller ones (local_models::recommended).
    static func recommended(kind: String, total: UInt64, unified: Bool) -> [LocalCatalogModel] {
        let cloud = all.filter { $0.cloud != nil && fits($0, kind: kind, total: total, unified: unified) }
        let picks = all.filter { $0.cloud == nil && $0.recommend != nil && fits($0, kind: kind, total: total, unified: unified) }
            .sorted { ($0.recommend ?? 0) < ($1.recommend ?? 0) }
        return cloud + picks.prefix(3)
    }

    /// "Coding, tool use, thinking · 32K context".
    static func usesLine(_ m: LocalCatalogModel) -> String {
        var caps = m.capabilities.joined(separator: ", ")
        if let f = caps.first { caps = f.uppercased() + caps.dropFirst() }
        guard let c = m.context else { return caps }
        return caps + " · \(c / 1024)K context"
    }
}

/// What a machine's page lists: Frog's picks for it, everything already on it, and the rest of
/// the catalog that fits behind "More models".
struct LocalModelList: Equatable {
    var recommended: [LocalModelRow] = []
    var onMachine: [LocalModelRow] = []
    var more: [LocalModelRow] = []
    /// Why Frog Cloud's models aren't offered here, when none of them run on it.
    var cloudNote: String?
    /// What holds for every row on this machine, said once ("mew's Frog node (0.1.0) can't
    /// download or delete models…", "Stuck loading …").
    var machineNote: String?
}

/// One model on a machine's page, ready to draw: what it is, where it's from, whether it fits,
/// where it stands and what its button does.
struct LocalModelRow: Equatable, Identifiable {
    enum State: Equatable {
        case notDownloaded
        case downloading(done: UInt64, total: UInt64, rate: Double?)
        case onDisk
        case loading(seconds: Int, afterTurn: Bool)
        case loaded(decode: Double?)
    }
    /// A control: on, or off with the reason it's off.
    struct Control: Equatable {
        var enabled: Bool
        var why: String?
        static let on = Control(enabled: true)
        static func off(_ why: String) -> Control { Control(enabled: false, why: why) }
    }

    /// The repo id (what the node lists and `/models/load` takes).
    var id: String
    var name: String
    /// The pooled spec (`node/<hash>`) when it's on the machine.
    var spec: String?
    /// "Hugging Face · mlx-community/Qwen3-32B-4bit".
    var source: String?
    var sourceURL: URL?
    var format: String?
    /// "Coding, tool use, thinking · 32K context"; nil for a model Frog doesn't know.
    var uses: String?
    /// "18 GB download" or "17 GB on disk".
    var size: String?
    /// "needs 20 GB of 24 GB · fits", "needs 52 GB, mew has 24 GB".
    var fit: String?
    var fits: Bool
    var state: State
    /// Why the last thing didn't happen, in one line ("Couldn't load: …", "Stuck loading …").
    var note: String?
    var get: Control = .on
    var load: Control = .on
    var delete: Control = .on
    var cancelDownload = false

    var downloadBytes: UInt64?

    /// "Get · 18 GB".
    var getLabel: String { ["Get", downloadBytes.map { LocalModelRow.gbDecimal($0) }].compactMap { $0 }.joined(separator: " · ") }

    /// "4.2 of 18 GB · 32 MB/s".
    var progressLine: String? {
        guard case .downloading(let done, let total, let rate) = state else { return nil }
        let amount = "\(Self.gbDecimal(done, unit: false)) of \(Self.gbDecimal(total))"
        guard let rate, rate > 0 else { return amount }
        return amount + " · \(Int((rate / 1e6).rounded())) MB/s"
    }

    /// A download's size as Hugging Face and the model menu write it (decimal GB): "18 GB",
    /// "4.6 GB".
    static func gbDecimal(_ b: UInt64, unit: Bool = true) -> String {
        let g = Double(b) / 1e9
        let n = g >= 10 ? "\(Int(g.rounded()))" : String(format: "%.1f", g)
        return unit ? n + " GB" : n
    }
}

/// What This Mac's own downloads look like to the list (ModelDownloads, by repo).
struct LocalDownload: Equatable {
    var done: UInt64
    var total: UInt64
    var rate: Double?
    var failed: String?
}

extension LocalModelList {
    /// The page for `d`, from its last `/node`, this Mac's pending asks and downloads, and the
    /// clock. Pure: every state here comes from the node saying so now, or from an ask still
    /// inside its deadline.
    @MainActor
    static func build(_ d: Device, pending: [String: Date] = [:], problems: [String: String] = [:],
                      waitingSwap: Set<String> = [], downloads: [String: LocalDownload] = [:],
                      deleting: Set<String> = [], installed: (String) -> Bool = { _ in false },
                      now: Date = Date()) -> LocalModelList {
        let isMac = d.role == .thisMac
        let kind = d.kind.isEmpty ? (isMac ? "metal" : "cuda") : d.kind
        let usable = LocalCatalog.usable(total: d.totalBytes, unified: d.unified)
        let where_ = isMac ? "this Mac" : d.name

        func fitLine(_ need: UInt64?) -> (String?, Bool) {
            guard let need, d.totalBytes > 0 else { return (nil, true) }
            let n = Device.gb(need), t = Device.gb(d.totalBytes)
            if need <= usable { return ("needs \(n) of \(t) · fits", true) }
            if need > d.totalBytes { return ("needs \(n), \(where_) has \(t)", false) }
            return ("needs \(n) of \(t), too little left for macOS and your apps", false)
        }

        func row(catalog c: LocalCatalogModel?, disk m: Device.PooledModel?) -> LocalModelRow {
            let id = m?.id ?? c?.source.repo ?? ""
            let key = Devices.rowKey(d.id, id)
            let need = m?.loadBytes ?? c?.memory_bytes
            let (fit, fits) = fitLine(need)
            let repoLike = id.split(separator: "/").count == 2 && !id.hasPrefix("/")
            var r = LocalModelRow(
                id: id, name: c?.name ?? LocalCatalog.displayName(id),
                spec: m.map { "node/\($0.weightsHash.prefix(12))" },
                source: c.map { "\($0.source.host) · \($0.source.repo)" } ?? (repoLike ? "Hugging Face · \(id)" : nil),
                sourceURL: c?.source.url ?? (repoLike ? URL(string: "https://huggingface.co/\(id)") : nil),
                format: m?.quant ?? c?.format,
                uses: c.map(LocalCatalog.usesLine),
                size: nil, fit: fit, fits: fits, state: .notDownloaded,
                downloadBytes: c?.download_bytes)
            if let m {
                r.size = (m.sizeBytes ?? c?.download_bytes).map { "\(LocalModelRow.gbDecimal($0)) on disk" }
            } else {
                r.size = c.map { "\(LocalModelRow.gbDecimal($0.download_bytes)) download" }
            }

            // Where it stands: the node's word now, or this Mac's ask inside its deadline.
            let deadline = Device.loadDeadline(bytes: m?.sizeBytes ?? c?.download_bytes)
            let asked = pending[key].map { now.timeIntervalSince($0) }
            if let m, m.loaded {
                r.state = .loaded(decode: d.decode)
            } else if d.loadingID == id {
                r.state = .loading(seconds: Int(d.loadingSecs ?? 0), afterTurn: false)
            } else if m != nil, let asked, asked <= deadline {
                r.state = .loading(seconds: Int(asked), afterTurn: r.spec.map(waitingSwap.contains) ?? false)
            } else if m != nil {
                r.state = .onDisk
                if let asked, asked > deadline {
                    r.note = "Couldn't load: no answer from \(where_) in \(Int(deadline / 60)) min."
                }
            } else if let p = d.pulling, p.model == id {
                r.state = .downloading(done: p.done, total: p.total, rate: p.rate)
                let still = now.timeIntervalSince(p.movedAt)
                if still > 120 { r.note = "No progress for \(Int(still / 60)) min." }
            } else if isMac, let dl = downloads[id], dl.failed == nil {
                r.state = .downloading(done: dl.done, total: dl.total, rate: dl.rate)
                r.cancelDownload = true
            } else if isMac, installed(id) {
                // In this Mac's Hugging Face cache, though the engine hasn't listed it (not
                // running, or the download just finished): on disk, not Get.
                r.state = .onDisk
                r.size = c.map { "\(LocalModelRow.gbDecimal($0.download_bytes)) on disk" }
            }

            // Why the last thing didn't happen.
            if let s = d.stuckLoad, s.id == id {
                r.note = "Stuck loading for \(Self.duration(s.seconds)): \(where_) never finished it. Restart the Frog node on \(where_) to clear it."
            }
            if let why = problems[key] { r.note = why.hasPrefix("Couldn't") ? why : "Couldn't load: \(why)" }
            if m == nil, let last = d.lastPull, last.model == id, !last.ok, !last.cancelled {
                r.note = "Couldn't download: \(last.error ?? "\(where_) stopped without saying why.")"
            }
            if m == nil, isMac, let failed = downloads[id]?.failed { r.note = "Couldn't download: \(failed)" }

            // What each control does here.
            if !isMac {
                r.get = .off(d.canPull
                    ? "Downloading onto \(d.name) from Frog isn't ready yet."
                    : "\(d.name)'s Frog node\(d.version.map { " (\($0))" } ?? "") can't download models. Update it on \(d.name).")
            } else if d.pulling != nil || downloads.values.contains(where: { $0.failed == nil }) {
                r.get = .off("One download at a time.")
            }
            if !fits { r.load = .off(fit ?? "It doesn't fit.") }
            else if r.spec == nil { r.load = .off("Loads once Frog's engine on this Mac lists it.") }
            else if d.stuckLoad != nil {
                // The node's worker never came back from that load; another would wait behind it.
                r.load = .off("\(where_.prefix(1).uppercased() + where_.dropFirst()) is stuck on another load. Restart the Frog node there first.")
            }
            if deleting.contains(key) { r.delete = .off("Deleting…") }
            else if case .loaded = r.state { r.delete = .off("Stop it first.") }
            else if case .loading = r.state { r.delete = .off("It's loading.") }
            else if !isMac && !d.canPull {
                r.delete = .off("\(d.name)'s Frog node\(d.version.map { " (\($0))" } ?? "") can't delete models. Update it on \(d.name).")
            } else if isMac && LocalCatalog.byRepo(id) == nil && !ModelDownloads.isInstalled(id) {
                r.delete = .off("Frog didn't download it; remove it from the Hugging Face cache yourself.")
            }
            return r
        }

        var list = LocalModelList()
        let disk = d.models
        let diskByID = Dictionary(disk.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let picks = LocalCatalog.recommended(kind: kind, total: d.totalBytes, unified: d.unified)
        list.recommended = picks.map { row(catalog: $0, disk: diskByID[$0.source.repo.lowercased()]) }
        var shown = Set(picks.map { $0.source.repo.lowercased() })

        // Everything on the machine shows, whatever it is: loaded first, then by name.
        var on: [LocalModelRow] = []
        for m in disk where !shown.contains(m.id.lowercased()) {
            on.append(row(catalog: LocalCatalog.byRepo(m.id), disk: m))
            shown.insert(m.id.lowercased())
        }
        // A download in progress that isn't a pick.
        if let p = d.pulling, !shown.contains(p.model.lowercased()) {
            on.append(row(catalog: LocalCatalog.byRepo(p.model), disk: nil))
            shown.insert(p.model.lowercased())
        }
        for (repo, dl) in downloads where isMac && dl.failed == nil && !shown.contains(repo.lowercased()) {
            on.append(row(catalog: LocalCatalog.byRepo(repo), disk: nil))
            shown.insert(repo.lowercased())
        }
        list.onMachine = on.sorted { a, b in
            let la = a.state.isLoaded, lb = b.state.isLoaded
            if la != lb { return la }
            if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return a.id.localizedStandardCompare(b.id) == .orderedAscending
        }

        // The rest of what fits, behind "More models": not the same model again in another
        // packaging (mew's bf16 Gemma 3 4B already answers for the 4-bit one).
        let names = Set((list.recommended + list.onMachine).map(\.name))
        list.more = LocalCatalog.all
            .filter { $0.cloud == nil && !shown.contains($0.source.repo.lowercased()) && !names.contains($0.name)
                && LocalCatalog.fits($0, kind: kind, total: d.totalBytes, unified: d.unified) }
            .sorted { $0.memory_bytes > $1.memory_bytes }
            .map { row(catalog: $0, disk: nil) }

        let cloud = LocalCatalog.all.filter { $0.cloud != nil }
        if !cloud.isEmpty, !cloud.contains(where: { LocalCatalog.fits($0, kind: kind, total: d.totalBytes, unified: d.unified) }),
           let smallest = cloud.map(\.memory_bytes).min() {
            let names = cloud.map { $0.name }
            let listed = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
            list.cloudNote = "\(listed) run in Frog Cloud, not on \(where_): the smallest needs about \(Device.gb(smallest)) of NVIDIA GPU memory."
        }
        // Two checkpoints of one model both listed: say which is which ("Qwen3 0.6B · 4-bit").
        var all = list.recommended + list.onMachine + list.more
        let counts = Dictionary(all.map { ($0.name, 1) }, uniquingKeysWith: +)
        for i in all.indices where counts[all[i].name, default: 0] > 1 {
            if let v = ModelIdentity.cleanName(all[i].id).variant ?? all[i].format { all[i].name += " · \(v)" }
        }
        let a = list.recommended.count, b = a + list.onMachine.count
        list.recommended = Array(all[..<a]); list.onMachine = Array(all[a..<b]); list.more = Array(all[b...])

        // Said once rather than on every greyed-out button.
        if let s = d.stuckLoad {
            list.machineNote = "\(d.name) has been stuck loading \(LocalCatalog.displayName(s.id)) for \(Self.duration(s.seconds)). Restart the Frog node on \(d.name); until then it can't load anything."
        } else if !isMac, d.online, !d.canPull {
            list.machineNote = "\(d.name)'s Frog node\(d.version.map { " (\($0))" } ?? "") can't download or delete models. Update it on \(d.name) to get more; what's on it loads as usual."
        } else if !isMac, d.online {
            list.machineNote = "Downloading onto \(d.name) from Frog isn't ready yet."
        }
        return list
    }

    /// "5 days", "3 hours", "12 min".
    static func duration(_ s: Int) -> String {
        if s >= 2 * 86400 { return "\(s / 86400) days" }
        if s >= 2 * 3600 { return "\(s / 3600) hours" }
        return "\(max(1, s / 60)) min"
    }
}

extension LocalModelRow.State {
    var isLoaded: Bool { if case .loaded = self { true } else { false } }
}
