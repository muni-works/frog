// Frog Cloud gateway client: the §4 routes and the §2 websocket handshake, with reconnect.
// See docs/plans/2026-10-28-frog-cloud-wire-contract.md.
import type { Envelope, NewSession, Op, Refused, RepoList, SessionSummary, Welcome } from "./protocol";

export const PROTOCOL = 1;
export const CLIENT = "frog-web/0.1.0";

/** Close codes the gateway uses that mean "don't reconnect". */
const CLOSE_REFUSED = 4001;
const CLOSE_DELETED = 4004;

type WebSocketCtor = new (url: string, protocols?: string[]) => WebSocket;

export interface GatewayOptions {
  /** e.g. `https://cloud.frog.toys` or `http://127.0.0.1:8788` for the mock. */
  origin: string;
  /** The account's bearer token from frog.toys sign-in. */
  token: string;
  fetch?: typeof fetch;
  WebSocket?: WebSocketCtor;
  /** Protocol to offer in hello; only tests change it. */
  protocol?: number;
}

export class GatewayError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

/** An error from Frog Cloud (or the network on the way to it) as a sentence for the UI. The raw
 * server text is for logs and tooltips, never the message itself. */
export function friendly(e: unknown): string {
  const status = typeof (e as { status?: unknown })?.status === "number" ? (e as { status: number }).status : null;
  const raw = e instanceof Error ? e.message : String(e ?? "");
  if (status === null) {
    // fetch rejects with a TypeError ("Failed to fetch", "Load failed") when it can't connect.
    if (e instanceof TypeError || /fetch|network/i.test(raw)) return "Frog Cloud is unreachable. Check your connection and try again.";
    return "Something went wrong. Try again.";
  }
  if (status === 401) return "Your sign-in expired. Sign in again.";
  if (status === 402) return "You're out of Frog Cloud credit. Top up to keep going.";
  if (status === 403) return "Your account doesn't have access to that.";
  if (status === 404) return "That session doesn't exist any more.";
  if (status === 429) return "Too many requests at once. Wait a moment and try again.";
  if (status >= 500 || status === 0) return "Frog Cloud is unreachable. Try again in a moment.";
  // 400 and friends name the field that was wrong.
  if (/repo/i.test(raw)) return "That repo doesn't look right. Use owner/name, like ecto/frog.";
  if (/model/i.test(raw)) return "That model isn't available. Pick another one.";
  return raw && raw.length < 120 && !/[{}<>]/.test(raw) ? `${raw[0].toUpperCase()}${raw.slice(1).replace(/\.?$/, ".")}` : "Frog Cloud couldn't do that. Try again.";
}

export class Gateway {
  readonly origin: string;
  private readonly fetch: typeof fetch;

  constructor(readonly opts: GatewayOptions) {
    this.origin = opts.origin.replace(/\/+$/, "");
    this.fetch = opts.fetch ?? globalThis.fetch.bind(globalThis);
  }

