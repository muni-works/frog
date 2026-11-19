import { Fragment, useEffect, useRef, useState, type ReactNode } from 'react'
import { notifyOn, notifySupported, setNotify } from '../alerts'
import { billingHistory, billingPortal, createKey, CouponError, firstName, listKeys, PLANS, portalErrorMessage, redeemCoupon, revokeKey, TOP_UPS, type Account, type CreditRow, type KeyInfo, type Provider } from '../auth'
import { friendly } from '../cloud/client'
import { canPull, catalogModel, displayName, memoryLine, runningLine, usesLine, type Machine } from '../machines'
import type { Mode } from '../cloud/protocol'
import { modelName, placeColor, usdPerM, type Model } from '../models'
import { savedDensity, savedTheme, SECTIONS, setDensity, WEB_SECTIONS, setTheme, webRows, webWords, type Density, type Section, type SettingRow, type Theme } from '../settings'
import { InvitePill } from './DownloadChip'
import { ICON, Icon } from './icons'
import { creditLine, dollars } from './Overlays'

// Settings mode (docs/design/app-shell.md): the shell's sidebar becomes the section list with
// Back to app, and the main area shows one section. The sections and their rows come from
// design/settings.json, the list the Mac draws too: each row the web can do is drawn by RENDER
// below, and each of the Mac's rows (platform invite) is an invitation under "On your Mac".

/** Back to app, then one row per section, in three runs with a small gap between (no labels):
 *  the app, what Frog knows and can do, you. */
export function SettingsSidebar({ current, onBack, onOpen }: { current: Section; onBack: () => void; onOpen: (s: Section) => void }) {
  return (
    <div className="docs-side settings-side">
      <nav aria-label="Settings" className="nav">
        <button type="button" className="row big" onClick={onBack}><Icon d={ICON.arrowLeft} size={17} /><span style={{ flex: 1 }}>Back to app</span><span className="kb">esc</span></button>
      </nav>
      <div className="docs-list">
        {WEB_SECTIONS.map((s, i) => (
          <button key={s.id} type="button" className={`srow${s.id === current ? ' on' : ''}${i > 0 && WEB_SECTIONS[i - 1].run !== s.run ? ' run-start' : ''}`} aria-current={s.id === current ? 'page' : undefined} onClick={() => onOpen(s.id)}>
            <span className="stitle">{s.label}</span>
          </button>
        ))}
      </div>
    </div>
  )
}

/** The Settings row beside Documentation in Threads mode's sidebar. */
export function SettingsRow({ onOpen }: { onOpen: () => void }) {
  return (
    <button type="button" className="row big settings-row" onClick={onOpen} title="Settings ⌘,">
      <Icon d={ICON.gear} size={17} />
      <span style={{ flex: 1 }}>Settings</span>
      <span className="kb">⌘,</span>
    </button>
  )
}

export interface SettingsProps {
  section: Section
  account: Account | null
  /** This browser's key; absent with the dev key, which the edge doesn't know. */
  apiKey?: string
  models?: Model[]
  machines?: Machine[]
  /** A machine page to open on (Models). */
  machine?: string
  /** Billing: put the cursor in "Have a code?" (the out-of-credit card's link). */
  focusCoupon?: number
  /** The bar above the page: the phone's menu button, the sidebar toggle when it's folded. */
  bar?: ReactNode
  onOpen: (s: Section) => void
  onConnect?: (provider: Provider) => void
  onSignOut: () => void
  onTopUp?: (dollars: number) => Promise<void>
  onSubscribe?: (plan: string) => Promise<void>
  /** A code was redeemed: the new balance, so the sidebar's credit updates. */
  onRedeemed?: (r: { added_cents: number; credit_cents: number }) => void
  /** Permissions › New sessions start in: the same choice as the new session's composer. */
  newMode?: Mode
  onNewMode?: (m: Mode) => void
  /** Models › New conversations use: a pinned model id, or null for the last one picked. */
  pinnedModel?: string | null
  onPinModel?: (id: string | null) => void
}

