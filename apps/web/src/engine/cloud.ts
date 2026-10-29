import { Gateway, type Connection, type ConnectionState } from '../cloud/client'
import type { Op } from '../cloud/protocol'
import type { EngineClient } from './client'

const CAPS: Op = { op: 'set_client_caps', ask: true, panes: false }

/** EngineClient over the Frog Cloud gateway: one websocket per subscribed session. */
export class CloudEngine implements EngineClient {
  private conns = new Map<string, Connection>()
  private watchers = new Set<(session: string, s: ConnectionState) => void>()
  /** Ops sent before the session is subscribed (e.g. the first message of a new session). */
  private early = new Map<string, Op[]>()

  constructor(readonly gateway: Gateway) {}

  subscribe(session: string, after: number, onEnvelope: Parameters<EngineClient['subscribe']>[2]) {
    const conn = this.gateway.connect(session, { onEnvelope, onState: (s) => this.watchers.forEach((w) => w(session, s)) }, after)
    this.conns.set(session, conn)
    // What this client can do, so the engine offers the model the right tools: questions get a
    // card here (Ask), but preview panes need a webview the web app can't host yet. A terminal
    // the user opens works either way.
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

  /** Connection state changes (connecting, live, refused, closed) for every session. */
  watch(f: (session: string, s: ConnectionState) => void) {
    this.watchers.add(f)
    return () => { this.watchers.delete(f) }
  }
}
