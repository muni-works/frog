import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security

/// Frog Cloud on the iPhone, without a Mac: the web app's sessions, signed in with GitHub
/// (PKCE at the edge's `/auth/web`, back on frog://signin), the key in this phone's Keychain.
@MainActor
@Observable
final class CloudPhone: NSObject {
    static let shared = CloudPhone()

    // `FROG_GATEWAY_KEY` (with `FROG_GATEWAY`) for a local gateway, as on the Mac.
    private(set) var key: String? = ProcessInfo.processInfo.environment["FROG_GATEWAY_KEY"] ?? CloudPhone.readKey()
    private(set) var sessions: [CloudGateway.Session] = []
    /// Cloud sessions whose open conversation has a turn running (see `CloudChat`).
    var running: Set<String> = []
    private(set) var error: String?
    private(set) var signingIn = false
    private var poll: Task<Void, Never>?

    var gateway: CloudGateway? { key.map(CloudGateway.init(token:)) }
    var live: [CloudGateway.Session] { sessions.filter { $0.archived != true } }

    func start() {
        guard poll == nil else { return }
        poll = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func refresh() async {
        guard let gateway else { sessions = []; return }
        do {
            sessions = try await gateway.sessions().sorted { ($0.last_turn ?? $0.updated) > ($1.last_turn ?? $1.updated) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func conversation(_ s: CloudGateway.Session) -> Conversation? {
        guard let gateway else { return nil }
        let c = Conversation(folder: URL(fileURLWithPath: "/workspace/repo"), link: CloudLink(gateway: gateway, session: s.id), replay: false, session: s.id)
        c.cloudSession = s.id
        return c
    }

    func create(repo: String?) async -> CloudGateway.Session? {
        do {
            let s = try await gateway?.create(repo: repo, model: nil)
            await refresh()
            return s
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func archive(_ id: String) async { try? await gateway?.archive(id, true); await refresh() }
    func remove(_ id: String) async { try? await gateway?.remove(id); await refresh() }

    // MARK: Sign-in

    private struct Exchange: Decodable { let key: String }
    private var auth: ASWebAuthenticationSession?

    func signIn() {
        let verifier = Self.random(32)
        let state = Self.random(16)
        var u = URLComponents(url: CloudGateway.origin.appending(path: "auth/web"), resolvingAgainstBaseURL: false)!
        u.queryItems = [
            .init(name: "challenge", value: Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "state", value: state), .init(name: "device", value: Self.device),
            .init(name: "return", value: "frog://signin"),
        ]
        signingIn = true
        let session = ASWebAuthenticationSession(url: u.url!, callback: .customScheme("frog")) { [weak self] url, failure in
            Task { @MainActor in
                guard let self else { return }
                defer { self.signingIn = false; self.auth = nil }
                let q = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                guard failure == nil, let code = q.first(where: { $0.name == "code" })?.value,
                      q.first(where: { $0.name == "state" })?.value == state else {
                    if failure != nil, (failure as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        self.error = failure?.localizedDescription
                    }
                    return
                }
                await self.exchange(code: code, verifier: verifier)
            }
        }
        session.presentationContextProvider = self
        auth = session
        session.start()
    }

    private func exchange(code: String, verifier: String) async {
        var r = URLRequest(url: CloudGateway.origin.appending(path: "v1/auth/exchange"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier, "device_name": Self.device])
        do {
            let (data, response) = try await URLSession.shared.data(for: r)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { error = "Sign-in didn't finish. Try again."; return }
            let key = try JSONDecoder().decode(Exchange.self, from: data).key
            Self.writeKey(key)
            self.key = key
            error = nil
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() {
        Self.writeKey(nil)
        key = nil
        sessions = []
    }

    private static var device: String {
        if let d = UserDefaults.standard.string(forKey: "cloudDevice") { return d }
        let d = "Frog for iPhone · \(random(3).prefix(4))"
        UserDefaults.standard.set(d, forKey: "cloudDevice")
        return d
    }

    // MARK: Keychain

    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "frog", kSecAttrAccount as String: "cloud"]

    private static func readKey() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func writeKey(_ key: String?) {
        SecItemDelete(query as CFDictionary)
        guard let key else { return }
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func random(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b64url(Data(b))
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension CloudPhone: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
