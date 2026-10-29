import { useEffect, useRef, useState } from 'react'
import type { Image, Mode } from '../cloud/protocol'
import { modes, price, type Model } from '../models'
import { parseRepo } from '../store'

// Port of Composer.dc.html with platform="web". The web is all Frog Cloud, so there is no run-on
// chip (the Mac's "this Mac / Frog Cloud" choice).

export interface ComposerProps {
  /** Context used of the window, from the engine's status: a ring by the send button. */
  context?: { used: number | null; window: number } | null
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
  /** Signed out: the repo chip asks to sign in (with what's typed) instead of opening the picker. */
  onConnect?: (text: string) => void
  /** Signed out: with nothing typed, the send button is a sign-in button instead. */
  onSignIn?: () => void
  onModel?: (id: string) => void
  /** When the engine asks before acting; the chip shows once the engine (or a new session) says. */
  mode?: Mode | null
  onMode?: (mode: Mode) => void
  onSend: (text: string, images: Image[]) => void
  /** Suggestion chips over the box while it's empty. `send` chips send on click; others fill
   * the box. `act` marks one that acts outside the project (push, deploy). */
  chips?: { text: string; send?: boolean; act?: boolean }[]
  /** Messages sent while Frog works: they go together when the turn ends. × takes one back. */
  queued?: { text: string; images: Image[] }[]
  onUnqueue?: (i: number) => void
  /** False when the session's model can't read images (the engine's status.vision). */
  vision?: boolean | null
  /** A message taken back out of the queue, for the field. */
  restore?: { text: string; images: Image[] } | null
  onStop?: () => void
  /** A new session's repo picker, in the composer: recent repos, the account's repos, search, or
   * a pasted URL. Optional: a session can start without one. */
  onRepo?: (repo: string | undefined) => void
  recent?: string[]
  /** Repos the Frog GitHub App can reach, plus public ones (GET /v1/repos). */
  repos?: string[]
  /** The App's install page, to give Frog access to more repos. */
  install?: string
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
  // Where the open menu's button sits, so the menu opens right above it.
  const [at, setAt] = useState(8)
  const anchor = (e: { currentTarget: Element }) => setAt(e.currentTarget.getBoundingClientRect().left - (root.current?.getBoundingClientRect().left ?? 0))
  const ref = useRef<HTMLTextAreaElement>(null)
  const working = p.state === 'working', paused = p.state === 'paused'
  const timer = useTimer(working ? p.startedAt : undefined)
  useEffect(() => { if (p.draft !== undefined) setText(p.draft) }, [p.draft])
  useEffect(() => { if (p.autoFocus) ref.current?.focus() }, [p.autoFocus])
  useEffect(() => { if (p.pickRepo) setMenu('repo') }, [p.pickRepo])
  // A menu closes on any click outside it (its own toggle chip toggles it), or Escape.
  const root = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!menu) return
    const down = (e: MouseEvent) => {
      const t = e.target as Element
      if (root.current?.contains(t) && t.closest('.cz-menu, [aria-expanded]')) return
      setMenu(null)
    }
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') setMenu(null) }
    document.addEventListener('mousedown', down)
    document.addEventListener('keydown', key)
    return () => { document.removeEventListener('mousedown', down); document.removeEventListener('keydown', key) }
  }, [menu])

  const [images, setImages] = useState<Image[]>([])
  const file = useRef<HTMLInputElement>(null)
  useEffect(() => {
    if (!p.restore) return
    setText((t) => (t ? `${p.restore!.text}\n${t}` : p.restore!.text))
    setImages((im) => [...p.restore!.images, ...im])
  }, [p.restore])
  /** Images from paste, drop or the file picker, as base64 (Op::Submit images). Up to 8, 5 MB each. */
  const attach = async (files: Iterable<File>) => {
    const add: Image[] = []
    for (const f of files) {
      if (!f.type.startsWith('image/') || f.size > 5 * 1024 * 1024) continue
      const data = await new Promise<string>((res) => { const r = new FileReader(); r.onload = () => res(String(r.result).split(',')[1] ?? ''); r.readAsDataURL(f) })
      add.push({ mime: f.type, data })
    }
    if (add.length) setImages((im) => [...im, ...add].slice(0, 8))
  }
  const send = () => {
    const t = text.trim()
    if ((!t && !images.length) || paused || p.busy) return
    p.onSend(t, images)
    setText('')
    setImages([])
  }
  const placeholder = working ? 'Working… Esc interrupts · Return queues a follow-up'
    : paused ? 'Paused · out of credits'
    : 'Ask Frog to do something, or paste a GitHub repo'
  const hasGit = (p.adds ?? 0) + (p.dels ?? 0) > 0

  return (
    <div className="cz" ref={root}>
      {!text && !images.length && !working && !menu && !!p.chips?.length && (
        <div className="cz-chips">
          {p.chips.map((c) => (
            <button key={c.text} type="button" className={`cz-sug${c.act ? ' act' : ''}`}
              onClick={() => { if (c.send) p.onSend(c.text, []); else { setText(c.text); ref.current?.focus() } }}>
              {c.act ? '↗ ' : ''}{c.text}
            </button>
          ))}
        </div>
      )}
      {menu === 'plus' && (
        <div className="f-card cz-menu" role="menu" style={{ left: 8 }}>
          <button type="button" role="menuitem" onClick={() => { setMenu(null); file.current?.click() }}><span>▣</span>Attach images…</button>
          <button type="button" role="menuitem" onClick={() => { setText(text + '@'); setMenu(null); ref.current?.focus() }}><span>@</span>Mention a file</button>
        </div>
      )}

      {menu === 'model' && (
        <div className="f-card cz-menu" role="menu" aria-label="Model" style={{ left: at, width: 300 }}>
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
        const match = (r: string) => r.toLowerCase().includes(q.trim().toLowerCase())
        const recent = (p.recent ?? []).filter(match)
        const yours = (p.repos ?? []).filter((r) => match(r) && !recent.includes(r))
        const list = [...recent, ...yours]
        const pick = (r: string | undefined) => { p.onRepo!(r); setMenu(null); setQ(''); ref.current?.focus() }
        return (
          <div className="f-card cz-menu cz-repos" role="menu" aria-label="Repo" style={{ left: 150, width: 320 }}>
            <input className="cz-search" autoFocus value={q} placeholder="Search repos, or paste a GitHub URL" aria-label="Repo"
              onChange={(e) => setQ(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Escape') setMenu(null)
                if (e.key === 'Enter') { e.preventDefault(); const r = typed ?? list[0]; if (r) pick(r) }
              }} />
            {typed && !list.includes(typed) && <button type="button" role="menuitem" onClick={() => pick(typed)}><span style={{ flex: 1 }}>{typed}</span><span className="det">from GitHub</span></button>}
            {!q && (
              <button type="button" role="menuitemradio" aria-checked={!p.repo} onClick={() => pick(undefined)}>
                <span style={{ flex: 1 }}>No repo</span><span style={{ color: 'var(--frog)', opacity: !p.repo ? 1 : 0 }}>✓</span>
              </button>
            )}
            <div className="cz-list">
              {([['Recent', recent], ['Your repos', yours]] as const).map(([h, rs]) => rs.length > 0 && (
                <div key={h}>
                  <div className="cz-menu-h">{h}</div>
                  {rs.map((r) => (
                    <button key={r} type="button" role="menuitemradio" aria-checked={r === p.repo} onClick={() => pick(r)}>
                      <span style={{ flex: 1 }}>{r}</span><span style={{ color: 'var(--frog)', opacity: r === p.repo ? 1 : 0 }}>✓</span>
                    </button>
                  ))}
                </div>
              ))}
            </div>
            {!typed && list.length === 0 && q && <div className="det wrap" style={{ padding: '6px 10px' }}>No match. Type owner/name or paste a GitHub URL.</div>}
            {p.install && <a className="cz-more" href={p.install} target="_blank" rel="noreferrer">Give Frog access to more repos</a>}
          </div>
        )
      })()}
      {menu === 'mode' && (
        <div className="f-card cz-menu" role="menu" aria-label="When Frog asks" style={{ left: at, width: 300 }}>
          <div className="cz-menu-h">When Frog asks</div>
          {modes.map((m) => (
            <button key={m.id} type="button" role="menuitemradio" aria-checked={m.id === p.mode} onClick={() => { p.onMode?.(m.id); setMenu(null) }}>
              <span style={{ flex: 1, minWidth: 0 }}><b style={{ fontWeight: 600 }}>{m.label}</b><br /><span className="det wrap">{m.note}</span></span>
              <span style={{ color: 'var(--frog)', opacity: m.id === p.mode ? 1 : 0 }}>✓</span>
            </button>
          ))}
        </div>
      )}

      {/* The context bar: only once there's something to show, a bound PR or file changes. */}
      {p.branch && (!!p.pr || hasGit) && (
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

      {!!p.queued?.length && (
        <div className="cz-queue" aria-label="Queued messages">
          {p.queued.map((q, i) => (
            <div key={i} className="cz-queued">
              <span className="det">Queued</span><span className="ellip" style={{ flex: 1 }}>{q.text || `${q.images.length} image${q.images.length === 1 ? '' : 's'}`}</span>
              <button type="button" className="f-btn f-btn--plain" aria-label="Take back" title="Take back to edit" onClick={() => p.onUnqueue?.(i)}>✕</button>
            </div>
          ))}
        </div>
      )}
      <div className="f-glass cz-box"
        onDragOver={(e) => { if ([...e.dataTransfer.items].some((i) => i.type.startsWith('image/'))) e.preventDefault() }}
        onDrop={(e) => { if (e.dataTransfer.files.length) { e.preventDefault(); attach(e.dataTransfer.files) } }}>
        <input ref={file} type="file" accept="image/*" multiple hidden onChange={(e) => { if (e.target.files) attach(e.target.files); e.target.value = '' }} />
        {images.length > 0 && (
          <div className="cz-imgs">
            {images.map((im, i) => (
              <div key={i} className="cz-img">
                <img src={`data:${im.mime};base64,${im.data}`} alt="" />
                <button type="button" aria-label="Remove image" onClick={() => setImages(images.filter((_, j) => j !== i))}>✕</button>
              </div>
            ))}
            {p.vision === false && <span className="det wrap" style={{ color: 'var(--notice)' }}>This model can't see images; it gets a note that one was attached.</span>}
          </div>
        )}
        <label htmlFor="cz" className="sr">Message Frog</label>
        <textarea
          id="cz" ref={ref} rows={working ? 1 : 2} placeholder={placeholder} value={text}
          onChange={(e) => setText(e.target.value)}
          onPaste={(e) => { const fs = [...e.clipboardData.files].filter((f) => f.type.startsWith('image/')); if (fs.length) { e.preventDefault(); attach(fs) } }}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey && !e.metaKey) { e.preventDefault(); send() }
            if (e.key === 'Escape' && working) p.onStop?.()
          }}
        />
        <div className="cz-row">
          <button type="button" className="cz-ic" onClick={() => setMenu(menu === 'plus' ? null : 'plus')} aria-label="Attach images or mention a file" aria-expanded={menu === 'plus'} style={{ width: 28, height: 28, border: '1px solid var(--line)' }}>
            <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><path d="M12 5v14M5 12h14" /></svg>
          </button>
          {(!!p.model || !!p.models?.length) && (
            <button type="button" className="f-pill f-pill--cloud" aria-label={`Model: ${p.model ?? 'default'} on Frog Cloud`} aria-expanded={menu === 'model'}
              disabled={!p.models?.length || !p.onModel} onClick={(e) => { anchor(e); setMenu(menu === 'model' ? null : 'model') }}>
              <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M7 18a5 5 0 0 1-.6-9.96A6 6 0 0 1 18 9a4.5 4.5 0 0 1-.5 9z" /></svg>
              {p.model ?? 'Default model'}{p.models?.length ? <span className="chev">▾</span> : null}
            </button>
          )}
          {p.mode && p.onMode && (
            <button type="button" className="f-pill" style={{ color: p.mode === 'yolo' ? 'var(--notice)' : 'var(--muted)' }} aria-expanded={menu === 'mode'}
              title="When Frog asks before acting" onClick={(e) => { anchor(e); setMenu(menu === 'mode' ? null : 'mode') }}>
              {modes.find((m) => m.id === p.mode)?.label} <span className="chev">▾</span>
            </button>
          )}
          {!p.branch && (
            <button type="button" className="cz-chip" disabled={!p.onRepo && !p.onConnect} aria-expanded={menu === 'repo'} onClick={() => (p.onConnect ? p.onConnect(text) : setMenu(menu === 'repo' ? null : 'repo'))}>
              <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M3 7h6l2 2h10v10H3z" /></svg>
              {p.repo || 'No repo'}
            </button>
          )}
          <span style={{ flex: 1 }} />
          {p.context?.window ? <ContextRing used={p.context.used} window={p.context.window} /> : null}
          <span style={{ fontSize: 12, color: paused ? 'var(--warn)' : p.waiting ? 'var(--notice)' : 'var(--muted)', whiteSpace: 'nowrap' }}>
            {working && p.waiting ? 'Waiting on you' : working ? `Working · ${timer}` : paused ? 'Out of credits' : ''}
          </span>
          {working ? (
            <button type="button" className="cz-send" aria-label="Stop (Esc)" onClick={p.onStop} style={{ background: 'var(--fg)', color: 'var(--bg)' }}>
              <svg aria-hidden="true" width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><rect x="5" y="5" width="14" height="14" rx="2" /></svg>
            </button>
          ) : p.onSignIn && !text.trim() && !images.length ? (
            <button type="button" className="cz-signin" onClick={p.onSignIn}>
              <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M12 .5a11.5 11.5 0 0 0-3.64 22.41c.58.1.79-.25.79-.56v-2c-3.2.7-3.88-1.37-3.88-1.37-.52-1.33-1.28-1.69-1.28-1.69-1.05-.71.08-.7.08-.7 1.16.08 1.77 1.19 1.77 1.19 1.03 1.77 2.7 1.26 3.36.96.1-.75.4-1.26.73-1.55-2.55-.29-5.24-1.28-5.24-5.69 0-1.26.45-2.29 1.19-3.1-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.17 1.18a11 11 0 0 1 5.77 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.81 1.19 1.84 1.19 3.1 0 4.42-2.7 5.39-5.26 5.68.41.36.78 1.06.78 2.14v3.17c0 .31.21.67.8.56A11.5 11.5 0 0 0 12 .5z" /></svg>
              Sign in
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

/** How full the context is, as a ring (the Mac's ContextRing); click it for the numbers. */
function ContextRing({ used, window }: { used: number | null; window: number }) {
  const [open, setOpen] = useState(false)
  const f = used ? Math.min(1, used / window) : 0
  const color = f > 0.8 ? 'var(--warn)' : f > 0.6 ? 'var(--notice)' : 'var(--muted)'
  const k = (n: number) => (n >= 1000 ? `${Math.round(n / 1000)}k` : String(n))
  const r = 6.5, c = 2 * Math.PI * r
  return (
    <span className="ctx">
      <button type="button" className="ctx-ring" aria-expanded={open} onClick={() => setOpen(!open)}
        aria-label={`Context ${Math.round(f * 100)}% full`} title={`${k(used ?? 0)} of ${k(window)} tokens (${Math.round(f * 100)}%)`}>
        <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
          <circle cx="9" cy="9" r={r} fill="none" stroke="var(--line-strong)" strokeWidth="2.5" />
          <circle cx="9" cy="9" r={r} fill="none" stroke={color} strokeWidth="2.5" strokeLinecap="round"
            strokeDasharray={`${f * c} ${c}`} transform="rotate(-90 9 9)" style={{ transition: 'stroke-dasharray .4s' }} />
        </svg>
      </button>
      {open && (
        <div className="f-card ctx-card" role="dialog" aria-label="Context">
          <div className="ctx-h"><b>Context</b><b style={{ color: f > 0.6 ? color : undefined }}>{Math.round(f * 100)}%</b></div>
          <div className="ctx-bar"><span style={{ width: `${f * 100}%`, background: f > 0.6 ? color : 'var(--frog)' }} /></div>
          <div className="det">{(used ?? 0).toLocaleString()} of {window.toLocaleString()} tokens</div>
        </div>
      )}
    </span>
  )
}
