import { useEffect, useRef, useState } from 'react'
import type { Mode } from '../cloud/protocol'
import { modes, price, type Model } from '../models'
import { parseRepo } from '../store'

// Port of Composer.dc.html with platform="web": the run-on chip is fixed to Frog Cloud.

export interface ComposerProps {
  state?: 'idle' | 'working' | 'paused'
  repo?: string
  branch?: string
  pr?: string
  adds?: number
  dels?: number
  startedAt?: number
  /** The running turn is blocked on a permission ask. */
  waiting?: boolean
  draft?: string
  /** The model id (without `cloud/`) and the ones to pick from; the menu shows when there's a list. */
  model?: string | null
  models?: Model[]
  onModel?: (id: string) => void
  /** When the engine asks before acting; the chip shows once the engine (or a new session) says. */
  mode?: Mode | null
  onMode?: (mode: Mode) => void
  onSend: (text: string) => void
  onStop?: () => void
  /** A new session's repo picker, in the composer: recent repos, search, or a pasted URL.
   * With `onRepo`, sending without a repo opens it instead. */
  onRepo?: (repo: string) => void
  recent?: string[]
  /** Open the repo menu on mount (e.g. back from sign-in with a message but no repo). */
  pickRepo?: boolean
  /** Starting a session: the send button waits. */
  busy?: boolean
  onGit?: () => void
  autoFocus?: boolean
}


function useTimer(since?: number) {
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    if (!since) return
    const t = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(t)
  }, [since])
  if (!since) return ''
  const s = Math.max(0, Math.floor((now - since) / 1000))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