  private async req<T>(method: string, path: string, body?: unknown): Promise<T> {
    const res = await this.fetch(this.origin + path, {
      method,
      headers: { authorization: `Bearer ${this.opts.token}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    if (!res.ok) {
      let json: { error?: string } | undefined;
      try { json = text ? JSON.parse(text) : undefined; } catch { /* an HTML error page from a proxy */ }
      throw new GatewayError(res.status, json?.error ?? res.statusText);
    }
    const json = text ? JSON.parse(text) : undefined;
    return json as T;
  }

  repos(): Promise<RepoList> {
    return this.req("GET", "/v1/repos");
  }

  async list(): Promise<SessionSummary[]> {
    return (await this.req<{ sessions: SessionSummary[] }>("GET", "/v1/sessions")).sessions;
  }

  get(id: string): Promise<SessionSummary> {
    return this.req("GET", `/v1/sessions/${encodeURIComponent(id)}`);
  }

  create(body: NewSession): Promise<SessionSummary & { ws: string }> {
    return this.req("POST", "/v1/sessions", body);
  }

  async remove(id: string): Promise<void> {
    await this.req("DELETE", `/v1/sessions/${encodeURIComponent(id)}`);
  }

  /** Archive or restore a session: it moves to or from the Archived list, nothing is lost. */
  async archive(id: string, archived: boolean): Promise<SessionSummary> {
    return this.req("PATCH", `/v1/sessions/${encodeURIComponent(id)}`, { archived });
  }

  /** Opens the session's websocket; it reconnects with `resume_after` until closed. */
  connect(id: string, handlers: ConnectionHandlers, resumeAfter = 0): Connection {
    return new Connection(this, id, handlers, resumeAfter);
  }

  wsUrl(id: string): string {
    return this.origin.replace(/^http/, "ws") + `/v1/sessions/${encodeURIComponent(id)}/ws`;
  }
}

export type ConnectionState =
  | { state: "connecting"; attempt: number }
  | { state: "live"; welcome: Welcome }
  | { state: "refused"; refused: Refused }
  | { state: "closed"; code: number; reason: string };

export interface ConnectionHandlers {
  onEnvelope(env: Envelope): void;
  onState?(s: ConnectionState): void;
}

export class Connection {
  /** Highest seq seen; sent as `resume_after` on reconnect. */
  lastSeq: number;
  state: ConnectionState = { state: "connecting", attempt: 0 };
  private ws: WebSocket | null = null;
  private live = false;
  private stopped = false;
  private attempt = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private queue: Op[] = [];

  constructor(
    private readonly gw: Gateway,
    readonly id: string,
    private readonly handlers: ConnectionHandlers,
    resumeAfter: number,
  ) {
    this.lastSeq = resumeAfter;
    this.open();
  }

  /** Sends an op, or queues it until the handshake completes. */
  send(op: Op): void {
    if (this.live && this.ws) this.ws.send(JSON.stringify(op));
    else this.queue.push(op);
  }

  close(): void {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    this.ws?.close(1000);
  }

  /** Drops the socket as a network failure would; the connection reconnects. Tests use it. */
  drop(): void {
    this.ws?.close(4000, "dropped");
  }

  private set(s: ConnectionState) {
    this.state = s;
    this.handlers.onState?.(s);
  }

  private open() {
    const Ctor = this.gw.opts.WebSocket ?? (globalThis.WebSocket as WebSocketCtor);
    // Browsers can't set headers on a websocket, so the token rides in the subprotocol list.
    const ws = new Ctor(this.gw.wsUrl(this.id), ["frog", `bearer.${this.gw.opts.token}`]);
    this.ws = ws;
    this.live = false;
    this.set({ state: "connecting", attempt: this.attempt });
    ws.onopen = () => {
      ws.send(JSON.stringify({ hello: { protocol: this.gw.opts.protocol ?? PROTOCOL, client: CLIENT, resume_after: this.lastSeq } }));
    };
    ws.onmessage = (m: MessageEvent) => this.message(String(m.data));
    ws.onclose = (e: CloseEvent) => this.closed(ws, e.code, e.reason);
  }

  private message(text: string) {
    let v: any;
    try {
      v = JSON.parse(text);
    } catch {
      return;
    }
    if (!this.live) {
      if (v?.refused) {
        this.stopped = true;
        this.set({ state: "refused", refused: v.refused });
        return;
      }
      if (!v?.welcome) return;
      this.live = true;
      this.attempt = 0;
      this.set({ state: "live", welcome: v.welcome });
      for (const op of this.queue.splice(0)) this.ws!.send(JSON.stringify(op));
      return;
    }
    if (typeof v?.seq !== "number" || typeof v.event !== "string") return;
    // Replay after a reconnect can overlap what we already have.
    if (v.seq <= this.lastSeq) return;
    this.lastSeq = v.seq;
    this.handlers.onEnvelope(v as Envelope);
  }

  private closed(ws: WebSocket, code: number, reason: string) {
    if (ws !== this.ws) return;
    this.ws = null;
    this.live = false;
    if (this.state.state === "refused") return;
    if (this.stopped || code === CLOSE_REFUSED || code === CLOSE_DELETED) {
      this.set({ state: "closed", code, reason });
      return;
    }
    this.attempt += 1;
    const delay = Math.min(250 * 2 ** (this.attempt - 1), 10_000);
    this.set({ state: "connecting", attempt: this.attempt });
    this.timer = setTimeout(() => this.open(), delay);
  }
}
