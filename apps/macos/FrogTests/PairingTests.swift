import CryptoKit
import SwiftUI
import XCTest
@testable import Frog

/// Pairing (docs/node-protocol.md §4): SPAKE2 byte-for-byte with the RustCrypto `spake2` 0.4
/// crate tang uses, the key schedule, confirms and key box, a whole pairing against the mock
/// node, and fingerprint pinning.
///
/// The vectors were generated with `spake2 = "0.4"`, `hkdf 0.12`, `hmac 0.12`, `aes-gcm 0.10`
/// (a fixed RNG feeding `start_a_with_rng` / `start_b_with_rng`; A = "frog-client",
/// B = "tang-node").
@MainActor
final class PairingTests: XCTestCase {
    struct Vector { let pw, ra, rb, msgA, msgB, key, wrongMsgB, wrongKeyA: String }

    static let vectors = [
        Vector(pw: "123456",
               ra: "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40",
               rb: "65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4",
               msgA: "41b73db5ecb16a5d354f7145d6b46c15a9700a6df3278cdd71fe70ef3099d1f342",
               msgB: "4264e8026b226c5237ec77fd068edcb1530274efc73c44a397477a99714cdebec5",
               key: "25297cca51395ccd6b300a9a0169aa395a9b6989cf89a421cdab7108fda693ce",
               wrongMsgB: "42393c046a101592b4bdc3887b582e2b572b6db3096cbc6409163983fa425e1b88",
               wrongKeyA: "291d4987c860413b188edddb7b5f73ed889330ab988d15132bbab1d9631f9688"),
        Vector(pw: "000000",
               ra: "0708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40414243444546",
               rb: "090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748",
               msgA: "41de461d195083ae4fe68c1dc78abc1e8e9b634eaf008ed1dde040ad90261f4df7",
               msgB: "420c0974bdc94b9130311d5e9f9c964cc434361390fe052dccfc2e5b9235d48740",
               key: "1cb8e3b78941f9d2ee7ea2a40bf1374b5479751b6c8498b0364e48350edd4209",
               wrongMsgB: "42e4e9f94c5edfa247e1468b1d8765e391af57677123461a1c14d67449b726704c",
               wrongKeyA: "39cd91452555dd13c1bdedf12e7b1a679af183bada00fd17f2a3fe1c129d058e"),
        Vector(pw: "987654",
               ra: "c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff0001020304050607",
               rb: "2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60",
               msgA: "411d283058a6b4e5ff4c8ac676f543521644765eec585ba1a5fd47d3b41d097caf",
               msgB: "42024ded864857c5a0eb8e07a518d4f2e2c6078d5ef271a9068ae9937a2da17561",
               key: "328956a46a770c18649ac0cde1142b541c8d11feb68171480a895ac121f8da3d",
               wrongMsgB: "42c8617a22fcda36139ac64a7af52051fd387f98a173ba21db420324a43c385720",
               wrongKeyA: "0c7cae1620e230e8a7cc13a04dccf3343061c3736af047dbf3687a4da7155fbf"),
    ]

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func bytes(_ s: String) -> [UInt8] { Point.hex(s) }

    func testSpake2MatchesTheRustCrate() throws {
        for v in Self.vectors {
            let pw = Data(v.pw.utf8)
            let a = Spake2.start(.a, password: pw, idA: PairCrypto.idA, idB: PairCrypto.idB, random: bytes(v.ra))
            let b = Spake2.start(.b, password: pw, idA: PairCrypto.idA, idB: PairCrypto.idB, random: bytes(v.rb))
            XCTAssertEqual(hex(a.message), v.msgA, v.pw)
            XCTAssertEqual(hex(b.message), v.msgB, v.pw)
            XCTAssertEqual(hex(try a.finish(b.message)), v.key, v.pw)
            XCTAssertEqual(hex(try b.finish(a.message)), v.key, v.pw)
            // B with the wrong code: A still finishes, to a key nobody else has.
            let wrong = try a.finish(Data(bytes(v.wrongMsgB)))
            XCTAssertEqual(hex(wrong), v.wrongKeyA)
            XCTAssertNotEqual(hex(wrong), v.key)
        }
    }

