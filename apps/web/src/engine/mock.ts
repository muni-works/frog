import type { EngineClient } from './client'
import type { Envelope, Event, FileDiff, Op } from './protocol'

// A fake engine. Each session keeps a durable log of envelopes; `subscribe` replays it and
// then streams live, which is what `Op::Subscribe { after }` does on the real engine.
// Turns are scripted: a list of steps, each a pause then some events, with an optional
// gate that waits for the user's `Op::Permission`.

type Step = { wait: number; events: Event[] } | { gate: string; onAllow: Step[]; onDeny: Step[] }

const usage = { context_tokens: 18_400, input_tokens: 42_100, output_tokens: 1_900, model_calls: 6 }
const done = (turn: number): Event => ({ event: 'turn_ended', turn, reason: { type: 'complete' }, usage })

let ids = 0
const nextId = () => `i${++ids}`

/** A message item that streams in word by word. */
function say(text: string, gap = 40): Step[] {
  const id = nextId()
  const words = text.split(/(?<= )/)
  return [
    { wait: 200, events: [{ event: 'item_started', id, kind: { type: 'message' } }] },
    ...words.map((w) => ({ wait: gap, events: [{ event: 'item_delta', id, delta: { type: 'text', text: w } }] as Event[] })),
    { wait: 0, events: [{ event: 'item_completed', id, item: { type: 'message', text } }] },
  ]
}

function decide(text: string): Step[] {
  const id = nextId()
  return [{ wait: 300, events: [
    { event: 'item_started', id, kind: { type: 'reasoning' } },
    { event: 'item_completed', id, item: { type: 'reasoning', text } },
  ] }]
}

function tool(name: string, arg: string, display: string, wait = 600, output?: string[]): Step[] {
  const id = nextId()
  return [
    { wait: 250, events: [{ event: 'item_started', id, kind: { type: 'tool_call', name, arg } }] },
    ...(output ?? []).map((text) => ({ wait: 220, events: [{ event: 'item_delta', id, delta: { type: 'output', text } }] as Event[] })),
    { wait, events: [{ event: 'item_completed', id, item: { type: 'tool_call', name, arg, input: { arg }, outcome: 'ok', output: (output ?? []).join(''), display } }] },
  ]
}

const sessionDiff: FileDiff = {
  path: 'auth/session.ts', created: false, added: 2, removed: 1,
  hunks: [{ lines: [
    { kind: 'context', old: 41, new: 41, text: 'export function session(req: Request) {' },
    { kind: 'remove', old: 42, new: null, text: '  const t = readRefresh(req)' },
    { kind: 'add', old: null, new: 42, text: '  const jar = parseCookies(req)' },
    { kind: 'add', old: null, new: 43, text: '  const t = readRefresh(jar)' },
  ] }],
}

function edit(diff: FileDiff, after: Step[], denied: Step[]): Step[] {
  const id = nextId(), ask = `p${id}`
  const item = (outcome: 'ok' | 'denied'): Event => ({ event: 'item_completed', id, item: { type: 'tool_call', name: 'Edit', arg: diff.path, input: { path: diff.path }, outcome, output: '', display: null, diff } })
  return [
    { wait: 300, events: [
      { event: 'item_started', id, kind: { type: 'tool_call', name: 'Edit', arg: diff.path } },
      { event: 'permission_request', id: ask, item: id, name: 'Edit', arg: diff.path, always: 'Edit auth/**', preview: diff },
    ] },
    { gate: ask,
      onAllow: [{ wait: 200, events: [{ event: 'permission_resolved', id: ask, decision: 'allow' }, item('ok')] }, ...after],
      onDeny: [{ wait: 200, events: [{ event: 'permission_resolved', id: ask, decision: 'deny' }, item('denied')] }, ...denied] },
  ]
}

