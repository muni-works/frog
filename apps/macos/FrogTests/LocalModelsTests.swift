import SwiftUI
import XCTest
@testable import Frog

/// A machine's model list (Settings › Models › a machine): what each row says and offers, the
/// short default list per machine, and states that end.
@MainActor
final class LocalModelsTests: XCTestCase {
    /// mew's `GET /node` on 2026-11-17 (Frog 0.6.4, tang-llm 0.1.0), trimmed to what the app
    /// reads; its id, key and paths left out. It had said "loading openai/gpt-oss-20b" for
    /// 454,050 s (five days): nothing loaded, one turn waiting, the load never ended.
    static let mewReport = #"""
    {"schema":2,"node_id":"fixture-mew","name":"mew","version":"0.1.0",
     "hardware":{"kind":"cuda","name":"NVIDIA GeForce RTX 3090","unified_memory":false,"total_bytes":25295257600,"free_bytes":13303087104},
     "models":{"loaded":[],"loading":{"id":"openai/gpt-oss-20b","elapsed_ms":454050303},
      "on_disk":[
       {"id":"mlx-community/Qwen3-32B-4bit","weights_hash":"1111111111111111","quant":"mlx-4bit","size_bytes":18429850874,"load_bytes":21651076346},
       {"id":"Qwen/Qwen2.5-7B","weights_hash":"2222222222222222","quant":"bf16","size_bytes":15231271888,"load_bytes":5827299090},
       {"id":"openai/gpt-oss-20b","weights_hash":"3333333333333333","quant":"bf16","size_bytes":13761316904,"load_bytes":5346765387},
       {"id":"unsloth/gemma-3-4b-it","weights_hash":"4444444444444444","quant":"bf16","size_bytes":8600277880,"load_bytes":4633420665},
       {"id":"mlx-community/Qwen3-14B-4bit","weights_hash":"5555555555555555","quant":"mlx-4bit","size_bytes":8307898514,"load_bytes":10723817618},
       {"id":"mlx-community/Qwen3-8B-4bit","weights_hash":"6666666666666666","quant":"mlx-4bit","size_bytes":4607835174,"load_bytes":6889536550},
       {"id":"Qwen/Qwen3-VL-2B-Instruct","weights_hash":"7777777777777777","quant":"bf16","size_bytes":4255140312,"load_bytes":3210024132},
       {"id":"Qwen/Qwen2.5-1.5B","weights_hash":"8888888888888888","quant":"bf16","size_bytes":3087467144,"load_bytes":2176972982}
      ]},
     "queue":{"running":[],"waiting":[{"id":894}]}}
    """#

    static func mew() throws -> Device {
        var d = Device(id: "n1", role: .node, name: "mew")
        d.paired = true
        d.apply(try JSONDecoder().decode(NodeReport.self, from: Data(mewReport.utf8)))
        return d
    }

    /// Regression: a load the node has reported for days isn't "loading"; it's stuck, and the
    /// row goes back to what the model really is (on disk) with the reason.
    func testALoadReportedForDaysIsNotLoading() throws {
        let d = try Self.mew()
        XCTAssertNil(d.loadingID, "a five-day-old load isn't a load in progress")
        XCTAssertNil(d.loading)
        XCTAssertEqual(d.stuckLoad, Device.StuckLoad(id: "openai/gpt-oss-20b", seconds: 454_050))
        XCTAssertEqual(d.runningLine, "idle")

        let list = LocalModelList.build(d)
        let oss = try XCTUnwrap(list.onMachine.first { $0.id == "openai/gpt-oss-20b" })
        XCTAssertEqual(oss.state, .onDisk)
        XCTAssertEqual(oss.note, "Stuck loading for 5 days: mew never finished it. Restart the Frog node on mew to clear it.")
        // Another load would wait behind the dead one: Load is off, and says why.
        let q32 = try XCTUnwrap(list.recommended.first)
        XCTAssertEqual(q32.load, .off("Mew is stuck on another load. Restart the Frog node there first."))
        XCTAssertFalse(list.all.contains { if case .loading = $0.state { true } else { false } })
    }

    // MARK: the short default list

    func testMewsDefaultListLeadsWithWhatFitsAndKeepsWhatsOnDisk() throws {
        let list = LocalModelList.build(try Self.mew())
        XCTAssertEqual(list.recommended.map(\.name), ["Qwen3 32B", "Qwen3 14B", "Qwen3 8B"])
        XCTAssertEqual(list.recommended.map(\.state), [.onDisk, .onDisk, .onDisk])
        // Everything already on mew shows, whatever it is.
        XCTAssertEqual(list.onMachine.map(\.name), ["Gemma 3 4B", "GPT Oss 20B", "Qwen2.5 1.5B", "Qwen2.5 7B", "Qwen3 VL 2B"])
        // The rest of what fits sits behind More models: never a cloud model, never one that won't fit.
        XCTAssertEqual(list.more.map(\.name), ["Qwen3 4B", "Qwen3 1.7B", "Qwen3 0.6B"])
        XCTAssertEqual(list.cloudNote, "Qwen3 Coder Next, GLM-5.3 Flash and DeepSeek V4.1 Flash run in Frog Cloud, not on mew: the smallest needs about 52 GB of NVIDIA GPU memory.")
    }

    func testDefaultListPerMachineSize() {
        XCTAssertEqual(LocalModelList.build(Self.mac(gb: 16)).recommended.map(\.name), ["Qwen3 8B", "Qwen3 4B", "Qwen3 1.7B"])
        XCTAssertEqual(LocalModelList.build(Self.mac(gb: 64)).recommended.map(\.name), ["Qwen3 32B", "Qwen3 14B", "Qwen3 8B"])
        XCTAssertEqual(LocalModelList.build(Self.node(gb: 24)).recommended.map(\.name), ["Qwen3 32B", "Qwen3 14B", "Qwen3 8B"])
        // Nothing listed is something the machine can't run.
        for d in [Self.mac(gb: 16), Self.mac(gb: 64), Self.node(gb: 24)] {
            let l = LocalModelList.build(d)
            XCTAssertTrue((l.recommended + l.more).allSatisfy(\.fits), d.name)
            XCTAssertNotNil(l.cloudNote)
            XCTAssertTrue((l.recommended + l.more).allSatisfy { r in LocalCatalog.byRepo(r.id)?.cloud == nil })
        }
        XCTAssertEqual(LocalModelList.build(Self.mac(gb: 16)).more.map(\.name), ["Gemma 3 4B", "Qwen3 0.6B"])
    }

    // MARK: what a row says

    func testRowWording() throws {
        let q32 = try XCTUnwrap(LocalModelList.build(try Self.mew()).recommended.first)
        XCTAssertEqual(q32.name, "Qwen3 32B")
        XCTAssertEqual(q32.source, "Hugging Face · mlx-community/Qwen3-32B-4bit")
        XCTAssertEqual(q32.format, "mlx-4bit")
        XCTAssertEqual(q32.uses, "Coding, uses tools, reasons · 32K context")
        XCTAssertEqual(q32.size, "18 GB on disk")
        XCTAssertEqual(q32.fit, "needs 20 GB of 24 GB · fits")

        let get = try XCTUnwrap(LocalModelList.build(Self.mac(gb: 64)).recommended.first)
        XCTAssertEqual(get.state, .notDownloaded)
        XCTAssertEqual(get.size, "18 GB download")
        XCTAssertEqual(get.getLabel, "Get · 18 GB")
        XCTAssertEqual(get.get, .on)

        // On disk but too big for this machine: still listed (it's there), with why it won't load.
        var small = Self.mac(gb: 16)
        small.models = [.init(name: "Qwen3-32B-4bit", weightsHash: "1111111111111111", quant: "mlx-4bit", loaded: false,
                              id: "mlx-community/Qwen3-32B-4bit", loadBytes: 21_651_076_346, sizeBytes: 18_429_850_874)]
        let big = try XCTUnwrap(LocalModelList.build(small).onMachine.first)
        XCTAssertEqual(big.fit, "needs 20 GB, this Mac has 16 GB")
        XCTAssertEqual(big.load, .off("needs 20 GB, this Mac has 16 GB"))

        // A model Frog doesn't know reads from its id, with its source.
        let qwen25 = try XCTUnwrap(LocalModelList.build(try Self.mew()).onMachine.first { $0.id == "Qwen/Qwen2.5-7B" })
        XCTAssertEqual(qwen25.name, "Qwen2.5 7B")
        XCTAssertEqual(qwen25.source, "Hugging Face · Qwen/Qwen2.5-7B")
        XCTAssertNil(qwen25.uses)
    }

    func testDownloadProgressLine() {
        var r = LocalModelRow(id: "x", name: "Qwen3 32B", fits: true, state: .downloading(done: 4_200_000_000, total: 18_429_850_874, rate: 32_400_000))
        XCTAssertEqual(r.progressLine, "4.2 of 18 GB · 32 MB/s")
        r.state = .downloading(done: 0, total: 18_429_850_874, rate: nil)
        XCTAssertEqual(r.progressLine, "0.0 of 18 GB")
    }

    // MARK: states that end

    func testALoadThisMacAskedForEndsAtItsDeadline() throws {
        let d = try Self.mew(stuck: false)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let key = Devices.rowKey("n1", "mlx-community/Qwen3-8B-4bit")
        let at = { (s: TimeInterval) in LocalModelList.build(d, pending: [key: t0], now: t0.addingTimeInterval(s)).recommended[2] }
        XCTAssertEqual(at(12).state, .loading(seconds: 12, afterTurn: false))
        XCTAssertEqual(at(601).state, .onDisk)
        XCTAssertEqual(at(601).note, "Couldn't load: no answer from mew in 10 min.")
    }

    func testAFailedLoadShowsTheNodesReason() throws {
        let d = try Self.mew(stuck: false)
        let key = Devices.rowKey("n1", "mlx-community/Qwen3-32B-4bit")
        let r = LocalModelList.build(d, problems: [key: "It doesn't fit anymore: not enough free memory."]).recommended[0]
        XCTAssertEqual(r.state, .onDisk)
        XCTAssertEqual(r.note, "Couldn't load: It doesn't fit anymore: not enough free memory.")
    }

    func testANodeLoadInsideItsDeadlineIsLoadingThenLoadedThenEvicted() throws {
        var d = try Self.mew(stuck: false)
        d.apply(try Self.report(loading: #"{"id":"mlx-community/Qwen3-8B-4bit","elapsed_ms":12000}"#))
        XCTAssertEqual(LocalModelList.build(d).recommended[2].state, .loading(seconds: 12, afterTurn: false))
        d.apply(try Self.report(loaded: "mlx-community/Qwen3-8B-4bit"))
        XCTAssertEqual(LocalModelList.build(d).recommended[2].state, .loaded(decode: 61))
        // Evicted (another client unloaded it): back on disk, nothing left spinning.
        d.apply(try Self.report())
        XCTAssertEqual(LocalModelList.build(d).recommended[2].state, .onDisk)
        XCTAssertNil(LocalModelList.build(d).recommended[2].note)
    }

    func testANodeDownloadMovesStallsAndFails() throws {
        var d = try Self.mew(stuck: false)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let pull = { (done: UInt64) in #"{"model":"mlx-community/Qwen3-4B-4bit","done_bytes":\#(done),"total_bytes":2263022529}"# }
        d.apply(try Self.report(pulling: pull(0)), at: t0)
        d.apply(try Self.report(pulling: pull(100_000_000)), at: t0.addingTimeInterval(2))
        XCTAssertTrue(d.canPull)
        var r = try XCTUnwrap(LocalModelList.build(d, now: t0.addingTimeInterval(2)).onMachine.first { $0.id == "mlx-community/Qwen3-4B-4bit" })
        XCTAssertEqual(r.state, .downloading(done: 100_000_000, total: 2_263_022_529, rate: 50_000_000))
        XCTAssertEqual(r.progressLine, "0.1 of 2.3 GB · 50 MB/s")
        XCTAssertNil(r.note)
        // No bytes for three minutes: still downloading as the node says, with how long it's been stuck.
        d.apply(try Self.report(pulling: pull(100_000_000)), at: t0.addingTimeInterval(182))
        r = try XCTUnwrap(LocalModelList.build(d, now: t0.addingTimeInterval(182)).onMachine.first { $0.id == "mlx-community/Qwen3-4B-4bit" })
        XCTAssertEqual(r.note, "No progress for 3 min.")
        // Interrupted: the node's own reason, and the row is back to Get.
        d.apply(try Self.report(lastPull: #"{"model":"mlx-community/Qwen3-4B-4bit","ok":false,"cancelled":false,"error":"connection reset by peer"}"#))
        r = try XCTUnwrap(LocalModelList.build(d).more.first { $0.id == "mlx-community/Qwen3-4B-4bit" })
        XCTAssertEqual(r.state, .notDownloaded)
        XCTAssertEqual(r.note, "Couldn't download: connection reset by peer")
    }

    func testAMacDownloadThatFailedSaysWhy() throws {
        let d = Self.mac(gb: 64)
        let repo = "mlx-community/Qwen3-32B-4bit"
        var r = LocalModelList.build(d, downloads: [repo: LocalDownload(done: 9_000_000_000, total: 18_429_850_874, rate: 40e6)]).recommended[0]
        XCTAssertEqual(r.state, .downloading(done: 9_000_000_000, total: 18_429_850_874, rate: 40e6))
        XCTAssertTrue(r.cancelDownload)
        r = LocalModelList.build(d, downloads: [repo: LocalDownload(done: 0, total: 0, failed: "The network connection was lost.")]).recommended[0]
        XCTAssertEqual(r.state, .notDownloaded)
        XCTAssertEqual(r.note, "Couldn't download: The network connection was lost.")
    }

    // MARK: controls

    func testControlsSayWhatTheyDoOrWhyTheyCant() throws {
        // mew's tang 0.1.0 has neither /models/pull nor /models/delete.
        let mew = LocalModelList.build(try Self.mew(stuck: false))
        let get = try XCTUnwrap(mew.more.first)
        XCTAssertEqual(get.get, .off("mew's Frog node (0.1.0) can't download models. Update it on mew."))
        XCTAssertEqual(mew.recommended[0].load, .on)
        XCTAssertEqual(mew.recommended[0].delete, .off("mew's Frog node (0.1.0) can't delete models. Update it on mew."))
        // A node that reports pulls takes deletes.
        var newer = try Self.mew(stuck: false)
        newer.apply(try Self.report(pulling: "null"))
        XCTAssertEqual(LocalModelList.build(newer).recommended[0].delete, .on)
        // Loaded: Stop, and no Delete until it's stopped.
        newer.apply(try Self.report(loaded: "mlx-community/Qwen3-32B-4bit", pulling: "null"))
        XCTAssertEqual(LocalModelList.build(newer).recommended[0].delete, .off("Stop it first."))
        // This Mac downloads itself.
        XCTAssertEqual(LocalModelList.build(Self.mac(gb: 16)).recommended[0].get, .on)
    }

    // MARK: names agree everywhere

    func testNamesAgreeWithTheMenuAndFrogCloud() throws {
        let cloud = LocalCatalog.all.filter { $0.cloud != nil }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: cloud.map { ($0.cloud!, $0.name) }), ModelIdentity.frogCloudNames)
        // The composer's menu offers the catalog's models, by the catalog's names and sizes.
        XCTAssertEqual(SuggestedModel.all.map(\.title), ["Qwen3 4B", "Qwen3 8B", "Qwen3 32B", "Qwen3 1.7B", "Gemma 3 4B"])
        XCTAssertEqual(SuggestedModel.gbText(try XCTUnwrap(SuggestedModel.all.first { $0.title == "Qwen3 32B" }).approxGB), "18 GB")
        // A model on your machines reads the same in the menu as on the machine's page.
        let devices = Devices()
        devices.seed([try Self.mew(stuck: false)])
        XCTAssertTrue(devices.machineModels().map(\.name).contains("Qwen3 32B"))
    }

    // MARK: snapshots (docs/design/local-models/)

    /// The machine page offscreen, light and dark: mew as Cam saw it (stuck load, twelve
    /// checkpoints on disk), a 16 GB Mac with More models open, a 64 GB Mac mid-download with
    /// each control state, and a fresh 24 GB node.
    func testRenderLocalModels() throws {
        let devices = Devices()
        var states = Self.mac(gb: 64)
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        states.models = [
            .init(name: "Qwen3-8B-4bit", weightsHash: "6666666666666666", quant: "mlx-4bit", loaded: true,
                  id: "mlx-community/Qwen3-8B-4bit", loadBytes: 6_889_536_550, sizeBytes: 4_607_835_174),
            .init(name: "Qwen3-14B-4bit", weightsHash: "5555555555555555", quant: "mlx-4bit", loaded: false,
                  id: "mlx-community/Qwen3-14B-4bit", loadBytes: 10_723_817_618, sizeBytes: 8_307_898_514),
            .init(name: "Qwen3-0.6B", weightsHash: "9999999999999999", quant: "bf16", loaded: false,
                  id: "Qwen/Qwen3-0.6B", loadBytes: 2_436_069_137, sizeBytes: 1_503_300_328),
        ]
        states.model = "Qwen3-8B-4bit"; states.decode = 61.4
        let fresh = Self.node(gb: 24)
        devices.seed([try Self.mew(), Self.mac(gb: 16), states, fresh])
        let downloads = ["mlx-community/Qwen3-32B-4bit": LocalDownload(done: 7_400_000_000, total: 18_429_850_874, rate: 41_000_000)]

        try render("machine-mew", height: 1180) {
            MachinesSettings(devices: devices, path: ["n1"], fixtureAccount: ("Cam · cam@example.com", "$12.34"))
        }
        try render("mac-16gb", height: 760) {
            Form { MachineModelsSections(device: devices.list[1], devices: devices, showMore: true, fixedNow: t0, fixedDownloads: [:]) }
                .formStyle(.grouped)
        }
        try render("mac-64gb-states", height: 820) {
            Form { MachineModelsSections(device: devices.list[2], devices: devices, showMore: true, fixedNow: t0, fixedDownloads: downloads) }
                .formStyle(.grouped)
        }
        try render("node-24gb-fresh", height: 760) {
            Form { MachineModelsSections(device: devices.list[3], devices: devices, showMore: true, fixedNow: t0, fixedDownloads: [:]) }
                .formStyle(.grouped)
        }
        try render("info-popover", width: 360, height: 220) {
            LocalModelInfo(row: LocalModelList.build(try! Self.mew()).recommended[0])
        }
    }

    private func render<V: View>(_ name: String, width: CGFloat = 620, height: CGFloat, @ViewBuilder _ view: () -> V) throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = ProcessInfo.processInfo.environment["FROG_LOCAL_MODELS_OUT"].map { URL(fileURLWithPath: $0) }
            ?? repo.appending(path: "docs/design/local-models")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (suffix, look) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let host = NSHostingView(rootView: view().frame(width: width, height: height).background(FrogCanvas.color))
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: look)
            window.contentView = host
            window.orderInForTest()
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appending(path: "\(name)-\(suffix).png"))
        }
    }

    // MARK: fixtures

    static func mew(stuck: Bool) throws -> Device {
        guard !stuck else { return try mew() }
        var d = Device(id: "n1", role: .node, name: "mew")
        d.paired = true
        d.apply(try report())
        return d
    }

    /// mew's report with the stuck load taken out, and whatever a test puts in.
    static func report(loading: String = "null", loaded: String? = nil, pulling: String? = nil, lastPull: String? = nil) throws -> NodeReport {
        var v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(mewReport.utf8)) as? [String: Any])
        var models = try XCTUnwrap(v["models"] as? [String: Any])
        models["loading"] = try JSONSerialization.jsonObject(with: Data(loading.utf8), options: .fragmentsAllowed)
        if let loaded {
            models["loaded"] = [["id": loaded, "weights_hash": "6666666666666666", "quant": "mlx-4bit",
                                 "rates": ["decode_tok_s": 61.0], "memory": ["weights_bytes": 4_607_835_174]]]
        }
        if let pulling { models["pulling"] = try JSONSerialization.jsonObject(with: Data(pulling.utf8), options: .fragmentsAllowed) }
        if let lastPull { models["pulling"] = NSNull(); models["last_pull"] = try JSONSerialization.jsonObject(with: Data(lastPull.utf8)) }
        v["models"] = models
        return try JSONDecoder().decode(NodeReport.self, from: JSONSerialization.data(withJSONObject: v))
    }

    static func mac(gb: UInt64) -> Device {
        var d = Device(id: "this-mac", role: .thisMac, name: "studio")
        d.chip = "M4 Max"; d.kind = "metal"; d.unified = true
        d.totalBytes = gb << 30; d.freeBytes = (gb / 2) << 30; d.online = true
        return d
    }

    static func node(gb: UInt64) -> Device {
        var d = Device(id: "n2", role: .node, name: "box")
        d.chip = "RTX 3090"; d.kind = "cuda"; d.unified = false
        d.totalBytes = gb << 30; d.freeBytes = gb << 30; d.online = true; d.paired = true
        return d
    }
}

extension LocalModelList {
    var all: [LocalModelRow] { recommended + onMachine + more }
}
