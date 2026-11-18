// "Try it on your own code": the one card an account without GitHub sees, after its first
// finished turn (design board 2, "Web: the first run", moment C). Once per account: it belongs
// to the session where it first showed, and "Keep going here" retires it for good.
//
// The edge has no flag for this yet, so the memory is this browser's, keyed per account.
import type { Account } from './auth'
import type { Thread } from './engine/thread'

/** Per account: the session the card belongs to, or done (dismissed). */
export type CardMemo = { session: string } | { done: true }

const KEY = 'frog.connectCard'

/** What tells accounts apart on this browser: the email, else the Google account, else the name. */
export function accountTag(a: Pick<Account, 'email' | 'google' | 'name'>): string {
  return a.email || a.google || a.name || 'account'
}

function all(s: Storage | undefined): Record<string, CardMemo> {
  try { return JSON.parse(s?.getItem(KEY) ?? '{}') ?? {} } catch { return {} }
}

export function loadMemo(s: Storage | undefined, tag: string): CardMemo | null {
  return all(s)[tag] ?? null
}

export function saveMemo(s: Storage | undefined, tag: string, memo: CardMemo) {
  try { s?.setItem(KEY, JSON.stringify({ ...all(s), [tag]: memo })) } catch { /* private mode: it shows again next visit */ }
}

/** A turn in this thread ran to the end (not an error, a stop or an empty wallet), and none is running. */
export function finishedTurn(t: Pick<Thread, 'turns' | 'running'>): boolean {
  return !t.running && t.turns.some((u) => u.reason?.type === 'complete')
}

/** Whether the card shows in `session`, and whether showing it claims the session for it. */
export function connectCard(memo: CardMemo | null, o: { github: boolean; session: string; finished: boolean }): { show: boolean; claim: boolean } {
  const no = { show: false, claim: false }
  if (o.github || (memo && 'done' in memo)) return no
  if (memo) return { show: memo.session === o.session && o.finished, claim: false }
  return o.finished ? { show: true, claim: true } : no
}