    func testSpake2RejectsBadMessages() {
        let a = Spake2.start(.a, password: Data("123456".utf8), idA: PairCrypto.idA, idB: PairCrypto.idB)
        XCTAssertThrowsError(try a.finish(a.message)) { XCTAssertEqual($0 as? Spake2.Failure, .badSide) }
        XCTAssertThrowsError(try a.finish(Data([0x42, 1, 2]))) { XCTAssertEqual($0 as? Spake2.Failure, .wrongLength) }
        // y = 2 isn't on the curve.
        XCTAssertThrowsError(try a.finish(Data([0x42, 2] + [UInt8](repeating: 0, count: 31)))) {
            XCTAssertEqual($0 as? Spake2.Failure, .corruptMessage)
        }
    }

    func testBasePointRoundTrips() {
        XCTAssertEqual(Point.base.compressed, [0x58] + [UInt8](repeating: 0x66, count: 31))
        // ℓ·B is the identity.
        XCTAssertEqual(Point.base.times(Scalar.order).compressed, Point.identity.compressed)
    }

    func testKeyScheduleConfirmsAndKeyBoxMatchTheVector() throws {
        let v = Self.vectors[0]
        let keys = PairCrypto.keys(Data(bytes(v.key)))
        let raw = { (k: SymmetricKey) in k.withUnsafeBytes { Data($0) } }
        XCTAssertEqual(hex(raw(keys.confirmClient)), "365f2c7116f2f117e62c0aed24b6ab0bcab05859f93ed3c83f76737da97c6fef")
        XCTAssertEqual(hex(raw(keys.confirmNode)), "95b373064fe8070e468d88922407e70a092e3b325ddc164f2f3e6264128822f9")
        XCTAssertEqual(hex(raw(keys.wrap)), "633ef73badbfd4063df68b1c92a53ed34be7fa62b7099ce77adcecf9c01a898c")
        let t = PairCrypto.transcript(clientID: "c0ffee-client", clientMsg: Data(bytes(v.msgA)),
                                      nodeMsg: Data(bytes(v.msgB)), identity: Data(repeating: 0x11, count: 32),
                                      nodeID: "node-1234")
        XCTAssertEqual(hex(t), "8b73e773038be67acea8f43000856517778c3a8a431cd30a1fd75eeae652a9e5")
        XCTAssertEqual(hex(PairCrypto.confirm(keys.confirmClient, t)), "bf7f412ddf3dae20ed7d83a3a318701dd270fb490d2fabb211435dd382439e7c")
        XCTAssertEqual(hex(PairCrypto.confirm(keys.confirmNode, t)), "c0cee6d2606c3e5ce797a2f0bc527afb9ec7338e83b8a29150545df85d23b5a3")
        let box = Data(bytes("22222222222222222222222201ce586c69d9556aaac53d7b72492ddfe2e422b2438ef3c75194c3aee85c69f42c9c1489ab4f1768ee77c6e11268114a1ede4a78eaa336d250855a29fba981"))
        XCTAssertEqual(try PairCrypto.open(box, keys.wrap, t), "tnk_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(try PairCrypto.seal("tnk_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", keys.wrap, t,
                                           nonce: Data(repeating: 0x22, count: 12)), box)
        // A box bound to another transcript doesn't open.
        XCTAssertThrowsError(try PairCrypto.open(box, keys.wrap, Data(repeating: 0, count: 32)))
    }

    func testFingerprintIsFirst16BytesOfSHA256() {
        let pk = Data(repeating: 0x11, count: 32)
        XCTAssertEqual(PairCrypto.fingerprint(pk), String(hex(Data(SHA256.hash(data: pk))).prefix(32)))
        XCTAssertEqual(PairCrypto.grouped("3f2a91c0aaaabbbb"), "3f2a 91c0 aaaa bbbb")
    }

    // MARK: against the mock node

    private var node: MockNode!
    private var base: URL!

    override func setUp() async throws {
        node = MockNode(name: "mew")
        let port = try node.start()
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    override func tearDown() async throws { node.stop() }

    func testPairsWithTheMockAndReadsNodeWithTheKey() async throws {
        let code = node.openWindow(code: "424242")
        let (paired, key) = try await PairClient.pair(base: base, code: code, clientID: "test-client",
                                                      clientName: "test", expectedFingerprint: node.fingerprint)
        XCTAssertEqual(paired.fingerprint, node.fingerprint)
        XCTAssertEqual(paired.node_id, node.nodeID)
        XCTAssertEqual(paired.name, "mew")
        XCTAssertTrue(key.hasPrefix("tnk_"))
        guard case .report(let r) = await Devices.fetch(base, key: key) else { return XCTFail("no report") }
        XCTAssertEqual(r.schema, 2)
        XCTAssertEqual(r.identity?.fingerprint, node.fingerprint)
        XCTAssertNotNil(r.models.loaded.first?.weights_hash)
        guard case .unauthorized("bad key") = await Devices.fetch(base, key: "tnk_nope") else { return XCTFail() }
        // The window closed with the pairing.
        await assertPairFails(code, .noWindow)
        // Un-pair: the node drops the key.
        await PairClient.unpair(base: base, clientID: "test-client", key: key)
        guard case .unauthorized = await Devices.fetch(base, key: key) else { return XCTFail("still paired") }
    }

    func testWrongCodeReadsAsWrongCodeAndFiveCloseTheWindow() async {
        node.openWindow(code: "111111")
        for _ in 0..<5 { await assertPairFails("222222", .wrongCode) }
        await assertPairFails("111111", .noWindow)
    }

    func testExpiredWindow() async {
        node.openWindow(code: "111111", seconds: -1)
        await assertPairFails("111111", .noWindow)
    }

    func testSpoofedFingerprintIsRefusedBeforeAnythingIsSaved() async {
        node.openWindow(code: "111111")
        do {
            _ = try await PairClient.pair(base: base, code: "111111", clientID: "c", clientName: "t",
                                          expectedFingerprint: String(repeating: "0", count: 32))
            XCTFail("paired with the wrong node")
        } catch { XCTAssertEqual(error as? PairError, .notThatNode) }
    }

    private func assertPairFails(_ code: String, _ expected: PairError, line: UInt = #line) async {
        do {
            _ = try await PairClient.pair(base: base, code: code, clientID: "test-client", clientName: "t",
                                          expectedFingerprint: nil)
            XCTFail("paired", line: line)
        } catch { XCTAssertEqual(error as? PairError, expected, line: line) }
    }

    // MARK: store and pinning

    private func tempStore() -> PairedStore {
        PairedStore(file: FileManager.default.temporaryDirectory.appending(path: "frog-nodes-\(UUID()).json"),
                    service: "frog-tests-\(UUID().uuidString)")
    }

    func testStoreWritesTheEngineFileAndKeychain() throws {
        let store = tempStore()
        let n = PairedNode(node_id: "n1", fingerprint: "fp", name: "mew", base_url: "http://mew.local:8911")
        try store.save(n, key: "tnk_secret")
        defer { try? store.remove(nodeID: "n1") }
        XCTAssertEqual(store.load(), [n])
        XCTAssertEqual(store.key(for: "n1"), "tnk_secret")
        let text = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertTrue(text.contains("\"nodes\""))
        XCTAssertFalse(text.contains("tnk_secret"), "the key never goes in the file")
        let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        try store.remove(nodeID: "n1")
        XCTAssertEqual(store.load(), [])
        XCTAssertNil(store.key(for: "n1"))
    }

    func testPinningMismatchStopsPolling() async throws {
        node.openWindow(code: "333333")
        let (paired, key) = try await PairClient.pair(base: base, code: "333333", clientID: "pin-client",
                                                      clientName: "t", expectedFingerprint: nil)
        let devices = Devices()
        devices.store = tempStore()
        try devices.store.save(paired, key: key)
        defer { try? devices.store.remove(nodeID: paired.node_id) }
        devices.reloadPaired()

        await devices.poll()
        var card = try XCTUnwrap(devices.list.first { $0.id == paired.node_id })
        XCTAssertTrue(card.online)
        XCTAssertTrue(card.paired)
        XCTAssertEqual(card.models.first?.loaded, true)
        XCTAssertEqual(devices.whereRuns(model: "node/a1b2c3d4e5f6"), "on mew")

        // Another machine answers at that address with the same key list: refuse it.
        node.swapIdentity()
        await devices.poll()
        card = try XCTUnwrap(devices.list.first { $0.id == paired.node_id })
        XCTAssertFalse(card.online)
        XCTAssertEqual(card.refused, "This isn't the mew you paired.")
        XCTAssertNil(devices.whereRuns(model: "node/a1b2c3d4e5f6"))
        // And it stays refused: no more polls make it usable.
        await devices.poll()
        XCTAssertFalse(try XCTUnwrap(devices.list.first { $0.id == paired.node_id }).online)
    }

    func testChipReadsWhereTheEngineSaysItRan() {
        let devices = Devices()
        XCTAssertEqual(devices.serving(model: "node/a1b2c3d4e5f6", ranOn: RanOn(nodeId: "x", name: "mew", local: false)).name, "mew")
        XCTAssertEqual(devices.serving(model: "node/a1b2c3d4e5f6", ranOn: RanOn(nodeId: nil, name: "this Mac", local: true)).deviceID, "this-mac")
    }
}

