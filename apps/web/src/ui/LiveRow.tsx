import { createContext, useContext, useEffect, useRef, useState, type KeyboardEvent, type ReactNode } from 'react'
import type { Entry } from '../engine/thread'
import { segments, type TimedEvent } from '../engine/timeline'
import type { Model } from '../models'
import { TurnLine, TurnPanel, paceFromCounts } from './TurnGraph'
import { CopyButton } from './Transcript'
import { OUTLINE_MAX, STALL_AT, liveRow, rateOf, secs, stalledLabel, type LiveRow } from './rows'

// Phase 2 of the unified transcript (docs/design/transcript/spec.md, "The thinking row and the
// stats line"): one live row at the end of the running turn, its stats 2 under it, and the
// thinking's outline, live or settled. The row's words come from rows.ts `liveRow`.
//
// What changes several times a second (the token count, the clock, signs of life) reaches the
// row through LiveContext, so it redraws the row and never the memoized turn above it.

export interface LiveInfo {
  /** When the running turn started (engine time). */
  startedAt: number
  live: { output: number; soFar: boolean; slow: boolean; cached: number | null } | null
  pulse: number
  firstOutputAt: number | null
  askedAt: number | null
  activity: string | null
  /** A card outside the turn (an MCP elicitation) is waiting on a person. */
  waitingElsewhere: boolean
}
export const LiveContext = createContext<LiveInfo | null>(null)

/** Re-render every `ms` while mounted. */
function useNow(ms = 1000) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), ms); return () => clearInterval(t) }, [ms])
  return now
}

// Opened thinking stays open for that turn when the row redraws or scrolls back (spec, "Hover
// and opening"); it never opens itself.
const opened = new Map<string, boolean>()
/** For tests: forget what was opened. */
export function resetThoughts() { opened.clear() }
function useOpen(id: string | undefined): [boolean, (v: boolean) => void] {
  const [open, set] = useState(() => (id ? opened.get(id) ?? false : false))
  useEffect(() => { set(id ? opened.get(id) ?? false : false) }, [id])
  return [open, (v) => { if (id) opened.set(id, v); set(v) }]
}

/** The thought, cross-fading when it changes: out over 180 ms, in over 240 ms, overlapping, no
 * movement (transcript.css; reduced motion swaps). */
function ThoughtFade({ text }: { text: string }) {
  const [layers, setLayers] = useState<{ now: string; was: string | null; n: number }>({ now: text, was: null, n: 0 })
  useEffect(() => {
    setLayers((l) => (l.now === text ? l : { now: text, was: l.now || null, n: l.n + 1 }))
  }, [text])
  return (
    <span className="live-thought" title={layers.now || undefined}>
      {layers.was && <span key={`o${layers.n}`} className="tf tf-was" aria-hidden="true">{layers.was}</span>}
      <span key={`i${layers.n}`} className={`tf${layers.n ? ' tf-now' : ''}`}>{layers.now}</span>
    </span>
  )
}

/** The thinking as an outline: one line per shown thought, a line opening its paragraph, the
 * whole text one more click away in its own box. Return opens, arrows move, Esc closes a level. */