/** One section. */
export function SettingsPage(p: SettingsProps) {
  const scroller = useRef<HTMLDivElement>(null)
  // Models › a machine's own page, until Back or another section.
  const [machine, setMachine] = useState<string | null>(p.machine ?? null)
  useEffect(() => { if (p.section !== 'models') setMachine(null) }, [p.section])
  // A new section starts at its top, unless Billing was opened for its code field, which has the
  // cursor (and the browser has scrolled it into view).
  useEffect(() => { if (!p.focusCoupon) scroller.current?.scrollTo?.(0, 0) }, [p.section, machine]) // eslint-disable-line react-hooks/exhaustive-deps
  const open = p.section === 'models' ? (p.machines ?? []).find((m) => m.id === machine) : undefined
  return (
    <main className="main docs-main settings-main">
      <div className="titlebar">{p.bar}<Crumbs section={p.section} machine={open?.name} onSection={() => setMachine(null)} /></div>
      <div className="scroll" ref={scroller}>
        <div className="col settings-page" aria-label={SECTIONS.find((s) => s.id === p.section)?.label}>
          {open
            ? <MachinePage machine={open} machines={p.machines ?? []} />
            : <SectionView {...p} onMachine={setMachine} />}
        </div>
      </div>
    </main>
  )
}

/** Where you are, in the header: "Settings › Models › mew". The page draws no title of its own;
 *  a parent you can go back to is a link. */
export function Crumbs({ section, machine, onSection }: { section: Section; machine?: string; onSection: () => void }) {
  const label = SECTIONS.find((s) => s.id === section)?.label
  return (
    <nav className="crumbs" aria-label="Breadcrumb">
      <span>Settings</span>
      <span className="crumb-sep" aria-hidden="true">›</span>
      {machine
        ? <><button type="button" onClick={onSection} title={`Back to ${label}`}>{label}</button><span className="crumb-sep" aria-hidden="true">›</span><b aria-current="page">{machine}</b></>
        : <b aria-current="page">{label}</b>}
    </nav>
  )
}

type Ctx = SettingsProps & { onMachine: (id: string) => void; historyStamp?: number }

/** A row: label and description from the list, the control on the right. */
function Row({ row, children }: { row: SettingRow; children?: ReactNode }) {
  const { label, description } = webWords(row)
  return (
    <div className="set-row" data-row={row.id}>
      <div style={{ flex: 1, minWidth: 0 }}><b>{label}</b>{description && <div className="det wrap">{description}</div>}</div>
      {children}
    </div>
  )
}

/** The rows the web draws, by id. Each returns its row (or rows); a row drawn inside another's
 *  block (the code field is in the credit card, as on the Mac) is in DRAWN_BY instead. A test holds
 *  this to the list: every web row has a renderer and no renderer is for a row the web leaves out. */
export const RENDER: Record<string, (row: SettingRow, p: Ctx) => ReactNode> = {
  notifications: (row) => notifySupported() ? <Notify row={row} /> : null,
  theme: (row) => <ThemeRow row={row} />,
  density: (row) => <DensityRow row={row} />,
  'default-model': (row, p) => <DefaultModel row={row} {...p} />,
  machines: (_, p) => <Machines machines={p.machines ?? []} onOpen={p.onMachine} />,
  'frog-cloud': (_, p) => <FrogCloud account={p.account} onBilling={() => p.onOpen('billing')} />,
  'default-mode': (row, p) => <DefaultMode row={row} mode={p.newMode ?? 'auto'} onMode={p.onNewMode} />,
  'cloud-sandbox': (row) => <Row row={row}><span className="det" title="Each cloud session gets a machine of its own; nothing it runs reaches yours">Always on</span></Row>,
  shortcuts: () => <Shortcuts />,
  profile: (_, p) => <Profile {...p} />,
  'sign-ins': (_, p) => <Logins account={p.account} onConnect={p.onConnect} />,
  devices: (_, p) => p.apiKey ? <Keys apiKey={p.apiKey} /> : null,
  plan: (_, p) => <Subscription account={p.account} apiKey={p.apiKey} onSubscribe={p.onSubscribe} />,
  credit: (_, p) => <Credit {...p} />,
  'credit-history': (_, p) => p.apiKey ? <History key={p.historyStamp} apiKey={p.apiKey} /> : null,
  prices: (_, p) => <Prices models={p.models ?? []} />,
}
export const DRAWN_BY: Record<string, string> = { coupon: 'credit' }

