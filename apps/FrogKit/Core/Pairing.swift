import CryptoKit
import Foundation
import Network

/// How a phone and this Mac find and trust each other on the local network. Shared by both apps.
///
/// The Mac advertises `_frog._tcp` on Bonjour. The connection is TLS with a pre-shared key made
/// from the pairing code (HMAC-SHA256), so it's encrypted and only someone who has the code can
/// complete the handshake: no certificates, no accounts. The code travels by sight: typed from the
/// Mac's settings, or in the QR code there (`frog://pair?...`), which the Camera app opens in frog.
/// On the network, messages are JSON, one per line, over that TLS (Network.framework's WebSocket
/// doesn't survive a PSK handshake). Loopback (the Simulator on this Mac) stays plain WebSocket.
enum Pairing {
    static let service = "_frog._tcp"
    static let lanPort: NWEndpoint.Port = 8914

    /// TLS-PSK, keyed by `code`, carrying JSON lines.
    static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(code.utf8))
        let psk = HMAC<SHA256>.authenticationCode(for: Data("frog-pair-v1".utf8), using: key)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = "frog".data(using: .utf8)!.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, pskData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        // PSK cipher suites are TLS 1.2's; without this the handshake tries 1.3 and aborts.
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    /// Plain WebSocket, for loopback.
    static func plain() -> NWParameters {
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return params
    }

    private static var websocket: NWProtocolWebSocket.Options {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 << 20
        return ws
    }

    /// Splits a byte stream into lines (the network framing).
    final class Lines: @unchecked Sendable {
        private var buffer = Data()

        func push(_ chunk: Data) -> [Data] {
            buffer.append(chunk)
            var out: [Data] = []
            while let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<i]
                if !line.isEmpty { out.append(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...i)
            }
            return out
        }
    }

    /// What the QR code in the Mac's settings says.
    static func url(name: String, host: String, code: String) -> URL {
        var c = URLComponents()
        c.scheme = "frog"
        c.host = "pair"
        c.queryItems = [.init(name: "name", value: name), .init(name: "host", value: host), .init(name: "code", value: code)]
        return c.url!
    }

    /// A `frog://pair` link, read back.
    static func parse(_ url: URL) -> (name: String, host: String?, code: String)? {
        guard url.scheme == "frog", url.host() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        let name = items.first { $0.name == "name" }?.value ?? "Mac"
        return (name, items.first { $0.name == "host" }?.value, code)
    }
}
