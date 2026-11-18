// The transcript's lines, worked out once and drawn by Transcript.tsx (docs/design/transcript/
// spec.md, phase 1: "Lines", "Failure", "Test runs", "Measure and the left edge"). The words come
// from docs/design/transcript/verbs.json, the one verb list the Mac reads too.
import verbs from '../../../../docs/design/transcript/verbs.json'
import type { Entry } from '../engine/thread'
import type { FileDiff } from '../cloud/protocol'

export type ObjectFormat = 'command' | 'path' | 'pattern' | 'host' | 'text' | 'tool' | 'none'
export interface Look { tool: string; live: string; past: string; created?: string; object: ObjectFormat }

const TABLE = new Map<string, Look>()
for (const t of verbs.tools as (Look & { aliases?: string[] })[]) {
  for (const name of [t.tool, ...(t.aliases ?? [])]) TABLE.set(name.toLowerCase(), t)
}
const UNKNOWN = verbs.unknown as Omit<Look, 'tool'>

/** The verbs for an engine tool name (any casing; aliases like `!` and `MultiEdit` included). */
export function lookOf(name: string): Look {
  return TABLE.get(name.toLowerCase()) ?? { tool: name, ...UNKNOWN }
}

/** "github › list_issues" for `mcp__github__list_issues`: a tool the table doesn't know, by name. */
export function toolTitle(name: string): string {
  if (!name.startsWith('mcp__')) return name
  const parts = name.slice(5).split('__')
  return parts.length >= 2 ? `${parts[0]} › ${parts.slice(1).join('__')}` : name.slice(5)
}

/** A command that opens with `cd <dir> &&` (or `;`): the rest, and a worktree's name for the
 * place (`…/worktrees/audit334` → "audit334"; anywhere else it is noise and gets none). */
export function splitCd(command: string): { command: string; place: string } | null {
  const m = /^\s*cd\s+(?:"([^"]+)"|'([^']+)'|([^\s;&]+))\s*(?:&&|;)\s*([\s\S]+)$/.exec(command)
  if (!m) return null
  const dir = m[1] ?? m[2] ?? m[3] ?? ''
  const parts = dir.split('/')
  const i = parts.indexOf('worktrees')
  return { command: m[4], place: i >= 0 && parts[i + 1] ? parts[i + 1] : '' }
}

const host = (url: string) => {
  try { return new URL(url).host || url } catch { return url }
}

/** "0.8s", "9.0s", "12s", "2m 5s": a step's time, in the footer's words. */
export function duration(ms: number): string {
  const s = ms / 1000
  return s < 10 ? `${s.toFixed(1)}s` : s < 60 ? `${Math.round(s)}s` : `${Math.floor(s / 60)}m ${Math.round(s % 60)}s`
}

export type LineState = 'run' | 'ok' | 'failed' | 'denied'
export type LineKind = 'command' | 'edit' | 'read' | 'search' | 'web' | 'other'

export interface Line {
  kind: LineKind
  state: LineState
  /** The verb, in muted ("Ran", "Failed", "Didn't run"); empty when a gist is the line. */
  verb: string
  /** What it acted on, in fg; mono for code, paths and commands. Empty for none. */
  object: string
  mono: boolean
  /** The engine's gist, when it is the whole line (a finished, successful step). */
  gist: string
  /** At the right, in meta: "54 lines", "10 of 11 · 9s", "you said no". Not an edit's counts. */
  result: string
  /** An edit's counts, drawn green and red. */
  diff: { added: number; removed: number } | null
  /** The full argument when the line shows less of it (a cd prefix dropped, a host). */
  title: string
}

const KIND: Record<string, LineKind> = {
  bash: 'command', '!': 'command', edit: 'edit', multiedit: 'edit', write: 'edit', read: 'read',
  grep: 'search', glob: 'search', codemap: 'search', webfetch: 'web', websearch: 'web',
}

/** The result the engine's own display gives, without the verb it repeats: "Read 54 lines"
 * under "Read src/a.rs" is "54 lines". The display is the engine's; nothing is parsed out of the
 * output. */
function fromDisplay(display: string | null | undefined, past: string): string {
  const d = (display ?? '').trim().split('\n')[0]
  if (!d) return ''
  return d.toLowerCase().startsWith(past.toLowerCase() + ' ') ? d.slice(past.length + 1) : d
}

