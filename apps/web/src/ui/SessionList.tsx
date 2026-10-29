import { useEffect, useMemo, useRef, useState } from 'react'
import type { SessionSummary } from '../cloud/protocol'
import type { Thread } from '../engine/thread'
import { outOfCredits } from '../store'

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

function age(ms: number, now: number) {
  const s = (now - ms) / 1000
  if (s < 60) return 'now'
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86_400) return `${Math.floor(s / 3600)}h`
  if (s < 7 * 86_400) return `${Math.floor(s / 86_400)}d`
  return new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

// When you last opened each session, so a finish you haven't seen gets a dot.
const SEEN = 'frog.seen'
function loadSeen(): Record<string, number> { try { return JSON.parse(localStorage.getItem(SEEN) ?? '{}') } catch { return {} } }

export function SessionList(p: {
  sessions: SessionSummary[]
  thread: (id: string) => Thread
  title: (s: SessionSummary) => string
  current: string | null
  onOpen: (id: string) => void
  onClear: (ids: string[]) => void
  error: string | null
}) {
  const [q, setQ] = useState('')
  const [failedOpen, setFailedOpen] = useState(false)
  const [seen, setSeen] = useState(loadSeen)
  const now = Date.now()
  const list = useRef<HTMLDivElement>(null)
  const search = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (!p.current) return
    const s = p.sessions.find((x) => x.id === p.current)
    if (!s || (seen[s.id] ?? 0) >= s.updated) return
    const next = { ...seen, [s.id]: s.updated }
    setSeen(next)
    try { localStorage.setItem(SEEN, JSON.stringify(next)) } catch { /* private mode */ }
  }, [p.current, p.sessions, seen])

  // ⌘K is the palette; "/" jumps to the sidebar's own filter.
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      const typing = (e.target as HTMLElement).closest('input, textarea, [contenteditable]')
      if (e.key === '/' && !typing) { e.preventDefault(); search.current?.focus() }
    }
    addEventListener('keydown', key)
    return () => removeEventListener('keydown', key)
  }, [])

  const { groups, failed } = useMemo(() => {
    const needle = q.trim().toLowerCase()
    const match = (s: SessionSummary) => !needle || `${p.title(s)} ${s.repo} ${s.branch} ${s.pr ?? ''}`.toLowerCase().includes(needle)
    // A sandbox that never got a turn in, and isn't open, is clutter: it folds.
    const neverStarted = (s: SessionSummary) => s.state === 'error' && s.id !== p.current && !p.thread(s.id).turns.length
    const shown = p.sessions.filter(match)
    const failed = needle ? [] : shown.filter(neverStarted)
    const rest = needle ? shown : shown.filter((s) => !neverStarted(s))
    const groups: { name: string; rows: SessionSummary[] }[] = []
    for (const s of [...rest].sort((a, b) => b.updated - a.updated)) {
      const name = day(s.updated, now)
      const g = groups[groups.length - 1]
      if (g?.name === name) g.rows.push(s)
      else groups.push({ name, rows: [s] })
    }
    return { groups, failed }
  }, [q, p.sessions, p.current, p.thread, p.title, now])

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
    const unread = s.id !== p.current && !!seen[s.id] && s.updated > seen[s.id]
    const { glyph, detail } = look(s, t, unread)
    const repo = s.repo ? s.repo.split('/')[1] ?? s.repo : null
    const quiet = !glyph && s.id !== p.current
    return (
      <button key={s.id} type="button" className={`srow${s.id === p.current ? ' on' : ''}${detail ? ' two' : ''}`} onClick={() => p.onOpen(s.id)}
        title={s.state === 'error' ? s.error ?? "The sandbox couldn't start" : undefined}>
        <span className={`sg${glyph ? ` sg-${glyph}` : ''}`} aria-label={glyph ?? undefined} />
        <span className="sbody">
          <span className="sline">
            <span className={`stitle${quiet ? ' quiet' : ''}`}>{p.title(s)}</span>
            {s.pr && <span className="stag">PR {s.pr.replace(/^#/, '')}</span>}
            {!s.pr && repo && <span className="stag">{repo}</span>}
            <span className="sage">{age(s.updated, now)}</span>
          </span>
          {detail && <span className={`sdetail${glyph === 'ask' ? ' ask' : glyph === 'run' ? ' run' : ''}`}>{detail}</span>}
        </span>
      </button>
    )
  }

  return (
    <div className="slist" ref={list} onKeyDown={move}>
      <label className="ssearch">
        <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><circle cx="11" cy="11" r="7" /><path d="M20 20l-3.5-3.5" /></svg>
        <input ref={search} value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search sessions" aria-label="Search sessions"
          onKeyDown={(e) => { if (e.key === 'Escape') { setQ(''); search.current?.blur() } }} />
        {!q && <kbd>/</kbd>}
      </label>
      {p.error && <div className="det wrap" style={{ padding: '10px 8px', color: 'var(--warn)' }}>Couldn't load sessions: {p.error}</div>}
      {!p.error && p.sessions.length === 0 && <div className="det wrap" style={{ padding: '14px 8px' }}>No sessions yet. Start one and it shows up here, and in Frog on your other devices.</div>}
      {q && !groups.length && <div className="det" style={{ padding: '14px 8px' }}>No sessions match “{q}”.</div>}
      {groups.map((g) => (
        <div key={g.name}>
          <div className="h"><span>{g.name}</span></div>
          {g.rows.map(row)}
        </div>
      ))}
      {failed.length > 0 && <>
            <div className="srow sfold">
              <button type="button" className="sfold-t" aria-expanded={failedOpen} onClick={() => setFailedOpen(!failedOpen)}>
                <span className="sg"><span className={`chev2${failedOpen ? ' open' : ''}`}>›</span></span>
                <span>{failed.length} couldn't start</span>
              </button>
              <button type="button" className="sclear" onClick={() => p.onClear(failed.map((s) => s.id))}>Clear</button>
            </div>
            {failedOpen && failed.map(row)}
      </>}
    </div>
  )
}