/** Rows run under their group's label, in groups the page's rules draw; Billing's blocks aren't rows. */
const UNGROUPED = new Set(['profile', 'plan', 'credit', 'credit-history', 'prices'])

/** A section: its title, the rows that work here, then the Mac's rows as invitations. */
function SectionView(p: SettingsProps & { onMachine: (id: string) => void }) {
  // A redeemed code shows in the credit history at once.
  const [stamp, setStamp] = useState(0)
  const ctx: Ctx = { ...p, historyStamp: stamp, onRedeemed: (r) => { setStamp((n) => n + 1); p.onRedeemed?.(r) } }
  const { rows, invites } = webRows(p.section)
  const drawn = rows.filter((r) => !DRAWN_BY[r.id])
  const groups = new Set(drawn.map((r) => r.group ?? ''))
  // Consecutive rows of one group share a group block, under its label when the page has several.
  const runs: { group: string; rows: SettingRow[] }[] = []
  for (const r of drawn) {
    const g = r.group ?? ''
    if (runs.at(-1)?.group === g && !UNGROUPED.has(r.id) && !UNGROUPED.has(runs.at(-1)!.rows[0].id)) runs.at(-1)!.rows.push(r)
    else runs.push({ group: g, rows: [r] })
  }
  return (<>
    {runs.map((run, i) => (
      <Fragment key={run.rows[0].id}>
        {run.group && groups.size > 1 && runs[i - 1]?.group !== run.group && <div className="set-h">{run.group}</div>}
        {UNGROUPED.has(run.rows[0].id)
          ? run.rows.map((r) => <Fragment key={r.id}>{RENDER[r.id]?.(r, ctx)}</Fragment>)
          : <div className="set-group">{run.rows.map((r) => <Fragment key={r.id}>{RENDER[r.id]?.(r, ctx)}</Fragment>)}</div>}
      </Fragment>
    ))}
    <Invites rows={invites} section={p.section} machines={p.machines} />
  </>)
}

/** The Mac's rows, at the foot under one label: same words, and the pill where the control would be. */
function Invites({ rows, section, machines }: { rows: SettingRow[]; section: Section; machines?: Machine[] }) {
  if (!rows.length) return null
  return (<>
    <div className="set-h">On your Mac</div>
    <div className="set-group set-invites">
      {rows.map((r) => <Row key={r.id} row={r}><InvitePill section={section} machines={machines} /></Row>)}
    </div>
  </>)
}

/** A segmented choice, frog-drawn: two to four options on a line. */
function Seg<T extends string>({ label, options, value, onPick }: { label: string; options: { id: string; label: string }[]; value: T; onPick: (v: T) => void }) {
  return (
    <div className="topup-amts set-seg" role="radiogroup" aria-label={label}>
      {options.map((o) => <button key={o.id} type="button" role="radio" aria-checked={value === o.id} className={value === o.id ? 'on' : ''} title={(o as { description?: string }).description} onClick={() => onPick(o.id as T)}>{o.label}</button>)}
    </div>
  )
}

// ---------- Account ----------

