import Foundation
import Security

/// frog on a home server (`frog --listen`, see docs/ios-siri.md): ask it something and read the
/// answer, one HTTP request per turn. Unlike the Mac bridge, this needs no pairing and no app
/// in front: it's what Siri uses. The request goes from this device to your server and nowhere
/// else; the model and its tools run there.
enum House {
    /// Where frog listens, e.g. https://frog.pedersen.garden. Kept in the shared group.
    static var url: String {
        get { Snapshot.defaults.string(forKey: "houseURL") ?? "" }
        set { Snapshot.defaults.set(newValue, forKey: "houseURL") }
    }

    /// A profile name or provider/model on the server; empty is the server's default.
    static var model: String {
        get { Snapshot.defaults.string(forKey: "houseModel") ?? "" }
        set { Snapshot.defaults.set(newValue, forKey: "houseModel") }
    }

    /// The bearer token (FROG_LISTEN_TOKEN on the server), in the Keychain. An unsigned
    /// Simulator build can't use the Keychain: launch it with FROG_HOUSE_TOKEN instead.
    static var token: String {
        get { ProcessInfo.processInfo.environment["FROG_HOUSE_TOKEN"] ?? Keychain.read(account: "house-token") ?? "" }
        set { Keychain.write(newValue, account: "house-token") }
    }

    static var configured: Bool { URL(string: url)?.host() != nil && !token.isEmpty }

    /// What came back: the answer so far, whether the turn finished, and its session (to
    /// continue the conversation).
    struct Answer: Sendable {
        var text = ""
        var done = false
        var failed: String?
        var session: String?
    }

    enum Failure: LocalizedError {
        case notSetUp
        /// The server couldn't be reached at all (the place for the on-device fallback).
        case unreachable(String)
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .notSetUp: "Add your server's address and token first."
            case .unreachable(let why): "Can't reach the house: \(why)"
            case .refused(let why): why
            }
        }
    }

    /// Ask, calling `update` as the answer grows. Returns when the turn ends or `budget` runs
    /// out (then `done` is false and the turn carries on on the server).
    static func ask(_ text: String, session: String? = nil, budget: Duration? = nil,
                    update: @escaping @Sendable (Answer) -> Void = { _ in }) async throws -> Answer {
        guard configured, let base = URL(string: url) else { throw Failure.notSetUp }
        var req = URLRequest(url: base.appending(path: "v1/turn"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": text]
        if let session { body["session"] = session }
        if !model.isEmpty { body["model"] = model }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let reading = Task { () throws -> Answer in
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: req)
            } catch let e as URLError where e.code != .cancelled {
                throw Failure.unreachable(e.localizedDescription)
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Failure.refused(http.statusCode == 401 ? "The token doesn't match the server's." : "The server said \(http.statusCode).")
            }
            var answer = Answer()
            for try await line in bytes.lines {
                guard let env = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if Task.isCancelled { break }
                answer.session = env["session"] as? String ?? answer.session
                if fold(env, into: &answer) { update(answer) }
                if answer.done { break }
            }
            return answer
        }
        guard let budget else { return try await reading.value }
        // Siri waits only so long: past the budget, hand back what's there.
        let timer = Task {
            try? await Task.sleep(for: budget)
            reading.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await reading.value
        } catch is CancellationError {
            return Answer()
        } catch let e as URLError where e.code == .cancelled {
            return Answer()
        }
    }

    /// A turn's answer once it has finished on the server (it carries on after Siri hangs up);
    /// nil while it's still running.
    static func answer(session: String) async throws -> String? {
        guard configured, let base = URL(string: url) else { throw Failure.notSetUp }
        var req = URLRequest(url: base.appending(path: "v1/session/\(session)/answer"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard json?["done"] as? Bool == true else { return nil }
        return json?["text"] as? String ?? ""
    }

    /// One event into the answer; true if the answer changed. Text streams in as deltas, and the
    /// completed message replaces them (the last message of a turn is its answer).
    static func fold(_ env: [String: Any], into a: inout Answer) -> Bool {
        switch env["event"] as? String {
        case "turn_started":
            a.text = ""
            return false
        case "item_delta":
            guard let d = env["delta"] as? [String: Any], d["type"] as? String == "text", let t = d["text"] as? String else { return false }
            a.text += t
            return true
        case "item_started":
            // A new message (after a tool call) starts the answer over.
            if (env["kind"] as? [String: Any])?["type"] as? String == "message" { a.text = "" }
            return false
        case "item_completed":
            guard let item = env["item"] as? [String: Any], item["type"] as? String == "message", let t = item["text"] as? String else { return false }
            a.text = t
            return true
        case "turn_ended":
            a.done = true
            if let r = env["reason"] as? [String: Any], r["type"] as? String != "complete" {
                a.failed = (r["error"] as? [String: Any])?["message"] as? String ?? (r["type"] as? String)
            }
            return true
        default:
            return false
        }
    }
}

/// A string in the Keychain, readable after first unlock (Siri asks from the lock screen).
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "eco.frog.remote",
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}
