// The warning before the wall (onboarding funnel, board 3, "A"): one quiet line under the
// composer once most of the last credit added is spent. Never a modal.
import { useEffect, useState } from 'react'
import { billingHistory, type Account, type CreditRow } from '../auth'
import { aboutTurns, lastAddedCents, leftLine, lowCredit, turnsLine } from '../wall'

/** The newest credit added, from Billing's history, once per key and credit change. */
export function useLastAdded(apiKey: string | undefined, account: Account | null): number | null {
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
  if (!account || !got) return null
  return lastAddedCents(history, account)
}

export function CreditWarning({ account, addedCents, avg, onAdd }: { account: Account | null; addedCents: number | null; avg: number | null; onAdd: () => void }) {
  if (addedCents == null || !lowCredit(account, addedCents)) return null
  const cents = account!.credit_cents
  const n = aboutTurns(cents / 100, avg)
  return (
    <div className="credit-warn" role="status">
      <span className="credit-warn-dot" aria-hidden="true" />
      <span className="credit-warn-text">{leftLine(cents)} of credit left{n != null ? `, ${turnsLine(n)} at your average` : ''}</span>
      <button type="button" className="credit-warn-add" onClick={onAdd}>Add credit</button>
    </div>
  )
}