export function Outline({ e, live, onClose }: { e: Entry; live: boolean; onClose: () => void }) {
  const lines = live ? (e.shown ?? []).map((text) => ({ text, start: -1, end: -1 })) : (e.thoughts ?? [])
  const [para, setPara] = useState<number | null>(null)
  const [more, setMore] = useState(false)
  const [full, setFull] = useState(lines.length === 0)
  const box = useRef<HTMLDivElement>(null)
  // Twelve at most: the first twelve of a finished think; while live, the newest twelve, since
  // the outline grows at the bottom.
  const from = more || !live ? 0 : Math.max(0, lines.length - OUTLINE_MAX)
  const shown = lines.slice(from, more || live ? lines.length : OUTLINE_MAX)
  const hidden = lines.length - shown.length
  const moreButton = hidden > 0 && <button type="button" className="line-link outline-more" onClick={() => setMore(true)}>{hidden} more</button>
  const key = (ev: KeyboardEvent) => {
    if (ev.key === 'Escape') {
      ev.stopPropagation()
      if (full && lines.length) setFull(false)
      else if (para != null) setPara(null)
      else onClose()
      return
    }
    if (ev.key !== 'ArrowDown' && ev.key !== 'ArrowUp') return
    const items = [...(box.current?.querySelectorAll<HTMLButtonElement>('button.outline-line') ?? [])]
    const at = items.indexOf(document.activeElement as HTMLButtonElement)
    const next = items[Math.max(0, Math.min(items.length - 1, at + (ev.key === 'ArrowDown' ? 1 : -1)))]
    if (next) { ev.preventDefault(); next.focus() }
  }
  return (
    <div className="outline" ref={box} onKeyDown={key}>
      {live && moreButton}
      {shown.map((l, k) => {
        const i = k + from
        const can = l.start >= 0 && l.end > l.start
        const now = live && i === lines.length - 1
        return (
          <div key={i} className="outline-item">
            <button type="button" className={`outline-line${now ? ' now' : ''}`} aria-expanded={can ? para === i : undefined} aria-disabled={!can || undefined}
              onClick={() => can && setPara(para === i ? null : i)}>{l.text}</button>
            {para === i && <div className="outline-para">{e.text.slice(l.start, l.end).trim()}</div>}
          </div>
        )
      })}
      {!live && moreButton}
      {full ? (
        <div className="thought-full">
          <div className="thought-body">{e.text}</div>
          {!live && <div className="line-foot"><CopyButton text={e.text} label="Copy the thinking" /></div>}
        </div>
      ) : (
        <button type="button" className="line-link outline-more" onClick={() => setFull(true)}>Show all {e.text.length.toLocaleString('en-US')} characters</button>
      )}
    </div>
  )
}

/** A finished (or stopped) think: one quiet line, "Thought for 31s", opening to its outline. */
export function ThinkingLine({ e, label }: { e: Entry; label: string }) {
  const [open, setOpen] = useOpen(e.id)
  const row = useRef<HTMLButtonElement>(null)
  return (
    <div className="line-row thought" data-row="line" data-kind="thought" data-item={e.id}>
      <div className="line-plate">
        <button ref={row} type="button" className="line" aria-expanded={open} onClick={() => setOpen(!open)}>
          <span className="line-mark chev" aria-hidden="true">›</span>
          <span className="line-verb">{label}</span>
        </button>
      </div>
      {open && <Outline e={e} live={false} onClose={() => { setOpen(false); row.current?.focus() }} />}
    </div>
  )
}

/** The stats (spec, "The stats line"): time after the first second, tokens, tokens per second,
 * in meta. A count of streamed pieces is never shown as exact: no decimals, "so far" on hover. */
function Stats({ info, row, rate, quiet, now, graph }: { info: LiveInfo; row: LiveRow; rate: number | null; quiet: number; now: number; graph?: ReactNode }) {
  const took = now - info.startedAt
  const parts: string[] = []
  const hover: string[] = []
  if (took >= 1000) { parts.push(secs(took)); hover.push(`${row.kind === 'thinking' ? 'Thinking' : 'Working'} for ${secs(took).replace(/s$/, ' seconds')}`) }
  if (row.kind === 'waiting') {
    if (info.askedAt != null && now - info.askedAt >= 1000) parts.push(`waited ${secs(now - info.askedAt)}`)
  } else {
    if (info.live) {
      parts.push(`${info.live.output.toLocaleString('en-US')} tokens`)
      hover.push(`Written ${info.live.output.toLocaleString('en-US')} tokens${info.live.soFar ? ' so far' : ''}${rate != null ? ` at ${rate} tokens per second` : ''}`)
    }
    if (rate != null && rate > 0) parts.push(`${rate} tok/s`)
    // Slow is the engine's word for it (#426), shown while the latest count says so.
    if (info.live?.slow) parts.push('Slow')
    if (info.live?.cached) hover.push(`Read ${info.live.cached.toLocaleString('en-US')} tokens from cache`)
    if (row.kind === 'writing' && quiet >= STALL_AT) parts.push(stalledLabel(quiet).replace(/^No/, 'no'))
  }
  if (info.firstOutputAt != null) hover.push(`First token after ${(Math.max(0, info.firstOutputAt - info.startedAt) / 1000).toFixed(1)} seconds`)
  if (!parts.length && !graph) return null
  return (
    <div className="live-stats">
      <span className="live-figures" title={hover.join('\n') || undefined}>
        {parts.map((p, i) => <span key={i}>{i > 0 && <span className="dot" aria-hidden="true"> · </span>}{p}</span>)}
      </span>
      {graph}
    </div>
  )
}