/// Pictures of the notice, the code sheet and a paired card, from a real pairing with the mock
/// (written to $TMPDIR/frog-snapshots).
@MainActor
final class PairingSnapshotTests: XCTestCase {
    func testSnapshots() async throws {
        let node = MockNode(name: "mew")
        let port = try node.start()
        defer { node.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!

        var found = Device(id: node.nodeID, role: .node, name: "mew")
        found.chip = "RTX 3090"; found.kind = "cuda"; found.totalBytes = node.mem; found.unified = false
        found.keyed = true; found.online = true; found.fingerprint = node.fingerprint; found.link = .ethernet

        try render("pair-notice.png", width: 620, height: 44) {
            NodeOfferRow(device: found, use: {}, dismiss: {}).padding(6)
        }
        try render("pair-sheet.png", width: 400, height: 250) { PairSheet(device: found) }
        try render("pair-sheet-typed.png", width: 400, height: 250) { PairSheet(device: found, code: "2718") }
        try render("pair-sheet-wrong.png", width: 400, height: 250) {
            PairSheet(device: found, problem: PairError.wrongCode.line("mew"))
        }
        try render("card-unpaired.png", width: 260, height: 190) {
            MachineRow(device: found).frame(width: 236).padding(12)
        }

        // A real pairing, then the card as Devices draws it.
        node.openWindow(code: "271828")
        let (paired, key) = try await PairClient.pair(base: base, code: "271828", clientID: "snap", clientName: "t",
                                                      expectedFingerprint: node.fingerprint)
        let devices = Devices()
        devices.store = PairedStore(file: FileManager.default.temporaryDirectory.appending(path: "snap-\(UUID()).json"),
                                    service: "frog-tests-\(UUID().uuidString)")
        try devices.store.save(paired, key: key)
        defer { try? devices.store.remove(nodeID: paired.node_id) }
        devices.reloadPaired()
        await devices.poll()
        var card = try XCTUnwrap(devices.list.first { $0.id == paired.node_id })
        card.link = .ethernet
        XCTAssertTrue(card.paired && card.online)
        try render("card-paired.png", width: 260, height: 190) {
            MachineRow(device: card).frame(width: 236).padding(12)
        }
        node.swapIdentity()
        await devices.poll()
        let refused = try XCTUnwrap(devices.list.first { $0.id == paired.node_id })
        try render("card-refused.png", width: 260, height: 190) {
            MachineRow(device: refused).frame(width: 236).padding(12)
        }
    }

    private func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, @ViewBuilder _ view: () -> V) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "frog-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (suffix, look) in [("", NSAppearance.Name.darkAqua), ("-light", .aqua)] {
            let host = NSHostingView(rootView: view().frame(width: width, height: height).background(FrogCanvas.color))
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: look)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = name.replacingOccurrences(of: ".png", with: "\(suffix).png")
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appending(path: file))
        }
    }
}
