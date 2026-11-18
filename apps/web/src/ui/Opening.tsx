import { useEffect, useRef, useState } from 'react'
import type { Image, SessionSummary } from '../cloud/protocol'
import type { Thread } from '../engine/thread'
import { secs } from './rows'

// A new session from Send to its first turn: one steady view (#calm-start).
//
// The message you sent is drawn once, as the first turn of the transcript, and stays the same
// node when the gateway answers with the session's id and again when the engine's first turn
// replaces it. Under it is one quiet status row in the live row's place and style, which the
// live row takes over at the first event.
//
// What the gateway tells us while a sandbox boots (zest sandbox/src/session.ts): the POST answer
// (state "starting"), then the session's state, "running" or "error" with a reason, from GET.
// The socket's welcome comes before the boot is done, so it is not a sign of progress. There are
// no phases (container, clone, engine), so the row says one thing until the first turn starts.

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
  verb: 'Starting',
  object: (repo?: string) => (repo ? `a sandbox for ${repo}` : 'a sandbox'),
  failed: 'Failed',
  retry: 'Try again',
  stuck: "Frog didn't pick this up.",
  /** Nothing for this long: a quick start never shows the row. */
  quietMs: 600,
  /** At most one change this often. */
  dwellMs: 1200,
  /** The clock shows from here. */
  clockMs: 5000,
}

/** What the row says now: starting, or failed with the reason. */
export function bootWords(o: { repo?: string; error?: string | null }): { verb: string; object: string; failed: boolean } {
  return o.error ? { verb: BOOT.failed, object: o.error, failed: true } : { verb: BOOT.verb, object: BOOT.object(o.repo), failed: false }
}

type Words = ReturnType<typeof bootWords>
const same = (a: Words, b: Words) => a.verb === b.verb && a.object === b.object

/** Holds each value at least `dwell` ms, then cross-fades to the newest (transcript.css `.tf`). */
function useSteady(value: Words, dwell: number) {
  const [s, set] = useState<{ now: Words; was: Words | null; n: number; at: number }>(() => ({ now: value, was: null, n: 0, at: Date.now() }))
  const latest = useRef(value)
  latest.current = value
  useEffect(() => {
    if (same(s.now, value)) return
    const wait = Math.max(0, s.at + dwell - Date.now())
    const t = setTimeout(() => set((p) => (same(p.now, latest.current) ? p : { now: latest.current, was: p.now, n: p.n + 1, at: Date.now() })), wait)
    return () => clearTimeout(t)
  }, [value.verb, value.object, s, dwell]) // eslint-disable-line react-hooks/exhaustive-deps
  return s
}

function Phrase({ w }: { w: Words }) {
  return <><span className={`live-label${w.failed ? ' boot-failed' : ''}`}>{w.verb}</span> <span className="line-obj" title={w.object}>{w.object}</span></>
}

/** The row under the sent message while the sandbox boots: the live row's place and look, held
 * still. Invisible for the first 600 ms (its space is kept, so nothing moves when it shows),
 * then "Starting a sandbox"; the seconds from 5 s; failed, the reason and Try again, in place. */
export function BootRow({ since, repo, error, upSince, onRetry }: { since: number; repo?: string; error?: string | null; /** When the gateway said it's up (no turn yet). */ upSince?: number; onRetry?: () => void }) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 250); return () => clearInterval(t) }, [])
  const late = upSince != null && now - upSince >= STUCK_MS
  const words = useSteady(bootWords({ repo, error: error ?? (late ? BOOT.stuck : null) }), BOOT.dwellMs)
  // Shown once, it stays shown: Try again restarts the clock, not the 600 ms.
  const shown = useRef(false)
  if (now - since >= BOOT.quietMs) shown.current = true
  const ready = shown.current
  const took = now - since
  const failed = words.now.failed
  return (
    <div className="live-row boot" data-row="live" data-kind="boot" data-state={failed ? 'failed' : 'still'} data-ready={ready ? 'true' : 'false'} role="status" aria-live="polite">
      <div className="line-plate">
        <div className="line live">
          <span className="line-mark" aria-hidden="true"><span className="live-dot" /></span>
          <span className="live-thought boot-words">
            {words.was && <span key={`o${words.n}`} className="tf tf-was" aria-hidden="true"><Phrase w={words.was} /></span>}
            <span key={`i${words.n}`} className={`tf${words.n ? ' tf-now' : ''}`}><Phrase w={words.now} /></span>
          </span>
          {failed && onRetry && <button type="button" className="line-link boot-retry" onClick={onRetry}>{BOOT.retry}</button>}
        </div>
      </div>
      {!failed && took >= BOOT.clockMs && <div className="live-stats"><span className="live-figures">{secs(took)}</span></div>}
    </div>
  )
}
