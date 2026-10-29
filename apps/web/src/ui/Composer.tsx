import { useEffect, useRef, useState } from 'react'

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
  /** Shown when the gateway reports one; there's no model list to pick from yet. */
  model?: string
  onSend: (text: string) => void
  onStop?: () => void
  onRepo?: () => void
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
  const [menu, setMenu] = useState<'plus' | null>(null)
  const ref = useRef<HTMLTextAreaElement>(null)
  const working = p.state === 'working', paused = p.state === 'paused'
  const timer = useTimer(working ? p.startedAt : undefined)
  useEffect(() => { if (p.draft !== undefined) setText(p.draft) }, [p.draft])
  useEffect(() => { if (p.autoFocus) ref.current?.focus() }, [p.autoFocus])

  const send = () => {
    const t = text.trim()
    if (!t || paused) return
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
          {p.model && (
            <span className="f-pill f-pill--cloud" style={{ cursor: 'default' }} title={`Model: ${p.model} on Frog Cloud`}>
              <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M7 18a5 5 0 0 1-.6-9.96A6 6 0 0 1 18 9a4.5 4.5 0 0 1-.5 9z" /></svg>
              {p.model}
            </span>
          )}
          {!p.branch && (
            <button type="button" className="cz-chip" onClick={p.onRepo}>
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
