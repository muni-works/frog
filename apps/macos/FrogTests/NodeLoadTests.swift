import XCTest
@testable import Frog

/// D6: putting a model onto a paired node from the picker. The mock node holds Qwen3-4B
/// (loaded), Qwen3-1.7B (fits, replacing it) and Qwen3-32B (never fits).
@MainActor
final class NodeLoadTests: XCTestCase {
    private var node: MockNode!
    private var devices: Devices!
    private var nodeID = ""

    private let qwen4 = "node/a1b2c3d4e5f6"
    private let qwen17 = "node/b2c3d4e5f607"
    private let qwen32 = "node/c3d4e5f60718"

    override func setUp() async throws {
        node = MockNode(name: "mew")
        let port = try node.start()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        node.openWindow(code: "161803")
        let (paired, key) = try await PairClient.pair(base: base, code: "161803", clientID: "d6", clientName: "t",
                                                      expectedFingerprint: node.fingerprint)
        devices = Devices()
        devices.store = PairedStore(file: FileManager.default.temporaryDirectory.appending(path: "d6-\(UUID()).json"),
                                    service: "frog-tests-\(UUID().uuidString)")
        try devices.store.save(paired, key: key)
        nodeID = paired.node_id
        devices.reloadPaired()
        await devices.poll()
    }

    override func tearDown() async throws {
        try? devices.store.remove(nodeID: nodeID)
        node.stop()
    }

    func testPickerStatesForEachModel() {
        XCTAssertEqual(devices.fit(model: qwen4), .loaded(node: "mew"))
        XCTAssertEqual(devices.fit(model: qwen17), .fits(node: "mew", replaces: "Qwen3-4B"))
        guard case .wontFit(let n, let need, let room) = devices.fit(model: qwen32) else { return XCTFail() }
        XCTAssertEqual(n, "mew")
        XCTAssertEqual(need, 70_000_000_000)
        XCTAssertGreaterThan(room, 20_000_000_000)
        XCTAssertNil(devices.fit(model: "local/whatever"))
        XCTAssertNil(devices.fit(model: "node/ffffffffffff"))

        XCTAssertEqual(devices.placeLine(model: qwen4), "on mew")
        XCTAssertEqual(devices.placeLine(model: qwen17), "on mew's disk · fits · replaces Qwen3-4B")
        XCTAssertEqual(devices.placeLine(model: qwen32), "on mew's disk · won't fit (needs 70.0 GB, 22.5 GB free)")
    }

    func testLoadShowsLoadingThenLoaded() async throws {
        node.loadSeconds = 1.5
        let load = Task { try await devices.load(model: qwen17) }
        // Asked, then the node's own `loading` (with elapsed time) while it runs.
        try await Task.sleep(for: .milliseconds(100))
        if case .loading(let n, _) = devices.fit(model: qwen17) { XCTAssertEqual(n, "mew") } else { XCTFail("not loading") }
        try await Task.sleep(for: .milliseconds(1100))
        await devices.poll()
        guard case .loading(_, let secs) = devices.fit(model: qwen17) else { return XCTFail("node isn't reporting loading") }
        XCTAssertGreaterThanOrEqual(secs, 1)
        let card = try XCTUnwrap(devices.list.first { $0.id == nodeID })
        XCTAssertEqual(card.loading, "Qwen3-1.7B-4bit")
        XCTAssertNotNil(card.loadingSecs)

        try await load.value
        XCTAssertEqual(node.loadRequests, ["mlx-community/Qwen3-1.7B-4bit"])
        XCTAssertEqual(devices.fit(model: qwen17), .loaded(node: "mew"))
        // The old one is back on disk, and now it's the one a load would replace.
        XCTAssertEqual(devices.fit(model: qwen4), .fits(node: "mew", replaces: "Qwen3-1.7B-4bit"))
    }

