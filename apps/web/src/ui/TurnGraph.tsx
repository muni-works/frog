import { useEffect, useMemo, useRef, useState, type MouseEvent as ReactMouseEvent } from 'react'
import { createPortal } from 'react-dom'
import type { Pace, TurnUsage } from '../cloud/protocol'
import type { Entry } from '../engine/thread'
import { totals, type Segment, type SegmentKind } from '../engine/timeline'
import { currentId, idOf, modelName, servedByName, type Model } from '../models'
import { money, tokens as fmtTokens, turnCost } from '../usage'
import { Hunks } from './Diff'
import { Outline } from './LiveRow'
import { lineOf, secs } from './rows'

// Phase 3 of the unified transcript (docs/design/transcript/spec.md, "The turn line and the turn
// panel"): a 200 × 16 line at the right end of the stats while live and of the footer at rest —
// a strip coloured by phase along the bottom, the pace curve above — grey until hovered; and the
// panel it opens, over the transcript, with the waterfall.

const W = 200
const H = 16
const STRIP = 3
/** A wait longer than this draws as a short broken segment with its length written on it. */
export const LONG_WAIT = 30_000
const BROKEN = 3_000

/** Tokens per second at `t` ms into the turn, from the pace buckets. */
export function speedAt(pace: Pace | null | undefined, t: number): number | null {
  if (!pace?.tokens.length) return null
  const i = Math.floor(t / pace.bucket_ms)
  return i >= 0 && i < pace.tokens.length ? Math.round((pace.tokens[i] * 1000) / pace.bucket_ms) : 0
}

/** A live turn's pace, from its running output counts (`output_tokens`, up to four a second):
 * the count's growth in each second since the turn started. `samples` are in the turn's clock. */
export function paceFromCounts(samples: { at: number; output: number }[], start: number, now: number, bucket = 1000): Pace | null {
  if (!samples.length) return null
  const n = Math.max(1, Math.ceil((now - start) / bucket))
  const tokens: number[] = []
  let prev = 0
  let k = 0
  for (let i = 0; i < n; i++) {
    const end = start + (i + 1) * bucket
    let last = prev
    while (k < samples.length && samples[k].at < end) last = samples[k++].output
    tokens.push(Math.max(0, last - prev))
    prev = last
  }
  return { bucket_ms: bucket, tokens }
}

/** The pace curve as an SVG path over `width` × `height`, the turn being `total` ms long. */
export function pacePath(pace: Pace | null | undefined, total: number, width: number, height: number): string {
  if (!pace?.tokens.length || total <= 0) return ''
  const max = Math.max(...pace.tokens, 1)
  const pts = pace.tokens.map((v, i) => [Math.min(width, (((i + 0.5) * pace.bucket_ms) / total) * width), height - (v / max) * (height - 1)])
  // The last bucket held to its end, so the curve runs as far as the time it covers.
  const end = Math.min(width, ((pace.tokens.length * pace.bucket_ms) / total) * width)
  if (end > pts[pts.length - 1][0]) pts.push([end, pts[pts.length - 1][1]])
  return pts.map(([x, y], i) => `${i ? 'L' : 'M'}${x.toFixed(1)},${y.toFixed(1)}`).join('')
}

/** The step a moment falls in: a tool, think or write before a wait (the step you'd look for). */
function stepAt(segs: Segment[], t: number): Segment | undefined {
  const here = segs.filter((s) => s.start_ms <= t && t < s.end_ms)
  return here.find((s) => s.kind !== 'waiting') ?? here[0]
}

/** What a step is called in a readout or a waterfall row. */
export function stepName(e: Entry | undefined, kind: SegmentKind): string {
  if (kind === 'waiting') return 'Waiting for you'
  if (!e) return kind === 'thinking' ? 'Thinking' : kind === 'writing' ? 'Writing' : 'A step'
  if (e.kind === 'reasoning') return 'Thinking'
  if (e.kind === 'message') return 'Writing'
  const l = lineOf(e)
  return [l.gist || l.verb, l.object].filter(Boolean).join(' ')
}

