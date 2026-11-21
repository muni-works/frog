// An answer that writes itself, as the Mac's InkReveal does (apps/FrogKit/UI/Transcript/
// InkReveal.swift): words appear at a reading pace on the display's clock rather than the
// network's, each one inking in from frog green to its own colour, behind a soft pen.
//
// Nothing here lays text out. Everything that has arrived is in the DOM, laid out once; what the
// pen hasn't reached is painted transparent with the CSS Custom Highlight API, and fresh runs get
// one of a few green-to-ink highlights by age (transcript.css, `::highlight(ink-…)`). So the
// reply's lines never move as it reveals (test/streaming-position.test.ts). Under reduced motion,
// a stream too fast to ink, or a browser without highlights, text simply appears; a finished
// message, or one picked up halfway, is simply there.
import { useEffect, useLayoutEffect, useRef, type RefObject } from 'react'

/** How long a word takes to settle from green into its own colour (s). */
const INK_TIME = 0.42
/** How far behind arrival the pen may run while streaming, and after (a quick catch-up). */
const LAG_STREAMING = 0.32
const LAG_DONE = 0.1
/** The slowest pace, in characters a second: about reading speed. */
const MIN_RATE = 42
/** Green-to-ink steps (`ink-1` … `ink-5`, transcript.css). */
export const INK_STEPS = 5
/** Runs fading at once; older ones settle early. */
const MAX_RUNS = 30
/** Above this arrival rate (chars/s) the ink can't be seen, only paid for: text just appears
 * until the stream slows below `SLOW_RATE`. */
const FAST_RATE = 1200
const SLOW_RATE = 600
/** A message longer than this when first seen is simply there (scrolled back to, reopened). */
const SHOWN_AT_START = 600

type Run = { start: number; end: number; at: number }

/** The pure clock, apart from the DOM, for tests: where the pen is after `dt` seconds. */
export function advance(revealed: number, total: number, dt: number, carry: number, streaming: boolean, text: string): { revealed: number; carry: number } {
  if (revealed >= total) return { revealed: total, carry: 0 }
  const backlog = total - revealed
  const rate = Math.max(MIN_RATE, backlog / (streaming ? LAG_STREAMING : LAG_DONE))
  carry += rate * dt
  if (carry < 1) return { revealed, carry }
  let target = Math.min(total, revealed + Math.floor(carry))
  carry -= target - revealed
  // Finish the word the target landed in.
  while (target < total && !/\s/.test(text[target - 1] ?? ' ')) target++
  return { revealed: target, carry }
}

/** The fade step of a run `age` seconds old: 1 (fresh, green) to INK_STEPS + 1 (settled). */
export function step(age: number): number {
  return Math.min(INK_STEPS + 1, 1 + Math.floor((age / INK_TIME) * INK_STEPS))
}

type Highlights = { set(name: string, h: unknown): void; delete(name: string): void }
const registry = (): Highlights | null => (globalThis as { CSS?: { highlights?: Highlights } }).CSS?.highlights ?? null
const HighlightCtor = (): (new (...r: Range[]) => { add(r: Range): void; clear(): void }) | null =>
  (globalThis as { Highlight?: new (...r: Range[]) => { add(r: Range): void; clear(): void } }).Highlight ?? null

/** The text nodes under `root` (minus the pen) with each one's start offset. */
function textNodes(root: HTMLElement): { nodes: Text[]; starts: number[]; text: string } {
  const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  const nodes: Text[] = [], starts: number[] = []
  let text = ''
  for (let n = walk.nextNode() as Text | null; n; n = walk.nextNode() as Text | null) {
    nodes.push(n)
    starts.push(text.length)
    text += n.data
  }
  return { nodes, starts, text }
}

function at(t: { nodes: Text[]; starts: number[] }, offset: number): [Text, number] | null {
  if (!t.nodes.length) return null
  let lo = 0, hi = t.nodes.length - 1
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (t.starts[mid] <= offset) lo = mid; else hi = mid - 1 }
  const n = t.nodes[lo]
  return [n, Math.min(n.data.length, offset - t.starts[lo])]
}

function range(t: { nodes: Text[]; starts: number[] }, a: number, b: number): Range | null {
  const s = at(t, a), e = at(t, b)
  if (!s || !e || b <= a) return null
  const r = document.createRange()
  r.setStart(s[0], s[1])
  r.setEnd(e[0], e[1])
  return r
}

/** Writes the reply in `say` (its `.md`), with the pen at `pen`. `text` is the source (its
 * changes are arrivals); `streaming` while the turn writes it. */
