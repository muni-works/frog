// Pay and resume (onboarding funnel, board 3, "C"): once credit is added from the wall, the turn
// that stopped on credit picks up by itself with Op::Continue, once.
//
// - A code: the redeem answer says what was added, so the continue goes at once, no reload.
// - Stripe: Checkout is a full page load that comes back to the bare origin (the edge only
//   accepts an origin as `return`), so the wall leaves a note (wall.ts savePending) and this page
//   reopens the session, polls the balance until the webhook has added the credit, then resumes.
//   If the credit doesn't show within a minute, the wall says so with a Resume button.
// Never on a positive balance alone: a later billing_limit waits for credit added again.
import { useCallback, useEffect, useRef, useState } from 'react'
import type { Account } from '../auth'
import type { Op } from '../cloud/protocol'
import type { Thread } from '../engine/thread'
import { clearPending, peekPending, resumeNote, savePending, shouldResume, stoppedTurn, type Added, type PendingTopUp } from '../wall'

export interface WallResumeDeps {
  /** The open session and its thread. */
  session: string | null
  thread: Thread | null
  send: (session: string, op: Op) => void
  /** The account now (/v1/me), for the Stripe return's polling. */
  fetchMe: (() => Promise<Account>) | null
  onAccount: (a: Account) => void
  /** Opens a session (back from Checkout, which lands on the bare origin). */
  openSession: (id: string) => void
  storage?: Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>
  /** The page's query on load, to tell a paid return (?session_id) from a cancelled one. */
  search?: string
  pollMs?: number
  pollTries?: number
}

export function useWallResume({ session, thread, send, fetchMe, onAccount, openSession, storage, search, pollMs = 2000, pollTries = 30 }: WallResumeDeps) {
  const [added, setAdded] = useState<Added | null>(null)
  const [waiting, setWaiting] = useState<string | null>(null)
  const resumed = useRef(new Set<string>())
  // Read in the initializer (React may call it twice), cleared in the effect (which may run twice).
  const [back] = useState(() => ({ pending: storage ? peekPending(storage) : null, paid: new URLSearchParams(search ?? '').has('session_id') }))

  useEffect(() => {
    const p = back.pending
    if (!p) return
    if (storage) clearPending(storage)
    openSession(p.session)
    if (!back.paid || !fetchMe) return
    setWaiting('Payment received. Waiting for the credit to arrive…')
    let n = 0
    let stop = false
    const again = () => { if (!stop && ++n < pollTries) setTimeout(tick, pollMs); else if (!stop) setWaiting("Payment received, but the credit hasn't shown up yet. It can take a minute.") }
    const tick = () => fetchMe().then((a) => {
      if (stop) return
      onAccount(a)
      if (a.credit_cents > p.before) { setWaiting(null); setAdded({ session: p.session, turn: p.turn, cents: Math.round(a.credit_cents - p.before) }) }
      else again()
    }, again)
    tick()
    return () => { stop = true }
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  const resume = useCallback((id: string, turn: number, cents?: number) => {
    resumed.current.add(`${id}:${turn}`)
    setAdded(null); setWaiting(null)
    send(id, { op: 'continue', note: resumeNote(cents) })
  }, [send])

  useEffect(() => {
    if (!session || !thread || !added || !shouldResume(added, session, thread, resumed.current)) return
    resume(session, added.turn, added.cents)
  }, [session, thread, added, resume])

  return {
    /** The wall's top-up is leaving for Checkout: note what to come back to. */
    leaving(dollars: number, before: number) {
      const turn = thread ? stoppedTurn(thread) : null
      if (!session || turn == null || !storage) return
      const p: PendingTopUp = { session, turn, cents: dollars * 100, before, at: Date.now() }
      savePending(storage, p)
    },
    /** Checkout didn't open: forget the note. */
    stayed() { if (storage) clearPending(storage) },
    /** A code was redeemed from the wall. */
    redeemed(r: { added_cents: number; credit_cents: number }) {
      const turn = thread ? stoppedTurn(thread) : null
      if (session && turn != null && r.added_cents > 0 && r.credit_cents > 0) setAdded({ session, turn, cents: r.added_cents })
    },
    /** What the wall says while the credit is on its way, and a way to resume by hand once it's in. */
    waiting,
    resumeByHand: (credit: number) => {
      const turn = thread ? stoppedTurn(thread) : null
      return session && turn != null && credit > 0 ? () => resume(session, turn) : undefined
    },
  }
}
