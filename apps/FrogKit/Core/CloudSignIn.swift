#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import Network

/// GitHub or Google sign-in for Frog Cloud, the web app's way (PKCE at the edge's `/auth/web`), coming
/// back to a one-shot listener on 127.0.0.1 (RFC 8252) instead of a page. The key it gets is
/// this Mac's own ("Frog for Mac · …"), saved where frog keeps its Frog Cloud key.
@MainActor
enum CloudSignIn {
    struct Exchange: Decodable { let key: String }

    /// `provider` is "github" or "google". `link` (from `/v1/auth/link`) signs the browser in as
    /// this Mac's account first, so "github" then connects GitHub to it rather than to whoever
    /// the browser's cookie is.
    static func run(provider: String = "github", link: String? = nil) async throws -> String {
        let verifier = random(32)
        let challenge = b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = random(16)
        let listener = try NWListener(using: .tcp, on: .any)
        let code = try await withCheckedThrowingContinuation { (done: CheckedContinuation<String, Error>) in
            let once = Once()
            let finish: @MainActor @Sendable (Result<String, Error>) -> Void = { r in
                guard once.take() else { return }
                listener.cancel()
                done.resume(with: r)
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                    let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let q = URLComponents(string: path)?.queryItems ?? []
                    let got = q.first { $0.name == "code" }?.value
                    let ok = got != nil && q.first { $0.name == "state" }?.value == state
                    let body = ok ? "Signed in. You can close this tab and go back to Frog." : "Sign-in didn't finish. Try again from Frog."
                    let page = "<!doctype html><meta charset=utf-8><title>Frog</title><body style=\"font:15px -apple-system;background:#000;color:#ececec;display:grid;place-items:center;height:90vh\">\(body)"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                    conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    guard path.hasPrefix("/frog-signin") else { return }
                    MainActor.assumeIsolated { finish(ok ? .success(got!) : .failure(CloudAccount.CloudError.rejected)) }
                }
            }
            listener.stateUpdateHandler = { s in
                MainActor.assumeIsolated {
                    switch s {
                    case .ready:
                        guard let port = listener.port?.rawValue else { return }
                        var u = URLComponents(url: CloudAccount.origin.appending(path: "auth/web"), resolvingAgainstBaseURL: false)!
                        u.queryItems = [
                            .init(name: "challenge", value: challenge), .init(name: "state", value: state),
                            .init(name: "device", value: device),
                            .init(name: "return", value: "http://127.0.0.1:\(port)/frog-signin"),
                            .init(name: "provider", value: provider),
                        ] + (link.map { [.init(name: "link", value: $0)] } ?? [])
                        NSWorkspace.shared.open(u.url!)
                    case .failed(let e): finish(.failure(e))
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            // Ten minutes is plenty for GitHub or Google; past it, stop listening.
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
                MainActor.assumeIsolated { finish(.failure(URLError(.timedOut))) }
            }
        }
        var request = URLRequest(url: CloudAccount.origin.appending(path: "v1/auth/exchange"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier, "device_name": device])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CloudAccount.CloudError.rejected }
        return try JSONDecoder().decode(Exchange.self, from: data).key
    }

    /// Resumes the sign-in exactly once: the redirect, a failure or the timeout, whichever first.
    @MainActor private final class Once: Sendable {
        private var done = false
        func take() -> Bool { defer { done = true }; return !done }
    }

    private static var device: String {
        let key = "cloudDevice"
        if let d = UserDefaults.standard.string(forKey: key) { return d }
        let d = "Frog for Mac · \(random(3).prefix(4))"
        UserDefaults.standard.set(d, forKey: key)
        return d
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
#endif
