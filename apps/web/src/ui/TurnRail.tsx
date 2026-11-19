import { useMemo, useRef, useState, type KeyboardEvent, type PointerEvent } from 'react'
import type { EndReason } from '../cloud/protocol'
import { chapterIndex, chapters, type ChapterTurn } from './chapters'

// The turn rail (docs/design/chrome/spec.md, "The turn rail"): the Mac's TimelineRail. The
// conversation as a line, a dot where each chapter starts, a thumb over the turns on screen and
// colour only on a turn that needs you. Hover for a turn's prompt; press or drag to scrub to it.

export const RAIL_WIDTH = 28
const PAD = 12

export interface RailTurn extends ChapterTurn { turn: number; reason?: EndReason }

/** The rail's height: by chapters, not turns, so a long session is a short list of topics. */
export function railHeight(chapterCount: number, room: number): number {
  return Math.min(room, 360, Math.max(1, chapterCount) * 18 + 28)
}

/** Where turn `i` of `n` sits: each chapter an equal share of the rail, its turns sharing that. */
export function yOf(i: number, n: number, starts: readonly number[], h: number): number {
  if (n <= 1) return h / 2
  const c = chapterIndex(i, starts)
  if (!starts.length || c === null) return PAD + ((h - 2 * PAD) * i) / (n - 1)
  const end = c + 1 < starts.length ? starts[c + 1] : n
  const within = (i - starts[c]) / Math.max(1, end - starts[c])
  return PAD + (h - 2 * PAD) * ((c + within) / starts.length)
}

/** The turn under a pointer at `y`. */
export function indexAt(y: number, n: number, starts: readonly number[], h: number): number | null {
  if (n === 0) return null
  if (n === 1) return 0
  const t = Math.min(1, Math.max(0, (y - PAD) / Math.max(1, h - 2 * PAD)))
  if (!starts.length) return Math.min(n - 1, Math.round(t * (n - 1)))
  const slot = t * starts.length
  const c = Math.min(starts.length - 1, Math.floor(slot))
  const end = c + 1 < starts.length ? starts[c + 1] : n
  return Math.min(n - 1, Math.max(0, starts[c] + Math.floor((slot - c) * (end - starts[c]))))
}

/** A turn's mark when it needs one: how it went wrong, or that it's running. */
function signal(t: RailTurn, last: boolean, running: boolean): string | null {
  if (!t.reason) return last && running ? 'var(--frog)' : null
  if (t.reason.type === 'error') return 'var(--warn)'
  if (t.reason.type === 'looping' || t.reason.type === 'step_limit' || t.reason.type === 'max_tokens') return 'var(--notice)'
  return null
}

export function TurnRail({ turns, visible, running, room, onJump }: {
  turns: readonly RailTurn[]
  /** Indices of the turns on screen. */
  visible: ReadonlySet<number>
  running: boolean
  /** Height free under the title row. */
  room: number
  onJump: (index: number) => void
}) {
  const { chapters: cs, starts, titles } = useMemo(() => chapters(turns), [turns])
  const h = railHeight(cs.length, room)
  const n = turns.length
  const [hovered, setHovered] = useState<number | null>(null)
  const dragging = useRef(false)
  const lo = [...visible].reduce((a, b) => Math.min(a, b), Infinity)
  const hi = [...visible].reduce((a, b) => Math.max(a, b), -Infinity)
  const current = Number.isFinite(lo) ? chapterIndex(lo, starts) : null
  const mid = RAIL_WIDTH / 2

  // The chapter dots drawn: each clear of the last by 7, the current chapter always.
  const marks: { c: number; y: number }[] = []
  let lastY = -Infinity
  starts.forEach((s, c) => {
    const y = yOf(s, n, starts, h)
    if (c !== current && y - lastY < 7) return
    if (c === current && marks.length && y - marks[marks.length - 1].y < 7 && marks[marks.length - 1].c !== current) marks.pop()
    lastY = y
    marks.push({ c, y })
  })

  const at = (e: PointerEvent<HTMLDivElement>) => indexAt(e.clientY - e.currentTarget.getBoundingClientRect().top, n, starts, h)
  const jump = (i: number | null) => { if (i !== null) { setHovered(i); onJump(i) } }
  const key = (e: KeyboardEvent<HTMLDivElement>) => {
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return
    e.preventDefault()
    const c = (current ?? 0) + (e.key === 'ArrowDown' ? 1 : -1)
    if (c >= 0 && c < starts.length) onJump(starts[c])
  }
  const label = `Timeline, ${n} turn${n === 1 ? '' : 's'}${current !== null ? `, in chapter ${current + 1} of ${cs.length}` : ''}`
  const ht = hovered !== null ? turns[hovered] : null
  const hc = hovered !== null ? chapterIndex(hovered, starts) : null

  return (
    <div className="turn-rail" role="slider" tabIndex={0} aria-label={label} aria-valuemin={1} aria-valuemax={Math.max(1, cs.length)} aria-valuenow={(current ?? 0) + 1}
      style={{ height: h }} onKeyDown={key}
      onPointerMove={(e) => { const i = at(e); setHovered(i); if (dragging.current) jump(i) }}
      onPointerLeave={() => { if (!dragging.current) setHovered(null) }}
      onPointerDown={(e) => { dragging.current = true; e.currentTarget.setPointerCapture?.(e.pointerId); jump(at(e)) }}
      onPointerUp={() => { dragging.current = false }}
      onPointerCancel={() => { dragging.current = false }}>
      <svg aria-hidden="true" width={RAIL_WIDTH} height={h}>
        <rect x={mid - 0.5} y={PAD} width={1} height={Math.max(0, h - 2 * PAD)} className="rail-line" />
        {Number.isFinite(lo) && <rect x={mid - 6} y={yOf(lo, n, starts, h) - 7} width={12} height={yOf(hi, n, starts, h) - yOf(lo, n, starts, h) + 14} rx={6} className="rail-thumb" />}
        {marks.map(({ c, y }) => {
          const here = c === current
          if (cs[c].kind === 'compacted') return (<g key={c} className="rail-break"><rect x={mid - 4} y={y - 3.5} width={8} height={1} /><rect x={mid - 4} y={y + 2.5} width={8} height={1} /></g>)
          if (cs[c].kind === 'run') return <circle key={c} cx={mid} cy={y} r={here ? 3 : 2.25} fill="none" strokeWidth={1} className={here ? 'rail-run here' : 'rail-run'} />
          return <circle key={c} cx={mid} cy={y} r={here ? 3.5 : 2.5} className={here ? 'rail-dot here' : 'rail-dot'} />
        })}
        {turns.map((t, i) => {
          const color = signal(t, i === n - 1, running)
          return color ? <circle key={`s${i}`} cx={mid} cy={yOf(i, n, starts, h)} r={2} fill={color} /> : null
        })}
        {hovered !== null && <circle cx={mid} cy={yOf(hovered, n, starts, h)} r={5} fill="none" strokeWidth={1} className="rail-ring" />}
      </svg>
      {ht && (
        <div className="rail-label" style={{ top: yOf(hovered!, n, starts, h) - 13 }}>
          {hc !== null && starts[hc] === hovered && <span className="rail-muted">{titles[hc]}</span>}
          <span className="rail-muted rail-num">{ht.turn}</span>
          <span className="rail-prompt">{ht.input && !ht.input.startsWith('<') ? ht.input.split('\n')[0] : '(no prompt)'}</span>
        </div>
      )}
    </div>
  )
}
