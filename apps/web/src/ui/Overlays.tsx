import { useEffect, useMemo, useState } from 'react'
import { API, type Account } from '../auth'
import type { SessionSummary } from '../cloud/protocol'
import { parseRepo } from '../store'

/** No repo listing API yet, so this takes owner/name or a GitHub URL, plus the account's recent repos. */
export function RepoPicker({ recent, onPick, busy }: { recent: string[]; onPick: (repo: string) => void; busy?: boolean }) {
  const [q, setQ] = useState('')
  const repo = parseRepo(q)
  const list = recent.filter((r) => r.includes(q.trim().toLowerCase()))
  return (
    <div className="cardx picker">
      <form style={{ padding: '10px 12px', display: 'flex', gap: 8 }} onSubmit={(e) => { e.preventDefault(); if (repo) onPick(repo) }}>
        <input className="f-field" autoFocus value={q} placeholder="owner/name, or paste a GitHub URL" aria-label="Repo" style={{ fontSize: 14, padding: '8px 10px' }}
          onChange={(e) => setQ(e.target.value)} />
        <button type="submit" className="f-btn f-btn--prominent" disabled={!repo || busy}>{busy ? 'Starting…' : 'Start'}</button>
      </form>
      {list.map((r) => (
        <button key={r} type="button" className="row pick" disabled={busy} onClick={() => onPick(r)}>
          <span className="det">▤</span><span style={{ flex: 1 }}><b style={{ fontWeight: 600 }}>{r}</b></span><span className="det">used before</span>
        </button>
      ))}
      <div className="row pick" style={{ color: 'var(--muted)', cursor: 'default' }}>
        <span>Private repos need the Frog GitHub App on that repo. Public repos work without it.</span>
      </div>
    </div>
  )
}

export interface Command { id: string; label: string; hint?: string; run: () => void }

export function Palette({ commands, sessions, onOpen, onClose }: { commands: Command[]; sessions: SessionSummary[]; onOpen: (id: string) => void; onClose: () => void }) {
  const [q, setQ] = useState('')
  const [hi, setHi] = useState(0)
  const items = useMemo(() => {
    const all: Command[] = [...commands, ...sessions.map((s) => ({ id: s.id, label: s.title, hint: s.repo.split('/')[1], run: () => onOpen(s.id) }))]
    return all.filter((c) => c.label.toLowerCase().includes(q.toLowerCase()))
  }, [q, commands, sessions, onOpen])
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

export function tasksLine(a: Account | null) {
  if (!a) return ''
  return `${a.tasks_left} ${a.tasks_left === 1 ? 'task' : 'tasks'} left`
}

const tabs = ['Account', 'Plan'] as const

export function Settings({ account, onSignOut, onClose }: { account: Account | null; onSignOut: () => void; onClose: () => void }) {
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
              <div className="grow"><div className="name"><b>{account?.handle ?? account?.email ?? 'Signed in'}</b>{account?.handle && <span className="f-badge">GitHub</span>}</div><div className="detail">{account?.email ?? ''}</div></div>
              <div className="acts"><button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={onSignOut}>Sign out</button></div>
            </div>
            <p className="det wrap">Cloud sessions belong to your account, so they show up on every device you sign in on.</p>
            <div className="set-row"><span style={{ flex: 1 }}>Devices and keys</span><a href={`${API}/account`} target="_blank" rel="noreferrer">Manage</a></div>
          </>)}
          {tab === 'Plan' && (<>
            <h2>Plan</h2>
            <div className="set-row">
              <div style={{ flex: 1 }}><b style={{ textTransform: 'capitalize' }}>{account?.plan ?? '…'}</b><div className="det">{tasksLine(account)}{account?.resets_at ? ` · resets ${new Date(account.resets_at).toLocaleDateString()}` : ''}</div></div>
              <a className="f-btn f-btn--bordered" href={`${API}/billing`} target="_blank" rel="noreferrer" style={{ textDecoration: 'none' }}>Billing</a>
            </div>
            <p className="det wrap">Frog for Mac is free with local models. Credits only pay for Frog Cloud.</p>
          </>)}
        </div>
      </div>
    </div>
  )
}
