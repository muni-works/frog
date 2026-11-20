// Plans and the meter (docs: "Frog on a phone", frames 2, 3, 5, 6): what the composer's meter
// says, what the plan sheet and the once-only card after a first result say, and the numbers
// behind them. Pure, so the tests load it without Vite.
//
// The words of the plan sheet (frame 5) and the card (frame 6) live in COPY, one place, because
// they aren't signed off yet.
//
// What the numbers are:
// - A plan's weekly amount and how many run at once are the plans' facts (PLAN_FACTS).
// - "Tasks like this one" divides by what this session has cost so far, at list price
//   (wall.ts sessionSpend): close to what was debited, not the ledger. Always said with "about",
//   and left out when there's no finished turn or the cost is zero.
import type { Account, CreditRow } from './auth'
import { costLine, leftLine } from './wall'

/** The three plans: price a month, dollars of work a week, how many sessions run at once. The ids
 *  are the edge's (auth.ts PLANS, POST /v1/billing/subscribe). */
export const PLAN_FACTS = [
  { id: 'pro', name: 'Pro', price: 20, weekly: 5, at: 2 },
  { id: 'max5', name: 'Max', price: 100, weekly: 25, at: 4 },
  { id: 'max', name: 'Ultra', price: 200, weekly: 50, at: 8 },
] as const
export type PlanFact = (typeof PLAN_FACTS)[number]

/** The free credit a new account gets: 25¢, $1 once GitHub is connected. */
export const FREE_CENTS = 25
export const FREE_GITHUB_CENTS = 100