export function useInk(say: RefObject<HTMLElement | null>, pen: RefObject<HTMLElement | null>, text: string, streaming: boolean) {
  const s = useRef({ started: false, revealed: 0, carry: 0, runs: [] as Run[], arrivals: [] as { at: number; total: number }[], instant: false, holdUntil: 0, frame: 0, last: 0, streaming, hidden: [] as HTMLElement[] })
  s.current.streaming = streaming
  const md = { get current() { return say.current?.querySelector<HTMLElement>(':scope > .md') ?? null } }

  useLayoutEffect(() => {
    const st = s.current
    const root = md.current
    if (!root) return
    const total = textNodes(root).text.length
    const reduce = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches
    if (!st.started) {
      st.started = true
      if (!streaming || reduce || total > SHOWN_AT_START || !registry() || !HighlightCtor()) st.revealed = Infinity
    }
    // How fast text is arriving, over the last half second (with some hysteresis).
    const now = performance.now() / 1000
    if (streaming) {
      st.arrivals = [...st.arrivals.filter((a) => now - a.at <= 0.5 && a.total <= total), { at: now, total }]
      const first = st.arrivals[0]
      const rate = st.arrivals.length > 1 ? (total - first.total) / Math.max(now - first.at, 0.05) : 0
      if (!st.instant && rate > FAST_RATE) st.instant = true
      else if (st.instant && rate < SLOW_RATE) st.instant = false
    }
    if (st.instant) st.revealed = Infinity
    paint()
    if (!st.frame) { st.last = now; st.frame = requestAnimationFrame(tick) }
  }, [text, streaming])

  useEffect(() => () => { const st = s.current; if (st.frame) cancelAnimationFrame(st.frame); st.frame = 0; clear() }, [])

  function clear() {
    const reg = registry()
    if (reg) { reg.delete('ink-hidden'); for (let k = 1; k <= INK_STEPS; k++) reg.delete(`ink-${k}`) }
    for (const el of s.current.hidden) el.style.visibility = ''
    s.current.hidden = []
  }

  function tick(ms: number) {
    const st = s.current
    st.frame = 0
    const root = md.current
    if (!root) return
    const now = ms / 1000
    const dt = Math.min(Math.max(now - st.last, 0), 1 / 20)
    st.last = now
    const t = textNodes(root)
    const total = t.text.length
    if (st.revealed < total && (now >= st.holdUntil || !st.streaming)) {
      const from = st.revealed
      const next = advance(st.revealed, total, dt, st.carry, st.streaming, t.text)
      st.revealed = next.revealed
      st.carry = next.carry
      if (st.revealed > from) {
        st.runs.push({ start: from, end: st.revealed, at: now })
        // A breath after a sentence or paragraph, when the model isn't far ahead.
        const prev = t.text[st.revealed - 2], last = t.text[st.revealed - 1]
        if (st.streaming && total - st.revealed < 24 && st.revealed >= 2 && (/[.!?:]/.test(prev ?? '') || last === '\n')) st.holdUntil = now + 0.09
      }
    }
    st.runs = st.runs.filter((r) => now - r.at < INK_TIME).slice(-MAX_RUNS)
    paint(now, t)
    if (st.revealed < total || st.runs.length || st.streaming) st.frame = requestAnimationFrame(tick)
    else clear()
  }

  function paint(now = performance.now() / 1000, t = md.current ? textNodes(md.current) : null) {
    const st = s.current
    const root = md.current
    if (!root || !t) return
    const total = t.text.length
    const reg = registry(), H = HighlightCtor()
    const shown = Math.min(st.revealed, total)
    if (reg && H) {
      const hidden = range(t, shown, total)
      reg.set('ink-hidden', hidden ? new H(hidden) : new H())
      const steps = Array.from({ length: INK_STEPS }, () => new H())
      for (const r of st.runs) {
        const k = step(now - r.at)
        const rr = k <= INK_STEPS ? range(t, r.start, Math.min(r.end, total)) : null
        if (rr) steps[k - 1].add(rr)
      }
      steps.forEach((h, i) => reg.set(`ink-${i + 1}`, h))
    }
    // Code boxes, tables and inline code's plates appear when the pen reaches them, not as empty
    // boxes or tints ahead of it (the Mac: "no tint ahead of the pen").
    for (const el of st.hidden) el.style.visibility = ''
    st.hidden = []
    if (shown < total) {
      for (const el of root.querySelectorAll<HTMLElement>(':scope > .md-code, :scope > .md-table, :not(pre) > code')) {
        const first = t.nodes.findIndex((n) => el.contains(n))
        if (first >= 0 && t.starts[first] >= shown) { el.style.visibility = 'hidden'; st.hidden.push(el) }
      }
    }
    placePen(now, t, shown, total)
  }

  function placePen(now: number, t: { nodes: Text[]; starts: number[]; text: string }, shown: number, total: number) {
    const st = s.current
    const el = pen.current
    const box = el?.offsetParent as HTMLElement | null
    if (!el || !box) return
    const active = (st.streaming || shown < total) && Number.isFinite(st.revealed) && shown > 0
    // After the last revealed word: back over trailing spaces and newlines.
    let i = shown
    while (i > 0 && /\s/.test(t.text[i - 1])) i--
    const r = active && i > 0 ? range(t, i - 1, i) : null
    const rect = r?.getBoundingClientRect()
    if (!rect || !rect.height) { el.style.transition = 'opacity .3s'; el.style.opacity = '0'; return }
    el.style.transition = 'none'
    const b = box.getBoundingClientRect()
    const h = Math.max(10, rect.height * 0.72)
    el.style.transform = `translate(${rect.right - b.left + 3}px, ${rect.top - b.top + (rect.height - h) / 2}px)`
    el.style.height = `${h}px`
    // It breathes while the model is quiet mid-answer.
    const waiting = shown >= total
    el.style.opacity = String(waiting ? 0.35 + 0.65 * (0.5 + 0.5 * Math.cos(now * 4.2)) : 1)
  }
}