/** Mark the transcript's row for `item` with the hover plate (or a fold holding it). */
/** The row drawing `item`: its own, or the closed fold holding it. */
function rowOf(root: ParentNode, item: string): HTMLElement | null {
  const own = root.querySelector<HTMLElement>(`[data-item="${CSS.escape(item)}"]`)
  if (own && own.offsetParent !== null) return own
  return root.querySelector<HTMLElement>(`[data-steps~="${CSS.escape(item)}"]`) ?? own
}
function plate(root: Element | null, item: string | undefined) {
  document.querySelectorAll('.tx .scrubbed').forEach((x) => x.classList.remove('scrubbed'))
  if (!root || !item) return
  const row = rowOf(root, item)
  ;(row?.querySelector(':scope > .line-plate') ?? row)?.classList.add('scrubbed')
}
/** Scroll the transcript to the row for `item`. */
export function showStep(item: string | undefined) {
  if (!item) return
  const tx = document.querySelector('.tx')
  if (tx) rowOf(tx, item)?.scrollIntoView({ block: 'center', behavior: 'smooth' })
}

/** The turn line: grey at rest; on hover it takes its colours and scrubs. A click on the strip
 * goes to that step; anywhere else opens the panel. */
export function TurnLine({ segs, total, pace, entries, onOpen }: { segs: Segment[]; total: number; pace?: Pace | null; entries: Entry[]; onOpen: () => void }) {
  const [at, setAt] = useState<number | null>(null)
  const box = useRef<SVGSVGElement>(null)
  // The axis ends where the last segment does (live, that's now): a finished turn's bookkeeping
  // after its last step isn't drawn, so the strip reaches the right edge (spec, the right line).
  const span = Math.max(segs.length ? Math.max(...segs.map((s) => s.end_ms)) : total, 1)
  const x = (ms: number) => (ms / span) * W
  const path = pacePath(pace, span, W, H - STRIP - 1)
  const pick = (ev: ReactMouseEvent) => {
    const r = box.current!.getBoundingClientRect()
    return { t: Math.max(0, Math.min(span, ((ev.clientX - r.left) / r.width) * span)), strip: ev.clientY - r.top >= (r.height * (H - STRIP * 2)) / H }
  }
  const under = at != null ? stepAt(segs, at) : undefined
  useEffect(() => { plate(box.current?.closest('.turn') ?? null, under?.item) }, [under?.item])
  useEffect(() => () => plate(null, undefined), [])
  const speed = at != null ? speedAt(pace, at) : null
  return (
    <span className="turn-graph" data-hover={at != null || undefined}>
      <svg ref={box} width={W} height={H} viewBox={`0 0 ${W} ${H}`} role="button" tabIndex={0} aria-label="This turn's timeline: open the turn panel"
        onMouseMove={(ev) => setAt(pick(ev).t)} onMouseLeave={() => setAt(null)}
        onClick={(ev) => { const p = pick(ev); const s = p.strip ? stepAt(segs, p.t) : undefined; if (s?.item && s.kind !== 'waiting') showStep(s.item); else onOpen() }}
        onKeyDown={(ev) => { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); onOpen() } }}>
        {path && <path className="pace" d={path} fill="none" />}
        {segs.map((s, i) => <rect key={i} className={`seg seg-${s.kind}`} x={x(s.start_ms)} y={H - STRIP} width={Math.max(1, x(s.end_ms) - x(s.start_ms))} height={STRIP} />)}
        {at != null && <line className="hair" x1={x(at)} x2={x(at)} y1={0} y2={H} />}
      </svg>
      {at != null && (
        <span className="turn-read" role="status">
          {[secs(at), speed != null ? `${speed} tok/s` : '', under ? stepName(entries.find((e) => e.id === under.item), under.kind) : ''].filter(Boolean).join(' · ')}
        </span>
      )}
    </span>
  )
}

