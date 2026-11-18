import { GATEWAY } from './store'
import type { SessionSummary } from './cloud/protocol'

// Funnel events (docs/design/funnel/events.md): the few moments only this app can see, sent to
// the gateway's POST /v1/events, which forwards allow-listed names and values to PostHog. Never
// straight to PostHog, so PostHog never sees this browser or its IP.
//
// Off unless the gateway says so: `account.events` is true only while PostHog is configured on
// the gateway. Signed out, nothing is sent at all, and nothing is stored in this browser (no
// cookie, no id): the gateway takes who it is from the key. Never a prompt, a repo, a branch, a
// PR's name or number, or any text: every property is a word from a fixed list.

/** The words a hand-off's `where` may be (the gateway's allow-list has the same ones). */
export type Where = 'credit_wall' | 'chip' | 'composer' | 'settings' | 'footer' | 'other'

type Props = Record<string, string | number | boolean>
export interface Event { event: string; props: Props }

let on: { key: string } | null = null
/** The last session list seen, by id: the baseline `sessionEvents` diffs against. */
let seen: Map<string, SessionSummary> | null = null

/** Turn events on or off from what the gateway said about this account. A key change starts over. */
export function configureTracking(key: string | null, account: { events?: boolean } | null) {
  const next = key && account?.events === true ? { key } : null
  if (next?.key !== on?.key) seen = null
  on = next
}

export function trackingOn(): boolean { return on !== null }

/** Send one event; never throws, never waits. `keepalive` lets a click that leaves the page land. */
export function track(event: string, props: Props = {}, send: typeof fetch = globalThis.fetch): void {
  if (!on) return
  try {
    void send(`${GATEWAY}/v1/events`, {
      method: 'POST',
      keepalive: true,
      headers: { authorization: `Bearer ${on.key}`, 'content-type': 'application/json' },
      body: JSON.stringify({ event, props }),
    }).catch(() => { /* best effort */ })
  } catch { /* best effort */ }
}

/** What changed between two polls of the session list that the funnel counts: a turn ended
 * (`last_turn` moved on) and a pull request got bound (`pr` went from empty to set). Sessions new
 * to the list count only for a PR, not for turns, since their earlier turns weren't seen here. */
export function sessionEvents(prev: ReadonlyMap<string, SessionSummary>, next: readonly SessionSummary[]): Event[] {
  const out: Event[] = []
  for (const s of next) {
    const p = prev.get(s.id)
    if (p && (s.last_turn ?? 0) > (p.last_turn ?? 0)) out.push({ event: 'turn_finished', props: { client: 'web' } })
    if (p && s.pr && !p.pr) out.push({ event: 'pr_opened', props: { client: 'web' } })
  }
  return out
}

/** Feed each fresh session list here (store.ts). The first list after sign-in is only a baseline. */
export function noteSessions(list: readonly SessionSummary[], send?: typeof fetch) {
  if (!on) return
  if (seen) for (const e of sessionEvents(seen, list)) track(e.event, e.props, send)
  seen = new Map(list.map((s) => [s.id, s]))
}

/** The hand-off a click lands on: a link to the Mac app (`/mac`, `/download`), and where it sits,
 * from the nearest container that names itself. Null for any other click. */
export function handoffOf(target: Element | null): Where | null {
  const a = target?.closest?.('a[href]')
  if (!a) return null
  const path = (a.getAttribute('href') ?? '').replace(/^https?:\/\/[^/]+/, '').split(/[?#]/)[0]
  if (path !== '/mac' && path !== '/download') return null
  if (a.closest('[data-chip]')) return 'chip'
  if (a.closest('[aria-label="Out of credit"]')) return 'credit_wall'
  if (a.closest('.cz')) return 'composer'
  if (a.closest('.settings-main, .set-row')) return 'settings'
  if (a.closest('.foot-links')) return 'footer'
  return 'other'
}

/** One click listener for every web → Mac hand-off, so the cards don't each need wiring. */
export function listenForHandoffs(doc: Document = document) {
  doc.addEventListener('click', (e) => {
    const where = handoffOf(e.target instanceof Element ? e.target : null)
    if (where) track('handoff_clicked', { from: 'web', to: 'mac', where })
  }, { capture: true })
}
