import { useEffect, useState } from 'react'
import type { EngineClient } from './engine/client'
import { MockEngine } from './engine/mock'
import { emptyThread, reduce, type Thread } from './engine/thread'

// Everything the app knows, in memory. Session metadata (repo, branch, PR) belongs to the
// account; what happened inside a session comes only from its engine event stream.

export interface Session {
  id: string
  title: string
  repo: string
  branch: string
  pr?: string
  checks?: 'passing' | 'failing' | 'running'
  merged?: boolean
  age: string
}

export interface Repo { name: string; meta: string; when: string }

export const repos: Repo[] = [
  { name: 'ecto/ledger', meta: 'TypeScript · private', when: 'pushed 2h ago' },
  { name: 'ecto/garden', meta: 'Rust · private', when: 'yesterday' },
  { name: 'ecto/frog', meta: 'Rust · private', when: 'yesterday' },
  { name: 'ecto/dotfiles', meta: 'Shell · public', when: 'last week' },
]

export const starters = [
  { i: '✓', title: 'Fix the failing tests', detail: 'Runs them, finds why, fixes it' },
  { i: '⑂', title: 'Review my open PR', detail: 'Reads the diff, leaves notes' },
  { i: '?', title: 'Explain this codebase', detail: 'A map of how it fits together' },
  { i: '+', title: 'Add a small feature', detail: 'Plans it, builds it, opens a PR' },
]

export const models = [
  { id: 'dart', note: 'Fast and capable. The default.' },
  { id: 'dart-deep', note: 'Slower, for big refactors' },
]

const mock = new MockEngine()
export const engine: EngineClient = mock

export const seedSessions: Session[] = [
  { id: 's-auth', title: 'Fix the failing tests in auth/', repo: 'ecto/ledger', branch: 'frog/fix-auth', pr: '#214', checks: 'running', age: 'now' },
  { id: 's-temporal', title: 'Move dates to Temporal', repo: 'ecto/ledger', branch: 'frog/temporal', age: '2m' },
  { id: 's-vitest', title: 'Bump vitest', repo: 'ecto/ledger', branch: 'frog/vitest', age: '2h' },
  { id: 's-login', title: 'Fix login redirect', repo: 'ecto/ledger', branch: 'frog/login', pr: '#209', merged: true, age: 'Mon' },
  { id: 's-soil', title: 'Add soil sensor', repo: 'ecto/garden', branch: 'frog/soil', merged: true, age: 'Fri' },
]

// Histories, replayed through the same protocol a live session uses.
mock.seed('s-auth', 'Fix the failing tests in auth/')
mock.seed('s-vitest', 'Add a small feature: bump vitest to 2.1', false)
mock.seed('s-login', 'Explain why login redirects to /', false)
mock.seed('s-soil', 'Add a soil sensor reading', false)
mock.append('s-temporal', [
  { event: 'turn_started', turn: 1, input: 'Move every date in ledger from moment to Temporal, and keep the tests green.' },
  { event: 'item_started', id: 't1', kind: { type: 'tool_call', name: 'Edit', arg: '31 files' } },
  { event: 'item_completed', id: 't1', item: { type: 'tool_call', name: 'Edit', arg: '31 files', input: {}, outcome: 'ok', output: '', display: 'rewrote 31 files · +612 −540' } },
  { event: 'item_started', id: 't2', kind: { type: 'tool_call', name: 'Bash', arg: 'npm test' } },
  { event: 'item_completed', id: 't2', item: { type: 'tool_call', name: 'Bash', arg: 'npm test', input: {}, outcome: 'ok', output: '', display: 'ran the tests · 214 pass · 3 fail' } },
  { event: 'item_started', id: 't3', kind: { type: 'message' } },
  { event: 'item_completed', id: 't3', item: { type: 'message', text: 'First pass is done and saved. 3 tests in reports/ still fail.' } },
  { event: 'turn_ended', turn: 1, reason: { type: 'error', error: { type: 'out_of_credits' } }, usage: { context_tokens: null, input_tokens: 0, output_tokens: 0, model_calls: 0 } },
])

/** Subscribe to every session's stream and keep a folded `Thread` per session. */
export function useThreads(ids: string[]) {
  const [threads, setThreads] = useState<Record<string, Thread>>({})
  const key = ids.join(',')
  useEffect(() => {
    const offs = ids.map((id) => engine.subscribe(id, 0, (env) =>
      setThreads((all) => ({ ...all, [id]: reduce(all[id] ?? emptyThread, env) }))))
    return () => offs.forEach((off) => off())
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key])
  return (id: string) => threads[id] ?? emptyThread
}

export const outOfCredits = (t: Thread) => t.ended?.type === 'error' && t.ended.error.type === 'out_of_credits'
