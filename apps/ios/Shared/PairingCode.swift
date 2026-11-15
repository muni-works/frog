import Foundation
import Security

/// The pairing code is the key to the Mac (it keys the TLS), so it lives in the Keychain, shared
/// with the share extension, never in defaults. Readable after first unlock, so answering from
/// the lock screen still works.
enum PairingCode {
    private static let account = "pairing-code"
    private static let service = "toys.frog.remote"
    /// `$(AppIdentifierPrefix)toys.frog.remote`, from Info.plist.
    private static var group: String? { Bundle.main.object(forInfoDictionaryKey: "FrogKeychainGroup") as? String }

    private static var query: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let group, !group.hasPrefix("$(") { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ code: String) {
        SecItemDelete(query as CFDictionary)
        guard !code.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(code.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}