/** Pick a script for what the user typed. Crude on purpose: it's a prototype. */
function script(turn: number, text: string): Step[] {
  const t = text.toLowerCase()
  if (t.includes('test')) return [
    ...tool('Bash', 'npm test auth', 'ran the tests · 2 failing in auth/', 500, ['FAIL auth/session.test.ts\n', 'FAIL auth/refresh.test.ts\n', 'Tests: 2 failed, 12 passed\n']),
    ...tool('Read', 'auth/session.ts', 'read auth/session.ts, auth/refresh.ts'),
    ...decide('parse cookies before reading the refresh token.'),
    ...say("The refresh token is read before the cookie is parsed, so a fresh login looks expired. I'll parse first."),
    ...edit(sessionDiff,
      [...tool('Bash', 'npm test auth', 'ran the tests · 14 pass', 700, ['PASS auth/session.test.ts\n', 'PASS auth/refresh.test.ts\n', 'Tests: 14 passed, 14 total\n']),
        ...say('Fixed. All 14 auth tests pass. Want me to push this to the PR?'), { wait: 0, events: [done(turn)] }],
      [...say("OK, I won't touch it. Tell me what you'd rather I do."), { wait: 0, events: [{ event: 'turn_ended', turn, reason: { type: 'denied' }, usage }] }]),
  ]
  if (t.includes('review') || t.includes('pr')) return [
    ...tool('Bash', 'git clone ecto/ledger', 'cloned ecto/ledger into your sandbox'),
    ...tool('Bash', 'gh pr view 212', 'found PR #212 · Move dates to Temporal'),
    ...tool('Read', 'reports/', 'read 31 changed files', 1400),
    ...say("Reading the diff. I'll start with reports/, where the time zones change."),
    ...decide('flag the DST edge in reports/tz.ts rather than rewrite it.'),
    ...say('Two notes so far: reports/tz.ts drops the offset on DST days, and one test pins a local time zone. I left both as review comments.'),
    { wait: 0, events: [done(turn)] },
  ]
  if (t.includes('explain')) return [
    ...tool('Glob', '**/*.ts', 'listed 184 files'),
    ...tool('Read', 'README.md', 'read README.md, src/index.ts'),
    ...say('ledger is a small accounting app: src/ holds the API, reports/ builds the statements, and auth/ handles sessions. Everything goes through src/db.ts.'),
    { wait: 0, events: [done(turn)] },
  ]
  return [
    ...tool('Read', '.', 'looked around the repo'),
    ...decide('start small and show a plan first.'),
    ...say("Here's my plan: find where this lives, make the change, run the tests, then show you the diff."),
    { wait: 0, events: [done(turn)] },
  ]
}

export class MockEngine implements EngineClient {
  private logs = new Map<string, Envelope[]>()
  private listeners = new Map<string, Set<(e: Envelope) => void>>()
  private gates = new Map<string, { onAllow: Step[]; onDeny: Step[]; rest: Step[]; live: boolean }>()
  private turns = new Map<string, number>()
  private timers = new Map<string, number>()

  /** Run a turn to completion (or its first gate) with no delays, to seed history. */
  seed(session: string, text: string, stopAtGate = true) {
    this.startTurn(session, text, false, stopAtGate)
  }

  /** Append raw events to a session's log, for histories no script produces. */
  append(session: string, events: Event[]) {
    events.forEach((e) => this.emit(session, e))
  }

  subscribe(session: string, after: number, on: (e: Envelope) => void) {
    for (const e of this.logs.get(session) ?? []) if (e.seq > after) on(e)
    let set = this.listeners.get(session)
    if (!set) this.listeners.set(session, (set = new Set()))
    set.add(on)
    return () => { set!.delete(on) }
  }

  send(session: string, op: Op) {
    if (op.op === 'submit') return this.startTurn(session, op.text, true, false)
    if (op.op === 'permission') {
      const g = this.gates.get(op.id)
      if (!g) return
      this.gates.delete(op.id)
      const allow = op.decision !== 'deny'
      this.run(session, [...(allow ? g.onAllow : g.onDeny), ...(allow ? g.rest : [])], true)
    }
    if (op.op === 'interrupt') {
      clearTimeout(this.timers.get(session))
      const turn = this.turns.get(session) ?? 0
      this.emit(session, { event: 'turn_ended', turn, reason: { type: 'cancelled' }, usage })
    }
  }

  private startTurn(session: string, text: string, live: boolean, stopAtGate: boolean) {
    const turn = (this.turns.get(session) ?? 0) + 1
    this.turns.set(session, turn)
    this.emit(session, { event: 'turn_started', turn, input: text })
    this.run(session, script(turn, text), live, stopAtGate)
  }

  private run(session: string, steps: Step[], live: boolean, stopAtGate = false) {
    const [step, ...rest] = steps
    if (!step) return
    if ('gate' in step) {
      this.gates.set(step.gate, { onAllow: step.onAllow, onDeny: step.onDeny, rest, live })
      if (!stopAtGate && !live) this.send(session, { op: 'permission', id: step.gate, decision: 'allow' })
      return
    }
    const go = () => { step.events.forEach((e) => this.emit(session, e)); this.run(session, rest, live, stopAtGate) }
    if (!live) return go()
    this.timers.set(session, window.setTimeout(go, step.wait))
  }

  private emit(session: string, event: Event) {
    const log = this.logs.get(session) ?? []
    this.logs.set(session, log)
    const env = { ...event, seq: log.length + 1, session, created: Date.now() } as Envelope
    log.push(env)
    this.listeners.get(session)?.forEach((l) => l(env))
  }
}
