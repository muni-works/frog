import CryptoKit
import Foundation

/// Pushes to a real phone pass through frog's relay and Apple's servers. Neither gets to read
/// them: the Mac seals the alert and its details with a key only the paired phone has (derived
/// from the pairing code, like the TLS between them), and the phone's notification service
/// extension opens it before anything is shown. What stays in the clear is what iOS itself
/// needs: the category (Allow / Deny buttons), the thread, the sound, and a placeholder alert
/// for a phone that can't open it (unpaired since, or the code changed).
enum PushCrypto {
    /// The wire key, the field name and the version a phone checks before trying.
    static let field = "enc"
    static let version = 1

    private static func key(code: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                               salt: Data("frog-push-v1".utf8), info: Data("payload".utf8), outputByteCount: 32)
    }

    /// `plaintext` sealed for the phone paired with `code`: nonce, ciphertext and tag, base64.
    static func seal(_ plaintext: Data, code: String) throws -> String {
        try ChaChaPoly.seal(plaintext, using: key(code: code)).combined.base64EncodedString()
    }

    /// What `seal` made, opened with the same code; nil for the wrong code or a tampered box.
    static func open(_ sealed: String, code: String) -> Data? {
        guard let combined = Data(base64Encoded: sealed),
              let box = try? ChaChaPoly.SealedBox(combined: combined) else { return nil }
        return try? ChaChaPoly.open(box, using: key(code: code))
    }
}
