// The warning before the wall (onboarding funnel, board 3, "A"): one quiet line under the
// composer once most of the last credit added is spent. Never a modal.
import { useEffect, useState } from 'react'
import { billingHistory, type Account, type CreditRow } from '../auth'
import { aboutTurns, lastAddedCents, leftLine, lowCredit, turnsLine } from '../wall'

/** Billing's credit history (null until it's in, or when it couldn't be read) and the newest
 *  credit added, once per key and credit change. */
export function useCreditHistory(apiKey: string | undefined, account: Account | null): { history: CreditRow[] | null; lastAdded: number | null } {
  const [history, setHistory] = useState<CreditRow[] | null>(null)
  const [got, setGot] = useState(false)
  // A top-up or a code changes the balance upward; fetch again then, not on every debit.
  const [peak, setPeak] = useState(0)
  const credit = account?.credit_cents ?? 0
  useEffect(() => { if (credit > peak) setPeak(credit) }, [credit]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!apiKey || !account) return
    let live = true
    billingHistory(apiKey).then((h) => { if (live) { setHistory(h); setGot(true) } }, () => { if (live) setGot(true) })
    return () => { live = false }
  }, [apiKey, !!account, peak]) // eslint-disable-line react-hooks/exhaustive-deps
  if (!account || !got) return { history: null, lastAdded: null }
  return { history, lastAdded: lastAddedCents(history, account) }
}

/** The newest credit added, from Billing's history. */
export const useLastAdded = (apiKey: string | undefined, account: Account | null) => useCreditHistory(apiKey, account).lastAdded

export function CreditWarning({ account, addedCents, avg, onAdd, onPlans }: { account: Account | null; addedCents: number | null; avg: number | null; onAdd: () => void; onPlans?: () => void }) {
  if (addedCents == null || !lowCredit(account, addedCents)) return null
  const cents = account!.credit_cents
  const n = aboutTurns(cents / 100, avg)
  return (
    <div className="credit-warn" role="status">
      <span className="credit-warn-dot" aria-hidden="true" />
      <span className="credit-warn-text">{leftLine(cents)} of credit left{n != null ? `, ${turnsLine(n)} at your average` : ''}</span>
      {onPlans && !account!.subscription && <button type="button" className="credit-warn-add" onClick={onPlans}>See plans</button>}
      <button type="button" className="credit-warn-add" onClick={onAdd}>Add credit</button>
    </div>
  )
}