/** The end of the running turn: the live row and its stats, or the stats alone under an answer
 * that's writing. */
export function LiveTail({ entries, tl, waiting, waitItem, models = [] }: { entries: Entry[]; tl?: TimedEvent[]; waiting: boolean; /** The step a card now up belongs to. */ waitItem?: string; models?: Model[] }) {
  const info = useContext(LiveContext)
  const now = useNow()
  // Signs of life in the viewer's clock: the engine's times can be skewed against ours.
  const life = useRef({ pulse: -1, at: Date.now() })
  if (info && info.pulse !== life.current.pulse) life.current = { pulse: info.pulse, at: Date.now() }
  const samples = useRef<{ at: number; output: number }[]>([])
  const turn = useRef(0)
  if (info && turn.current !== info.startedAt) { turn.current = info.startedAt; samples.current = [] }
  const out = info?.live?.output
  if (out != null && samples.current[samples.current.length - 1]?.output !== out) samples.current = [...samples.current.slice(-40), { at: Date.now(), output: out }]
  const row = liveRow(entries, { waiting: waiting || !!info?.waitingElsewhere, activity: info?.activity ?? null })
  const [open, setOpen] = useOpen(row.kind === 'thinking' ? row.item : undefined)
  const [ready, setReady] = useState(false)
  useEffect(() => { setReady(false); const t = setTimeout(() => setReady(true), 600); return () => clearTimeout(t) }, [row.item, row.kind])
  const button = useRef<HTMLButtonElement>(null)
  const [panel, setPanel] = useState(false)
  if (!info) return null

  const quiet = now - life.current.at
  const rate = rateOf(samples.current, now)
  // The turn line at the stats' right end while live (spec, "The turn line"): the segments so far,
  // the open one growing to now, and the pace from the running counts, a second a bucket.
  // A card still up is a wait growing to now, cut out of its step like an answered one.
  const up = waiting && info.askedAt != null ? [{ created: now, event: 'permission_resolved', asked: info.askedAt, ...(waitItem ? { item: waitItem } : {}) }] : []
  const segs = segments([...(tl ?? []), ...up], now)
  const total = Math.max(1, now - info.startedAt)
  const pace = paceFromCounts(samples.current, info.startedAt, now)
  const graph = segs.length ? <TurnLine segs={segs} total={total} pace={pace} entries={entries} onOpen={() => setPanel(true)} /> : undefined
  const stats = (
    <>
      <Stats info={info} row={row} rate={rate} quiet={quiet} now={now} graph={graph} />
      {panel && <TurnPanel segs={segs} total={total} entries={entries} models={models} live pace={pace} onClose={() => setPanel(false)} />}
    </>
  )
  if (row.kind === 'writing') return <div className="live-tail" data-row="stats">{stats}</div>

  // Thinking (and the pause before it) can stall; a step or a card is held still on purpose. At
  // 30 s the engine asks the person (Keep waiting / Stop the turn), and the card waits like any.
  const thinking = row.kind === 'thinking'
  const stalled = thinking && quiet >= STALL_AT
  const state = row.kind === 'waiting' ? 'waiting' : stalled ? 'stalled' : thinking && quiet < 1500 && info.pulse > 0 ? 'on' : 'still'
  const item = thinking && row.item ? entries.find((e) => e.id === row.item) : undefined
  const words: ReactNode = (
    <>
      <span className="line-mark" aria-hidden="true"><span className="live-dot" /></span>
      <span className="live-label">{stalled ? stalledLabel(quiet) : row.label}</span>
      {row.object && <span className={`line-obj${row.mono ? ' mono' : ''}`}>{row.object}</span>}
      {thinking && item && !stalled && !open && <ThoughtFade text={ready ? row.thought : ''} />}
      {item && <span className="live-chev" aria-hidden="true">›</span>}
    </>
  )
  return (
    <div className="live-row" data-row="live" data-kind={row.kind} data-state={state} role="status">
      <div className="line-plate">
        {item
          ? <button ref={button} type="button" className="line live" aria-expanded={open} onClick={() => setOpen(!open)}>{words}</button>
          : <div className="line live">{words}</div>}
      </div>
      {open && item && <Outline e={item} live onClose={() => { setOpen(false); button.current?.focus() }} />}
      {stats}
    </div>
  )
}
