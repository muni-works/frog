import { Gateway, type Connection, type ConnectionState } from '../cloud/client'
import type { Op } from '../cloud/protocol'
import { PreviewHub } from '../preview'
import type { EngineClient } from './client'

const CAPS: Op = { op: 'set_client_caps', ask: true, panes: true }

/** EngineClient over the Frog Cloud gateway: one websocket per subscribed session. */
export class CloudEngine implements EngineClient {
  private conns = new Map<string, Connection>()
  private watchers = new Set<(session: string, s: ConnectionState) => void>()
  /** Ops sent before the session is subscribed (e.g. the first message of a new session). */
  private early = new Map<string, Op[]>()
  private hubs = new Map<string, PreviewHub>()

  constructor(readonly gateway: Gateway) {}

  subscribe(session: string, after: number, onEnvelope: Parameters<EngineClient['subscribe']>[2], onReset?: () => void) {
    // The engine's requests to a preview pane are this client's to answer, not the transcript's.
    const deliver: typeof onEnvelope = (env) => {
      if (env.event === 'pane_request') this.preview(session).request(env)
      onEnvelope(env)
    }
    const conn = this.gateway.connect(session, { onEnvelope: deliver, onReset, onState: (s) => this.watchers.forEach((w) => w(session, s)) }, after)
    this.conns.set(session, conn)
    // What this client can do, so the engine offers the model the right tools: questions get a
    // card here (Ask), and preview panes an iframe onto the sandbox's dev server (PreviewHub).
    conn.send(CAPS)
    for (const op of this.early.get(session) ?? []) conn.send(op) // Connection queues until its handshake
    this.early.delete(session)
    return () => { conn.close(); if (this.conns.get(session) === conn) this.conns.delete(session) }
  }

  send(session: string, op: Op) {
    const conn = this.conns.get(session)
    if (conn) conn.send(op)
    else this.early.set(session, [...(this.early.get(session) ?? []), op])
  }

  /** The session's preview panes: what they report and how the engine's requests get answered. */
  preview(session: string): PreviewHub {
    let hub = this.hubs.get(session)
    if (!hub) {
      hub = new PreviewHub((op) => this.send(session, op), (port) => this.gateway.preview(session, port))
      this.hubs.set(session, hub)
    }
    return hub
  }

  /** Connection state changes (connecting, live, refused, closed) for every session. */
  watch(f: (session: string, s: ConnectionState) => void) {
    this.watchers.add(f)
    return () => { this.watchers.delete(f) }
  }
}