/** One step as its line. `diff` is the edit the step made or is asking to make. */
export function lineOf(e: Entry, diff: FileDiff | undefined = e.diff): Line {
  const name = e.name ?? ''
  const look = lookOf(name)
  const kind = KIND[name.toLowerCase()] ?? 'other'
  const state: LineState = !e.done ? 'run' : e.outcome === 'error' ? 'failed' : e.outcome === 'denied' ? 'denied' : 'ok'
  const arg = (e.arg ?? '').trim()
  let object = ''
  let place = ''
  let title = ''
  switch (look.object) {
    case 'command': {
      const cd = splitCd(arg)
      object = (cd?.command ?? arg).split('\n')[0]
      if (cd) { place = cd.place; title = arg }
      if (object.length > 120) { object = object.slice(0, 119) + '…'; title = arg }
      break
    }
    case 'host': object = host(arg); if (object !== arg) title = arg; break
    case 'tool': object = toolTitle(name); title = arg; break
    case 'none': break
    default: object = arg.split('\n')[0]
  }
  if (diff && look.object === 'path' && !object) object = diff.path
  const gist = state === 'ok' && e.gist ? e.gist : ''
  const verb = state === 'failed' ? 'Failed' : state === 'denied' ? "Didn't run" : state === 'run' ? look.live
    : diff?.created && look.created ? look.created : look.past
  const time = e.started != null && e.ended != null && e.ended >= e.started ? duration(e.ended - e.started) : ''
  let result = ''
  if (state === 'denied') result = 'you said no'
  else if (state !== 'run') {
    if (e.tests) result = [`${e.tests.passed} of ${e.tests.total}`, time].filter(Boolean).join(' · ')
    else if (kind === 'command') result = place ? `in ${place}` : ''
    else if (!diff) result = fromDisplay(e.display, look.past)
  }
  return {
    kind, state, verb: gist ? '' : verb, object: gist ? '' : object,
    mono: ['command', 'path', 'pattern', 'tool'].includes(look.object), gist, result,
    diff: diff && state !== 'denied' && state !== 'run' ? { added: diff.added, removed: diff.removed } : null, title,
  }
}

// A failed command opens itself once (spec, "Failure"): the first time it is drawn failed it
// starts open, and from then on it is however the person last left it. Kept outside the row's
// state, so a remount (the app replaying a cached session, a session switch) neither reopens what
// the person closed nor closes what opened itself.
const remembered = new Map<string, boolean>()
/** Whether a row should be open when drawn: a failed command, unless the person closed it. */
export function opensItself(e: Entry, line: Line = lineOf(e)): boolean {
  const was = remembered.get(e.id)
  if (was !== undefined) return was
  if (line.state !== 'failed' || line.kind !== 'command') return false
  remembered.set(e.id, true)
  return true
}
/** The person opened or closed a row: remember it for a self-opening one. */
export function rememberOpen(id: string, open: boolean) {
  if (remembered.has(id)) remembered.set(id, open)
}
/** For tests: forget which failures have opened. */
export function resetOpened() { remembered.clear() }

// Folds: four or more finished steps in a row, with no prose between, fold into one line. A
// failed step never folds (and splits the run around it).
export const FOLD_AT = 4
export interface Step { kind: 'step' | 'other'; id: string; failed: boolean }
export type Folded<T extends Step> = T | { kind: 'fold'; id: string; steps: T[] }

export function foldRuns<T extends Step>(items: T[]): Folded<T>[] {
  const out: Folded<T>[] = []
  let run: T[] = []
  const flush = () => {
    if (run.length >= FOLD_AT) out.push({ kind: 'fold', id: `fold-${run[0].id}`, steps: run })
    else out.push(...run)
    run = []
  }
  for (const x of items) {
    if (x.kind === 'step' && !x.failed) run.push(x)
    else { flush(); out.push(x) }
  }
  flush()
  return out
}

/** "12 steps · 14s": a fold's words, its time from the first step's start to the last's end. */
export function foldTime(steps: Entry[]): string {
  const starts = steps.map((s) => s.started).filter((x): x is number => x != null)
  const ends = steps.map((s) => s.ended).filter((x): x is number => x != null)
  return starts.length && ends.length ? duration(Math.max(...ends) - Math.min(...starts)) : ''
}

// The left edge (spec, "Measure and the left edge"). A line's mark hangs `hang` into the gutter;
// when the pane is too narrow for a gutter that wide, the marks come inside the column and all
// text indents by `hang` together. transcript.css switches at the same width.
export const GUTTER = 32
export const NARROW_GUTTER = 16
export const HANG = 26
/** Panes narrower than this (the phone, a narrow split) get the narrow gutter. */
export const INSET_BELOW = 480

