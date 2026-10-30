#if os(macOS)
import AppKit
import Foundation
import Observation

/// The Frog Cloud account, as the web app shows it: credit, and the plan's 5-hour and weekly
/// allowance windows when subscribed. Read from the edge's `/v1/me` with the same key frog uses
/// (FROG_API_KEY, else the Keychain item frog saved). Past the plan, credit pays at usage prices.
@MainActor
@Observable
final class CloudAccount {
    static let shared = CloudAccount()
    static let origin = URL(string: "https://api.frog.toys")!

    struct Window: Decodable, Hashable {
        let kind: String
        let used: Double
        let limit: Double
        let resets_at: String
        var label: String { kind == "5h" ? "This 5 hours" : "This week" }
        var fraction: Double { limit > 0 ? min(1, used / limit) : 0 }
        var resets: Date? { ISO8601DateFormatter().date(from: resets_at) }
    }

    struct Subscription: Decodable, Hashable {
        let plan: String
        let name: String
        let windows: [Window]
        let over: Bool
    }

    struct Me: Decodable {
        let name: String?
        let handle: String?
        let email: String?
        let credit_cents: Double
        let subscription: Subscription?
    }

    /// The plans, as Settings → Billing offers them on the web.
    static let plans: [(id: String, name: String, price: Int, blurb: String)] = [
        ("pro", "Pro", 20, "For steady daily use"),
        ("max5", "Max 5x", 100, "5× Pro, more at once"),
        ("max", "Max 20x", 200, "20× Pro, for heavy use"),
    ]
    static let topUps = [5, 10, 25, 50, 100]

    private(set) var me: Me?
    private(set) var error: String?
    private(set) var loading = false

    var signedIn: Bool { Self.key() != nil }

    func refresh() async {
        guard let key = Self.key() else { me = nil; error = nil; return }
        loading = true
        defer { loading = false }
        do {
            me = try await call(Me.self, "/v1/me", key: key)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Leaves for Stripe Checkout: a plan, or credit in whole dollars.
    func subscribe(_ plan: String) async { await checkout("/v1/billing/subscribe", ["plan": plan]) }
    func topUp(_ dollars: Int) async { await checkout("/v1/billing/topup", ["amount": dollars * 1_000_000]) }

    private struct Checkout: Decodable { let url: String }

    private func checkout(_ path: String, _ body: [String: Any]) async {
        guard let key = Self.key() else { return }
        var body = body
        body["return"] = "https://frog.toys"
        do {
            let r = try await call(Checkout.self, path, key: key, body: body)
            if let url = URL(string: r.url) { NSWorkspace.shared.open(url) }
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

    nonisolated static func key() -> String? {
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
}
#endif
