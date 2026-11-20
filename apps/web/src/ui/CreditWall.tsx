// The credit wall (onboarding funnel, board 3, "B"): where the work stopped on an empty wallet,
// in place of the composer. A pause with a receipt, not an error: the work is saved, what the
// session cost, the smallest amount that finishes it, and a code if they have one.
//
// No "Finish on your Mac": the Mac app can't be asked to open a given Frog Cloud session (it has
// no `frog://session/<id>` handler), and a cloud session opened there still runs, and bills, in
// Frog Cloud. A plan first (the plan sheet, frame 5), credit second: a plan bought from here
// comes back to the session, which resumes with a click once the plan shows on the account.
import { useState } from 'react'
import { aboutTurns, cardFeeCents, costLine, leftLine, sessionSpend, turnsLine, WALL_AMOUNTS } from '../wall'
import type { Thread } from '../engine/thread'
import type { Model } from '../models'
import { Coupon } from './Settings'

export interface WallProps {
  thread: Thread
  models: readonly Model[]
  /** The account's average turn cost in dollars; null under five priced turns. */
  avg: number | null
  /** The bearer key, for the inline coupon field; absent on a dev key. */
  apiKey?: string
  /** Leaves for Stripe Checkout with this many dollars; absent where top-ups aren't offered. */
  onTopUp?: (dollars: number) => Promise<void>
  onRedeemed?: (r: { added_cents: number; credit_cents: number }) => void
  /** Credit came back (Stripe returned and the webhook landed, or it hasn't yet): what to say,
   *  and a way to resume by hand when the automatic one couldn't. */
  waiting?: { text: string; onResume?: () => void } | null
  /** The balance now, in cents. Credit back by another route (Billing, a reload after the wait,
   *  a plan window that reset) shows it with a Resume button: a click, never by itself. */
  credit?: number
  /** When `credit` was fetched (ms): only a balance read after the wall appeared counts, not the
   *  one from before the stop that the account still holds for a moment. */
  creditAt?: number
  onResume?: () => void
  /** The plan sheet: offered first, above the credit amounts. */
  onPlans?: () => void
  /** A plan is on and inside its allowance: the turn can resume without credit. */
  planOn?: boolean
}

export function CreditWall({ thread, models, avg, apiKey, onTopUp, onRedeemed, waiting, credit, creditAt = 0, onResume, onPlans, planOn }: WallProps) {
  const [since] = useState(() => Date.now())
  const [amount, setAmount] = useState(WALL_AMOUNTS[0])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [code, setCode] = useState(false)
  const spend = sessionSpend(thread, models)
  const fee = cardFeeCents(amount)
  const pay = () => {
    if (!onTopUp || busy) return
    setBusy(true); setError(null)
    onTopUp(amount).catch((e) => { setBusy(false); setError(e instanceof Error ? e.message : String(e)) })
  }
  return (
    <section className="cardx wall" aria-label="Out of credit">
      <b className="wall-t">You're out of Frog Cloud credit. Your work is saved.</b>
      <div className="det wrap">
        {spend.turns > 0 && <>This session has {spend.dollars != null ? `cost ${costLine(spend.dollars)} over` : 'run'} {spend.turns.toLocaleString('en-US')} turn{spend.turns === 1 ? '' : 's'}. </>}
        Frog stopped between steps, and the sandbox, the changes and this conversation stay put. It picks up from there.
      </div>
      {waiting ? (
        <div className="wall-row" role="status">
          <span className="det wrap" style={{ flex: 1 }}>{waiting.text}</span>
          {waiting.onResume && <button type="button" className="f-btn f-btn--prominent" onClick={waiting.onResume}>Resume</button>}
        </div>
      ) : credit != null && credit > 0 && creditAt > since && onResume ? (
        <div className="wall-row">
          <button type="button" className="f-btn f-btn--prominent" onClick={onResume}>Resume</button>
          <span className="det wrap">You have {leftLine(credit)} of credit now. Frog picks up where it stopped.</span>
        </div>
      ) : planOn && creditAt > since && onResume ? (
        <div className="wall-row">
          <button type="button" className="f-btn f-btn--prominent" onClick={onResume}>Resume</button>
          <span className="det wrap">Your plan is on. Frog picks up where it stopped.</span>
        </div>
      ) : onTopUp && (<>
        {onPlans && (
          <div className="wall-row">
            <button type="button" className="f-btn f-btn--prominent" onClick={onPlans}>See plans</button>
            <span className="det wrap">A plan gives you a weekly amount of work at the same prices. Or add credit:</span>
          </div>
        )}
        <div className="wall-amts" role="radiogroup" aria-label="Amount">
          {WALL_AMOUNTS.map((d) => {
            const n = aboutTurns(d, avg)
            return (
              <button key={d} type="button" role="radio" aria-checked={d === amount} className={`wall-amt${d === amount ? ' on' : ''}`} onClick={() => setAmount(d)}>
                <b>${d}</b>{n != null && <span>{turnsLine(n, d !== WALL_AMOUNTS[0])}</span>}
              </button>
            )
          })}
        </div>
        <div className="wall-row">
          <button type="button" className={`f-btn ${onPlans ? 'f-btn--bordered' : 'f-btn--prominent'}`} disabled={busy} onClick={pay}>{busy ? 'Opening checkout…' : `Add $${amount} and resume`}</button>
          <span className="det wrap">Plus a {fee}¢ card fee. Pay per token, no subscription.</span>
        </div>
        {error && <div role="alert" className="det wrap" style={{ color: 'var(--warn)' }}>Couldn't open checkout ({error}). Try again.</div>}
      </>)}
      {apiKey && (code
        ? <Coupon apiKey={apiKey} focus={1} onRedeemed={onRedeemed} />
        : <div className="wall-row"><button type="button" className="f-btn f-btn--plain f-btn--small wall-code" onClick={() => setCode(true)}>Have a code?</button></div>)}
    </section>
  )
}