/** Wall time drawn on the waterfall's axis: a wait over 30 s takes 3 s of room. */
export function axis(segs: Segment[], total: number) {
  const long = segs.filter((s) => s.kind === 'waiting' && s.end_ms - s.start_ms > LONG_WAIT).map((s) => [s.start_ms, s.end_ms]).sort((a, b) => a[0] - b[0])
  const cut = (t: number) => long.reduce((d, [a, b]) => d + Math.max(0, Math.min(t, b) - a) - Math.min(Math.max(0, Math.min(t, b) - a), BROKEN), 0)
  const drawn = Math.max(1, total - cut(total))
  return { at: (t: number) => ((t - cut(t)) / drawn) * 100, broken: (s: Segment) => s.kind === 'waiting' && s.end_ms - s.start_ms > LONG_WAIT }
}

/** Nice tick spacing for `total` ms: about five ticks. */
function tickEvery(total: number) {
  const steps = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600].map((s) => s * 1000)
  return steps.find((s) => total / s <= 6) ?? 1_200_000
}

/** The turn panel: over the transcript, which dims and doesn't reflow. Esc or a click outside
 * closes it. A live turn's last bar keeps growing. */
export function TurnPanel({ segs, total, entries, usage, models, credit, live, pace, onClose }: {
  segs: Segment[]; total: number; entries: Entry[]; usage?: TurnUsage; models: Model[]; credit?: string; live: boolean
  /** A live turn's pace from its running counts (a finished turn's is in `usage`). */
  pace?: Pace | null; onClose: () => void
}) {
  const [rect, setRect] = useState<DOMRect | null>(null)
  const [sel, setSel] = useState<string | null>(null)
  const card = useRef<HTMLDivElement>(null)
  const close = useRef(onClose)
  close.current = onClose
  useEffect(() => {
    const pane = document.querySelector('.scroll')
    const measure = () => setRect(pane?.getBoundingClientRect() ?? null)
    measure()
    window.addEventListener('resize', measure)
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') close.current() }
    document.addEventListener('keydown', key)
    card.current?.focus()
    return () => { window.removeEventListener('resize', measure); document.removeEventListener('keydown', key) }
  }, [])

  const id = idOf(usage?.model ?? null)
  const model = models.find((m) => currentId(m.id) === id)
  const cost = usage ? turnCost(usage, model) : null
  const sum = totals(segs)
  const ax = useMemo(() => axis(segs, total), [segs, total])
  // One row per item, in the order they started; a wait sits on its tool's row.
  const rows = useMemo(() => {
    const order: string[] = []
    for (const s of segs) { const k = s.item ?? `wait-${s.start_ms}`; if (!order.includes(k)) order.push(k) }
    return order.map((k) => ({ item: k, segs: segs.filter((s) => (s.item ?? `wait-${s.start_ms}`) === k), e: entries.find((e) => e.id === k) }))
  }, [segs, entries])
  const every = tickEvery(total)
  const ticks = Array.from({ length: Math.floor(total / every) + 1 }, (_, i) => i * every)
  const chosen = rows.find((r) => r.item === sel)
  const path = pacePath(usage?.pace ?? pace, total, 100, 28)
  // The same time the footer shows (wall time) when the turn has it.
  const parts = [secs(usage?.timing?.wall_ms ?? total), usage?.output_tokens ? `${usage.output_tokens.toLocaleString('en-US')} tokens` : '', cost ? money(cost.total) : ''].filter(Boolean)

  if (!rect) return null
  return createPortal(
    <div className="turn-panel-scrim" style={{ left: rect.left, top: rect.top, width: rect.width, height: rect.height }} onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
      <div className="turn-panel f-card" role="dialog" aria-label="This turn" tabIndex={-1} ref={card}>
        <div className="tp-head">
          <b>This turn</b>
          <span className="tp-meta">{[id ? modelName(id) : '', usage?.served_by ? servedByName(usage.served_by) : ''].filter(Boolean).join(' · ')}</span>
          <span className="tp-totals">{parts.join(' · ')}</span>
          <button type="button" className="line-link" onClick={onClose} aria-label="Close">Close</button>
        </div>
        <div className="tp-where">
          <div className="tp-h">Where the time went</div>
          {(['thinking', 'tool', 'waiting', 'writing'] as SegmentKind[]).map((k) => (
            <div key={k} className="tp-kv"><span><i className={`tp-key seg-${k}`} />{{ thinking: 'Thinking', tool: 'Tools', waiting: 'Waiting on you', writing: 'Writing' }[k]}</span><span>{sum[k] ? secs(sum[k]) : '—'}</span></div>
          ))}
          {usage && <div className="tp-kv"><span>Read</span><span>{fmtTokens(usage.input_tokens)} tokens{usage.cached_tokens ? `, ${fmtTokens(usage.cached_tokens)} from cache` : ''}</span></div>}
          {cost && <div className="tp-kv"><span>Cost</span><span>{money(cost.total)}{credit ? ` of ${credit} left` : ''}</span></div>}
        </div>
        <div className="tp-body">
          <div className="tp-fall">
            <div className="tp-axis">
              {path && <svg className="tp-pace" viewBox="0 0 100 28" preserveAspectRatio="none"><path d={path} fill="none" vectorEffect="non-scaling-stroke" /></svg>}
              {ticks.map((t) => <span key={t} className="tp-tick" style={{ left: `${ax.at(t)}%` }}>{secs(t)}</span>)}
            </div>
            {rows.map((r) => (
              <button key={r.item} type="button" className={`tp-row${sel === r.item ? ' on' : ''}`} aria-pressed={sel === r.item} onClick={() => setSel(sel === r.item ? null : r.item)}>
                <span className="tp-name">{stepName(r.e, r.segs[0].kind)}</span>
                <span className="tp-track">
                  {r.segs.map((s, i) => (
                    <span key={i} className={`tp-bar seg-${s.kind}${ax.broken(s) ? ' broken' : ''}${live && s.end_ms >= total ? ' growing' : ''}`}
                      style={{ left: `${ax.at(s.start_ms)}%`, width: `max(2px, ${ax.at(s.end_ms) - ax.at(s.start_ms)}%)` }}
                      title={`${secs(s.start_ms)} to ${secs(s.end_ms)}`}>{ax.broken(s) ? secs(s.end_ms - s.start_ms) : ''}</span>
                  ))}
                </span>
              </button>
            ))}
            {!rows.length && <div className="tp-none">Nothing ran in this turn.</div>}
          </div>
          {chosen && (
            <div className="tp-detail">
              <div className="tp-h">{stepName(chosen.e, chosen.segs[0].kind)}</div>
              {chosen.e?.kind === 'tool' && chosen.e.diff ? <div className="line-box"><Hunks diff={chosen.e.diff} /></div>
                : chosen.e?.kind === 'tool' ? <pre className="line-out">{(chosen.e.output || chosen.e.display || 'No output.').split('\n').slice(-40).join('\n')}</pre>
                : chosen.e?.kind === 'reasoning' ? <Outline e={chosen.e} live={!chosen.e.done} onClose={() => setSel(null)} />
                : chosen.e?.kind === 'message' ? <div className="line-said">{chosen.e.text.slice(0, 600)}{chosen.e.text.length > 600 ? '…' : ''}</div>
                : null}
              {chosen.e && <button type="button" className="line-link" onClick={() => { const it = chosen.item; onClose(); setTimeout(() => showStep(it), 0) }}>Show in transcript</button>}
            </div>
          )}
        </div>
      </div>
    </div>,
    document.body,
  )
}
