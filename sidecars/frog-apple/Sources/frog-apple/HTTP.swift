import Foundation
import Network

/// A minimal HTTP/1.1 server: one request per connection, JSON bodies, and streamed responses
/// (no Content-Length, connection closed at the end), which is all an SSE client needs.
final class HTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let body: Data
    }

    final class Response: @unchecked Sendable {
        private let conn: NWConnection
        private var started = false
        init(_ conn: NWConnection) { self.conn = conn }

        func json(_ status: Int, _ object: Any) {
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { [conn] _ in conn.cancel() })
        }

        /// Start an SSE stream; returns false once the client has gone away.
        @discardableResult
        func event(_ object: Any) async -> Bool {
            let line = String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
            return await raw("data: \(line)\n\n")
        }

        func raw(_ text: String) async -> Bool {
            var data = Data()
            if !started {
                started = true
                data += Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8)
            }
            data += Data(text.utf8)
            return await withCheckedContinuation { cont in
                conn.send(content: data, completion: .contentProcessed { err in cont.resume(returning: err == nil) })
            }
        }

        func finish() async {
            _ = await raw("data: [DONE]\n\n")
            conn.cancel()
        }
    }

    private let listener: NWListener
    private let handler: @Sendable (Request, Response) async -> Void

    init(port: UInt16, handler: @escaping @Sendable (Request, Response) async -> Void) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
        self.handler = handler
    }

    func start() {
        listener.newConnectionHandler = { [self] conn in
            conn.start(queue: .global())
            read(conn, buffer: Data())
        }
        listener.start(queue: .global())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, err in
            var buf = buffer
            if let data { buf += data }
            if let req = parse(buf) {
                Task { await self.handler(req, Response(conn)) }
            } else if done || err != nil {
                conn.cancel()
            } else {
                read(conn, buffer: buf)
            }
        }
    }

    /// A complete request, or nil if more bytes are needed.
    private func parse(_ data: Data) -> Request? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let length = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = data[split.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), body: Data(body.prefix(length)))
    }
}
