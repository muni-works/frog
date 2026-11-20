// The credit wall (onboarding funnel, board 3): what the warning, the wall card and the resume
// after paying read off the account and the threads this browser holds. Pure, so the tests load
// it without Vite.
//
// What the numbers are, and what they aren't:
// - A turn's cost is its `usage` at the model's list price from /v1/models (usage.ts turnCost),
//   the same number the turn footer shows. The edge has no per-turn or per-session spend route,
//   and background model calls (gists, titles) aren't in a turn's usage, so this is close to what
//   was debited, not the ledger.
// - "About N turns" averages the priced Frog Cloud turns of every session this browser holds, so
//   it's this account's own turns, as far as this browser has seen them.
import type { Account, CreditRow } from './auth'
import type { Thread } from './engine/thread'
import { currentId, idOf, type Model } from './models'
import { turnCost } from './usage'

type Turn = Thread['turns'][number]

/** Turns needed before "about N turns" shows: fewer is a guess, not an average. */
export const MIN_TURNS = 5
/** The warning shows once this much of the last credit added is spent. */
export const WARN_SPENT = 0.8
/** The wall's amounts: the board's four, each one the edge sells (auth.ts TOP_UPS). */
export const WALL_AMOUNTS = [5, 10, 25, 100]

/** A turn's cost in dollars, or null when it made no model call or its model has no prices. */
export function costOf(t: Turn, models: readonly Model[]): number | null {
  const u = t.usage
  if (!u || u.model_calls <= 0) return null
  const id = idOf(u.model ?? null)
  const m = models.find((x) => currentId(x.id) === id)
  return turnCost(u, m)?.total ?? null
}

/** What this session has cost so far and over how many turns. `dollars` is null when no turn
 *  could be priced; `turns` counts every turn that called the model. */
export function sessionSpend(t: Thread, models: readonly Model[]): { dollars: number | null; turns: number } {
  let dollars: number | null = null
  let turns = 0
  for (const turn of t.turns) {
    if (!turn.usage || turn.usage.model_calls <= 0) continue
    turns++
    const c = costOf(turn, models)
    if (c != null) dollars = (dollars ?? 0) + c
  }
  return { dollars, turns }
}

/** The average cost of a turn across these threads, or null under MIN_TURNS priced turns. Free
 *  turns (a local model, a zero price) aren't counted: they say nothing about what credit buys. */
export function averageTurn(threads: readonly Thread[], models: readonly Model[]): number | null {
  let sum = 0
  let n = 0
  for (const t of threads) for (const turn of t.turns) {
    const c = costOf(turn, models)
    if (c == null || c <= 0) continue
    sum += c
    n++
  }
  return n >= MIN_TURNS ? sum / n : null
}

/** About how many turns `dollars` buys at `avg` a turn; null without an average. */
export function aboutTurns(dollars: number, avg: number | null): number | null {
  if (avg == null || avg <= 0 || dollars <= 0) return null
  return Math.floor(dollars / avg)
}

/** "about 80 turns", "about 1,600", "about 1 turn". `short` drops the noun (the amount tiles). */
export function turnsLine(n: number, short = false): string {
  if (n < 1) return short ? 'under 1' : 'less than a turn'
  const num = n.toLocaleString('en-US')
  return short ? `about ${num}` : `about ${num} turn${n === 1 ? '' : 's'}`
}

/** "20¢", "$4.12": what's left, as the warning says it. */
export function leftLine(cents: number): string {
  if (cents < 1) return 'Less than 1¢'
  return cents < 100 ? `${Math.floor(cents)}¢` : `$${(Math.floor(cents) / 100).toFixed(2)}`
}

/** "83¢", "$1.84", "<1¢". */
export function costLine(dollars: number): string {
  if (dollars < 0.01) return '<1¢'
  return dollars < 1 ? `${Math.round(dollars * 100)}¢` : `$${dollars.toFixed(2)}`
}

/** The credit the warning measures against: the newest credit added (a top-up or a code), else
 *  the free credit (25¢, $1 once GitHub is connected). The edge lists no grants and has no
 *  "credit at the last top-up" field, so this is the closest honest denominator. */
export function lastAddedCents(history: readonly CreditRow[] | null, account: Pick<Account, 'handle'>): number {
  const row = history?.find((r) => !r.status || r.status === 'succeeded')
  const cents = row ? (row.amount_micro_usd != null ? row.amount_micro_usd / 1e4 : row.added_cents ?? 0) : 0
  return cents > 0 ? cents : account.handle ? 100 : 25
}

/** The quiet warning: credit is left, but WARN_SPENT of the last credit added is gone. Not on a
 *  plan that's still inside its allowance (credit isn't what's paying). */
