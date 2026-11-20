// Tap the meter: the plan sheet (frame 5). On free credit, what's left, about how many more tasks
// like this one it buys, the three plans and one button for the picked one (the existing
// subscribe path, Stripe Checkout), and credit as the second choice. On a plan, this week and
// this 5 hours, when each resets, the credit, and Billing. Signed out, the same plans behind
// Sign in. Also at /pay. The words are plans.ts COPY.
import { useState } from 'react'
import type { Account, Provider } from '../auth'
import { friendly } from '../cloud/client'
import { barTone, canCompact } from '../usage'
import { leftLine } from '../wall'
import { COPY, FREE_CENTS, FREE_GITHUB_CENTS, PLAN_FACTS, type PlanFact } from '../plans'
import { Sheet } from './Sheet'

export interface PlanSheetProps {
  /** Null signed out (or while a signed-in account loads: `loading`). */
  account: Account | null
  loading?: boolean
  /** About how many more tasks like this one what's left buys; null leaves the line out. */
  more: number | null
  onClose: () => void
  /** Leaves for Stripe Checkout; absent where subscribing isn't offered (the dev key). */
  onSubscribe?: (plan: string) => Promise<void>
  /** The existing credit flow (Billing's Add credit, or the wall's amounts). */
  onCredit: () => void
  onBilling: () => void
  /** Signed out: sign in, then back to this sheet. */
  onSignIn?: (provider: Provider) => void
  /** The open session's context, on a phone, where the composer's ring popover isn't. */
  context?: { used: number | null; window: number; onCompact?: () => void; compacting?: boolean }
}

export function PlanSheet(p: PlanSheetProps) {
  const sub = p.account?.subscription
  return (
    <Sheet label={sub ? 'Your plan' : 'Plans'} onClose={p.onClose} className="plan-sheet">
      {({ close, closeThen }) => (<>
        {sub ? <OnPlan {...p} sub={sub} onBilling={() => closeThen(p.onBilling)} /> : <Pick {...p} onCredit={() => closeThen(p.onCredit)} />}
        {p.context && p.context.window > 0 && <Context {...p.context} onCompact={p.context.onCompact && (() => { p.context!.onCompact!(); close() })} />}
      </>)}
    </Sheet>
  )
}

function Pick({ account, loading, more, onSubscribe, onCredit, onSignIn }: PlanSheetProps) {
  const [picked, setPicked] = useState<PlanFact>(PLAN_FACTS[0])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const left = account?.credit_cents ?? (FREE_CENTS)
  const go = () => {
    if (!account) { if (!loading) onSignIn?.('github'); return }
    if (!onSubscribe || busy) return
    setBusy(true); setError(null)
    onSubscribe(picked.id).catch((e) => { setBusy(false); setError(friendly(e)) })
  }
  return (<>
    <h2 className="sheet-head ps-title">{!account ? (loading ? 'Plans' : `${leftLine(FREE_CENTS)} free to start`) : left > 0 ? COPY.sheetTitle(leftLine(left)) : COPY.sheetTitleOut}</h2>
    <p className="det wrap ps-lead">{!account ? `${loading ? '' : `${leftLine(FREE_GITHUB_CENTS)} with GitHub. `}${COPY.sheetLead(null)}` : COPY.sheetLead(more)}</p>
    <div className="ps-plans" role="radiogroup" aria-label="Plans">
      {PLAN_FACTS.map((x) => (
        <button key={x.id} type="button" role="radio" aria-checked={x.id === picked.id} className={`ps-plan${x.id === picked.id ? ' on' : ''}`} onClick={() => setPicked(x)}>
          <span className="ps-l"><b>{x.name}</b><span>{COPY.planLine(x)}</span></span>
          <span className="ps-p">{COPY.planPrice(x)} <span>{COPY.planPer}</span></span>
        </button>
      ))}
    </div>
    <button type="button" className="f-btn f-btn--prominent ps-go" disabled={busy || loading || (!!account && !onSubscribe)} onClick={go}>
      {busy ? 'Opening checkout…' : loading ? 'Loading your account…' : !account ? `Sign in with GitHub to get ${picked.name}` : COPY.getPlan(picked)}
    </button>
    {!account && !loading && onSignIn && <p className="det ps-credit">Or <button type="button" className="ps-link" onClick={() => onSignIn('google')}>sign in with Google</button>. You come back here after.</p>}
    {error && <div role="alert" className="det wrap" style={{ color: 'var(--warn)', textAlign: 'center' }}>Couldn't open checkout ({error}). Try again.</div>}
    {account && <p className="det ps-credit">{COPY.creditBefore}<button type="button" className="ps-link" onClick={onCredit}>{COPY.creditLink}</button>{COPY.creditAfter}</p>}
    <p className="ps-foot">{COPY.foot}</p>
  </>)
}

const when = (iso: string, kind: '5h' | 'weekly') => new Date(iso).toLocaleString(undefined, kind === '5h' ? { hour: 'numeric', minute: '2-digit' } : { weekday: 'long', hour: 'numeric', minute: '2-digit' })

function OnPlan({ account, sub, onBilling }: PlanSheetProps & { sub: NonNullable<Account['subscription']> }) {
  return (<>
    <h2 className="sheet-head ps-title">{sub.name}</h2>
    {sub.over && <p className="det wrap ps-lead">Past your plan for now, so turns are paying from credit at the same prices.</p>}
    {[...sub.windows].filter((w) => w.limit > 0).sort((a, b) => (a.kind === 'weekly' ? 0 : 1) - (b.kind === 'weekly' ? 0 : 1)).map((w) => {
      const f = Math.min(1, w.used / w.limit)
      return (
        <div key={w.kind} className="ps-win">
          <div className="ps-win-h"><b>{w.kind === 'weekly' ? 'This week' : 'This 5 hours'}</b><span className="det">{Math.round(f * 100)}% used{w.resets_at ? `, resets ${when(w.resets_at, w.kind)}` : ''}</span></div>
          <div className="ctx-bar" role="img" aria-label={`${w.kind === 'weekly' ? 'This week' : 'This 5 hours'}, ${Math.round(f * 100)}% used`}><span style={{ width: `${f * 100}%`, background: barTone(f) }} /></div>
        </div>
      )
    })}
    <div className="ps-row"><span>Credit</span><span className="det">{leftLine(Math.max(0, account?.credit_cents ?? 0))}</span></div>
    <button type="button" className="f-btn f-btn--bordered ps-go" onClick={onBilling}>Billing</button>
    <p className="ps-foot">{COPY.foot}</p>
  </>)
}

function Context({ used, window, onCompact, compacting }: NonNullable<PlanSheetProps['context']>) {
  const x = used && window ? Math.min(1, used / window) : 0
  return (
    <div className="ps-win ps-ctx">
      <div className="ps-win-h"><b>Context</b><span className="det">{(used ?? 0).toLocaleString()} of {window.toLocaleString()} tokens, {Math.round(x * 100)}%</span></div>
      <div className="ctx-bar"><span style={{ width: `${x * 100}%`, background: barTone(x) }} /></div>
      {(compacting || (onCompact && canCompact(used, window))) && (
        <button type="button" className="f-btn f-btn--bordered ps-compact" disabled={compacting || !onCompact} onClick={onCompact}>{compacting ? 'Compacting…' : 'Compact now'}</button>
      )}
    </div>
  )
}