export function Composer(p: ComposerProps) {
  const [text, setText] = useState(p.draft ?? '')
  const [menu, setMenu] = useState<'plus' | 'model' | 'mode' | 'repo' | null>(p.pickRepo ? 'repo' : null)
  const [q, setQ] = useState('')
  const ref = useRef<HTMLTextAreaElement>(null)
  const working = p.state === 'working', paused = p.state === 'paused'
  const timer = useTimer(working ? p.startedAt : undefined)
  useEffect(() => { if (p.draft !== undefined) setText(p.draft) }, [p.draft])
  useEffect(() => { if (p.autoFocus) ref.current?.focus() }, [p.autoFocus])
  useEffect(() => { if (p.pickRepo) setMenu('repo') }, [p.pickRepo])

  const send = () => {
    const t = text.trim()
    if (!t || paused || p.busy) return
    if (p.onRepo && !p.repo) return setMenu('repo')
    p.onSend(t)
    setText('')
  }
  const placeholder = working ? 'Working… Esc interrupts · Return queues a follow-up'
    : paused ? 'Paused · out of credits'
    : 'Ask Frog to do something, or paste a GitHub repo'
  const hasGit = (p.adds ?? 0) + (p.dels ?? 0) > 0

  return (
    <div className="cz">
      {menu === 'plus' && (
        <div className="f-card cz-menu" role="menu" style={{ left: 8 }}>
          <button type="button" role="menuitem" onClick={() => { setText(text + '@'); setMenu(null); ref.current?.focus() }}><span>@</span>Mention a file</button>
        </div>
      )}

      {menu === 'model' && (
        <div className="f-card cz-menu" role="menu" aria-label="Model" style={{ left: 150, width: 300 }}>
          <div className="cz-menu-h">Model on Frog Cloud</div>
          {p.models?.map((m) => (
            <button key={m.id} type="button" role="menuitemradio" aria-checked={m.id === p.model} onClick={() => { p.onModel?.(m.id); setMenu(null) }}>
              <span style={{ flex: 1, minWidth: 0 }}><b style={{ fontWeight: 600 }}>{m.id}</b><br /><span className="det">{[price(m), m.context ? `${Math.round(m.context / 1000)}k context` : ''].filter(Boolean).join(' · ')}</span></span>
              <span style={{ color: 'var(--frog)', opacity: m.id === p.model ? 1 : 0 }}>✓</span>
            </button>
          ))}
        </div>
      )}
      {menu === 'repo' && p.onRepo && (() => {
        const typed = parseRepo(q)
        const list = (p.recent ?? []).filter((r) => r.toLowerCase().includes(q.trim().toLowerCase()))
        const pick = (r: string) => { p.onRepo!(r); setMenu(null); setQ(''); ref.current?.focus() }
        return (
          <div className="f-card cz-menu cz-repos" role="menu" aria-label="Repo" style={{ left: 150, width: 320 }}>
            <input className="cz-search" autoFocus value={q} placeholder="Search repos, or paste a GitHub URL" aria-label="Repo"
              onChange={(e) => setQ(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Escape') setMenu(null)
                if (e.key === 'Enter') { e.preventDefault(); const r = typed ?? list[0]; if (r) pick(r) }
              }} />
            {typed && !list.includes(typed) && <button type="button" role="menuitem" onClick={() => pick(typed)}><span style={{ flex: 1 }}>{typed}</span><span className="det">from GitHub</span></button>}
            {list.length > 0 && <div className="cz-menu-h">Recent</div>}
            {list.map((r) => (
              <button key={r} type="button" role="menuitemradio" aria-checked={r === p.repo} onClick={() => pick(r)}>
                <span style={{ flex: 1 }}>{r}</span><span style={{ color: 'var(--frog)', opacity: r === p.repo ? 1 : 0 }}>✓</span>
              </button>
            ))}
            {!typed && list.length === 0 && <div className="det wrap" style={{ padding: '6px 10px' }}>Type owner/name or paste a GitHub URL. Private repos need the Frog GitHub App.</div>}
          </div>
        )
      })()}
      {menu === 'mode' && (
        <div className="f-card cz-menu" role="menu" aria-label="When Frog asks" style={{ left: 150, width: 300 }}>
          <div className="cz-menu-h">When Frog asks</div>
          {modes.map((m) => (
            <button key={m.id} type="button" role="menuitemradio" aria-checked={m.id === p.mode} onClick={() => { p.onMode?.(m.id); setMenu(null) }}>
              <span style={{ flex: 1, minWidth: 0 }}><b style={{ fontWeight: 600 }}>{m.label}</b><br /><span className="det wrap">{m.note}</span></span>
              <span style={{ color: 'var(--frog)', opacity: m.id === p.mode ? 1 : 0 }}>✓</span>
            </button>
          ))}
        </div>
      )}

      {p.branch && (
        <div className="cz-bar" title="Where this conversation works, and what's changed there">
          <span style={{ color: 'var(--fg)' }}>{p.repo?.split('/')[1] ?? p.repo}</span>
          <span style={{ color: 'var(--faint)' }}>{p.branch}</span>
          <span style={{ flex: 1 }} />
          {p.pr && (
            <a href="#" className="cz-plate" onClick={(e) => e.preventDefault()} title={`This session is bound to ${p.pr}. Pushes go there, and checks and reviews show up here.`}>
              <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="var(--frog)" strokeWidth="2.2" strokeLinecap="round"><circle cx="6" cy="6" r="2.5" /><circle cx="6" cy="18" r="2.5" /><circle cx="18" cy="18" r="2.5" /><path d="M6 8.5v7M18 15.5V9a3 3 0 0 0-3-3h-4" /></svg>
              <span className="num">{p.pr}</span>
            </a>
          )}
          {hasGit && (
            <>
              <span className="cz-plate num" title="Files with uncommitted changes"><span style={{ color: 'var(--frog)' }}>+{p.adds}</span><span style={{ color: 'var(--warn)' }}>−{p.dels}</span></span>
              <button type="button" className="cz-plate" onClick={p.onGit} title={p.pr ? 'Ask Frog to commit and push to the bound PR' : 'Ask Frog to commit the current changes'}>
                {p.pr ? `Push to ${p.pr}` : 'Commit changes'}
              </button>
            </>
          )}
        </div>
      )}

      <div className="f-glass cz-box">
        <label htmlFor="cz" className="sr">Message Frog</label>
        <textarea
          id="cz" ref={ref} rows={working ? 1 : 2} placeholder={placeholder} value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey && !e.metaKey) { e.preventDefault(); send() }
            if (e.key === 'Escape' && working) p.onStop?.()
          }}
        />
        <div className="cz-row">
          <button type="button" className="cz-ic" onClick={() => setMenu(menu === 'plus' ? null : 'plus')} aria-label="Mention a file" aria-expanded={menu === 'plus'} style={{ width: 28, height: 28, border: '1px solid var(--line)' }}>
            <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><path d="M12 5v14M5 12h14" /></svg>
          </button>
          <span className="cz-chip" title="Web sessions run in a private Frog Cloud sandbox" style={{ color: 'var(--place-cloud)', cursor: 'default' }}>
            <span aria-hidden="true">☁</span>Frog Cloud
          </span>
          {(!!p.model || !!p.models?.length) && (
            <button type="button" className="f-pill f-pill--cloud" aria-label={`Model: ${p.model ?? 'default'} on Frog Cloud`} aria-expanded={menu === 'model'}
              disabled={!p.models?.length || !p.onModel} onClick={() => setMenu(menu === 'model' ? null : 'model')}>
              <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M7 18a5 5 0 0 1-.6-9.96A6 6 0 0 1 18 9a4.5 4.5 0 0 1-.5 9z" /></svg>
              {p.model ?? 'Default model'}{p.models?.length ? <span className="chev">▾</span> : null}
            </button>
          )}
          {p.mode && p.onMode && (
            <button type="button" className="f-pill" style={{ color: p.mode === 'yolo' ? 'var(--notice)' : 'var(--muted)' }} aria-expanded={menu === 'mode'}
              title="When Frog asks before acting" onClick={() => setMenu(menu === 'mode' ? null : 'mode')}>
              {modes.find((m) => m.id === p.mode)?.label} <span className="chev">▾</span>
            </button>
          )}
          {!p.branch && (
            <button type="button" className="cz-chip" disabled={!p.onRepo} aria-expanded={menu === 'repo'} onClick={() => setMenu(menu === 'repo' ? null : 'repo')}>
              <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M3 7h6l2 2h10v10H3z" /></svg>
              {p.repo || 'Connect a repo'}
            </button>
          )}
          <span style={{ flex: 1 }} />
          <span style={{ fontSize: 12, color: paused ? 'var(--warn)' : p.waiting ? 'var(--notice)' : 'var(--muted)', whiteSpace: 'nowrap' }}>
            {working && p.waiting ? 'Waiting on you' : working ? `Working · ${timer}` : paused ? 'Out of credits' : ''}
          </span>
          {working ? (
            <button type="button" className="cz-send" aria-label="Stop (Esc)" onClick={p.onStop} style={{ background: 'var(--fg)', color: 'var(--bg)' }}>
              <svg aria-hidden="true" width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><rect x="5" y="5" width="14" height="14" rx="2" /></svg>
            </button>
          ) : (
            <button type="button" className="cz-send" aria-label="Send" onClick={send} style={{ background: paused ? 'var(--faint)' : 'var(--frog)' }}>
              <svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"><path d="M12 19V5M5 12l7-7 7 7" /></svg>
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