export function lowCredit(account: Account | null, addedCents: number): boolean {
  if (!account || account.credit_cents <= 0) return false
  if (account.subscription && !account.subscription.over) return false
  // Rounded to a hundredth of a cent, so "exactly 80% spent" counts (0.8 isn't exact in floats).
  return Math.round(account.credit_cents * 100) <= Math.round(addedCents * (1 - WARN_SPENT) * 100)
}

/** The edge's card fee on a top-up (zest edge/src/stripe.ts cardFeeCents: 2.9% + 30¢, charged
 *  on top so the credit bought is the credit got). */
export function cardFeeCents(dollars: number): number {
  const cents = Math.round(dollars * 100)
  return Math.ceil((cents + 30) / (1 - 0.029)) - cents
}

// ---------- resuming ----------

const NOTE = /^<resumed after (?:\$(\d+\.\d\d) of )?(Frog Cloud credit was added|a Frog Cloud plan started); [^>]*; continue where you left off>$/

/** What Op::Continue tells the model when credit was added: its own note, so the model knows
 *  why it stopped. The transcript shows it as one line (resumedLine), not a message. Without an
 *  amount (resumed by hand, the amount unknown) it says credit was added. */
export function resumeNote(addedCents?: number, plan = false): string {
  if (plan) return '<resumed after a Frog Cloud plan started; your previous turn stopped when credit ran out, between steps; continue where you left off>'
  const amount = addedCents && addedCents > 0 ? `$${(addedCents / 100).toFixed(2)} of ` : ''
  return `<resumed after ${amount}Frog Cloud credit was added; your previous turn stopped when credit ran out, between steps; continue where you left off>`
}

/** The one line a resumed turn shows in place of its input, or null for any other input. */
export function resumedLine(input: string): string | null {
  const m = input.match(NOTE)
  if (!m) return null
  if (m[2].startsWith('a Frog Cloud plan')) return 'Plan started. Frog picked up where it stopped.'
  return m[1] ? `$${m[1]} added. Frog picked up where it stopped.` : 'Credit added. Frog picked up where it stopped.'
}

/** The turn the wall is for: the last one, when it ended on money (`billing_limit`, or the edge's
 *  402 that old logs still hold, as store.ts outOfCredits reads it). */
export function stoppedTurn(t: Thread): number | null {
  const last = t.turns[t.turns.length - 1]
  if (!last || t.running || !last.reason) return null
  const r = last.reason
  const money = r.type === 'billing_limit' || (r.type === 'error' && /insufficient_credit|out_of_credits|402/.test(JSON.stringify((r as { error?: unknown }).error ?? '')))
  return money ? last.turn : null
}

/** A top-up left for Stripe from the wall: Checkout comes back to the bare origin, so this is
 *  how the page knows which session to open and resume. */
export interface PendingTopUp { session: string; turn: number; cents: number; before: number; at: number; /** A plan, not credit: reopen the session, no polling for credit. */ plan?: true }

const PENDING_KEY = 'frog.wallTopUp'
/** A Checkout older than this isn't the one this page is coming back from. */
export const PENDING_TTL_MS = 60 * 60_000

export function savePending(s: Pick<Storage, 'setItem'>, p: PendingTopUp) {
  try { s.setItem(PENDING_KEY, JSON.stringify(p)) } catch { /* private mode: no auto-resume */ }
}

/** Reads it without clearing it (safe to call twice, as React's StrictMode does with state
 *  initializers); null when absent, malformed or stale. */
export function peekPending(s: Pick<Storage, 'getItem'>, now = Date.now()): PendingTopUp | null {
  let raw: string | null = null
  try { raw = s.getItem(PENDING_KEY) } catch { return null }
  if (!raw) return null
  try {
    const p = JSON.parse(raw) as PendingTopUp
    if (typeof p.session !== 'string' || typeof p.turn !== 'number' || typeof p.cents !== 'number' || typeof p.before !== 'number') return null
    return now - p.at <= PENDING_TTL_MS ? p : null
  } catch { return null }
}

export function clearPending(s: Pick<Storage, 'removeItem'>) {
  try { s.removeItem(PENDING_KEY) } catch { /* nothing to clear */ }
}

/** Reads and clears it. */
export function takePending(s: Pick<Storage, 'getItem' | 'removeItem'>, now = Date.now()): PendingTopUp | null {
  const p = peekPending(s, now)
  clearPending(s)
  return p
}

/** Credit added from the wall, waiting to resume its session's stopped turn. */
export interface Added { session: string; turn: number; cents: number }

/** Whether to send the continue now: credit was added from the wall for this session's stopped
 *  turn, that turn is still the stopped one, and it hasn't been resumed before. Never on a
 *  positive balance alone: a later billing_limit (a new turn) waits for a new top-up. */
export function shouldResume(added: Added | null, session: string, t: Thread, resumed: ReadonlySet<string>): boolean {
  if (!added || added.session !== session) return false
  const turn = stoppedTurn(t)
  if (turn == null || turn !== added.turn) return false
  return !resumed.has(`${session}:${turn}`)
}
