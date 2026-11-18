import Foundation
import Network
import XCTest
@testable import Frog

/// A local Frog Cloud for flow tests: the account (`/v1/me`), sign-in (`/auth/web` is the
/// browser's part, played by `browser`; `/v1/auth/exchange`), the link token, billing checkout,
/// and the gateway's repos and sessions. `install()` points the app at it through its DEBUG
/// seams, so nothing reaches api.frog.toys, no browser opens, no key touches the Keychain, and
/// Stripe Checkout is a URL the test reads.
@MainActor
final class FakeFrogCloud {
    struct Account {
        var name = "Flow Tester"
        var handle: String? = "flowtester"
        var creditCents: Double = 500
        var plan: (id: String, name: String)? = nil
    }

    var account = Account()
    var repos = ["flowtester/demo"]
    /// Sessions the gateway lists (id, title, repo, state).
    var sessions: [[String: Any]] = []
    /// Every request: "METHOD /path" and its JSON body.
    private(set) var requests: [(line: String, body: [String: Any])] = []
    /// What the app opened: Stripe Checkout and the like.
    private(set) var opened: [URL] = []
    /// The key the app saved (where `frog --set-key cloud` would have put it).
    private(set) var savedKey: String? { didSet { keyBox.set(savedKey) } }
    private let keyBox = KeyBox()
    /// The sign-in pages the app sent the browser to.
    private(set) var signInPages: [URL] = []
    /// Answer the browser's sign-in (the code comes back to the app), or leave it waiting.
    var browserCompletes = true

    private let server: TinyHTTP
    private var restores: [() -> Void] = []
    private let issued = "fake-cloud-key-\(UUID().uuidString.prefix(6))"
    private let code = "fake-code"

    var origin: URL { URL(string: "http://127.0.0.1:\(server.port)")! }

    init() throws {
        server = try TinyHTTP()
        server.handler = { [weak self] method, path, headers, body in
            MainActor.assumeIsolated {
                let (status, obj) = self?.route(method, path, headers, body) ?? (404, [:])
                return (status, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
            }
        }
        try server.start()
    }

    /// Points the app here. Signed out to start (`signIn()` or `signedIn` for the rest).
    func install(signedIn: Bool = false) {
        let (account, gateway) = (CloudAccount.origin, CloudGateway.origin)
        let (browser, opener, sink, provider) = (CloudSignIn.openBrowser, CloudAccount.openURL, ProviderStore.keySink, CloudAccount.keyProvider)
        restores.append {
            CloudAccount.origin = account
            CloudGateway.origin = gateway
            CloudSignIn.openBrowser = browser
            CloudAccount.openURL = opener
            ProviderStore.keySink = sink
            CloudAccount.keyProvider = provider
            CloudAccount.stagedRefreshes = false
        }
        CloudAccount.stagedRefreshes = true
        CloudAccount.origin = origin
        CloudGateway.origin = origin
        CloudSignIn.openBrowser = { [weak self] url in self?.browser(url) }
        CloudAccount.openURL = { [weak self] url in self?.opened.append(url) }
        ProviderStore.keySink = { [weak self] key, id in
            guard id == "cloud" else { return true }
            self?.savedKey = key.isEmpty ? nil : key
            return true
        }
        let box = keyBox
        CloudAccount.keyProvider = { box.get() }
        if signedIn { savedKey = issued }
    }

    func uninstall() {
        restores.reversed().forEach { $0() }
        restores.removeAll()
        server.stop()
    }

    func requested(_ line: String) -> [String: Any]? { requests.last { $0.line == line }?.body }

    /// The browser: GitHub or Google said yes; back to the app's loopback with the code.
    private func browser(_ url: URL) {
        signInPages.append(url)
        guard browserCompletes,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let back = items.first(where: { $0.name == "return" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value,
              var r = URLComponents(string: back) else { return }
        r.queryItems = [.init(name: "code", value: code), .init(name: "state", value: state)]
        URLSession.shared.dataTask(with: r.url!).resume()
    }

    private func route(_ method: String, _ full: String, _ headers: [String: String], _ body: Data) -> (Int, Any) {
        let path = full.split(separator: "?").first.map(String.init) ?? full
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        requests.append(("\(method) \(path)", json))
        let authed = headers["authorization"] == "Bearer \(issued)"
        switch (method, path) {
        case ("POST", "/v1/auth/exchange"):
            return json["code"] as? String == code ? (200, ["key": issued]) : (401, ["error": "bad code"])
        case (_, _) where !authed:
            return (401, ["error": "unauthorized"])
        case ("GET", "/v1/me"):
            var me: [String: Any] = ["name": account.name, "credit_cents": account.creditCents]
            if let h = account.handle { me["handle"] = h }
            if let p = account.plan {
                me["subscription"] = ["plan": p.id, "name": p.name, "windows": [], "over": false]
            }
            return (200, ["account": me])
        case ("POST", "/v1/auth/link"):
            return (200, ["link": "fake-link"])
        case ("POST", "/v1/billing/topup"), ("POST", "/v1/billing/subscribe"):
            return (200, ["url": "https://checkout.example.invalid/session/flow"])
        case ("GET", "/v1/repos"):
            return (200, ["repos": repos.map { ["name": $0, "private": false] }, "install": NSNull(), "login": account.handle ?? NSNull()])
        case ("GET", "/v1/sessions"):
            return (200, ["sessions": sessions])
        case ("POST", "/v1/sessions"):
            let now = Date().timeIntervalSince1970 * 1000
            let s: [String: Any] = ["id": "cloud-\(sessions.count + 1)", "title": "", "repo": json["repo"] as? String ?? "",
                                    "branch": "frog/flow", "state": "starting", "created": now, "updated": now]
            sessions.append(s)
            return (200, s)
        default:
            return (404, ["error": "not in the fake"])
        }
    }

    /// The saved key, readable off the main thread (the account reads its key detached).
    private final class KeyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        func set(_ k: String?) { lock.lock(); key = k; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return key }
    }
}

/// A small HTTP/1.1 server on 127.0.0.1 (one request per connection), for fakes.
final class TinyHTTP: @unchecked Sendable {
    typealias Handler = @Sendable (String, String, [String: String], Data) -> (Int, Data)
    var handler: Handler = { _, _, _, _ in (404, Data("{}".utf8)) }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tiny-http")
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() throws {
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else {
            throw NSError(domain: "TinyHTTP", code: 1)
        }
        port = p
    }

    func stop() { listener.cancel() }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { c.cancel() } else { self.read(c, buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            var headers: [String: String] = [:]
            for line in head.split(separator: "\r\n").dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let body = buffer[end.upperBound...]
            if body.count < length, !done, error == nil { return self.read(c, buffer) }
            let first = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
            let method = first.first.map(String.init) ?? "GET"
            let path = first.dropFirst().first.map(String.init) ?? "/"
            // The handler runs on the main thread (fakes keep their state there).
            let handler = self.handler
            DispatchQueue.main.async {
                let (status, data) = handler(method, path, headers, Data(body))
                let response = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data(response.utf8) + data, completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }
}