/** "four", "12", "1,600": small counts in words, as the frames say them. */
export function countWord(n: number): string {
  const words = ['no', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten']
  return n >= 0 && n <= 10 ? words[n] : n.toLocaleString('en-US')
}

/** "$5", "$0.50": whole dollars without cents. */
const usd = (d: number) => (Number.isInteger(d) ? `$${d}` : `$${d.toFixed(2)}`)

/** The plan sheet's and the card's words (frames 5 and 6). Not signed off: change them here. */
export const COPY = {
  sheetTitle: (left: string) => `You have ${left} left`,
  sheetTitleOut: "You're out of credit",
  /** `n`: about how many more tasks like this one what's left buys; null leaves that out. */
  sheetLead: (n: number | null) => `${n != null && n >= 1 ? `About ${countWord(n)} more task${n === 1 ? '' : 's'} like this one. ` : ''}A plan gives you a weekly amount of work at the same prices.`,
  planLine: (p: PlanFact) => `${usd(p.weekly)} of work every week, ${p.at} at once`,
  planPrice: (p: PlanFact) => usd(p.price),
  planPer: 'a month',
  getPlan: (p: PlanFact) => `Get ${p.name}, ${usd(p.price)} a month`,
  creditBefore: 'Or ',
  creditLink: 'add credit instead',
  creditAfter: ', from $5. Cancel a plan any time.',
  foot: 'Past your plan you keep going on credit at the same prices.',
  /** Frame 6: what the first task cost out of the free credit, and what Pro covers in the same terms. */
  cardTook: (cost: string, of: string) => `That took ${cost} of your ${of}.`,
  cardPro: (n: number) => `Pro is $20 a month and covers about ${n.toLocaleString('en-US')} task${n === 1 ? '' : 's'} like this one every week.`,
  cardSee: 'See plans',
  cardLater: 'Not now',
}

/** What the meter is drawn from. `signedOut`: the landing, before an account exists. */
export type MeterState =
  | { kind: 'signedOut' }
  | { kind: 'account'; account: Pick<Account, 'credit_cents' | 'subscription'>; addedCents: number }

/** The meter: its words, how full its bar is (0…1), and its accessible name. */
export interface Meter { label: string; fill: number; aria: string; tone: 'go' | 'notice' | 'warn' }

/** The weekly window's share used, else the 5-hour one's; null without a plan or windows. */
export function weekShare(sub: Account['subscription']): { share: number; kind: '5h' | 'weekly' } | null {
  const ws = (sub?.windows ?? []).filter((w) => w.limit > 0)
  const w = ws.find((x) => x.kind === 'weekly') ?? ws[0]
  return w ? { share: Math.max(0, w.used / w.limit), kind: w.kind } : null
}

/** The meter's words (frames 1–3): "25¢ free" signed out, "21¢ left" on credit, "12% of week" on a
 *  plan, "Out of credit" (the credit wall's words) with nothing left. Past a plan's allowance it's
 *  the credit paying: what's left of that. */
export function meter(s: MeterState): Meter {
  const named = (label: string, fill: number, tone: Meter['tone']): Meter => ({ label, fill: Math.max(0, Math.min(1, fill)), aria: `${label}, open plans`, tone })
  if (s.kind === 'signedOut') return named(`${FREE_CENTS}¢ free`, 1, 'go')
  const { account: a, addedCents } = s
  const sub = a.subscription
  const week = sub ? weekShare(sub) : null
  if (sub && week && !sub.over && week.share < 1) {
    const pct = Math.round(week.share * 100)
    return named(`${pct}% of ${week.kind === 'weekly' ? 'week' : '5 hours'}`, week.share, week.share > 0.8 ? 'notice' : 'go')
  }
  if (a.credit_cents <= 0) return named('Out of credit', 0, 'warn')
  const of = Math.max(addedCents, a.credit_cents)
  const fill = of > 0 ? a.credit_cents / of : 0
  return named(`${leftLine(a.credit_cents)} left`, fill, fill <= 0.2 ? 'notice' : 'go')
}

/** On the free credit: no plan, and nothing paid in (no top-up or code in the history). A
 *  pay-per-token account with $12 isn't told "of your 25¢". */
export function onFreeCredit(account: Pick<Account, 'subscription'> | null, history: readonly CreditRow[] | null): boolean {
  if (!account || account.subscription) return false
  if (history == null) return false
  return !history.some((r) => !r.status || r.status === 'succeeded')
}

/** About how many more tasks like this one `cents` buys, from this session's cost so far; null
 *  without a finished turn, or when the cost is zero or unknown. */
export function moreTasks(cents: number, sessionDollars: number | null, finished: boolean): number | null {
  if (!finished || sessionDollars == null || sessionDollars <= 0 || cents <= 0) return null
  return Math.floor(cents / 100 / sessionDollars)
}

/** About how many tasks like this one a plan's weekly amount covers; null as above. */
export function weeklyTasks(p: PlanFact, sessionDollars: number | null): number | null {
  if (sessionDollars == null || sessionDollars <= 0) return null
  return Math.floor(p.weekly / sessionDollars)
}

/** The card's two lines (frame 6), or null when the numbers aren't there to be honest with. */
export function firstResultWords(sessionDollars: number | null, freeCents: number): { took: string; pro: string } | null {
  const n = weeklyTasks(PLAN_FACTS[0], sessionDollars)
  if (n == null || sessionDollars == null) return null
  return { took: COPY.cardTook(costLine(sessionDollars), leftLine(freeCents)), pro: COPY.cardPro(n) }
}

// ---------- the once-only card after a first result (frame 6) ----------
// Once per account, kept in this browser like connectCard.ts: it belongs to the session where it
// first showed, until See plans or Not now retires it for good.

/** Per account: the session the card belongs to, or done (a button was pressed). */
export type PlanCardMemo = { session: string } | { done: true }
const CARD_KEY = 'frog.planCard'

function cards(s: Storage | undefined): Record<string, PlanCardMemo> {
  try { return JSON.parse(s?.getItem(CARD_KEY) ?? '{}') ?? {} } catch { return {} }
}
export const loadPlanCard = (s: Storage | undefined, tag: string): PlanCardMemo | null => cards(s)[tag] ?? null
export function savePlanCard(s: Storage | undefined, tag: string, memo: PlanCardMemo) {
  try { s?.setItem(CARD_KEY, JSON.stringify({ ...cards(s), [tag]: memo })) } catch { /* private mode: it can show again next visit */ }
}

/** Whether the card shows in `session`, and whether showing it claims the session. Only on the
 *  free credit, only once a turn has finished and none is running, and only with a cost to say. */
export function planCard(memo: PlanCardMemo | null, o: { free: boolean; session: string; finished: boolean; running: boolean; cost: number | null }): { show: boolean; claim: boolean } {
  const no = { show: false, claim: false }
  if (!o.free || (memo && 'done' in memo) || o.running || !o.finished || o.cost == null || o.cost <= 0) return no
  if (memo) return { show: memo.session === o.session, claim: false }
  return { show: true, claim: true }
}

// ---------- /pay ----------

/** The plan sheet's own URL: works signed out (through sign-in and back), linkable from anywhere. */
export const PAY_PATH = '/pay'
export const isPayPath = (path: string) => /^\/pay\/?$/.test(path)
