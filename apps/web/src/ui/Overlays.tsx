import { PLANS, TOP_UPS } from '../auth'
import { useEffect, useMemo, useState } from 'react'
import { notifyOn, notifySupported, setNotify } from '../alerts'
import { billingHistory, billingPortal, createKey, firstName, listKeys, portalErrorMessage, revokeKey, type Account, type KeyInfo, type Provider } from '../auth'
import { friendly } from '../cloud/client'
import { modelName, placeColor, type Model } from '../models'
import { canPull, displayName, memoryLine, runningLine, type Machine } from '../machines'
import type { SessionSummary } from '../cloud/protocol'
import { DownloadAppChip } from './DownloadChip'
import { useLayer } from './layers'

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
  useLayer(true, onClose)
  const run = (c?: Command) => { if (!c) return; onClose(); c.run() }
  return (
    <div className="scrim" onMouseDown={onClose}>
      <div className="cardx palette" role="dialog" aria-label="Command palette" onMouseDown={(e) => e.stopPropagation()}>
        <input className="pal-in" autoFocus value={q} placeholder="Search sessions and commands" aria-label="Search"
          onChange={(e) => { setQ(e.target.value); setHi(0) }}
          onKeyDown={(e) => {
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
function Subscription({ account, apiKey, onSubscribe }: { account: Account | null; apiKey?: string; onSubscribe?: (plan: string) => Promise<void> }) {
  const [busy, setBusy] = useState<string | null>(null)
  const [portalError, setPortalError] = useState<string | null>(null)
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
      {apiKey && <button type="button" className="f-btn f-btn--plain f-btn--small" style={{ alignSelf: 'flex-start' }} disabled={busy === 'portal'}
        onClick={() => {
          setBusy('portal'); setPortalError(null)
          billingPortal(apiKey).catch((e) => { setBusy(null); setPortalError(portalErrorMessage(e) ?? "couldn't open the billing portal — try again") })
        }}>{busy === 'portal' ? 'Opening Stripe…' : 'Change or cancel your plan'}</button>}
      {portalError && <div className="det wrap" style={{ color: 'var(--notice)' }}>{portalError}</div>}
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
        onClick={() => { setBusy(true); setError(null); onTopUp(amount).catch((e) => { setBusy(false); setError(friendly(e)) }) }}>
        {busy ? 'Opening Stripe…' : `Add $${amount}`}
      </button>
      {error && <div className="det" style={{ color: 'var(--warn)' }}>Couldn't start checkout ({error}). Try again.</div>}
      <div className="det wrap">Paid through Stripe. Credit doesn't expire.</div>
    </div>
  )
}

const tabs = ['Account', 'Models', 'Billing'] as const
export type SettingsTab = (typeof tabs)[number]

const day = (iso: string) => new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })

/** Devices and keys, as api.frog.toys/account had them: each signed-in app, and keys made for
 * the CLI or a tool. A new key shows once. Revoking this browser's own key signs it out. */
function Keys({ apiKey }: { apiKey: string }) {
  const [keys, setKeys] = useState<KeyInfo[] | null>(null)
  const [made, setMade] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [error, setError] = useState<string | null>(null)
  const load = () => listKeys(apiKey).then(setKeys, () => setError("Couldn't load your keys."))
  useEffect(() => { load() }, [apiKey]) // eslint-disable-line react-hooks/exhaustive-deps
  const live = (keys ?? []).filter((k) => !k.revoked)
  return (
    <div className="set-keys">
      <b>Devices and keys</b>
      {!keys && !error && <div className="det">Loading…</div>}
      {live.map((k) => (
        <div key={k.id} className="set-row">
          <div style={{ flex: 1, minWidth: 0 }}>
            <b>{k.name ?? (k.kind === 'device' ? 'A device' : 'API key')}</b>{k.current && <span className="f-badge" style={{ marginLeft: 6 }}>This browser</span>}
            <div className="det">{k.kind === 'device' ? 'Signed in' : 'API key'} {day(k.created)}{k.last_used ? ` · last used ${day(k.last_used)}` : ''}</div>
          </div>
          {!k.current && <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => revokeKey(apiKey, k.id).then(load, () => setError("Couldn't revoke it. Try again."))}>Revoke</button>}
        </div>
      ))}
      {made ? (
        <div className="set-row" style={{ flexDirection: 'column', alignItems: 'stretch' }}>
          <div className="det wrap">Copy it now: it's only shown once. Use it as FROG_API_KEY.</div>
          <code style={{ wordBreak: 'break-all', userSelect: 'all' }}>{made}</code>
          <div style={{ display: 'flex', gap: 8 }}>
            <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => navigator.clipboard?.writeText(made)}>Copy</button>
            <button type="button" className="f-btn f-btn--plain f-btn--small" onClick={() => setMade(null)}>Done</button>
          </div>
        </div>
      ) : (
        <form className="set-row" onSubmit={(e) => { e.preventDefault(); createKey(apiKey, name).then((r) => { setMade(r.key); setName(''); load() }, () => setError("Couldn't make a key. Try again.")) }}>
          <input className="f-field" style={{ flex: 1 }} value={name} onChange={(e) => setName(e.target.value)} placeholder="New API key name (optional)" aria-label="New API key name" />
          <button type="submit" className="f-btn f-btn--bordered f-btn--small">Create key</button>
        </form>
      )}
      {error && <div className="det" style={{ color: 'var(--warn)' }}>{error}</div>}
    </div>
  )
}

