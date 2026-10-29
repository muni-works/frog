import { useEffect, useMemo, useState } from 'react'
import { API, firstName, type Account } from '../auth'
import type { SessionSummary } from '../cloud/protocol'

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
              <div className="grow"><div className="name"><b>{account?.name ?? firstName(account) ?? 'Signed in'}</b>{account?.handle && <span className="f-badge">GitHub</span>}</div><div className="detail">{[account?.handle && `@${account.handle}`, account?.email].filter(Boolean).join(' · ')}</div></div>
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
