import { PLANS, TOP_UPS } from '../auth'
import { useEffect, useMemo, useState } from 'react'
import { notifyOn, notifySupported, setNotify } from '../alerts'
import { API, firstName, type Account } from '../auth'
import type { Model } from '../models'
import type { SessionSummary } from '../cloud/protocol'

export interface Command { id: string; label: string; hint?: string; run: () => void }

export function Palette({ commands, sessions, onOpen, onClose, text }: { commands: Command[]; sessions: SessionSummary[]; onOpen: (id: string) => void; onClose: () => void; text?: (id: string) => string }) {
  const [q, setQ] = useState('')
  const [hi, setHi] = useState(0)
  const items = useMemo(() => {
    const needle = q.trim().toLowerCase()
    const named = [...commands, ...sessions.map((s) => ({ id: s.id, label: s.title, hint: s.repo.split('/')[1] ?? 'No repo', run: () => onOpen(s.id) }))]
      .filter((c) => c.label.toLowerCase().includes(needle))
    // Sessions whose loaded conversation mentions it, with the line it's on.
    const said: Command[] = needle.length < 3 || !text ? [] : sessions.flatMap((s) => {
      if (named.some((c) => c.id === s.id)) return []
      const body = text(s.id)
      const at = body.toLowerCase().indexOf(needle)
      if (at < 0) return []
      const line = body.slice(Math.max(0, body.lastIndexOf('\n', at) + 1), body.indexOf('\n', at) < 0 ? undefined : body.indexOf('\n', at)).trim()
      return [{ id: `t-${s.id}`, label: s.title, hint: line.length > 60 ? line.slice(0, 57) + '…' : line, run: () => onOpen(s.id) }]
    })
    return [...named, ...said]
  }, [q, commands, sessions, onOpen, text])
  const run = (c?: Command) => { if (!c) return; onClose(); c.run() }
  return (
    <div className="scrim" onMouseDown={onClose}>
      <div className="cardx palette" role="dialog" aria-label="Command palette" onMouseDown={(e) => e.stopPropagation()}>
        <input className="pal-in" autoFocus value={q} placeholder="Search sessions and commands" aria-label="Search"
          onChange={(e) => { setQ(e.target.value); setHi(0) }}
          onKeyDown={(e) => {
            if (e.key === 'Escape') onClose()
            if (e.key === 'ArrowDown') { e.preventDefault(); setHi(Math.min(hi + 1, items.length - 1)) }
            if (e.key === 'ArrowUp') { e.preventDefault(); setHi(Math.max(hi - 1, 0)) }
            if (e.key === 'Enter') run(items[hi])
          }} />
        <div className="pal-list">
          {items.length === 0 && <div className="det" style={{ padding: 14 }}>Nothing matches.</div>}
          {items.map((c, i) => (
            <button key={c.id} type="button" className={`row pick ${i === hi ? 'on' : ''}`} onMouseEnter={() => setHi(i)} onClick={() => run(c)}>
              <span style={{ flex: 1 }}>{c.label}</span><span className="det">{c.hint}</span>
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}

/** "$22.04 credit": what's left to spend on tokens. */
export function creditLine(a: Account | null) {
  if (!a) return ''
  return `${dollars(a.credit_cents / 100)} credit`
}

export function dollars(d: number) {
  return d > 0 && d < 0.01 ? '<$0.01' : `$${d.toFixed(2)}`
}

/** The plan and its allowance, or (without one) the plans to pick from. */
function Subscription({ account, onSubscribe }: { account: Account | null; onSubscribe?: (plan: string) => Promise<void> }) {
  const [busy, setBusy] = useState<string | null>(null)
  const sub = account?.subscription
  if (sub) return (
    <div className="bill-card">
      <div className="bill-h"><b>{sub.name}</b>{sub.over ? <span className="bill-over">Using credit</span> : <span className="det">Included allowance</span>}</div>
      {sub.windows.map((w) => {
        const f = w.limit ? Math.min(1, w.used / w.limit) : 0
        return (
          <div key={w.kind} className="allow">
            <div className="allow-h"><span>{w.kind === '5h' ? 'This 5 hours' : 'This week'}</span><span className="det">{Math.round(f * 100)}% · resets {new Date(w.resets_at).toLocaleString(undefined, w.kind === '5h' ? { hour: 'numeric', minute: '2-digit' } : { weekday: 'short' })}</span></div>
            <div className="ctx-bar"><span style={{ width: `${f * 100}%`, background: f >= 1 ? 'var(--warn)' : f > 0.8 ? 'var(--notice)' : 'var(--frog)' }} /></div>
          </div>
        )
      })}
      <a className="det" href={`${API}/billing`} target="_blank" rel="noreferrer">Change or cancel your plan</a>
    </div>
  )
  return (
    <div className="bill-card">
      <div className="bill-h"><b>Usage pricing</b><span className="det">No subscription</span></div>
      <div className="det wrap">Subscribe for an included allowance every 5 hours and every week. Past it, you keep going on credit at usage prices.</div>
      {onSubscribe && (
        <div className="plans">
          {PLANS.map((p) => (
            <button key={p.id} type="button" className="plan-pick" disabled={!!busy}
              onClick={() => { setBusy(p.id); onSubscribe(p.id).catch(() => setBusy(null)) }}>
              <b>{p.name}</b><span className="plan-price">${p.price}<span className="det">/mo</span></span><span className="det">{busy === p.id ? 'Opening Stripe…' : p.blurb}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

/** Add credit: pick an amount, then Stripe Checkout. */
function TopUp({ onTopUp }: { onTopUp: (dollars: number) => Promise<void> }) {
  const [amount, setAmount] = useState(TOP_UPS[1])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  return (
    <div className="topup">
      <b>Add credit</b>
      <div className="topup-amts" role="radiogroup" aria-label="Amount">
        {TOP_UPS.map((d) => <button key={d} type="button" role="radio" aria-checked={amount === d} className={amount === d ? 'on' : ''} onClick={() => setAmount(d)}>${d}</button>)}
      </div>
      <button type="button" className="f-btn f-btn--prominent" disabled={busy} style={{ justifyContent: 'center' }}
        onClick={() => { setBusy(true); setError(null); onTopUp(amount).catch((e) => { setBusy(false); setError(e instanceof Error ? e.message : String(e)) }) }}>
        {busy ? 'Opening Stripe…' : `Add $${amount}`}
      </button>
      {error && <div className="det" style={{ color: 'var(--warn)' }}>Couldn't start checkout ({error}). Try again.</div>}
      <div className="det wrap">Paid through Stripe. Credit doesn't expire.</div>
    </div>
  )
}

const tabs = ['Account', 'Billing'] as const

export function Settings({ account, models = [], onSignOut, onClose, onTopUp, onSubscribe }: { account: Account | null; models?: Model[]; onSignOut: () => void; onClose: () => void; onTopUp?: (dollars: number) => Promise<void>; onSubscribe?: (plan: string) => Promise<void> }) {
  const [tab, setTab] = useState<(typeof tabs)[number]>('Account')
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [onClose])
  return (
    <div className="scrim" onMouseDown={onClose}>
      <div className="cardx settings" role="dialog" aria-label="Settings" onMouseDown={(e) => e.stopPropagation()}>
        <nav className="set-nav">
          <b style={{ padding: '4px 8px 10px', fontSize: 15 }}>Settings</b>
          {tabs.map((t) => <button key={t} type="button" className={`row ${t === tab ? 'on' : ''}`} onClick={() => setTab(t)}>{t}</button>)}
        </nav>
        <div className="set-body">
          <button type="button" className="f-btn f-btn--plain set-x" aria-label="Close" onClick={onClose}>✕</button>
          {tab === 'Account' && (<>
            <h2>Account</h2>
            <div className="f-account">
              <span className="mark" style={{ width: 28, height: 28 }} />
              <div className="grow"><div className="name"><b>{account?.name ?? firstName(account) ?? 'Signed in'}</b>{account?.handle && <span className="f-badge">GitHub</span>}</div><div className="detail">{[account?.handle && `@${account.handle}`, account?.email].filter(Boolean).join(' · ')}</div></div>
              <div className="acts"><button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={onSignOut}>Sign out</button></div>
            </div>
            <p className="det wrap">Cloud sessions belong to your account, so they show up on every device you sign in on.</p>
            <div className="set-row"><span style={{ flex: 1 }}>Devices and keys</span><a href={`${API}/account`} target="_blank" rel="noreferrer">Manage</a></div>
            {notifySupported() && <Notify />}
          </>)}
          {tab === 'Billing' && (<>
            <h2>Billing</h2>
            <Subscription account={account} onSubscribe={onSubscribe} />
            <div className="bill-card">
              <div className="bill-h"><b>Usage credit</b><b className="num">{creditLine(account)}</b></div>
              <div className="det wrap">{account?.subscription
                ? account.subscription.over ? 'Your plan’s allowance is used up, so turns are paying from credit at the prices below until it resets.' : 'Used only past your plan’s allowance, at the prices below.'
                : 'Each turn pays from credit at the model’s prices below.'}</div>
              {onTopUp && <TopUp onTopUp={onTopUp} />}
            </div>
            {models.length > 0 && (
              <div className="set-prices">
                <div className="set-price-h"><span>Model</span><span>Input</span><span>Cached</span><span>Output</span></div>
                {models.map((m) => (
                  <div key={m.id} className="set-price">
                    <span>{m.id}</span><span>{perM(m.input)}</span><span>{perM(m.cached)}</span><span>{perM(m.output)}</span>
                  </div>
                ))}
                <div className="det">Per million tokens.</div>
              </div>
            )}
          </>)}
        </div>
      </div>
    </div>
  )
}

function Notify() {
  const [on, setOn] = useState(notifyOn())
  return (
    <label className="set-row">
      <div style={{ flex: 1 }}><b>Notifications</b><div className="det wrap">When a session needs you or finishes while Frog is in the background.</div></div>
      <input type="checkbox" role="switch" checked={on} onChange={async (e) => setOn(await setNotify(e.target.checked))} />
    </label>
  )
}

/** A per-token price as dollars per million tokens: "$0.20". */
function perM(p: number | null) {
  return p == null ? '—' : `$${(p * 1e6).toFixed(2)}`
}