export function gutterLayout(paneWidth: number): { gutter: number; mode: 'hang' | 'inset'; indent: number } {
  const gutter = paneWidth < INSET_BELOW ? NARROW_GUTTER : GUTTER
  const mode = gutter < HANG ? 'inset' : 'hang'
  return { gutter, mode, indent: mode === 'inset' ? HANG : 0 }
}

// The live row (spec, "The row"): one row at the end of the live turn for whatever runs now,
// worded from the verb table's `live` entry.
const LIVE = verbs.live as { thinking: string; waiting: string; thought: string; stopped: string; stalled: string; mixed: string; counts: Record<ObjectFormat, string> }

/** "4s", "31s", "2m 5s": whole seconds, for the row and its stats. */
export function secs(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`
}
const fill = (t: string, v: Record<string, string | number>) => t.replace(/\{(\w+)\}/g, (_, k) => String(v[k] ?? ''))

export type LiveKind = 'thinking' | 'step' | 'waiting' | 'activity' | 'writing'
export interface LiveRow {
  kind: LiveKind
  /** "Thinking", "Editing", "Reading 3 files", "Waiting for you", or what the engine says. */
  label: string
  object: string
  mono: boolean
  /** The engine's thought line, verbatim (thinking only; empty until it sends one). */
  thought: string
  /** The reasoning item the row stands for, while it thinks. */
  item?: string
}

/** What the live turn's row says now. A card waiting on a person wins; then what the engine says
 * it's doing; then the running steps (several fold into a count); then a think; an answer
 * writing has no row (its stats sit under the text); anything else is a think about to start. */
export function liveRow(entries: Entry[], o: { waiting: boolean; activity: string | null }): LiveRow {
  const row = (kind: LiveKind, label: string, rest: Partial<LiveRow> = {}): LiveRow => ({ kind, label, object: '', mono: false, thought: '', ...rest })
  if (o.waiting) return row('waiting', LIVE.waiting)
  if (o.activity) return row('activity', o.activity)
  const steps = entries.filter((e) => e.kind === 'tool' && !e.done)
  if (steps.length === 1) {
    const l = lineOf(steps[0])
    return row('step', l.verb, { object: l.object, mono: l.mono })
  }
  if (steps.length > 1) {
    const looks = new Set(steps.map((e) => lookOf(e.name ?? '').live))
    const look = lookOf(steps[0].name ?? '')
    return row('step', looks.size === 1 ? `${look.live} ${steps.length} ${LIVE.counts[look.object]}` : fill(LIVE.mixed, { n: steps.length }))
  }
  const last = entries[entries.length - 1]
  if (last?.kind === 'reasoning' && !last.done) return row('thinking', LIVE.thinking, { thought: last.thought ?? '', item: last.id })
  if (last?.kind === 'message' && !last.done && last.text) return row('writing', '')
  return row('thinking', LIVE.thinking)
}

/** A finished think's line: "Thought for 31s" from the engine's think_ms (an older log: the item's
 * own times); "Stopped after 12s" when the turn was stopped mid-think; plain "Thought" with no times. */
export function thoughtLabel(e: Entry, stoppedAt?: number): string {
  if (!e.done && stoppedAt != null && e.started != null) return fill(LIVE.stopped, { time: secs(stoppedAt - e.started) })
  // An older log has no think_ms: the item's own times, as the engine's timeline and the Mac read it.
  const ms = e.thinkMs ?? (e.done && e.started != null && e.ended != null && e.ended >= e.started ? e.ended - e.started : null)
  if (ms != null) return fill(LIVE.thought, { time: secs(Math.max(1000, ms)) })
  return 'Thought'
}

export const stalledLabel = (ms: number) => fill(LIVE.stalled, { time: secs(ms) })

/** The outline (spec, "Hover and opening"): at most twelve lines, then "24 more". */
export const OUTLINE_MAX = 12

/** Tokens per second over the last few seconds of `samples` (viewer clock, ms; output tokens),
 * or null until there's a second of them. Counted pieces are approximate: never a decimal. */
export function rateOf(samples: { at: number; output: number }[], now: number, windowMs = 4000): number | null {
  const recent = samples.filter((s) => s.at >= now - windowMs)
  const first = recent[0] ?? samples[samples.length - 1]
  const last = samples[samples.length - 1]
  if (!first || !last || last.at - first.at < 2000) return null
  return Math.round(((last.output - first.output) * 1000) / (now - first.at))
}

/** No output for this long while thinking: the row says so (the engine asks at 30 s). */
export const STALL_AT = 10_000
