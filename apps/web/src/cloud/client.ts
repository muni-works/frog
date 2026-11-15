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
  /** The token stopped working (a 401 from a route, or a socket that keeps failing while the
   * account check answers 401): the app signs out. */
  onUnauthorized?: () => void;
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
      if (res.status === 401) this.opts.onUnauthorized?.();
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
  /** The token was refused: no more reconnects; the app signs out. */
  | { state: "unauthorized" }
  | { state: "closed"; code: number; reason: string };

export interface ConnectionHandlers {
  onEnvelope(env: Envelope): void;
  onState?(s: ConnectionState): void;
  /** The gateway's log restarted below what we'd seen (a new sandbox, a reset store): drop what
   * was folded so far, since it replays from the start. */
  onReset?(): void;
}

/** Reconnects that fail before a welcome, in a row, before we ask whether the token still works.
 * A refused upgrade (401) reaches the browser as a bare 1006 close, indistinguishable from a
 * network drop, so the account route answers instead. */
export const AUTH_PROBE_AFTER = 3;

export class Connection {
  /** Highest seq seen; sent as `resume_after` on reconnect. */
  lastSeq: number;
  state: ConnectionState = { state: "connecting", attempt: 0 };
  private ws: WebSocket | null = null;
  private live = false;
  private stopped = false;
  private attempt = 0;
  /** Closes in a row that never reached a welcome. */
  private failures = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;
  /** Ops waiting for a live socket. */
  private queue: Op[] = [];
  /** Submits put on the wire but not yet started as a turn. A socket that dies mid-send loses
   * them silently, so they go again after the next welcome unless its replay shows them started. */
  private unacked: Extract<Op, { op: "submit" }>[] = [];
  /** After a welcome with submits to resend: the seq its replay runs to. Until then (or a short
   * wait, since replay skips what wasn't kept) everything waits, so a resend can't duplicate a
   * turn the replay is about to show started, and ops keep their order. */
  private replayTo = 0;
  private holdTimer: ReturnType<typeof setTimeout> | null = null;
  /** Resuming after N, the first envelope tells us whether the log restarted: replay only ever
   * sends seqs above N, so one at or below it is a new log. (`welcome.last_seq` can't say: it
   * may count only the kept envelopes, and frog serve already moves a restored engine's seqs
   * above what a resuming peer has.) */
  private checkFirst = false;

  constructor(
    private readonly gw: Gateway,
    readonly id: string,
    private readonly handlers: ConnectionHandlers,
    resumeAfter: number,
  ) {
    this.lastSeq = resumeAfter;
    this.open();
  }

  /** Sends an op, or queues it until the handshake completes. Submits are kept until their turn
   * starts and resent after a reconnect, never twice. */
  send(op: Op): void {
    if (this.live && this.ws && !this.replayTo) this.wire(op);
    else this.queue.push(op);
  }

  close(): void {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    if (this.holdTimer) clearTimeout(this.holdTimer);
    this.ws?.close(1000);
  }

  /** Drops the socket as a network failure would; the connection reconnects. Tests use it. */
  drop(): void {
    this.ws?.close(4000, "dropped");
  }

  private wire(op: Op) {
    if (op.op === "submit" && !this.unacked.includes(op)) this.unacked.push(op);
    this.ws!.send(JSON.stringify(op));
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
    // A refused upgrade errors, then closes; the close is what we act on.
    ws.onerror = () => {};
  }

  /** The log restarted: forget it and ask for it all again on a fresh socket. */
  private restart() {
    this.lastSeq = 0;
    this.handlers.onReset?.();
    this.ws?.close(4000, "resync");
  }

  /** Replay has caught up: what was waiting (and what the socket may have eaten) goes now. */
  private flush() {
    this.replayTo = 0;
    if (this.holdTimer) clearTimeout(this.holdTimer);
    this.holdTimer = null;
    if (!this.live || !this.ws) return;
    const resend = this.unacked.splice(0);
    const queued = this.queue.splice(0).filter((op) => !resend.includes(op as never));
    for (const op of [...resend, ...queued]) this.wire(op);
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
      const w = v.welcome as Partial<Welcome>;
      this.checkFirst = this.lastSeq > 0;
      this.live = true;
      this.attempt = 0;
      this.failures = 0;
      this.set({ state: "live", welcome: v.welcome });
      const to = typeof w.last_seq === "number" ? w.last_seq : 0;
      if (!this.unacked.length || to <= this.lastSeq) return this.flush();
      this.replayTo = to;
      this.holdTimer = setTimeout(() => this.flush(), 1000);
      return;
    }
    if (typeof v?.seq !== "number" || typeof v.event !== "string") return;
    if (this.checkFirst) {
      this.checkFirst = false;
      if (v.seq <= this.lastSeq) return this.restart();
    }
    // Replay after a reconnect can overlap what we already have.
    if (v.seq <= this.lastSeq) return;
    this.lastSeq = v.seq;
    if (v.event === "turn_started") {
      // A turn started: the submit with its text is delivered, or else the oldest one (turns
      // start in the order they were sent; the engine may reword the input). Erring this way
      // can only miss a resend, never send twice.
      const i = this.unacked.findIndex((op) => op.text === v.input);
      if (this.unacked.length) this.unacked.splice(i >= 0 ? i : 0, 1);
    }
    this.handlers.onEnvelope(v as Envelope);
    if (this.replayTo && this.lastSeq >= this.replayTo) this.flush();
  }

  private closed(ws: WebSocket, code: number, reason: string) {
    if (ws !== this.ws) return;
    const wasLive = this.live;
    this.ws = null;
    this.live = false;
    this.replayTo = 0;
    if (this.holdTimer) clearTimeout(this.holdTimer);
    if (this.state.state === "refused" || this.state.state === "unauthorized") return;
    if (this.stopped || code === CLOSE_REFUSED || code === CLOSE_DELETED) {
      this.set({ state: "closed", code, reason });
      return;
    }
    if (reason === "resync") {
      this.timer = setTimeout(() => this.open(), 0);
      return;
    }
    this.failures = wasLive ? 0 : this.failures + 1;
    this.attempt += 1;
    const delay = Math.min(250 * 2 ** (this.attempt - 1), 10_000);
    this.set({ state: "connecting", attempt: this.attempt });
    this.timer = setTimeout(() => this.open(), delay);
    if (this.failures >= AUTH_PROBE_AFTER && this.failures % AUTH_PROBE_AFTER === 0) this.probe();
  }

  /** Is it the token? The session list answers 401 if so (and the gateway signs us out). */
  private probe() {
    this.gw.list().catch((e) => {
      if ((e as { status?: number }).status !== 401 || this.stopped) return;
      this.stopped = true;
      if (this.timer) clearTimeout(this.timer);
      this.ws?.close(1000);
      this.set({ state: "unauthorized" });
    });
  }
}
