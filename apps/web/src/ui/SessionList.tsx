import { useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import type { SessionSummary } from '../cloud/protocol'
import type { Thread } from '../engine/thread'
import { outOfCredits, peek } from '../store'

// The sidebar's sessions, after the Mac's: quiet one-line rows filed under days, a glyph only
// when the state means something, a second line only while a session is live or wants you,
// and sandboxes that never started folded into one row you can clear.

type Glyph = 'run' | 'ask' | 'unread' | 'fail' | 'paused' | null

function look(s: SessionSummary, t: Thread, unread: boolean): { glyph: Glyph; detail: string | null } {
  if (t.ask) return { glyph: 'ask', detail: `Can I ${t.ask.name.toLowerCase()} ${t.ask.arg}?` }
  if (t.question) return { glyph: 'ask', detail: t.question.question }
  if (t.elicitation) return { glyph: 'ask', detail: `${t.elicitation.server} needs your input` }
  if (outOfCredits(t)) return { glyph: 'paused', detail: 'Paused · out of credits' }
  if (t.running) return { glyph: 'run', detail: t.activity?.text ?? 'Working…' }
  if (s.state === 'starting') return { glyph: 'run', detail: 'Starting a sandbox…' }
  if (s.state === 'error') return { glyph: 'fail', detail: null }
  if (t.ended?.type === 'error') return { glyph: 'fail', detail: null }
  return { glyph: unread ? 'unread' : null, detail: null }
}

const DAY = 86_400_000
function day(ms: number, now: number): string {
  const start = new Date(now); start.setHours(0, 0, 0, 0)
  const t0 = start.getTime()
  if (ms >= t0) return 'Today'
  if (ms >= t0 - DAY) return 'Yesterday'
  if (ms >= t0 - 7 * DAY) return 'Previous 7 days'
  if (ms >= t0 - 30 * DAY) return 'Previous 30 days'
  return 'Older'
}


/** `folded`: group headings collapsed in this browser, by name ("Yesterday", a repo). */
type View = { group: 'date' | 'repo' | 'none'; sort: 'activity' | 'created' | 'name'; compact: boolean; archived: boolean; folded: string[] }
const VIEW = 'frog.sidebar'
function loadView(): View {
  const d: View = { group: 'date', sort: 'activity', compact: false, archived: false, folded: [] }
  try { return { ...d, ...JSON.parse(localStorage.getItem(VIEW) ?? '{}') } } catch { return d }
}

/** The second line, when rows aren't compact: what's true of the session right now. */
function second(s: SessionSummary, t: Thread): string {
  if (s.state === 'error') return s.error ?? "Couldn't start"
  if (s.state === 'starting') return 'Starting a sandbox'
  const kept = peek(s.id, s.updated)
  const live = [...t.turns].reverse().flatMap((u) => [...u.entries].reverse()).find((e) => e.kind === 'message')
  const said = (live && 'text' in live ? (live.text as string) : null) ?? kept.reply
  const snippet = said?.replace(/[#*_`>|]/g, '').replace(/\s+/g, ' ').trim()
  if (snippet) return [s.repo ? s.repo.split('/')[1] ?? s.repo : null, snippet].filter(Boolean).join(' · ')
  // At rest with nothing kept: what it is, not that it's asleep.
  const turns = t.turns.length || kept.turns
  const model = (t.model ?? kept.model)?.split('/').pop()
  return [s.repo ? s.repo.split('/')[1] ?? s.repo : null, turns ? `${turns} turn${turns === 1 ? '' : 's'}` : null, model].filter(Boolean).join(' · ') || (s.repo || 'Scratch sandbox, no repo')
}

// When you last looked at each session, so a turn that ended since gets a dot. Keyed off the
// gateway's last_turn: `updated` also moves when a sandbox sleeps or wakes.
const SEEN = 'frog.seen'
function loadSeen(): Record<string, number> { try { return JSON.parse(localStorage.getItem(SEEN) ?? '{}') } catch { return {} } }

export function SessionList(p: {
  sessions: SessionSummary[]
  thread: (id: string) => Thread
  title: (s: SessionSummary) => string
  current: string | null
  onOpen: (id: string) => void
  /** The search button opens the ⌘K palette, which searches sessions and their transcripts. */
  onSearch: () => void
  /** The row's right-click menu, as on the Mac. */
  onRename: (s: SessionSummary) => void
  onArchive: (s: SessionSummary, archived: boolean) => void
  onDelete: (s: SessionSummary) => void
  onClear: (ids: string[]) => void
  error: string | null
}) {
  // View options, as on the Mac (sidebarGroup, sidebarSort, compactSidebar), kept per browser.
  const [view, setViewOpts] = useState<View>(loadView)
  const [menu, setMenu] = useState(false)
  // The view options button sits beside the sidebar's collapse toggle (App's #side-acts).
  const [slot, setSlot] = useState<HTMLElement | null>(null)
  useEffect(() => setSlot(document.getElementById('side-acts')), [])
  // Rows drawn so far: the first screenful or two, more as the list scrolls near its end.
  const [shown, setShown] = useState(60)
  const more = useRef<HTMLDivElement>(null)
  const [ctx, setCtx] = useState<{ s: SessionSummary; x: number; y: number } | null>(null)
  useEffect(() => {
    if (!ctx) return
    const close = () => setCtx(null)
    addEventListener('mousedown', close); addEventListener('keydown', close); addEventListener('blur', close)
    return () => { removeEventListener('mousedown', close); removeEventListener('keydown', close); removeEventListener('blur', close) }
  }, [ctx])
  const setView = (v: Partial<View>) => { const next = { ...view, ...v }; setViewOpts(next); try { localStorage.setItem(VIEW, JSON.stringify(next)) } catch { /* private mode */ } }
  const [failedOpen, setFailedOpen] = useState(false)
  const [seen, setSeen] = useState(loadSeen)
  const now = Date.now()
  const list = useRef<HTMLDivElement>(null)
  const opts = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!p.current) return
    const s = p.sessions.find((x) => x.id === p.current)
    const mark = s ? Math.max(s.last_turn ?? 0, s.updated) : 0
    if (!s || (seen[s.id] ?? 0) >= mark) return
    const next = { ...seen, [s.id]: mark }
    setSeen(next)
    try { localStorage.setItem(SEEN, JSON.stringify(next)) } catch { /* private mode */ }
  }, [p.current, p.sessions, seen])

  // Draw more rows when the end of what's drawn scrolls into view.
  useEffect(() => {
    const el = more.current
    if (!el) return
    const io = new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) setShown((n) => n + 60) }, { root: list.current, rootMargin: '400px' })
    io.observe(el)
    return () => io.disconnect()
  }, [shown, p.sessions.length])

  // "/" opens the palette too, like ⌘K.
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      const typing = (e.target as HTMLElement).closest('input, textarea, [contenteditable]')
      if (e.key === '/' && !typing) { e.preventDefault(); p.onSearch() }
    }
    addEventListener('keydown', key)
    return () => removeEventListener('keydown', key)
  }, [p.onSearch]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!menu) return
    const down = (e: MouseEvent) => { if (!opts.current?.contains(e.target as Node)) setMenu(false) }
    addEventListener('mousedown', down)
    return () => removeEventListener('mousedown', down)
  }, [menu])

  const { groups, failed, total } = useMemo(() => {
    // A sandbox that never got a turn in, and isn't open, is clutter: it folds.
    const neverStarted = (s: SessionSummary) => s.state === 'error' && s.id !== p.current && !p.thread(s.id).turns.length
    // Show: the active list, or what's been archived (the open session stays either way).
    const pool = p.sessions.filter((s) => !!s.archived === view.archived || s.id === p.current)
    const failed = view.archived ? [] : pool.filter(neverStarted)
    const when = (s: SessionSummary) => (view.sort === 'created' ? s.created ?? s.updated : s.updated)
    const rest = pool.filter((s) => view.archived || !neverStarted(s))
      .sort(view.sort === 'name' ? (a, b) => p.title(a).localeCompare(p.title(b)) : (a, b) => when(b) - when(a))
    const key = (s: SessionSummary) => view.group === 'date' ? day(when(s), now) : view.group === 'repo' ? (s.repo || 'No repo') : ''
    const groups: { name: string; rows: SessionSummary[] }[] = []
    for (const s of rest.slice(0, shown)) {
      const name = key(s)
      const g = groups.find((x) => x.name === name)
      if (g) g.rows.push(s)
      else groups.push({ name, rows: [s] })
    }
    return { groups, failed, total: rest.length }
  }, [view, p.sessions, p.current, p.thread, p.title, now, shown])

  // ↑/↓ move between rows, ⏎ opens (buttons already do), Esc leaves the filter.
  const move = (e: React.KeyboardEvent) => {
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return
    const rows = [...(list.current?.querySelectorAll<HTMLButtonElement>('button.srow') ?? [])]
    if (!rows.length) return
    e.preventDefault()
    const i = rows.indexOf(document.activeElement as HTMLButtonElement)
    const next = e.key === 'ArrowDown' ? (i < 0 ? 0 : Math.min(rows.length - 1, i + 1)) : Math.max(0, i - 1)
    rows[next].focus()
  }

  const row = (s: SessionSummary) => {
    const t = p.thread(s.id)
    const unread = s.id !== p.current && !!seen[s.id] && !!s.last_turn && s.last_turn > seen[s.id]
    const { glyph, detail } = look(s, t, unread)
    const repo = s.repo ? s.repo.split('/')[1] ?? s.repo : null
    const quiet = !glyph && s.id !== p.current
    const status = glyph === 'run' ? (s.state === 'starting' ? 'Starting' : 'Running') : glyph === 'ask' ? 'Needs you' : glyph === 'fail' ? 'Failed' : glyph === 'paused' ? 'Paused' : null
    return (
      <button key={s.id} type="button" className={`srow${s.id === p.current ? ' on' : ''}${(detail && s.id === p.current) || !view.compact ? ' two' : ''}`} onClick={() => p.onOpen(s.id)}
        onContextMenu={(e) => { e.preventDefault(); setCtx({ s, x: e.clientX, y: e.clientY }) }}
        title={s.state === 'error' ? s.error ?? "The sandbox couldn't start" : undefined}>
        <span className="sbody">
          <span className="sline">
            <span className={`stitle${quiet ? ' quiet' : ''}`}>{p.title(s)}</span>
            {view.compact && repo && <span className="srepo">{repo}</span>}
            {s.pr && (
              <span className="spr" title={`Pull request ${s.pr}`}>
                <svg aria-hidden="true" width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"><circle cx="6" cy="6" r="2.5" /><circle cx="6" cy="18" r="2.5" /><circle cx="18" cy="18" r="2.5" /><path d="M6 8.5v7M18 15.5V9a3 3 0 0 0-3-3h-4" /></svg>
                {s.pr.replace(/^#/, '')}
              </span>
            )}
            {status ? <span className={`sstate sstate-${glyph}`}><span className={`sg sg-${glyph}`} />{status}</span>
              : glyph === 'unread' ? <span className="sg sg-unread" aria-label="New" />
              : null}
          </span>
          {view.compact
            ? detail && s.id === p.current && <span className={`sdetail${glyph === 'ask' ? ' ask' : ''}`}>{detail}</span>
            : <span className={`sdetail${glyph === 'ask' ? ' ask' : glyph === 'run' ? ' run' : glyph === 'fail' ? ' fail' : ''}`}>{detail ?? second(s, t)}</span>}
        </span>
      </button>
    )
  }

  return (
    <div className={`slist${view.compact ? ' compact' : ''}`} ref={list} onKeyDown={move}>
      {slot && createPortal(
      <div className="sbar" ref={opts}>
        <button type="button" className="ic-btn" aria-label="View options" title="View options" aria-expanded={menu} onClick={() => setMenu(!menu)}>
          <svg aria-hidden="true" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round"><path d="M4 7h10M18 7h2M4 17h4M12 17h8" /><circle cx="16" cy="7" r="2" /><circle cx="10" cy="17" r="2" /></svg>
        </button>
        {menu && (
          <div className="f-card sview" role="menu" aria-label="View options">
            <div className="cz-menu-h">Show</div>
            {([false, true] as const).map((a) => (
              <button key={String(a)} type="button" role="menuitemradio" aria-checked={view.archived === a} onClick={() => setView({ archived: a })}>
                <span style={{ flex: 1 }}>{a ? 'Archived' : 'Active'}</span>{view.archived === a && <span className="ok">✓</span>}
              </button>
            ))}
            <div className="cz-menu-h">Group by</div>
            {(['date', 'repo', 'none'] as const).map((g) => (
              <button key={g} type="button" role="menuitemradio" aria-checked={view.group === g} onClick={() => setView({ group: g })}>
                <span style={{ flex: 1 }}>{{ date: 'Date', repo: 'Repo', none: 'None' }[g]}</span>{view.group === g && <span className="ok">✓</span>}
              </button>
            ))}
            <div className="cz-menu-h">Sort by</div>
            {(['activity', 'created', 'name'] as const).map((o) => (
              <button key={o} type="button" role="menuitemradio" aria-checked={view.sort === o} onClick={() => setView({ sort: o })}>
                <span style={{ flex: 1 }}>{{ activity: 'Last activity', created: 'Date created', name: 'Name' }[o]}</span>{view.sort === o && <span className="ok">✓</span>}
              </button>
            ))}
            <div className="sview-sep" />
            <button type="button" role="menuitemcheckbox" aria-checked={view.compact} onClick={() => setView({ compact: !view.compact })}>
              <span style={{ flex: 1 }}>Compact</span>{view.compact && <span className="ok">✓</span>}
            </button>
          </div>
        )}
      </div>,
        slot,
      )}
      {p.error && <div className="det wrap" style={{ padding: '10px 8px', color: 'var(--warn)' }}>Couldn't load sessions. {p.error}</div>}
      {view.archived && !groups.length && <div className="det wrap" style={{ padding: '14px 8px' }}>Nothing archived. Archive a session from its ⋯ menu.</div>}
      {!p.error && p.sessions.length === 0 && <div className="det wrap" style={{ padding: '14px 8px' }}>No sessions yet. Start one and it shows up here, and in Frog on your other devices.</div>}
      {groups.map((g) => {
        const names = view.folded ?? []
        const folded = !!g.name && names.includes(g.name)
        const fold = () => setView({ folded: folded ? names.filter((n) => n !== g.name) : [...names, g.name] })
        return (
          <div key={g.name}>
            {g.name && (
              <button type="button" className="h sgroup" aria-expanded={!folded} onClick={fold}>
                <span>{g.name}</span>
                <span className="sgroup-n">{folded ? g.rows.length : ''}<span className={`chev2${folded ? '' : ' open'}`}>›</span></span>
              </button>
            )}
            {!folded && g.rows.map(row)}
          </div>
        )
      })}
      {total > shown && <div ref={more} className="slist-more" aria-hidden="true" />}
      {ctx && (
        <div className="f-card sctx" role="menu" style={{ left: ctx.x, top: ctx.y }} onMouseDown={(e) => e.stopPropagation()}>
          <button type="button" role="menuitem" onClick={() => { setCtx(null); p.onOpen(ctx.s.id); p.onRename(ctx.s) }}>Rename…</button>
          <button type="button" role="menuitem" onClick={() => { setCtx(null); p.onArchive(ctx.s, !ctx.s.archived) }}>{ctx.s.archived ? 'Unarchive' : 'Archive'}</button>
          <div className="sview-sep" />
          <button type="button" role="menuitem" style={{ color: 'var(--warn)' }} onClick={() => { setCtx(null); p.onDelete(ctx.s) }}>Delete…</button>
        </div>
      )}
      {failed.length > 0 && <>
            <div className="srow sfold">
              <button type="button" className="sfold-t" aria-expanded={failedOpen} onClick={() => setFailedOpen(!failedOpen)}>
                <span className="sgf"><span className={`chev2${failedOpen ? ' open' : ''}`}>›</span></span>
                <span>{failed.length} couldn't start</span>
              </button>
              <button type="button" className="sclear" onClick={() => p.onClear(failed.map((s) => s.id))}>Clear</button>
            </div>
            {failedOpen && failed.map(row)}
      </>}
    </div>
  )
}
