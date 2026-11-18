// The mock's live previews (the real thing: src/preview.ts). A session's "sandbox" is this
// machine: POST /v1/sessions/:id/preview {port} returns http://<label>.localhost:<mock port>/,
// and requests on that host go to 127.0.0.1:<port> with the capture script added to HTML, as the
// Session DO does. Chrome and Safari resolve *.localhost to loopback, so each preview is its own
// origin here too. Labels aren't signed: `<session hex>-<port>`.
//
// Owner-only, as zest 3642f57: the minted `url` is a one-minute entry link,
// `<origin>/__frog/enter?t=<token>`, that sets the host's owner cookie and 302s to `/`. Without the
// cookie every request gets a 403 error page, except the capture script (so that page can say so).
import { request as httpRequest } from "node:http";
import { connect } from "node:net";
import { readFileSync } from "node:fs";

export const SCRIPT_PATH = "/__frog/preview.js";
export const ENTER_PATH = "/__frog/enter";
export const GATE_COOKIE = "__Host-frog_preview";
export const ENTRY_TTL_MS = 60_000;
const entries = new Map(); // token → { host label, expires }
const TAG = `<script src="${SCRIPT_PATH}"></script>`;
const LABEL = /^([0-9a-f]{20})-(\d{4,5})\.localhost$/;

export const okPort = (p) => Number.isInteger(p) && p >= 1024 && p <= 65535 && p !== 7070;

/** The preview's origin for a session's port. */
export function previewOrigin(host, id, port) {
  const mockPort = host.split(":")[1] ?? "80";
  return `http://${id.slice(2)}-${port}.localhost:${mockPort}`;
}

/** What POST /v1/sessions/:id/preview answers: a fresh entry link and the origin it enters. */
export function mintPreview(host, id, port, now = Date.now()) {
  const origin = previewOrigin(host, id, port);
  const t = Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
  entries.set(t, { label: `${id.slice(2)}-${port}`, expires: now + ENTRY_TTL_MS });
  return { url: `${origin}${ENTER_PATH}?t=${t}`, origin, port, expires: now + 8 * 3600_000 };
}

const gate = (label) => `owner-${label}`;
const cookies = (req) => (req.headers.cookie ?? "").split(";").map((c) => c.trim().split("="));

/** The session and port when `host` is a preview host, else null. */
export function previewTarget(host) {
  const m = (host ?? "").split(":")[0].toLowerCase().match(LABEL);
  return m && okPort(Number(m[2])) ? { session: "s_" + m[1], port: Number(m[2]) } : null;
}

const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
function page(res, status, message) {
  res.writeHead(status, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }).end(
    `<!doctype html><html><head><meta charset="utf-8"><meta name="frog-preview-error" content="${esc(message)}">${TAG}<title>Preview</title>` +
      `<style>body{font:14px/1.5 system-ui,sans-serif;color:#8a8f98;display:grid;place-items:center;height:100vh;margin:0}</style></head><body><p>${esc(message)}</p></body></html>`,
  );
}

function upstreamHeaders(req, target) {
  const local = `localhost:${target.port}`;
  const origin = `http://${req.headers.host}`;
  const h = { ...req.headers, host: local };
  if (h.origin === origin) h.origin = `http://${local}`;
  if (h.referer?.startsWith(origin)) h.referer = `http://${local}` + h.referer.slice(origin.length);
  delete h["accept-encoding"]; // so HTML can be rewritten as text
  return h;
}

/** Serve one request on a preview host. `script` is the capture script's path on disk, if any. */
export function servePreview(req, res, target, { script, exists }) {
  if (!exists(target.session)) return page(res, 404, "This session is gone.");
  const label = `${target.session.slice(2)}-${target.port}`;
  const path = req.url.split("?")[0];
  if (path === ENTER_PATH) {
    const t = new URL(req.url, "http://mock").searchParams.get("t") ?? "";
    const e = entries.get(t);
    if (!e || e.label !== label || e.expires < Date.now()) return page(res, 403, "This preview link has expired. Reload the preview in Frog.");
    return res.writeHead(302, { location: "/", "cache-control": "no-store", "set-cookie": `${GATE_COOKIE}=${gate(label)}; Path=/; HttpOnly; Secure; SameSite=None; Partitioned` }).end();
  }
  if (path !== SCRIPT_PATH && !cookies(req).some(([k, v]) => k === GATE_COOKIE && v === gate(label))) return page(res, 403, "Open this preview from Frog. Only the session's owner can view it.");
  if (path === SCRIPT_PATH) {
    let body = "// no capture script configured\n";
    try { if (script) body = readFileSync(script, "utf8"); } catch {}
    return res.writeHead(200, { "content-type": "text/javascript; charset=utf-8", "cache-control": "no-store" }).end(body);
  }
  const up = httpRequest({ host: "127.0.0.1", port: target.port, method: req.method, path: req.url, headers: upstreamHeaders(req, target) }, (r) => {
    const h = { ...r.headers };
    delete h["x-frame-options"];
    if (h["content-security-policy"]) {
      const kept = h["content-security-policy"].split(";").map((d) => d.trim()).filter((d) => d && !/^frame-ancestors\b/i.test(d)).join("; ");
      if (kept) h["content-security-policy"] = kept; else delete h["content-security-policy"];
    }
    const local = h.location?.match(new RegExp(`^https?://(?:localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0|\\[::1\\]):${target.port}(?=/|$)`));
    if (local) h.location = h.location.slice(local[0].length) || "/";
    h["referrer-policy"] ??= "same-origin";
    if (!(h["content-type"] ?? "").includes("text/html")) return res.writeHead(r.statusCode, h), r.pipe(res);
    const chunks = [];
    r.on("data", (c) => chunks.push(c));
    r.on("end", () => {
      let html = Buffer.concat(chunks).toString("utf8");
      const head = html.match(/<head(\s[^>]*)?>/i);
      html = head ? html.slice(0, head.index + head[0].length) + TAG + html.slice(head.index + head[0].length) : TAG + html;
      delete h["content-length"];
      res.writeHead(r.statusCode, h).end(html);
    });
  });
  up.on("error", () => page(res, 502, `Nothing is answering on port ${target.port} in the sandbox. Is the dev server running?`));
  req.pipe(up);
}

/** A websocket (HMR) on a preview host: piped to the dev server as is. */
export function upgradePreview(req, socket, head, target) {
  const up = connect(target.port, "127.0.0.1", () => {
    const h = upstreamHeaders(req, target);
    up.write(`${req.method} ${req.url} HTTP/1.1\r\n` + Object.entries(h).map(([k, v]) => `${k}: ${v}`).join("\r\n") + "\r\n\r\n");
    if (head?.length) up.write(head);
    up.pipe(socket);
    socket.pipe(up);
  });
  up.on("error", () => socket.end("HTTP/1.1 502 Bad Gateway\r\n\r\n"));
  socket.on("error", () => up.destroy());
}
