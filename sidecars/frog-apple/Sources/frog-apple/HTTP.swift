import Foundation
import Network

/// A minimal HTTP/1.1 server: one request per connection, JSON bodies, and streamed responses
/// (no Content-Length, connection closed at the end), which is all an SSE client needs.
final class HTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    /// Largest request accepted (head + body), and how long a client gets to send it.
    static let maxRequest = 8 << 20
    static let maxHead = 32 << 10
    static let readTimeout: TimeInterval = 30

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
            // Slow or stalled clients don't get to hold a connection open forever.
            let deadline = DispatchWorkItem { [weak conn] in conn?.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.readTimeout, execute: deadline)
            read(conn, buffer: Data(), deadline: deadline)
        }
        listener.start(queue: .global())
    }

    private func read(_ conn: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, err in
            var buf = buffer
            if let data { buf += data }
            switch parse(buf) {
            case .complete(let req):
                deadline.cancel()
                Task { await self.handler(req, Response(conn)) }
            case .invalid(let status, let message):
                deadline.cancel()
                Response(conn).json(status, ["error": ["message": message]])
            case .incomplete where done || err != nil:
                deadline.cancel()
                conn.cancel()
            case .incomplete:
                read(conn, buffer: buf, deadline: deadline)
            }
        }
    }

    enum Parsed {
        case complete(Request)
        case incomplete
        case invalid(Int, String)
    }

    /// A complete request, `.incomplete` if more bytes are needed, or why it's refused.
    private func parse(_ data: Data) -> Parsed {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > Self.maxHead ? .invalid(431, "request head too large") : .incomplete
        }
        guard split.lowerBound <= Self.maxHead else { return .invalid(431, "request head too large") }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return .invalid(400, "malformed request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil, name == "content-length" || name == "host" {
                return .invalid(400, "duplicate \(name) header")
            }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid(501, "chunked bodies aren't supported") }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .invalid(400, "invalid Content-Length") }
            length = n
        }
        guard length <= Self.maxRequest - split.upperBound else { return .invalid(413, "request too large") }
        let body = data[split.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .complete(Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(length))))
    }
}