/** Name, email and Sign out. */
function Profile({ account, onSignOut }: SettingsProps) {
  return (<>
    <div className="f-account">
      <span className="mark" style={{ width: 28, height: 28 }} />
      <div className="grow"><div className="name"><b>{account?.name ?? firstName(account) ?? 'Signed in'}</b>{account?.handle && <span className="f-badge">GitHub</span>}</div><div className="detail">{[account?.handle && `@${account.handle}`, account?.email].filter(Boolean).join(', ')}</div></div>
      <div className="acts"><button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={onSignOut} title="This browser forgets its key. Your sessions stay in your account.">Sign out</button></div>
    </div>
    <p className="det wrap">Cloud sessions belong to your account, so they show up on every device you sign in on.</p>
  </>)
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
      {who ? <span className="det">Connected</span> : onConnect && <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => onConnect(id)} title={`Adds ${name} to this account`}>Connect</button>}
    </div>
  ))
}

function Notify({ row }: { row: SettingRow }) {
  const [on, setOn] = useState(notifyOn())
  return (
    <label className="set-row" data-row={row.id}>
      <div style={{ flex: 1 }}><b>{row.label}</b><div className="det wrap">{row.description}</div></div>
      <input type="checkbox" role="switch" aria-label={row.label} checked={on} onChange={async (e) => setOn(await setNotify(e.target.checked))} />
    </label>
  )
}

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
  return (<>
    <div className="set-keys">
      {!keys && !error && <div className="set-row det">Loading…</div>}
      {live.map((k) => (
        <div key={k.id} className="set-row">
          <div style={{ flex: 1, minWidth: 0 }}>
            <b>{k.name ?? (k.kind === 'device' ? 'A device' : 'API key')}</b>{k.current && <span className="f-badge" style={{ marginLeft: 6 }}>This browser</span>}
            <div className="det">{k.kind === 'device' ? 'Signed in' : 'API key'} {day(k.created)}{k.last_used ? `, last used ${day(k.last_used)}` : ''}</div>
          </div>
          {!k.current && <button type="button" className="f-btn f-btn--bordered f-btn--small" title={k.kind === 'device' ? 'Signs that device out' : 'That key stops working'} onClick={() => revokeKey(apiKey, k.id).then(load, () => setError("Couldn't revoke it. Try again."))}>Revoke</button>}
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
          <button type="submit" className="f-btn f-btn--bordered f-btn--small" title="A key for the CLI or a tool. It's shown once.">Create key</button>
        </form>
      )}
      {error && <div className="det" style={{ color: 'var(--warn)' }}>{error}</div>}
    </div>
  </>)
}

// ---------- Appearance ----------

/** The theme, kept in this browser: System follows the device. */
function ThemeRow({ row }: { row: SettingRow }) {
  const [theme, setThemeState] = useState<Theme>(() => savedTheme())
  return <Row row={row}><Seg label={row.label} options={row.options!} value={theme} onPick={(t: Theme) => { setThemeState(t); setTheme(t) }} /></Row>
}

/** Compact tightens the transcript's gaps, kept in this browser. */
function DensityRow({ row }: { row: SettingRow }) {
  const [d, setD] = useState<Density>(() => savedDensity())
  return <Row row={row}><Seg label={row.label} options={row.options!} value={d} onPick={(v: Density) => { setD(v); setDensity(v) }} /></Row>
}

// ---------- Models ----------

/** New conversations use: the last model picked, or one model every time. */
function DefaultModel({ row, models = [], pinnedModel, onPinModel }: { row: SettingRow } & SettingsProps) {
  const value = pinnedModel && models.some((m) => m.id === pinnedModel) ? pinnedModel : ''
  return (
    <Row row={row}>
      <select className="f-pill invite-pill set-menu" aria-label={row.label} title="The model a new conversation starts on; the composer can still change it" value={value} onChange={(e) => onPinModel?.(e.target.value || null)} disabled={!onPinModel}>
        <option value="">The last model I used</option>
        {models.map((m) => <option key={m.id} value={m.id}>{modelName(m.id)}</option>)}
      </select>
    </Row>
  )
}

