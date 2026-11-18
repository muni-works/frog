#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import Security
import Observation

/// The Frog Cloud account, as the web app shows it: credit, and the plan's 5-hour and weekly
/// allowance windows when subscribed. Read from the edge's `/v1/me` with the same key frog uses
/// (FROG_API_KEY, else the Keychain item frog saved). Past the plan, credit pays at usage prices.
@MainActor
@Observable
final class CloudAccount {
    static let shared = CloudAccount()
    #if DEBUG
    /// Flow tests point the account at a local fake Frog Cloud (FakeFrogCloud).
    nonisolated(unsafe) static var origin = URL(string: "https://api.frog.toys")!
    /// Flow tests: never read the login Keychain (the test host shares the developer's), so the
    /// only key is `keyProvider`'s.
    nonisolated(unsafe) static var noKeychain = false
    /// Flow tests: where a page the account opens (Stripe Checkout) goes instead of the browser.
    nonisolated(unsafe) static var openURL: (@MainActor (URL) -> Void)?
    #else
    static let origin = URL(string: "https://api.frog.toys")!
    #endif

    struct Window: Decodable, Hashable {
        let kind: String
        let used: Double
        let limit: Double
        let resets_at: String
        var label: String { kind == "5h" ? "This 5 hours" : "This week" }
        var fraction: Double { limit > 0 ? min(1, used / limit) : 0 }
        /// The edge's `toISOString()`: milliseconds included.
        var resets: Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: resets_at) ?? ISO8601DateFormatter().date(from: resets_at)
        }
    }

    struct Subscription: Decodable, Hashable {
        let plan: String
        let name: String
        let windows: [Window]
        let over: Bool
    }

    /// `/v1/me` answers `{"account": {...}}`.
    private struct MeResponse: Decodable { let account: Me }

    struct Me: Decodable {
        let name: String?
        /// The GitHub login; nil until GitHub is connected (signed in with Google or email).
        let handle: String?
        /// GitHub's picture, else Google's. Older edges leave it out.
        let image: String?
        /// The Google account they sign in with; nil until they do. Older edges leave it out.
        let google: String?
        let email: String?
        let credit_cents: Double
        let subscription: Subscription?
    }

    /// The plans, as Settings → Billing offers them on the web.
    static let plans: [(id: String, name: String, price: Int, blurb: String)] = [
        ("pro", "Pro", 20, "For steady daily use"),
        ("max5", "Max", 100, "5× Pro, more at once"),
        ("max", "Ultra", 200, "10× Pro, for heavy use"),
    ]
    static let topUps = [5, 10, 25, 50, 100]

    private(set) var me: Me?
    private(set) var error: String?
    private(set) var loading = false

    /// frog's Frog Cloud key, read off the main thread (`security` blocks) and kept: views
    /// read this, never `readKey()`, since waiting on a process mid-render crashes SwiftUI.
    private(set) var key: String? = ProcessInfo.processInfo.environment["FROG_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    private var keyLoaded = false
    var signedIn: Bool { key != nil }

    #if DEBUG
    private var unstaged: (me: Me?, key: String?, loaded: Bool)?

    /// Snapshots: show this account (nil: signed out) instead of whoever's signed in on this Mac,
    /// so no checked-in image carries a real name, picture or credit.
    func stage(_ me: Me?) {
        if unstaged == nil { unstaged = (self.me, key, keyLoaded) }
        self.me = me
        key = me == nil ? nil : "staged"
        keyLoaded = true
    }

    /// A staged account (snapshots) never goes to the network.
    var isStaged: Bool { unstaged != nil }

    func unstage() {
        guard let u = unstaged else { return }
        (me, key, keyLoaded) = (u.me, u.key, u.loaded)
        unstaged = nil
    }
    #endif

    func ensureKey() async { if !keyLoaded { await reloadKey() } }

    /// Read the key again (at launch, and after signing in or out).
    func reloadKey() async {
        key = await Task.detached(priority: .userInitiated) { Self.readKey() }.value
        keyLoaded = true
    }

    private init() {
        Task { await reloadKey() }
    }

    func refresh() async {
        #if DEBUG
        if isStaged { return }
        #endif
        if !keyLoaded { await reloadKey() }
        guard let key else { me = nil; error = nil; return }
        loading = true
        defer { loading = false }
        do {
            me = try await call(MeResponse.self, "/v1/me", key: key).account
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Devices and keys, credit added, codes (as Settings on the web has them)

    /// A signed-in app or a key made for the CLI or a tool (`/v1/keys`).
    struct KeyInfo: Decodable, Identifiable, Hashable {
        let id: String
        let name: String?
        let kind: String?
        let created: String
        let last_used: String?
        let revoked: Bool?
        /// The key this app is using.
        let current: Bool?
    }
    private struct Keys: Decodable { let keys: [KeyInfo] }
    struct NewKey: Decodable { let key: String; let id: String }
    private struct OK: Decodable {}

    /// Credit added: a top-up, a redeemed code, or another kind the edge lists.
    struct CreditRow: Decodable, Hashable {
        let kind: String?
        let code: String?
        let at: String
        let amount_micro_usd: Double?
        let added_cents: Double?
        let status: String?
        var dollars: Double { amount_micro_usd.map { $0 / 1e6 } ?? added_cents.map { $0 / 100 } ?? 0 }
        /// What it was: nothing more for a top-up, the code for a coupon, else its kind.
        var label: String {
            switch kind {
            case nil, "topup": ""
            case "coupon": code.map { "Code \($0)" } ?? "Code"
            case let k?: k.replacingOccurrences(of: "_", with: " ")
            }
        }
    }
    private struct History: Decodable { let topups: [CreditRow] }

    struct Redeemed: Decodable { let added_cents: Double; let credit_cents: Double }
    /// The edge's own words for a code it didn't take ("That code has expired").
    struct CouponError: LocalizedError { let message: String; var errorDescription: String? { message } }
    private struct ErrorBody: Decodable { struct E: Decodable { let message: String }; let error: E }

    func keys() async throws -> [KeyInfo] {
        #if DEBUG
        if isStaged { return [] }
        #endif
        guard let key else { throw CloudError.rejected }
        return try await call(Keys.self, "/v1/keys", key: key).keys
    }

    func createKey(_ name: String) async throws -> NewKey {
        guard let key else { throw CloudError.rejected }
        return try await call(NewKey.self, "/v1/keys", key: key, body: ["name": name])
    }

    func revokeKey(_ id: String) async throws {
        guard let key else { throw CloudError.rejected }
        _ = try await call(OK.self, "/v1/keys/\(id)/revoke", key: key, body: [:])
    }

    func history() async throws -> [CreditRow] {
        #if DEBUG
        if isStaged { return [] }
        #endif
        guard let key else { throw CloudError.rejected }
        return try await call(History.self, "/v1/billing/history", key: key).topups
    }

    /// Redeems a code for Frog Cloud credit; a refusal throws the edge's message.
    func redeem(_ code: String) async throws -> Redeemed {
        guard let key else { throw CloudError.rejected }
        var request = URLRequest(url: Self.origin.appending(path: "/v1/coupons/redeem"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let e = try? JSONDecoder().decode(ErrorBody.self, from: data) { throw CouponError(message: e.error.message) }
            throw http.statusCode == 401 ? CloudError.rejected : CloudError.status(http.statusCode)
        }
        let r = try JSONDecoder().decode(Redeemed.self, from: data)
        await refresh()
        return r
    }

    /// Leaves for Stripe Checkout: a plan, or credit in whole dollars.
    func subscribe(_ plan: String) async { await checkout("/v1/billing/subscribe", ["plan": plan]) }
    func topUp(_ dollars: Int) async { await checkout("/v1/billing/topup", ["amount": dollars * 1_000_000]) }

    private struct Checkout: Decodable { let url: String }
    private struct Link: Decodable { let link: String }

    /// A 10-minute token that signs a browser in as this key's account (`/auth/web?link=…`).
    func linkToken() async throws -> String {
        await ensureKey()
        guard let key else { throw CloudError.rejected }
        return try await call(Link.self, "/v1/auth/link", key: key, body: [:]).link
    }

    private func checkout(_ path: String, _ body: [String: Any]) async {
        guard let key else { return }
        var body = body
        body["return"] = "https://frog.toys"
        do {
            let r = try await call(Checkout.self, path, key: key, body: body)
            if let url = URL(string: r.url) {
                #if DEBUG
                if let open = Self.openURL { return open(url) }
                #endif
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                await UIApplication.shared.open(url)
                #endif
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func call<T: Decodable>(_ type: T.Type, _ path: String, key: String, body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: Self.origin.appending(path: path), timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 401 ? CloudError.rejected : CloudError.status(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// frog's Frog Cloud key: FROG_API_KEY wins, then the Keychain (service "frog", account
    /// "cloud"), read through `security` as frog does so no new Keychain prompt appears.
    enum CloudError: LocalizedError {
        case rejected, status(Int)
        var errorDescription: String? {
            switch self {
            case .rejected: "This key can't read your account (it may predate sign-in). Sign in with GitHub to see your plan and credit."
            case .status(let code): "Frog Cloud answered \(code). Try again in a moment."
            }
        }
    }

    /// Where the app keeps its key, when it isn't the Keychain item read below (the iPhone
    /// hands over the key its own sign-in holds).
    nonisolated(unsafe) static var keyProvider: (@Sendable () -> String?)?

    nonisolated static func readKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["FROG_API_KEY"], !env.isEmpty { return env }
        if let key = keyProvider?() { return key }
        #if DEBUG
        if noKeychain { return nil }
        #endif
        #if os(macOS)
        return macKey()
        #else
        // The phone's own sign-in key (CloudPhone keeps it under the same service and account).
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "frog",
                                kSecAttrAccount as String: "cloud", kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
        #endif
    }

    #if os(macOS)
    nonisolated private static func macKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["FROG_API_KEY"], !env.isEmpty { return env }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "frog", "-a", "cloud", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let key = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
    #endif
}
