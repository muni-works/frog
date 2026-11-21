import { Gateway, type Connection, type ConnectionState } from '../cloud/client'
import type { Op } from '../cloud/protocol'
import { applySetting, customizableSettings, onSettings } from '../settings'
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
const settingsOp = (): Op => ({ op: 'settings', values: customizableSettings(), client: CLIENT_ID })

export const caps = (previews: boolean, top = true, customize = CUSTOMIZE_CAPS, notes = NOTES_CAPS): Op =>
  ({ op: 'set_client_caps', ask: true, panes: previews, ...(customize && top ? { customize: true } : {}), ...(notes && top ? { notes: true } : {}) })

/** This page's id on the ops that say which app sent them (`submit`, `settings`, `detach`):
 * several apps can share a cloud session, and its engine keeps each one's settings apart
 * (review 4, item 5). One per page load. */
export const CLIENT_ID = `web-${Math.random().toString(36).slice(2, 10)}`

/** EngineClient over the Frog Cloud gateway: one websocket per subscribed session. */
export class CloudEngine implements EngineClient {
  private conns = new Map<string, Connection>()
  private watchers = new Set<(session: string, s: ConnectionState) => void>()
  /** Ops sent before the session is subscribed (e.g. the first message of a new session). */
  private early = new Map<string, Op[]>()
  private hubs = new Map<string, PreviewHub>()
  /** Sessions known to be the person's own: listed with no `parent`, or created here. Unknown
   * parentage (not listed yet) is a child's: no Customize or notes caps until it's known. */
  private tops = new Set<string>()
  /** Whether the gateway serves previews: unknown until the session list first answers. */
  previews: boolean | undefined = undefined

  constructor(readonly gateway: Gateway) {
    // A setting the engine reads changed here (auto-note): every open session hears it.
    onSettings(() => this.conns.forEach((c) => c.send(settingsOp())))
  }

  subscribe(session: string, after: number, onEnvelope: Parameters<EngineClient['subscribe']>[2], onReset?: () => void) {
    // The engine's requests to a preview pane are this client's to answer, not the transcript's.
    const deliver: typeof onEnvelope = (env) => {
      if (env.event === 'pane_request') this.preview(session).request(env)
      // A setting this app owns, changed from the conversation (or put back by its Undo).
      // One typed in another app is that app's to apply.
      if (env.event === 'setting_change' && (!env.client || env.client === CLIENT_ID)) applySetting(env.id, env.value)
      onEnvelope(env)
    }
    // Told on every welcome, a reconnect too: it may reach a new engine (a woken sandbox).
    const greet = (): Op[] => [caps(this.previews === true, this.tops.has(session)), settingsOp()]
    const conn = this.gateway.connect(session, { onEnvelope: deliver, onReset, greet, onState: (s) => this.watchers.forEach((w) => w(session, s)) }, after)
    this.conns.set(session, conn)
    for (const op of this.early.get(session) ?? []) conn.send(op) // Connection queues until its handshake
    this.early.delete(session)
    return () => {
      // Its settings stop counting for the session's engine.
      conn.send({ op: 'detach', client: CLIENT_ID })
      conn.close()
      if (this.conns.get(session) === conn) this.conns.delete(session)
    }
  }

  send(session: string, op: Op) {
    // A typed message says which app it's from: a setting change is planned only for one the
    // app applies.
    if (op.op === 'submit' && op.typed) op = { ...op, client: CLIENT_ID }
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
    this.conns.forEach((c, session) => c.send(caps(on, this.tops.has(session))))
  }

  /** What GET /v1/sessions said about who started whom: only a session listed with no parent is
   * the person's own. An open session whose standing changed hears its caps again. */
  setParents(sessions: Iterable<{ id: string; parent?: string | null }>) {
    const next = new Set(this.created)
    for (const s of sessions) if (!s.parent) next.add(s.id)
    const was = this.tops
    this.tops = next
    this.conns.forEach((c, session) => {
      if (was.has(session) !== next.has(session)) c.send(caps(this.previews === true, next.has(session)))
    })
  }

  /** Sessions this client created for the person (the composer's new session): top-level. */
  private created = new Set<string>()
  markCreated(session: string) {
    this.created.add(session)
    if (!this.tops.has(session)) this.setParents([...this.tops].map((id) => ({ id })).concat({ id: session }))
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