// ---------- Permissions ----------

/** New sessions start in: the selected mode's one line under the label. Yolo asks first, as the
 *  composer does. */
function DefaultMode({ row, mode, onMode }: { row: SettingRow; mode: Mode; onMode?: (m: Mode) => void }) {
  const [confirm, setConfirm] = useState(false)
  const picked = row.options!.find((o) => o.id === mode) ?? row.options![0]
  return (<>
    <div className="set-row" data-row={row.id}>
      <div style={{ flex: 1, minWidth: 0 }}><b>{row.label}</b><div className="det wrap">{picked.description}</div></div>
      <Seg label={row.label} options={row.options!} value={mode} onPick={(m: Mode) => { if (m === 'yolo' && mode !== 'yolo') setConfirm(true); else { setConfirm(false); onMode?.(m) } }} />
    </div>
    {confirm && (
      <div className="set-row" role="alertdialog" aria-label="Start new sessions in Yolo?">
        <div style={{ flex: 1 }} className="det wrap">Every new session runs every step without asking. It's your sandbox; nothing is pushed unless you ask.</div>
        <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => { setConfirm(false); onMode?.('yolo') }}>Start in Yolo</button>
        <button type="button" className="f-btn f-btn--plain f-btn--small" onClick={() => setConfirm(false)}>Cancel</button>
      </div>
    )}
  </>)
}

// ---------- Shortcuts ----------

/** The web's own keys, read-only. */
export const WEB_SHORTCUTS: [string, [string, string][]][] = [
  ['Conversation', [['Send', '↩'], ['New line', '⇧↩'], ['Stop the turn', 'Esc'], ['Last message again', '↑'], ['Permission mode', '⌘.']]],
  ['Answer a request', [['Allow', '⌘↩'], ['Deny', '⌘.']]],
  ['App', [['Command palette', '⌘K'], ['New session', '⌘N'], ['Settings', '⌘,'], ['Show or hide the sidebar', '⌘\\'], ['Back to app', 'Esc']]],
]

function Shortcuts() {
  return WEB_SHORTCUTS.map(([group, keys]) => (
    <Fragment key={group}>
      <div className="set-h">{group}</div>
      <div className="set-group plain">
        {keys.map(([what, k]) => <div key={what} className="set-row"><div style={{ flex: 1 }}>{what}</div><span className="det mono">{k}</span></div>)}
      </div>
    </Fragment>
  ))
}

// ---------- Billing ----------

/** Usage credit: the balance, Add credit and the code field, one card as on the Mac. */
function Credit({ account, apiKey, focusCoupon, onTopUp, onRedeemed }: SettingsProps) {
  return (
    <div className="bill-card">
      <div className="bill-h"><b>Usage credit</b><b className="num">{creditLine(account)}</b></div>
      <div className="det wrap">{account?.subscription
        ? account.subscription.over ? 'Your plan’s allowance is used up, so turns are paying from credit at the prices below until it resets.' : 'Used only past your plan’s allowance, at the prices below.'
        : 'Each turn pays from credit at the model’s prices below.'}</div>
      {onTopUp && <TopUp onTopUp={onTopUp} />}
      {apiKey && <Coupon apiKey={apiKey} focus={focusCoupon} onRedeemed={onRedeemed} />}
    </div>
  )
}

