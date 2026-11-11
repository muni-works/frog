import CryptoKit
import Foundation
import Network
#if !MOCK_NODE_STANDALONE
@testable import Frog
#endif

/// The node side of docs/node-protocol.md §1–5, for developing and testing the Mac app before
/// tang's real `/pair` lands: identity, pairing window, `/pair/start|finish`, un-pair, and a
/// key-gated schema-2 `/node`. FrogTests runs it in process; `scripts/mock-node.sh` runs it on
/// its own and advertises it on Bonjour like `tang-llm serve`.
final class MockNode: @unchecked Sendable {
    let name: String
    let nodeID: String
    private(set) var identity = Curve25519.Signing.PrivateKey()
    let queue = DispatchQueue(label: "mock-node")
    private var listener: NWListener?
    /// Paired clients: client_id → SHA-256 of their key (hex).
    private(set) var keys: [String: String] = [:]
    private var window: Window?
    var advertise = false
    var gpu = "NVIDIA GeForce RTX 3090"
    var mem: UInt64 = 24 * 1_073_741_824

    struct Window {
        var code: String
        var expires: Date
        var failures = 0
        var inflight: Inflight?
    }
    struct Inflight {
        var pairID: String
        var clientID: String
        var transcript: Data
        var keys: PairCrypto.Keys
        var started: Date
    }

    init(name: String = "mew") {
        self.name = name
        nodeID = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    var publicKey: Data { identity.publicKey.rawRepresentation }
    var fingerprint: String { PairCrypto.fingerprint(publicKey) }

    /// A new identity, as if a different machine took this one's place (pinning tests).
    func swapIdentity() { queue.sync { identity = Curve25519.Signing.PrivateKey() } }

    // MARK: lifecycle

    /// Listen on `port` (0 = any free port); returns the port.
    func start(port: UInt16 = 0) throws -> UInt16 {
        let params = NWParameters.tcp
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
        if advertise { l.service = NWListener.Service(name: name, type: "_frog-node._tcp", txtRecord: txt()) }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { s in if case .ready = s { ready.signal() } }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: queue)
        listener = l
        _ = ready.wait(timeout: .now() + 5)
        return l.port?.rawValue ?? 0
    }

    func stop() { listener?.cancel(); listener = nil }

    private func txt() -> NWTXTRecord {
        var t = NWTXTRecord()
        t["v"] = "2"; t["id"] = nodeID; t["kind"] = "cuda"; t["gpu"] = gpu; t["mem"] = "\(mem)"
        t["unified"] = "0"; t["key"] = "1"; t["fp"] = fingerprint; t["pair"] = window == nil ? "0" : "1"
        return t
    }

    private func refreshTXT() {
        guard advertise, let l = listener else { return }
        l.service = NWListener.Service(name: name, type: "_frog-node._tcp", txtRecord: txt())
    }

    /// Open a 120 s window (what `tang-llm pair` does). Returns the code.
    @discardableResult
    func openWindow(code: String? = nil, seconds: TimeInterval = 120) -> String {
        let c = code ?? String(format: "%06d", Int.random(in: 0...999_999))
        queue.sync {
            window = Window(code: c, expires: Date().addingTimeInterval(seconds))
            refreshTXT()
        }
        return c
    }

