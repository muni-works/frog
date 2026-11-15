// A dependency-free websocket server side (RFC 6455), just enough for one-text-frame-per-message
// JSON: the fake engine and the mock gateway share it. Not for production traffic.
import { createHash } from "node:crypto";

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** Finish an HTTP upgrade on `socket`; returns a connection with send/close and message/close callbacks. */
export function accept(req, socket, { protocol } = {}) {
  const key = req.headers["sec-websocket-key"];
  if (!key) {
    socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
    return null;
  }
  const digest = createHash("sha1").update(key + GUID).digest("base64");
  const lines = ["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", `Sec-WebSocket-Accept: ${digest}`];
  if (protocol) lines.push(`Sec-WebSocket-Protocol: ${protocol}`);
  socket.write(lines.join("\r\n") + "\r\n\r\n");
  socket.setNoDelay(true);

  const conn = {
    open: true,
    onmessage: () => {},
    onclose: () => {},
    send(text) {
      if (conn.open) socket.write(frame(0x1, Buffer.from(text)));
    },
    close(code = 1000, reason = "") {
      if (!conn.open) return;
      conn.open = false;
      const body = Buffer.alloc(2 + Buffer.byteLength(reason));
      body.writeUInt16BE(code, 0);
      body.write(reason, 2);
      socket.end(frame(0x8, body));
      conn.onclose(code);
    },
  };

  let buf = Buffer.alloc(0);
  let parts = [];
  socket.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      const f = parse(buf);
      if (!f) break;
      buf = buf.subarray(f.length);
      if (f.op === 0x8) {
        const code = f.payload.length >= 2 ? f.payload.readUInt16BE(0) : 1005;
        if (conn.open) {
          conn.open = false;
          socket.end(frame(0x8, f.payload.subarray(0, 2)));
          conn.onclose(code);
        }
        return;
      }
      if (f.op === 0x9) socket.write(frame(0xa, f.payload));
      if (f.op === 0x1 || f.op === 0x0) {
        parts.push(f.payload);
        if (f.fin) {
          const text = Buffer.concat(parts).toString("utf8");
          parts = [];
          conn.onmessage(text);
        }
      }
    }
  });
  const gone = () => {
    if (conn.open) {
      conn.open = false;
      conn.onclose(1006);
    }
  };
  socket.on("close", gone);
  socket.on("error", gone);
  return conn;
}

function frame(op, payload) {
  const n = payload.length;
  const head = n < 126 ? Buffer.from([0x80 | op, n]) : n < 65536 ? Buffer.alloc(4) : Buffer.alloc(10);
  if (n >= 126) {
    head[0] = 0x80 | op;
    if (n < 65536) {
      head[1] = 126;
      head.writeUInt16BE(n, 2);
    } else {
      head[1] = 127;
      head.writeBigUInt64BE(BigInt(n), 2);
    }
  }
  return Buffer.concat([head, payload]);
}

function parse(buf) {
  if (buf.length < 2) return null;
  const fin = (buf[0] & 0x80) !== 0;
  const op = buf[0] & 0x0f;
  const masked = (buf[1] & 0x80) !== 0;
  let n = buf[1] & 0x7f;
  let at = 2;
  if (n === 126) {
    if (buf.length < 4) return null;
    n = buf.readUInt16BE(2);
    at = 4;
  } else if (n === 127) {
    if (buf.length < 10) return null;
    n = Number(buf.readBigUInt64BE(2));
    at = 10;
  }
  const mask = masked ? buf.subarray(at, at + 4) : null;
  if (masked) at += 4;
  if (buf.length < at + n) return null;
  const payload = Buffer.from(buf.subarray(at, at + n));
  if (mask) for (let i = 0; i < n; i++) payload[i] ^= mask[i & 3];
  return { fin, op, payload, length: at + n };
}
