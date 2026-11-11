import CryptoKit
import Foundation
import Security

/// Pairing with a tang node (docs/node-protocol.md §4): a 6-digit code drives SPAKE2, which
/// authenticates the node's identity and wraps the API key it hands over. The client is side A
/// ("frog-client"), the node side B ("tang-node").
enum PairCrypto {
    static let idA = Data("frog-client".utf8)
    static let idB = Data("tang-node".utf8)

    struct Keys {
        let confirmClient: SymmetricKey
        let confirmNode: SymmetricKey
        let wrap: SymmetricKey
    }

    static func keys(_ k: Data) -> Keys {
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: k), salt: Data(),
                                   info: Data(info.utf8), outputByteCount: 32)
        }
        return Keys(confirmClient: derive("frog-pair confirm client"),
                    confirmNode: derive("frog-pair confirm node"),
                    wrap: derive("frog-pair wrap"))
    }

    /// SHA-256(client_id ‖ 0x00 ‖ client msg ‖ node msg ‖ identity ‖ node_id). The SPAKE2
    /// messages are the full 33 bytes on the wire (side byte included).
    static func transcript(clientID: String, clientMsg: Data, nodeMsg: Data, identity: Data, nodeID: String) -> Data {
        var h = SHA256()
        h.update(data: Data(clientID.utf8))
        h.update(data: Data([0]))
        h.update(data: clientMsg)
        h.update(data: nodeMsg)
        h.update(data: identity)
        h.update(data: Data(nodeID.utf8))
        return Data(h.finalize())
    }

    static func confirm(_ key: SymmetricKey, _ transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcript, using: key))
    }

    /// nonce(12) ‖ AES-256-GCM(ciphertext ‖ tag), aad = transcript.
    static func seal(_ apiKey: String, _ key: SymmetricKey, _ transcript: Data, nonce: Data? = nil) throws -> Data {
        let n = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(Data(apiKey.utf8), using: key, nonce: n, authenticating: transcript)
        return Data(n) + box.ciphertext + box.tag
    }

    static func open(_ box: Data, _ key: SymmetricKey, _ transcript: Data) throws -> String {
        guard box.count > 28 else { throw PairError.badReply }
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: box.prefix(12)),
                                           ciphertext: box.dropFirst(12).dropLast(16), tag: box.suffix(16))
        let plain = try AES.GCM.open(sealed, using: key, authenticating: transcript)
        guard let s = String(data: plain, encoding: .utf8) else { throw PairError.badReply }
        return s
    }

    /// First 16 bytes of SHA-256 of the 32-byte public key, lowercase hex.
    static func fingerprint(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// "3f2a 91c0 …", for people.
    static func grouped(_ fp: String) -> String {
        stride(from: 0, to: fp.count, by: 4).map { i in
            let s = fp.index(fp.startIndex, offsetBy: i)
            return String(fp[s..<(fp.index(s, offsetBy: 4, limitedBy: fp.endIndex) ?? fp.endIndex)])
        }.joined(separator: " ")
    }
}

/// Why pairing stopped, each one plain line.
enum PairError: Error, Equatable {
    case wrongCode, expired, busy, noWindow
    /// The node's identity isn't the one Bonjour advertised.
    case notThatNode
    case badReply
    case network(String)

    func line(_ name: String) -> String {
        switch self {
        case .wrongCode: "That code didn't match. Check it on \(name) and try again."
        case .expired: "That code expired. Run tang-llm pair on \(name) for a new one."
        case .busy: "\(name) is pairing with something else. Try again in a moment."
        case .noWindow: "\(name) isn't showing a code. Run tang-llm pair on it first."
        case .notThatNode: "This isn't the \(name) frog found on your network. Nothing was saved."
        case .badReply: "\(name) answered in a way frog doesn't understand. It may need a newer tang."
        case .network(let why): "Couldn't reach \(name): \(why)"
        }
    }
}

/// A node this Mac has paired with. The key lives in the Keychain, the rest in nodes.json.
struct PairedNode: Codable, Equatable {
    var node_id: String
    var fingerprint: String
    var name: String
    var base_url: String
}

/// The client side of `/pair/start` and `/pair/finish`.
enum PairClient {
    struct Started: Decodable { let pair_id: String; let spake: Data; let node_id: String; let identity: Data; let name: String }
    struct Finished: Decodable { let confirm: Data; let key_box: Data }