    // MARK: HTTP

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buf
            if let data { buf.append(data) }
            if let req = Request(buf) {
                let (status, body) = self.handle(req, remote: c.endpoint)
                self.respond(c, status, body)
            } else if done || err != nil {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    private func respond(_ c: NWConnection, _ status: Int, _ body: Any?) {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "HTTP/1.1 \(status) X\r\nContent-Length: \(data.count)\r\nConnection: close\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        c.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in c.cancel() })
    }

    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        init?(_ buf: Data) {
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = head[0].split(separator: " ")
            guard first.count >= 2 else { return nil }
            method = String(first[0]); path = String(first[1])
            headers = [:]
            for line in head.dropFirst() {
                guard let i = line.firstIndex(of: ":") else { continue }
                headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
            let len = Int(headers["content-length"] ?? "0") ?? 0
            let rest = buf[end.upperBound...]
            guard rest.count >= len else { return nil }
            body = Data(rest.prefix(len))
        }

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    private func err(_ status: Int, _ why: String) -> (Int, Any?) { (status, ["error": why]) }

    private func handle(_ r: Request, remote: NWEndpoint) -> (Int, Any?) {
        switch (r.method, r.path) {
        case ("GET", "/health"): return (200, ["ok": true])
        case ("POST", "/pair/open"):
            let code = openWindowLocked()
            return (200, ["code": code, "expires_in": 120, "fingerprint": fingerprint])
        case ("POST", "/pair/start"): return start(r.json)
        case ("POST", "/pair/finish"): return finish(r.json)
        case ("GET", "/node"):
            if let denied = gate(r) { return denied }
            return (200, report())
        case ("DELETE", let p) where p.hasPrefix("/pair/"):
            let client = String(p.dropFirst("/pair/".count))
            guard let key = bearer(r), keys[client] == hash(key) else { return err(401, "bad key") }
            keys[client] = nil
            return (204, nil)
        default: return err(404, "not found")
        }
    }

    private func openWindowLocked() -> String {
        let c = String(format: "%06d", Int.random(in: 0...999_999))
        window = Window(code: c, expires: Date().addingTimeInterval(120))
        refreshTXT()
        print("mock node \(name): pairing code \(c)  fingerprint \(PairCrypto.grouped(fingerprint))")
        return c
    }

    private func start(_ j: [String: Any]) -> (Int, Any?) {
        guard var w = window, w.expires > Date() else { window = nil; return err(403, "no pairing window") }
        if let f = w.inflight, Date().timeIntervalSince(f.started) < 30 { return err(409, "pairing busy") }
        guard let clientID = j["client_id"] as? String,
              let msg = (j["spake"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { return err(400, "bad request") }
        let b = Spake2.start(.b, password: Data(w.code.utf8), idA: PairCrypto.idA, idB: PairCrypto.idB)
        guard let k = try? b.finish(msg) else { return err(400, "bad spake message") }
        let t = PairCrypto.transcript(clientID: clientID, clientMsg: msg, nodeMsg: b.message,
                                      identity: publicKey, nodeID: nodeID)
        let pairID = UUID().uuidString
        w.inflight = Inflight(pairID: pairID, clientID: clientID, transcript: t, keys: PairCrypto.keys(k), started: Date())
        window = w
        return (200, ["pair_id": pairID, "spake": b.message.base64EncodedString(), "node_id": nodeID,
                      "identity": publicKey.base64EncodedString(), "name": name])
    }

    private func finish(_ j: [String: Any]) -> (Int, Any?) {
        guard var w = window else { return err(410, "pairing expired") }
        guard w.expires > Date() else { window = nil; refreshTXT(); return err(410, "pairing expired") }
        guard let f = w.inflight, f.pairID == j["pair_id"] as? String,
              let confirm = (j["confirm"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { return err(410, "pairing expired") }
        w.inflight = nil
        guard PairCrypto.confirm(f.keys.confirmClient, f.transcript) == confirm else {
            w.failures += 1
            window = w.failures >= 5 ? nil : w
            refreshTXT()
            return err(401, "wrong code")
        }
        var raw = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &raw)
        let key = "tnk_" + Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        keys[f.clientID] = hash(key)
        window = nil
        refreshTXT()
        guard let box = try? PairCrypto.seal(key, f.keys.wrap, f.transcript) else { return err(500, "seal") }
        return (200, ["confirm": PairCrypto.confirm(f.keys.confirmNode, f.transcript).base64EncodedString(),
                      "key_box": box.base64EncodedString()])
    }

    private func bearer(_ r: Request) -> String? {
        guard let h = r.headers["authorization"], h.hasPrefix("Bearer ") else { return nil }
        return String(h.dropFirst(7))
    }

    private func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func gate(_ r: Request) -> (Int, Any?)? {
        if keys.isEmpty { return err(401, "not paired") }
        guard let k = bearer(r) else { return err(401, "missing key") }
        return keys.values.contains(hash(k)) ? nil : err(401, "bad key")
    }

    private func report() -> [String: Any] {
        let model: [String: Any] = [
            "id": "Qwen/Qwen3-4B", "weights_hash": "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
            "quant": "bf16", "rates": ["prefill_tok_s": 2100.0, "decode_tok_s": 41.0],
        ]
        return [
            "schema": 2, "node_id": nodeID, "name": name,
            "identity": ["fingerprint": fingerprint, "public_key": publicKey.base64EncodedString()],
            "hardware": ["kind": "cuda", "name": gpu, "unified_memory": false,
                         "total_bytes": mem, "free_bytes": mem - 9 * 1_073_741_824],
            "models": ["loaded": [model], "on_disk": [model]],
            "queue": ["running": [], "waiting": []],
        ]
    }
}
