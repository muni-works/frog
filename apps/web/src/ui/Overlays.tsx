import { useEffect, useMemo, useState } from 'react'
import { models, repos, type Session } from '../store'

export function RepoPicker({ onPick }: { onPick: (repo: string) => void }) {
  const [q, setQ] = useState('')
  const [hi, setHi] = useState(0)
  const list = repos.filter((r) => r.name.includes(q.toLowerCase()))
  const url = q.match(/github\.com\/([\w.-]+\/[\w.-]+)/)?.[1]
  return (
    <div className="cardx picker">
      <div style={{ padding: '10px 12px' }}>
        <input className="f-field" autoFocus value={q} placeholder="Search your repos, or paste a GitHub URL" aria-label="Search repos" style={{ fontSize: 14, padding: '8px 10px' }}
          onChange={(e) => { setQ(e.target.value); setHi(0) }}
          onKeyDown={(e) => {
            if (e.key === 'ArrowDown') setHi(Math.min(hi + 1, list.length - 1))
            if (e.key === 'ArrowUp') setHi(Math.max(hi - 1, 0))
            if (e.key === 'Enter') { if (url) onPick(url); else if (list[hi]) onPick(list[hi].name) }
          }} />
      </div>
      {url && <button type="button" className="row pick" onClick={() => onPick(url)}><span className="det">↗</span><span style={{ flex: 1 }}><b>{url}</b> <span className="det">from GitHub</span></span></button>}
      {list.map((r, i) => (
        <button key={r.name} type="button" className={`row pick ${i === hi ? 'on' : ''}`} onMouseEnter={() => setHi(i)} onClick={() => onPick(r.name)}>
          <span className="det">▤</span><span style={{ flex: 1 }}><b style={{ fontWeight: 600 }}>{r.name}</b> <span className="det">{r.meta}</span></span><span className="det">{r.when}</span>
        </button>
      ))}
      <div className="row pick" style={{ justifyContent: 'space-between', color: 'var(--muted)', cursor: 'default' }}>
        <span>Don't see it? <a href="#" onClick={(e) => e.preventDefault()}>Give Frog access to more repos</a></span><span>Public repos work without access</span>
      </div>
    </div>
  )
}

export interface Command { id: string; label: string; hint?: string; run: () => void }

export function Palette({ commands, sessions, onOpen, onClose }: { commands: Command[]; sessions: Session[]; onOpen: (id: string) => void; onClose: () => void }) {
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

const tabs = ['Account', 'Plan', 'Models', 'Permissions', 'MCP'] as const

export function Settings({ credits, model, onModel, onAddCredit, onSignOut, onClose }: { credits: number; model: string; onModel: (m: string) => void; onAddCredit: () => void; onSignOut: () => void; onClose: () => void }) {
  const [tab, setTab] = useState<(typeof tabs)[number]>('Account')
  const [mode, setMode] = useState('ask')
  const [mcp, setMcp] = useState([{ name: 'GitHub', on: true, note: 'Issues, PRs and checks' }, { name: 'Linear', on: false, note: 'Not connected' }, { name: 'Sentry', on: false, note: 'Not connected' }])
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
            <div className="f-account"><span className="mark" style={{ width: 28, height: 28 }} /><div className="grow"><div className="name"><b>Pip</b><span className="f-badge">GitHub</span></div><div className="detail">samr · sam@example.com</div></div><div className="acts"><button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={onSignOut}>Sign out</button></div></div>
            <p className="det wrap">Cloud sessions belong to your account, so they show up on every device you sign in on.</p>
            <h3>GitHub access</h3>
            <div className="set-row"><span style={{ flex: 1 }}>ecto · 4 repos</span><a href="#" onClick={(e) => e.preventDefault()}>Change access</a></div>
          </>)}
          {tab === 'Plan' && (<>
            <h2>Plan</h2>
            <div className="set-row"><div style={{ flex: 1 }}><b>Pay as you go</b><div className="det">{`$${credits.toFixed(2)} of Frog Cloud credit left`}</div></div><button type="button" className="f-btn f-btn--bordered" onClick={onAddCredit}>Add $10</button></div>
            <div className="set-row"><div style={{ flex: 1 }}><b>Pro</b><div className="det wrap">Cloud usage included every month, plus routines while you sleep.</div></div><button type="button" className="f-btn f-btn--prominent">See plans</button></div>
            <p className="det wrap">Frog for Mac is free with local models. Credits only pay for Frog Cloud.</p>
          </>)}
          {tab === 'Models' && (<>
            <h2>Models</h2>
            {models.map((m) => (
              <label key={m.id} className="set-row"><input type="radio" name="model" checked={m.id === model} onChange={() => onModel(m.id)} /><div style={{ flex: 1 }}><b>{m.id}</b><div className="det">{m.note}</div></div></label>
            ))}
            <h3>Your own key</h3>
            <div className="set-row"><span className="det" style={{ flex: 1 }}>Use your own provider key in the sandbox. Not billed as credit.</span><button type="button" className="f-btn f-btn--bordered f-btn--small">Add a key</button></div>
          </>)}
          {tab === 'Permissions' && (<>
            <h2>Permissions</h2>
            <p className="det wrap">What Frog may do in your sandbox without asking. Nothing is pushed until you say so.</p>
            {[['ask', 'Ask before edits and commands', 'The default'], ['edits', 'Allow edits, ask before commands', 'Good for small fixes'], ['auto', 'Allow everything in the sandbox', 'Still asks before anything leaves it']].map(([id, t, d]) => (
              <label key={id} className="set-row"><input type="radio" name="mode" checked={mode === id} onChange={() => setMode(id)} /><div style={{ flex: 1 }}><b>{t}</b><div className="det">{d}</div></div></label>
            ))}
            <h3>Always allowed</h3>
            <div className="set-row"><code style={{ flex: 1 }}>npm test</code><button type="button" className="f-btn f-btn--plain">Remove</button></div>
          </>)}
          {tab === 'MCP' && (<>
            <h2>MCP servers</h2>
            <p className="det wrap">Tools your cloud sessions can use.</p>
            {mcp.map((s, i) => (
              <label key={s.name} className="set-row"><div style={{ flex: 1 }}><b>{s.name}</b><div className="det">{s.on ? s.note : 'Not connected'}</div></div>
                <input type="checkbox" role="switch" checked={s.on} onChange={() => setMcp(mcp.map((x, j) => (j === i ? { ...x, on: !x.on, note: x.on ? x.note : 'Connected' } : x)))} /></label>
            ))}
            <button type="button" className="f-btn f-btn--bordered" style={{ alignSelf: 'flex-start' }}>Add a server</button>
          </>)}
        </div>
      </div>
    </div>
  )
}
