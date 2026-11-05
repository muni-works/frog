import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Gateway } from './cloud/client'
import type { EndReason, Envelope, RepoList, SessionSummary } from './cloud/protocol'
import { CloudEngine } from './engine/cloud'
import { emptyThread, reduce, type Thread } from './engine/thread'

// Sessions belong to the account and come from the gateway (GET /v1/sessions); what
// happens inside one comes only from its event stream. Nothing here is made up.

/** The gateway's origin. In dev, Vite proxies /v1 to $GATEWAY (default the mock). */
export const GATEWAY = (import.meta.env.VITE_GATEWAY as string | undefined) ?? location.origin

// New-session suggestions: three drawn at random from this pool on each visit. Concrete,
// worth a sandbox, and each one shows a different thing Frog is good at.
const POOL = [
  'Fix the failing tests',
  'Review my open PR and leave notes',
  'Explain how this codebase fits together',
  'Find and fix a bug from the open issues',
  'Add tests for the least-covered module',
  'Upgrade outdated dependencies and fix what breaks',
  'Speed up the slowest test',
  'Write a README for this repo',
  'Find dead code and remove it',
  'Add a dark mode',
  'Make the CI faster',
  'Audit this repo for security issues',
  'Turn the TODOs into a plan',
  'Add types where they’re missing',
]

// Signed out there's no repo yet, so these are cold starts: things worth doing from nothing.
const COLD = [
  'Build a tiny habit tracker web app',
  'Write a CLI that renames photos by date taken',
  'Make a Snake game in the browser',
  'Scaffold a REST API with auth and tests',
  'Explain how OAuth works, with a diagram',
  'Write a script that turns a CSV into charts',
  'Build a Markdown notes app that saves locally',
  'Prototype a Discord bot that summarizes threads',
  'Make a personal site from my GitHub profile',
  'Write a web scraper for a recipe site',
  'Compare three ways to build a job queue',
  'Build a pomodoro timer in Rust',
]

export function pickStarters(n = 3, cold = false): string[] {
  const a = [...(cold ? COLD : POOL)]
  for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]] }
  return a.slice(0, n)
}

export function useCloud(key: string | null) {
  return useMemo(() => (key ? new CloudEngine(new Gateway({ origin: GATEWAY, token: key })) : null), [key])
}

/** The account's sessions, refreshed every 15 s (the gateway has no push for the list). */
export function useSessions(cloud: CloudEngine | null) {
  const [sessions, setSessions] = useState<SessionSummary[]>([])
  const [error, setError] = useState<string | null>(null)
  const refresh = useCallback(async () => {
    if (!cloud) return
    try {
      setSessions((await cloud.gateway.list()).sort((a, b) => b.updated - a.updated))
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    }
  }, [cloud])
  useEffect(() => {
    if (!cloud) return setSessions([])
    // Near-live while you're looking (every 3s), slow when the tab is hidden, and at once on
    // coming back. One cheap read of the account's session index each time.
    refresh()
    let t = 0
    const arm = () => { clearInterval(t); t = window.setInterval(refresh, document.hidden ? 30_000 : 3_000) }
    const back = () => { if (!document.hidden) refresh(); arm() }
    arm()
    document.addEventListener('visibilitychange', back)
    addEventListener('focus', back)
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', back); removeEventListener('focus', back) }
  }, [cloud, refresh])
  return { sessions, error, refresh, setSessions }
}

/** Subscribe to these sessions' streams and keep a folded `Thread` per session. */
// Threads are kept in this browser too, so opening a session shows it at once (even after a
// reload) and the socket only fetches what came after. Capped: the newest few, none too big.
const THREADS = 'frog.thread.'
const KEEP = 24
const MAX_BYTES = 400_000
function loadThread(id: string): Thread | null {
  try { const v = localStorage.getItem(THREADS + id); return v ? { ...emptyThread, ...JSON.parse(v) } : null } catch { return null }
}
function saveThread(id: string, t: Thread) {
  try {
    // Kept whole: resuming after lastSeq delivers whatever ended or changed since. Only the
    // live activity line is dropped, since it's stale by the time anyone reads it back.
    const json = JSON.stringify({ ...t, activity: null })
    if (json.length > MAX_BYTES) return
    localStorage.setItem(THREADS + id, json)
    const index: string[] = JSON.parse(localStorage.getItem(THREADS + 'index') ?? '[]').filter((x: string) => x !== id)
    index.unshift(id)
    for (const old of index.splice(KEEP)) localStorage.removeItem(THREADS + old)
    localStorage.setItem(THREADS + 'index', JSON.stringify(index))
  } catch { /* full or private mode: memory only */ }
}