/** Credit purchases, newest first. */
function History({ apiKey }: { apiKey: string }) {
  const [rows, setRows] = useState<Awaited<ReturnType<typeof billingHistory>> | null>(null)
  useEffect(() => { billingHistory(apiKey).then(setRows, () => setRows([])) }, [apiKey])
  if (!rows?.length) return null
  return (
    <div className="set-prices">
      <div className="set-price-h"><span>Credit added</span><span /><span /><span>Amount</span></div>
      {rows.map((t) => (
        <div key={t.at} className="set-price">
          <span>{day(t.at)}</span><span /><span className="det">{t.status === 'succeeded' ? '' : t.status}</span><span>${(t.amount_micro_usd / 1e6).toFixed(2)}</span>
        </div>
      ))}
    </div>
  )
}

export function Settings({ account, apiKey, tab: initial = 'Account', models = [], machines = [], machine, onConnect, onSignOut, onClose, onTopUp, onSubscribe }: { account: Account | null; apiKey?: string; tab?: SettingsTab; models?: Model[]; machines?: Machine[]; machine?: string; onConnect?: (provider: Provider) => void; onSignOut: () => void; onClose: () => void; onTopUp?: (dollars: number) => Promise<void>; onSubscribe?: (plan: string) => Promise<void> }) {
  const [tab, setTab] = useState<SettingsTab>(initial)
  useLayer(true, onClose)
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
            <Logins account={account} onConnect={onConnect} />
            {apiKey && <Keys apiKey={apiKey} />}
            {notifySupported() && <Notify />}
          </>)}
          {tab === 'Models' && <ModelsSettings account={account} machines={machines} machine={machine} onBilling={() => setTab('Billing')} />}
          {tab === 'Billing' && (<>
            <h2>Billing</h2>
            <Subscription account={account} apiKey={apiKey} onSubscribe={onSubscribe} />
            <div className="bill-card">
              <div className="bill-h"><b>Usage credit</b><b className="num">{creditLine(account)}</b></div>
              <div className="det wrap">{account?.subscription
                ? account.subscription.over ? 'Your plan’s allowance is used up, so turns are paying from credit at the prices below until it resets.' : 'Used only past your plan’s allowance, at the prices below.'
                : 'Each turn pays from credit at the model’s prices below.'}</div>
              {onTopUp && <TopUp onTopUp={onTopUp} />}
            </div>
            {apiKey && <History apiKey={apiKey} />}
            {models.length > 0 && (
              <div className="set-prices">
                <div className="set-price-h"><span>Model</span><span>Input</span><span>Cached</span><span>Output</span></div>
                {models.map((m) => (
                  <div key={m.id} className="set-price">
                    <span>{modelName(m.id)}</span><span>{perM(m.input)}</span><span>{perM(m.cached)}</span><span>{perM(m.output)}</span>
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

/** The sign-ins this account has, as on the Mac and iPhone: GitHub (its repos) and Google. */
function Logins({ account, onConnect }: { account: Account | null; onConnect?: (provider: Provider) => void }) {
  const rows: [Provider, string, string | null | undefined, string][] = [
    ['github', 'GitHub', account?.handle && `@${account.handle}`, 'Needed for your repos.'],
    ['google', 'Google', account?.google, 'Sign in with your Google account.'],
  ]
  return rows.map(([id, name, who, why]) => (
    <div key={id} className="set-row">
      <div style={{ flex: 1 }}><b>{name}</b><div className="det wrap">{who ?? `Not connected. ${why}`}</div></div>
      {who ? <span className="det">Connected</span> : onConnect && <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => onConnect(id)}>Connect</button>}
    </div>
  ))
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

/** Settings › Models, as on the Mac: your machines (every node, This Mac included, the same
 *  row), a page per machine, then Frog Cloud. Pairing happens in the Mac app. */
function ModelsSettings({ account, machines, machine, onBilling }: { account: Account | null; machines: Machine[]; machine?: string; onBilling: () => void }) {
  const [open, setOpen] = useState<string | null>(machine ?? null)
  const d = machines.find((m) => m.id === open)
  if (d) return <MachinePage machine={d} machines={machines} onBack={() => setOpen(null)} />
  return (<>
    <h2>Models</h2>
    <div className="set-h">Machines</div>
    <div className="set-group">
      {machines.map((m) => (
        <button key={m.id} type="button" className="set-row set-machine" onClick={() => setOpen(m.id)}>
          <div style={{ flex: 1, minWidth: 0 }}><b>{m.name}</b>{m.thisMac && <span className="det" style={{ marginLeft: 6 }}>This Mac</span>}<div className="det">{m.hardware}</div></div>
          <span className={m.model ? '' : 'det'}>{runningLine(m)}</span>
          <span className="cz-dot" style={{ background: placeColor('local'), opacity: m.online ? 1 : 0.25 }} aria-hidden="true" />
          <span className="det">›</span>
        </button>
      ))}
      <div className="set-row"><div style={{ flex: 1 }}><b>Pair a machine</b><div className="det wrap">Machines you pair show here, with their models. <a href="/mac">Get the Mac app</a></div></div><DownloadAppChip label="Pair machines in the Mac app" machines={machines} /></div>
    </div>
    <div className="set-h">Frog Cloud</div>
    <div className="set-group">
      <div className="set-row"><div style={{ flex: 1 }}>Account</div><span className="det">{[account?.name ?? firstName(account), account?.email].filter(Boolean).join(' · ') || 'Signed in'}</span></div>
      <div className="set-row"><div style={{ flex: 1 }}>Credit</div><span className="num">{creditLine(account).replace(/ credit$/, '')}</span><button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={onBilling}>Add credit…</button></div>
    </div>
  </>)
}

/** A machine's page: status and memory, its models, and the node. Read-only on the web: what the
 *  Mac app does here (stop a model, rename or unpair the node) is a chip, not a dead button. */
function MachinePage({ machine: d, machines, onBack }: { machine: Machine; machines: readonly Machine[]; onBack: () => void }) {
  const used = d.freeBytes == null || !d.totalBytes ? 0 : 1 - Math.min(d.freeBytes, d.totalBytes) / d.totalBytes
  return (<>
    <button type="button" className="f-btn f-btn--plain f-btn--small" onClick={onBack}>‹ Models</button>
    <h2>{d.name}</h2>
    <div className="set-group">
      <div className="set-row"><div style={{ flex: 1 }}>Status</div><span className="det">{!d.online ? 'Not answering' : d.model ? 'Ready' : 'Idle'}</span></div>
      <div className="set-row"><div style={{ flex: 1 }}>Hardware</div><span className="det">{d.hardware}</span></div>
      <div className="set-row" style={{ flexDirection: 'column', alignItems: 'stretch', gap: 4 }}>
        <div className="ctx-bar"><span style={{ width: `${used * 100}%`, background: placeColor('local') }} /></div>
        <span className="det">{memoryLine(d)}</span>
      </div>
    </div>
    <div className="set-h">Models</div>
    <div className="set-group">
      {d.models.length === 0 && <div className="set-row det">{d.online ? 'No models on this machine.' : 'Not answering.'}</div>}
      {d.models.map((m) => (
        <div key={m.hash} className="set-row">
          <span className="radio" aria-hidden="true" style={{ borderColor: m.loaded ? placeColor('local') : 'var(--line-strong)' }}>{m.loaded && <span style={{ background: placeColor('local') }} />}</span>
          <div style={{ flex: 1 }}>{displayName(m.name)}{m.quant && <span className="det" style={{ marginLeft: 6 }}>{m.quant}</span>}</div>
          {m.loaded && d.decode ? <span className="det">{Math.round(d.decode)} tok/s</span> : null}
          {m.loaded && <DownloadAppChip label="Stop it in the Mac app" machines={machines} />}
          {!m.loaded && canPull() && <button type="button" className="f-btn f-btn--bordered f-btn--small" disabled>Delete</button>}
        </div>
      ))}
      {canPull() && <div className="set-row"><button type="button" className="f-btn f-btn--bordered f-btn--small" disabled>Download a model…</button></div>}
    </div>
    <div className="set-h">Node</div>
    <div className="set-group">
      <label className="set-row"><div style={{ flex: 1 }}>Share with my other machines</div><input type="checkbox" role="switch" checked disabled /></label>
      <div className="set-row"><div style={{ flex: 1 }}>Name</div><span>{d.name}</span><DownloadAppChip label="Rename it in the Mac app" machines={machines} /></div>
      {!d.thisMac && <div className="set-row"><DownloadAppChip label={`Unpair ${d.name} in the Mac app`} machines={machines} /></div>}
    </div>
  </>)
}