    /// Pair with the node at `base` using the code it shows. Returns the node and its API key.
    static func pair(base: URL, code: String, clientID: String, clientName: String,
                     expectedFingerprint: String?, session: URLSession = .shared,
                     random: [UInt8] = Spake2.randomBytes(64)) async throws -> (PairedNode, String) {
        let spake = Spake2.start(.a, password: Data(code.utf8), idA: PairCrypto.idA, idB: PairCrypto.idB, random: random)
        let started: Started = try await post(base, "pair/start", [
            "client_id": clientID, "client_name": clientName, "spake": spake.message.base64EncodedString(),
        ], session)
        let fp = PairCrypto.fingerprint(started.identity)
        if let expectedFingerprint, expectedFingerprint != fp { throw PairError.notThatNode }
        let k: Data
        do { k = try spake.finish(started.spake) } catch { throw PairError.badReply }
        let keys = PairCrypto.keys(k)
        let t = PairCrypto.transcript(clientID: clientID, clientMsg: spake.message, nodeMsg: started.spake,
                                      identity: started.identity, nodeID: started.node_id)
        let finished: Finished = try await post(base, "pair/finish", [
            "pair_id": started.pair_id,
            "confirm": PairCrypto.confirm(keys.confirmClient, t).base64EncodedString(),
        ], session)
        // The node's confirm first: nothing it says is trusted before it proves it had the code.
        guard PairCrypto.confirm(keys.confirmNode, t) == finished.confirm else { throw PairError.wrongCode }
        let apiKey: String
        do { apiKey = try PairCrypto.open(finished.key_box, keys.wrap, t) } catch { throw PairError.badReply }
        let node = PairedNode(node_id: started.node_id, fingerprint: fp, name: started.name,
                              base_url: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        return (node, apiKey)
    }

    /// `DELETE /pair/<client_id>` with the key; best effort (the Mac forgets either way).
    static func unpair(base: URL, clientID: String, key: String, session: URLSession = .shared) async {
        var req = URLRequest(url: base.appending(path: "pair/\(clientID)"))
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 3
        _ = try? await session.data(for: req)
    }

    private static func post<T: Decodable>(_ base: URL, _ path: String, _ body: [String: String],
                                           _ session: URLSession) async throws -> T {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw PairError.network(error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401: throw PairError.wrongCode
        case 403: throw PairError.noWindow
        case 409: throw PairError.busy
        case 410: throw PairError.expired
        default: throw PairError.network("it answered \(status)")
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw PairError.badReply }
    }
}

/// Paired nodes on disk: `~/.config/frog/nodes.json` (what the engine reads, §7) and each
/// node's key in the Keychain (service `frog`, account `node:<node_id>`, where the engine
/// looks for provider keys).
struct PairedStore {
    var file: URL
    /// The Keychain service; tests use their own.
    var service: String

    static let shared = PairedStore(
        file: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/frog/nodes.json"),
        service: "frog")

    private struct File: Codable { var nodes: [PairedNode] }

    func load() -> [PairedNode] {
        guard let data = try? Data(contentsOf: file),
              let f = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return f.nodes
    }

    func save(_ node: PairedNode, key: String) throws {
        try setKey(key, for: node.node_id)
        var nodes = load().filter { $0.node_id != node.node_id && $0.fingerprint != node.fingerprint }
        nodes.append(node)
        try write(nodes)
    }

    func remove(nodeID: String) throws {
        deleteKey(nodeID)
        try write(load().filter { $0.node_id != nodeID })
    }

    /// Point a paired node at the address it's reachable at now (DHCP moves things).
    func update(_ node: PairedNode) throws {
        var nodes = load()
        guard let i = nodes.firstIndex(where: { $0.node_id == node.node_id }), nodes[i] != node else { return }
        nodes[i] = node
        try write(nodes)
    }

    private func write(_ nodes: [PairedNode]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(File(nodes: nodes))
        let tmp = file.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }

    // MARK: Keychain

    // Through `/usr/bin/security`, the way the engine reads and writes provider keys: an item
    // the app made with SecItemAdd is the app's, so the engine's `security` read of it asked for
    // the login password on every poll. Made by `security`, both sides read it without asking.
    // Keys are cached here once read; they only change when pairing or un-pairing.
    private static let cache = KeyCache()
    private final class KeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String: String] = [:]
        subscript(_ id: String) -> String? {
            get { lock.withLock { keys[id] } }
            set { lock.withLock { keys[id] = newValue } }
        }
    }

    func key(for nodeID: String) -> String? {
        if let k = Self.cache[nodeID] { return k }
        let out = Self.security(["find-generic-password", "-s", service, "-a", "node:\(nodeID)", "-w"])
        guard out.ok else { return nil }
        let k = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return nil }
        Self.cache[nodeID] = k
        return k
    }

    private func setKey(_ key: String, for nodeID: String) throws {
        // The key is base64url with a prefix; it never needs quoting beyond this. It goes over
        // stdin to `security -i`, never on a command line where `ps` would show it.
        guard key.allSatisfy({ $0.isLetter || $0.isNumber || "_-".contains($0) }) else {
            throw NSError(domain: "frog.node", code: 1, userInfo: [NSLocalizedDescriptionKey: "The node sent a malformed key."])
        }
        // `security` run by the app is credited to the app, so name both explicitly: the app,
        // and `security` itself (which the engine reads keys with).
        let line = "add-generic-password -U -s \(service) -a \"node:\(nodeID)\" -l \"frog node \(nodeID)\""
            + " -T /usr/bin/security -T \"\(Bundle.main.bundlePath)\" -w \"\(key)\"\n"
        let out = Self.security(["-i"], stdin: line)
        guard out.ok, !out.err.contains("error") else {
            throw NSError(domain: "frog.node", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Keychain refused the node's key: \(out.err.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        Self.cache[nodeID] = key
    }

    private func deleteKey(_ nodeID: String) {
        Self.cache[nodeID] = nil
        _ = Self.security(["delete-generic-password", "-s", service, "-a", "node:\(nodeID)"])
    }

    private static func security(_ args: [String], stdin: String? = nil) -> (ok: Bool, text: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        if stdin != nil { p.standardInput = inp }
        do { try p.run() } catch { return (false, "", error.localizedDescription) }
        if let stdin {
            inp.fileHandleForWriting.write(Data(stdin.utf8))
            try? inp.fileHandleForWriting.close()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

/// This Mac's stable pairing identity.
enum PairIdentity {
    static var clientID: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "frog.node.clientID") { return id }
        let id = "frog-mac-" + UUID().uuidString.lowercased()
        d.set(id, forKey: "frog.node.clientID")
        return id
    }

    static var clientName: String { Host.current().localizedName ?? "Mac" }
}