/** What this browser kept of a thread, for the sidebar's second line; cached by when it was saved. */
export interface Peek { reply: string | null; turns: number; model: string | null }
const peeks = new Map<string, { at: number; v: Peek }>()
export function peek(id: string, updated: number): Peek {
  const hit = peeks.get(id)
  if (hit && hit.at >= updated) return hit.v
  const t = loadThread(id)
  const msg = t ? [...t.turns].reverse().flatMap((u) => [...u.entries].reverse()).find((e) => e.kind === 'message') : undefined
  const v = { reply: msg && 'text' in msg ? (msg.text as string) : null, turns: t?.turns.length ?? 0, model: t?.model ?? null }
  peeks.set(id, { at: updated, v })
  return v
}

/** Sign-out forgets every thread this browser kept. */
export function clearThreads() {
  try { Object.keys(localStorage).filter((k) => k.startsWith(THREADS)).forEach((k) => localStorage.removeItem(k)) } catch { /* nothing kept */ }
}

export function useThreads(cloud: CloudEngine | null, ids: string[]) {
  const [threads, setThreads] = useState<Record<string, Thread>>({})
  const cache = useRef(threads)
  cache.current = threads
  const key = ids.join(',')
  useEffect(() => {
    if (!cloud) return
    // Envelopes are folded once per animation frame, not one render per streamed token. A
    // hidden tab gets no frames, so a timer backs the frame up.
    const queued: { id: string; env: Envelope; known: Thread | null }[] = []
    let frame = 0
    let timer: ReturnType<typeof setTimeout> | undefined
    const flush = () => {
      if (frame) cancelAnimationFrame(frame)
      clearTimeout(timer)
      frame = 0
      const batch = queued.splice(0)
      if (batch.length) setThreads((all) => {
        const next = { ...all }
        for (const q of batch) next[q.id] = reduce(next[q.id] ?? q.known ?? emptyThread, q.env)
        return next
      })
    }
    const offs = ids.map((id) => {
      const known = cache.current[id] ?? loadThread(id)
      if (known && !cache.current[id]) setThreads((all) => ({ ...all, [id]: known }))
      return cloud.subscribe(id, known?.lastSeq ?? 0, (env) => {
        queued.push({ id, env, known })
        if (!frame) { frame = requestAnimationFrame(flush); timer = setTimeout(flush, 200) }
      })
    })
    return () => { flush(); offs.forEach((off) => off()) }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cloud, key])
  // Saved a moment after it settles, not on every streamed token.
  useEffect(() => {
    const t = setTimeout(() => ids.forEach((id) => threads[id] && saveThread(id, threads[id])), 800)
    return () => clearTimeout(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [threads, key])
  // A session not streaming yet still shows what this browser kept of it.
  return useCallback((id: string) => threads[id] ?? (ids.includes(id) ? loadThread(id) : null) ?? emptyThread, [threads, key]) // eslint-disable-line react-hooks/exhaustive-deps
}

/** The edge answers 402 `insufficient_credit` on inference; the engine ends the turn with that error. */
export function outOfCredits(t: Thread) {
  if (t.ended?.type !== 'error') return false
  return /insufficient_credit|out_of_credits|402/.test(JSON.stringify(t.ended.error ?? ''))
}

/** owner/name from "owner/name", a github.com URL, or a git remote. */
export function parseRepo(s: string): string | null {
  const m = s.trim().match(/^(?:https?:\/\/github\.com\/|git@github\.com:)?([\w.-]+)\/([\w.-]+?)(?:\.git)?\/?$/)
  return m ? `${m[1]}/${m[2]}` : null
}

/** Why a turn stopped on an error, in a line, unless it's the out-of-credits case (it has its own card). */
export function turnError(t: Thread): string | null {
  return outOfCredits(t) ? null : endError(t.ended)
}

/** Why a turn ended on an error, in a line; null for any other ending. */
export function endError(reason: EndReason | null | undefined): string | null {
  if (reason?.type !== 'error') return null
  const e = (reason as { error?: { type?: string; status?: number; message?: string } }).error ?? {}
  let detail = e.message ?? ''
  try { detail = JSON.parse(detail)?.error?.message ?? detail } catch { /* not JSON */ }
  if (e.status === 401) return `The model provider refused this session's key${detail ? ` (${detail})` : ''}.`
  if (e.status === 429) return 'Frog Cloud was too busy to answer, even after retrying. Try again in a moment.'
  if (e.status === 503) return 'No model was free on Frog Cloud, even after retrying. Try again in a moment.'
  return [e.type === 'provider' ? 'The model call failed' : 'The turn stopped', e.status ? `(${e.status})` : '', detail ? `: ${detail}` : ''].join(' ').replace(' :', ':').trim() + '.'
}

/** The account's repos for the composer menu; empty until the gateway answers (or if it can't). */
export function useRepos(cloud: CloudEngine | null) {
  const [list, setList] = useState<RepoList>({ repos: [] })
  useEffect(() => {
    if (!cloud) return
    let live = true
    cloud.gateway.repos().then((r) => live && setList(r), () => live && setList({ repos: [] }))
    return () => { live = false }
  }, [cloud])
  return list
}
