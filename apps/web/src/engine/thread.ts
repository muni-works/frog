import type { EndReason, Envelope, Event, FileDiff, ToolOutcome } from './protocol'

// Folds a session's envelopes into what the transcript draws. Pure, so replay and
// live streaming share one path: `reduce(thread, envelope)` for every envelope in order.

export interface Entry {
  id: string
  kind: 'message' | 'reasoning' | 'tool'
  text: string
  name?: string
  arg?: string
  display?: string | null
  outcome?: ToolOutcome
  diff?: FileDiff
  output: string
  done: boolean
}

export interface Ask { id: string; item: string; name: string; arg: string; preview?: FileDiff }

export interface Thread {
  lastSeq: number
  turns: { turn: number; input: string; entries: Entry[] }[]
  running: boolean
  ask: Ask | null
  ended: EndReason | null
  changes: FileDiff[]
  terminal: string
  /** When the running turn started (envelope `created`), for the composer's timer. */
  startedAt: number
}

export const emptyThread: Thread = { lastSeq: 0, turns: [], running: false, ask: null, ended: null, changes: [], terminal: '', startedAt: 0 }

function patch(t: Thread, id: string, f: (e: Entry) => Entry): Thread {
  return { ...t, turns: t.turns.map((u) => ({ ...u, entries: u.entries.map((e) => (e.id === id ? f(e) : e)) })) }
}

function apply(t: Thread, ev: Event, created: number): Thread {
  switch (ev.event) {
    case 'turn_started':
      return { ...t, running: true, ended: null, startedAt: created, turns: [...t.turns, { turn: ev.turn, input: ev.input, entries: [] }] }
    case 'turn_ended':
      return { ...t, running: false, ask: null, ended: ev.reason }
    case 'item_started': {
      const k = ev.kind
      const entry: Entry = k.type === 'tool_call'
        ? { id: ev.id, kind: 'tool', text: '', name: k.name, arg: k.arg, output: '', done: false }
        : { id: ev.id, kind: k.type, text: '', output: '', done: false }
      const last = t.turns[t.turns.length - 1]
      if (!last) return t
      const terminal = k.type === 'tool_call' && k.name === 'Bash' ? t.terminal + `sandbox ~/ledger $ ${k.arg}\n` : t.terminal
      return { ...t, terminal, turns: [...t.turns.slice(0, -1), { ...last, entries: [...last.entries, entry] }] }
    }
    case 'item_delta': {
      const d = ev.delta
      const next = patch(t, ev.id, (e) => (d.type === 'output' ? { ...e, output: e.output + d.text } : { ...e, text: e.text + d.text }))
      return d.type === 'output' ? { ...next, terminal: next.terminal + d.text } : next
    }
    case 'item_completed': {
      const it = ev.item
      const next = patch(t, ev.id, (e) => it.type === 'tool_call'
        ? { ...e, done: true, outcome: it.outcome, display: it.display, diff: it.diff, output: it.output }
        : { ...e, done: true, text: it.text })
      if (it.type === 'tool_call' && it.diff && it.outcome === 'ok') {
        const d = it.diff
        return { ...next, changes: [...next.changes.filter((c) => c.path !== d.path), d] }
      }
      return next
    }
    case 'permission_request':
      return { ...t, ask: { id: ev.id, item: ev.item, name: ev.name, arg: ev.arg, preview: ev.preview } }
    case 'permission_resolved':
      return { ...t, ask: null }
    default:
      return t
  }
}

export function reduce(t: Thread, env: Envelope): Thread {
  if (env.seq <= t.lastSeq) return t // already seen (a replay overlapping live)
  return { ...apply(t, env, env.created), lastSeq: env.seq }
}
