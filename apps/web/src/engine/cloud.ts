import { Gateway, type Connection, type ConnectionState } from '../cloud/client'
import type { Op } from '../cloud/protocol'
import { applySetting, customizableSettings } from '../settings'
import { PreviewHub } from '../preview'
import type { EngineClient } from './client'

/** What this client can do, so the engine offers the model the right tools: questions get a card
 * here (Ask), and preview panes an iframe onto the sandbox's dev server (PreviewHub) only when the
 * gateway serves previews; without them the model isn't offered a preview it can't show. */
// Customize cards (a `permission_request` with a `proposal`), their receipts with Undo, and
// `setting_change` are drawn here (docs/customize-events.md), so the engine may offer them.
// Off until the engine's Customize path passes review: the cards draw, but the engine isn't told
// so and never offers them. Only ever for a session the person is typing in, never one another
// session started (it has no one to click the card).
export const CUSTOMIZE_CAPS = false
// The same for noting on its own (`notes`): the noted line with Undo and Make it a rule draws,
// held off with Customize.
export const NOTES_CAPS = false
export const caps = (previews: boolean, top = true, customize = CUSTOMIZE_CAPS, notes = NOTES_CAPS): Op =>
  ({ op: 'set_client_caps', ask: true, panes: previews, ...(customize && top ? { customize: true } : {}), ...(notes && top ? { notes: true } : {}) })

/** EngineClient over the Frog Cloud gateway: one websocket per subscribed session. */
export class CloudEngine implements EngineClient {
  private conns = new Map<string, Connection>()
  private watchers = new Set<(session: string, s: ConnectionState) => void>()
  /** Ops sent before the session is subscribed (e.g. the first message of a new session). */
  private early = new Map<string, Op[]>()
  private hubs = new Map<string, PreviewHub>()
  /** Sessions another session started (the list's `parent`): no Customize caps for them. */
  private children = new Set<string>()
  /** Whether the gateway serves previews: unknown until the session list first answers. */
  previews: boolean | undefined = undefined

  constructor(readonly gateway: Gateway) {}

  subscribe(session: string, after: number, onEnvelope: Parameters<EngineClient['subscribe']>[2], onReset?: () => void) {
    // The engine's requests to a preview pane are this client's to answer, not the transcript's.
    const deliver: typeof onEnvelope = (env) => {
      if (env.event === 'pane_request') this.preview(session).request(env)
      // A setting this app owns, changed from the conversation (or put back by its Undo).
      if (env.event === 'setting_change') applySetting(env.id, env.value)
      onEnvelope(env)
    }
    const conn = this.gateway.connect(session, { onEnvelope: deliver, onReset, onState: (s) => this.watchers.forEach((w) => w(session, s)) }, after)
    this.conns.set(session, conn)
    conn.send(caps(this.previews === true, !this.children.has(session)))
    conn.send({ op: 'settings', values: customizableSettings() })
    for (const op of this.early.get(session) ?? []) conn.send(op) // Connection queues until its handshake
    this.early.delete(session)
    return () => { conn.close(); if (this.conns.get(session) === conn) this.conns.delete(session) }
  }

  send(session: string, op: Op) {
    const conn = this.conns.get(session)
    if (conn) conn.send(op)
    else this.early.set(session, [...(this.early.get(session) ?? []), op])
  }

  /** What GET /v1/sessions said about previews. On a change, every hub and every open session's
   * engine hears it (the engine re-syncs its tools on a repeated set_client_caps). */
  setPreviews(on: boolean) {
    if (this.previews === on) return
    this.previews = on
    this.hubs.forEach((h) => h.setAvailable(on))
    this.conns.forEach((c, session) => c.send(caps(on, !this.children.has(session))))
  }

  /** What GET /v1/sessions said about who started whom: a child session never gets Customize. */
  setChildren(ids: Iterable<string>) {
    this.children = new Set(ids)
  }

  /** The session's preview panes: what they report and how the engine's requests get answered. */
  preview(session: string): PreviewHub {
    let hub = this.hubs.get(session)
    if (!hub) {
      hub = new PreviewHub((op) => this.send(session, op), (port) => this.gateway.preview(session, port))
      if (this.previews !== undefined) hub.setAvailable(this.previews)
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
