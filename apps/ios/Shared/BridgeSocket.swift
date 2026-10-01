import Foundation
import Network

/// One connection to frog on a Mac: JSON lines over TLS keyed by the pairing code (see `Pairing`),
/// or a plain WebSocket on loopback. `host` is a Bonjour name ("Cam's MacBook Pro"), or host:port.
final class BridgeSocket: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "frog.bridge")
    private var closed = false
    /// Network connections frame messages as lines.
    private let lines: Pairing.Lines?

    var onReady: @Sendable () -> Void = {}
    var onMessage: @Sendable (Data) -> Void = { _ in }
    /// Once, when it ends. `early` if it never got going (can't reach it, or the code is wrong).
    var onClose: @Sendable (_ error: NWError?, _ early: Bool) -> Void = { _, _ in }
    private var ready = false

    init(host: String, code: String) {
        let (endpoint, secure) = Self.endpoint(host)
        conn = NWConnection(to: endpoint, using: secure ? Pairing.parameters(code: code) : Pairing.plain())
        lines = secure ? Pairing.Lines() : nil
    }

    static func endpoint(_ host: String) -> (NWEndpoint, secure: Bool) {
        if let i = host.lastIndex(of: ":"), let port = NWEndpoint.Port(String(host[host.index(after: i)...])) {
            // 8913 is the Mac's loopback-only port (the Simulator), plain; everything else is TLS.
            return (.hostPort(host: .init(String(host[..<i])), port: port), port != 8913)
        }
        return (.service(name: host, type: Pairing.service, domain: "local.", interface: nil), true)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                self.onReady()
                self.receive()
            case .waiting(let e), .failed(let e):
                self.finish(e)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receive() {
        if let lines {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                guard let self else { return }
                for line in data.map(lines.push) ?? [] { self.onMessage(line) }
                if let error { return self.finish(error) }
                if done { return self.finish(nil) }
                self.receive()
            }
            return
        }
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onMessage(data) }
            if let error { return self.finish(error) }
            self.receive()
        }
    }

    private func finish(_ error: NWError?) {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClose(error, !ready)
    }

    func send(_ text: String) {
        if lines != nil {
            conn.send(content: Data((text + "\n").utf8), completion: .idempotent)
            return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    func cancel() {
        queue.async { [weak self] in self?.finish(nil) }
    }
}

/// Macs running frog on this network, as Bonjour finds them.
@MainActor
@Observable
final class MacFinder {
    private(set) var names: [String] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: Pairing.service, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> String? in
                if case .service(let name, _, _, _) = r.endpoint { name } else { nil }
            }
            Task { @MainActor in self?.names = Array(Set(found)).sorted() }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