/** Prices per model, per million tokens. */
function Prices({ models }: { models: Model[] }) {
  if (!models.length) return null
  return (
    <div className="set-prices">
      <div className="set-price-h"><span>Model</span><span>Input</span><span>Cached</span><span>Output</span></div>
      {models.map((m) => (
        <div key={m.id} className="set-price">
          <span>{modelName(m.id)}</span><span>{perM(m.input)}</span><span>{perM(m.cached)}</span><span>{perM(m.output)}</span>
        </div>
      ))}
      <div className="det">Per million tokens.</div>
    </div>
  )
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
            <div className="allow-h"><span>{w.kind === '5h' ? 'This 5 hours' : 'This week'}</span><span className="det">{Math.round(f * 100)}%, resets {new Date(w.resets_at).toLocaleString(undefined, w.kind === '5h' ? { hour: 'numeric', minute: '2-digit' } : { weekday: 'short' })}</span></div>
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

/** "Have a code?": redeems a coupon for Frog Cloud credit. The edge's message shows under the
 *  field when it isn't redeemed, and what was typed stays. */
export function Coupon({ apiKey, focus, onRedeemed }: { apiKey: string; focus?: number; onRedeemed?: (r: { added_cents: number; credit_cents: number }) => void }) {
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [said, setSaid] = useState<{ ok: boolean; text: string } | null>(null)
  const field = useRef<HTMLInputElement>(null)
  useEffect(() => { if (focus) field.current?.focus() }, [focus])
  const redeem = () => {
    const c = code.trim()
    if (!c || busy) return
    setBusy(true); setSaid(null)
    redeemCoupon(apiKey, c).then(
      (r) => { setBusy(false); setCode(''); setSaid({ ok: true, text: `Added ${dollars(r.added_cents / 100)} of Frog Cloud credit` }); onRedeemed?.(r) },
      (e) => { setBusy(false); setSaid({ ok: false, text: e instanceof CouponError ? e.message : `Couldn't redeem it (${friendly(e)}). Try again.` }) },
    )
  }
  return (
    <form className="coupon" onSubmit={(e) => { e.preventDefault(); redeem() }}>
      <b>Have a code?</b>
      <div className="coupon-row">
        <input ref={field} className="f-field" value={code} onChange={(e) => setCode(e.target.value)} placeholder="Code" aria-label="Coupon code" autoComplete="off" spellCheck={false} />
        <button type="submit" className="f-btn f-btn--bordered f-btn--small" disabled={busy || !code.trim()}>{busy ? 'Redeeming…' : 'Redeem'}</button>
      </div>
      {said && <div role="status" className="det wrap" style={{ color: said.ok ? 'var(--frog)' : 'var(--warn)' }}>{said.text}</div>}
    </form>
  )
}

/** What a credit row was: a top-up says nothing more, a code says which, an unknown kind its name. */
export function creditRowLabel(t: CreditRow): string {
  if (!t.kind || t.kind === 'topup') return ''
  if (t.kind === 'coupon') return t.code ? `Code ${t.code}` : 'Code'
  return t.kind.replace(/_/g, ' ')
}

/** A credit row's amount in dollars. */
const rowDollars = (t: CreditRow) => (t.amount_micro_usd != null ? t.amount_micro_usd / 1e6 : t.added_cents != null ? t.added_cents / 100 : 0)

/** Credit added, newest first: top-ups, redeemed codes, and anything else the edge lists. */
function History({ apiKey }: { apiKey: string }) {
  const [rows, setRows] = useState<CreditRow[] | null>(null)
  useEffect(() => { billingHistory(apiKey).then(setRows, () => setRows([])) }, [apiKey])
  if (!rows?.length) return null
  return (
    <div className="set-prices credit-history">
      <div className="set-price-h"><span>Credit added</span><span /><span /><span>Amount</span></div>
      {rows.map((t, i) => (
        <div key={`${t.at}-${i}`} className="set-price credit-row">
          <span>{day(t.at)}</span><span className="det">{creditRowLabel(t)}</span><span className="det">{!t.status || t.status === 'succeeded' ? '' : t.status}</span><span>${rowDollars(t).toFixed(2)}</span>
        </div>
      ))}
    </div>
  )
}

/** A per-token price as dollars per million tokens: "$0.20". */
function perM(p: number | null) {
  return p == null ? '—' : usdPerM(p)
}

// ---------- Models ----------

/** Your machines, every node (This Mac included) the same row; each opens its page. */
function Machines({ machines, onOpen }: { machines: Machine[]; onOpen: (id: string) => void }) {
  if (!machines.length) return <div className="set-row det">No machines yet.</div>
  return machines.map((m) => (
    <button key={m.id} type="button" className="set-row set-machine" onClick={() => onOpen(m.id)} title={`Open ${m.name}'s page: its memory and models`}>
      <div style={{ flex: 1, minWidth: 0 }}><b>{m.name}</b>{m.thisMac && <span className="det" style={{ marginLeft: 6 }}>This Mac</span>}<div className="det">{m.hardware}</div></div>
      <span className={m.model ? '' : 'det'}>{runningLine(m)}</span>
      <span className="cz-dot" style={{ background: placeColor('local'), opacity: m.online ? 1 : 0.25 }} aria-hidden="true" />
      <span className="det">›</span>
    </button>
  ))
}

/** Frog Cloud: who's signed in and the credit, with Add credit in Billing. */
function FrogCloud({ account, onBilling }: { account: Account | null; onBilling: () => void }) {
  return (<>
    <div className="set-row"><div style={{ flex: 1 }}>Account</div><span className="det">{[account?.name ?? firstName(account), account?.email].filter(Boolean).join(', ') || 'Signed in'}</span></div>
    <div className="set-row"><div style={{ flex: 1 }}>Credit</div><span className="num">{creditLine(account).replace(/ credit$/, '')}</span><button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={onBilling} title="Opens Billing">Add credit…</button></div>
  </>)
}

/** A machine's page: status and memory, its models, then what the Mac app does here (rename or
 *  unpair it, share it) as invitations. Read-only on the web. */
function MachinePage({ machine: d, machines }: { machine: Machine; machines: readonly Machine[] }) {
  const used = d.freeBytes == null || !d.totalBytes ? 0 : 1 - Math.min(d.freeBytes, d.totalBytes) / d.totalBytes
  return (<>
    {/* Facts, not controls: no lines between them. Back is the header's "Models". */}
    <div className="set-group plain">
      <div className="set-row"><div style={{ flex: 1 }}>Status</div><span className="det">{!d.online ? 'Not answering' : d.model ? 'Ready' : 'Idle'}</span></div>
      <div className="set-row"><div style={{ flex: 1 }}>Hardware</div><span className="det">{d.hardware}</span></div>
      <div className="set-row" style={{ flexDirection: 'column', alignItems: 'stretch', gap: 4 }}>
        <div className="ctx-bar"><span style={{ width: `${used * 100}%`, background: placeColor('local') }} /></div>
        <span className="det">{memoryLine(d)}</span>
      </div>
    </div>
    <div className="set-h">Models</div>
    <div className="set-group plain">
      {d.models.length === 0 && <div className="set-row det">{d.online ? 'No models on this machine.' : 'Not answering.'}</div>}
      {d.models.map((m) => (
        <div key={m.hash} className="set-row">
          <span className="radio" aria-hidden="true" style={{ borderColor: m.loaded ? placeColor('local') : 'var(--line-strong)' }}>{m.loaded && <span style={{ background: placeColor('local') }} />}</span>
          <div style={{ flex: 1 }} title={[catalogModel(m.id)?.source.repo ?? m.id, m.quant].filter(Boolean).join(', ')}>
            {displayName(m.id || m.name)}
            {catalogModel(m.id) && <div className="det">{usesLine(catalogModel(m.id)!)}</div>}
          </div>
          {m.loaded && d.decode ? <span className="det">{Math.round(d.decode)} tok/s</span> : null}
          {!m.loaded && canPull() && <button type="button" className="f-btn f-btn--bordered f-btn--small" disabled>Delete</button>}
        </div>
      ))}
      {canPull() && <div className="set-row"><button type="button" className="f-btn f-btn--bordered f-btn--small" disabled>Download a model…</button></div>}
    </div>
    <Invites rows={webRows('models', 'machine').invites} section="models" machines={[...machines]} />
  </>)
}