    func testNothingLoadedMeansNothingToReplace() async throws {
        node.loaded = nil
        await devices.poll()
        XCTAssertEqual(devices.fit(model: qwen17), .fits(node: "mew", replaces: nil))
        XCTAssertEqual(devices.placeLine(model: qwen4), "on mew's disk · fits")
    }

    func testWontFitIsNeverSent() async {
        do {
            try await devices.load(model: qwen32)
            XCTFail("loaded what doesn't fit")
        } catch {}
        XCTAssertEqual(node.loadRequests, [])
    }

    func testBusyNodeSaysSoInOneLine() async {
        node.busy = true
        do {
            try await devices.load(model: qwen17)
            XCTFail("loaded while busy")
        } catch {
            XCTAssertEqual((error as? NodeLoadError)?.message, "It's busy with a turn. Try again when it's idle.")
        }
        XCTAssertEqual(devices.placeLine(model: qwen17), "It's busy with a turn. Try again when it's idle.")
        XCTAssertEqual(devices.fit(model: qwen4), .loaded(node: "mew"))
    }

    func testPickerRowsSayWhatPickingDoes() throws {
        let rows = devices.machineModels().filter { [qwen4, qwen17, qwen32].contains($0.spec) }
        let running = try XCTUnwrap(rows.first { $0.spec == qwen4 })
        XCTAssertTrue(running.running)
        XCTAssertNil(running.tag)
        XCTAssertEqual(running.places, "mew")
        XCTAssertEqual(rows.first { $0.spec == qwen17 }?.tag, "swaps")
        // Running models first.
        XCTAssertEqual(rows.first?.spec, qwen4)
    }

    func testBusyNodeSwapsAfterItsTurn() async throws {
        node.busy = true
        let swap = Task { try await devices.switchTo(qwen17, by: "s1") }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(devices.waitingSwap[qwen17], "mew")
        node.busy = false
        try await swap.value
        XCTAssertEqual(node.loadRequests.last.map { $0.hasSuffix("1.7B") || !$0.isEmpty }, true)
        XCTAssertNil(devices.waitingSwap[qwen17])
        XCTAssertEqual(devices.lastSwitch?.by, "s1")
        XCTAssertEqual(devices.lastSwitch?.line.hasPrefix("mew switched to "), true)
    }

    func testPickerLinesUseTheModelVocabulary() {
        for line in [NodeFit.loaded(node: "mew"), .loading(node: "mew", seconds: 4), .fits(node: "mew", replaces: "Qwen3-0.6B"),
                     .wontFit(node: "mew", need: 9_100_000_000, room: 4_200_000_000)].map(\.line) {
            XCTAssertNil(line.range(of: #"tok/s|\btang\b"#, options: [.regularExpression, .caseInsensitive]), line)
        }
        XCTAssertEqual(NodeFit.wontFit(node: "mew", need: 9_100_000_000, room: 4_200_000_000).line,
                       "on mew's disk · won't fit (needs 9.1 GB, 4.2 GB free)")
    }
}

/// The picker's lines from a real paired node, read-only (this Mac's nodes.json and Keychain).
/// Skipped unless `TEST_RUNNER_FROG_LIVE_NODE=<name>` is set.
@MainActor
final class LiveNodeFitTests: XCTestCase {
    func testLinesFromARealNode() async throws {
        guard let name = ProcessInfo.processInfo.environment["FROG_LIVE_NODE"] else { throw XCTSkip("no live node") }
        let devices = Devices()
        devices.reloadPaired()
        await devices.poll()
        let card = try XCTUnwrap(devices.list.first { $0.name == name && $0.online }, "\(name) isn't answering")
        for m in card.models {
            let spec = "node/\(m.weightsHash.prefix(12))"
            let line = try XCTUnwrap(devices.placeLine(model: spec))
            print("live: \(m.name): \(line)")
            if m.loaded { XCTAssertEqual(devices.fit(model: spec), .loaded(node: name)) }
        }
    }
}
