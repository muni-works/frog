import { useEffect, useRef, useState } from 'react'
import type { Image, SessionSummary } from '../cloud/protocol'
import type { Thread } from '../engine/thread'

// A new session from Send to its first turn: one steady view (#calm-start).
//
// The message you sent is drawn once, as the first turn of the transcript, and stays the same
// node when the gateway answers with the session's id and again when the engine's first turn
// replaces it. Under it is the live row itself (LiveRow.tsx `LiveTail`, given `start`), its words
// moving through the start's stages in place, and it carries on as the turn's live row.
//
// The stages are what the gateway really tells us (zest sandbox/src/session.ts): the POST in
// flight (reserving), the session's state "starting" (booting, and cloning with a repo: zest
// doesn't say which), then "running" (the engine is up; the turn starts next), or "error" with a
// reason. The socket's welcome comes before the boot is done, so it is not a sign of progress.

/** A session still opening: what was sent and where, from Send until its first turn starts. */
export interface Opening {
  text: string
  images: Image[]
  repo?: string
  base?: string
  /** When Send was pressed (viewer clock). */
  at: number
  /** The session as listed, so a list refresh that hasn't caught up can't drop it. */
  row: SessionSummary
  /** It couldn't start (the POST failed, or no turn came): why, in words. */
  failed?: string
  /** When the gateway first said the sandbox is up. */
  runningAt?: number
}

/** Up for this long with no turn: the engine didn't pick the first message up. */
export const STUCK_MS = 30_000
/** Up, no turn, for too long: Try again sends the message again rather than starting over. */
export const stuck = (o: Opening, now = Date.now()) => !o.failed && o.runningAt != null && now - o.runningAt >= STUCK_MS

/** The words a first message titles its session with until the engine names it. */
export const firstTitle = (text: string) => (text.length > 60 ? text.slice(0, 57) + '…' : text)

/** The listed sessions plus any still opening that the list doesn't have yet (a refresh that left
 * before the POST answered, or the placeholder while it's in flight). */
export function withOpening(listed: SessionSummary[], opening: Record<string, Opening>): SessionSummary[] {
  const missing = Object.values(opening).map((o) => o.row).filter((r) => !listed.some((s) => s.id === r.id))
  return missing.length ? [...missing, ...listed] : listed
}

/** The transcript while opening: the sent message as the first turn, nothing running yet. */
export function provisional(t: Thread, o: Opening): Thread {
  return { ...t, running: false, turns: [{ turn: 0, input: o.text, ...(o.images.length ? { images: o.images } : {}), entries: [] }] }
}

/** Messages still waiting on their turn. A delivered one goes in the same render its turn shows,
 * not an effect later, so the bubble is never drawn twice. */
export function undelivered<M extends { text: string; seen: number }>(list: M[] | undefined, turns: { input: string }[]): M[] | undefined {
  if (!list?.length) return list
  const left = list.filter((m) => turns.filter((u) => u.input === m.text).length <= m.seen)
  return left.length === list.length ? list : left
}

export const BOOT = {
  reserving: 'Reserving a sandbox',
  booting: 'Booting it',
  cloning: (repo: string) => `Booting it and cloning ${repo}`,
  engine: 'Starting Frog',
  failed: 'Failed',
  retry: 'Try again',
  stuck: "Frog didn't pick this up.",
  /** Nothing for this long: a quick start never shows the row. */
  quietMs: 600,
  /** At most one change this often. */
  dwellMs: 1200,
}

export type Stage = 'reserving' | 'booting' | 'engine'

/** A new session's start, for the live row: when Send was pressed, where it has got to, and what
 * went wrong. */
export interface StartInfo {
  since: number
  stage: Stage
  repo?: string
  /** It failed: why, in words. */
  error?: string | null
  /** When the gateway said it's up: no turn 30 s after, the engine didn't pick the message up. */
  upSince?: number
  onRetry?: () => void
}

export type Words = { verb: string; object: string; failed: boolean }

/** What the row says now: the stage, or Failed and why. */
export function startWords(o: { stage: Stage; repo?: string; error?: string | null; upSince?: number }, now = Date.now()): Words {
  const error = o.error ?? (o.upSince != null && now - o.upSince >= STUCK_MS ? BOOT.stuck : null)
  if (error) return { verb: BOOT.failed, object: error, failed: true }
  const verb = o.stage === 'reserving' ? BOOT.reserving : o.stage === 'engine' ? BOOT.engine : o.repo ? BOOT.cloning(o.repo) : BOOT.booting
  return { verb, object: '', failed: false }
}

const same = (a: Words, b: Words) => a.verb === b.verb && a.object === b.object && a.failed === b.failed

export type Steady = { now: Words; was: Words | null; n: number }

/** On, holds each value at least `dwell` ms, then cross-fades to the newest (transcript.css `.tf`).
 * Off, it is the value as it is. */
export function useSteady(value: Words, dwell: number, on: boolean): Steady {
  const [s, set] = useState<Steady & { at: number }>(() => ({ now: value, was: null, n: 0, at: Date.now() }))
  const latest = useRef(value)
  latest.current = value
  useEffect(() => {
    if (same(s.now, value)) return
    if (!on) { set((p) => ({ now: latest.current, was: null, n: p.n, at: Date.now() })); return }
    const t = setTimeout(() => set((p) => (same(p.now, latest.current) ? p : { now: latest.current, was: p.now, n: p.n + 1, at: Date.now() })), Math.max(0, s.at + dwell - Date.now()))
    return () => clearTimeout(t)
  }, [value.verb, value.object, value.failed, s, dwell, on]) // eslint-disable-line react-hooks/exhaustive-deps
  return on ? s : { now: value, was: null, n: s.n }
}

function Phrase({ w }: { w: Words }) {
  return <><span className={`live-label${w.failed ? ' start-failed' : ''}`}>{w.verb}</span>{w.object && <> <span className="line-obj" title={w.object}>{w.object}</span></>}</>
}

/** The row's words while they cross-fade: the old out over 180 ms, the new in over 240 ms. */
export function SteadyWords({ s }: { s: Steady }) {
  return (
    <span className="live-thought start-words">
      {s.was && <span key={`o${s.n}`} className="tf tf-was" aria-hidden="true"><Phrase w={s.was} /></span>}
      <span key={`i${s.n}`} className={`tf${s.n ? ' tf-now' : ''}`}><Phrase w={s.now} /></span>
    </span>
  )
}
