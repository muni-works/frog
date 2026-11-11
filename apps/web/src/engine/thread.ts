import type { ElicitSchema, EndReason, Envelope, Event, FileDiff, Image, Mode, Part, Todo, ToolOutcome, TurnUsage } from '../cloud/protocol'

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

export interface Ask { id: string; item: string; name: string; arg: string; always?: string; preview?: FileDiff; reason?: string }

/** The Ask tool waiting on a choice (`question`), answered with Op::Answer. */
export interface Question { id: string; item: string; question: string; options: { label: string; detail?: string }[]; multi: boolean; allowOther: boolean }
/** An MCP server waiting on input (`elicitation`), answered with Op::Elicit. */
export interface Elicitation { id: string; server: string; message: string; schema?: ElicitSchema; url?: string }

/** A terminal (or preview) pane the engine opened: its latest screen, and whether it closed. */
export interface Pane { id: string; kind: 'terminal' | 'preview'; title: string; cwd?: string; url?: string; closed: boolean; exit?: number; screen?: { cols: number; rows: number; lines: string[]; cursor: [number, number]; seq: number } }

export interface Thread {
  lastSeq: number
  /** The last envelope taken: its time and seq. A session woken from its sleep snapshot runs a
   * new engine whose seqs restart low (until ecto/frog#154 ships), so newer-in-time beats seq. */
  lastAt?: number
  lastRaw?: number
  /** Each turn's input and items; `usage` and `reason` once it ends. */
  turns: { turn: number; input: string; images?: Image[]; more?: Part[]; entries: Entry[]; at?: number; usage?: TurnUsage; reason?: EndReason }[]
  running: boolean
  ask: Ask | null
  ended: EndReason | null
  changes: FileDiff[]
  terminal: string
  /** When the running turn started (envelope `created`), for the composer's timer. */
  startedAt: number
  /** From `titled`, when the engine names the session. */
  title: string | null
  /** The engine's model spec (e.g. `cloud/glm-5.3-flash`) and mode, from `status` and the
   * `*_changed` events; null until the engine says. */
  model: string | null
  mode: Mode | null
  /** Context used and the window, from the latest `status`. */
  context: { used: number | null; window: number } | null
  /** What the engine says it's doing right now (`progress`, or a `notice` such as a retry),
   * while a turn runs. Ephemeral: cleared when output arrives or the turn ends. */
  activity: { text: string; warn: boolean } | null
  question: Question | null
  elicitation: Elicitation | null
  /** The session's plan (TodoWrite), from the latest `status`. */
  todos: Todo[]
  /** Whether the session's model reads images (status.vision); null until the engine says. */
  vision: boolean | null
  panes: Record<string, Pane>
  /** The model's suggested next message (its `Next` tool) for the last finished turn; `act`
   * means it acts outside the project (push, deploy). Cleared when the next turn starts. */
  next: { text: string; act: boolean } | null
  /** Where the context was shrunk: after how many turns, and what it says ("82k → 9k tokens"). */
  marks: { after: number; text: string; failed?: boolean }[]
  /** A compaction asked for and not yet answered. */
  compacting: boolean
}

export const emptyThread: Thread = { lastSeq: 0, turns: [], running: false, ask: null, ended: null, changes: [], terminal: '', startedAt: 0, title: null, model: null, mode: null, context: null, activity: null, question: null, elicitation: null, todos: [], vision: null, panes: {}, next: null, marks: [], compacting: false }

const kilo = (n: number) => (n >= 1000 ? `${Math.round(n / 1000)}k` : String(n))

/** Item ids are only unique within a turn, so updates go to the latest turn. */
function patch(t: Thread, id: string, f: (e: Entry) => Entry): Thread {
  const last = t.turns[t.turns.length - 1]
  if (!last) return t
  return { ...t, turns: [...t.turns.slice(0, -1), { ...last, entries: last.entries.map((e) => (e.id === id ? f(e) : e)) }] }
}

function apply(t: Thread, ev: Event, created: number): Thread {
  switch (ev.event) {
    case 'turn_started': {
      // A repeat of the turn still in progress (a replayed or doubled envelope) is the same
      // turn, not a second one: keep its items so no stale card shows up beside it.
      const last = t.turns[t.turns.length - 1]
      if (last && last.turn === ev.turn && !last.reason) return { ...t, running: true, ended: null }
      return { ...t, running: true, ended: null, next: null, startedAt: created, turns: [...t.turns, { turn: ev.turn, input: ev.input, images: ev.images, more: ev.more, entries: [], at: created }] }
    }
    case 'compacted':
      return { ...t, compacting: false, marks: [...(t.marks ?? []), { after: t.turns.length, text: `Compacted · ${kilo(ev.tokens_before)} → ${kilo(ev.tokens_after)} tokens` }] }
    case 'compaction_failed':
      return { ...t, compacting: false, marks: [...(t.marks ?? []), { after: t.turns.length, text: "Couldn't compact: the conversation doesn't fit even summarized. Start a new session.", failed: true }] }
    case 'context_pruned':
      return { ...t, marks: [...(t.marks ?? []), { after: t.turns.length, text: `Trimmed ${ev.results} old tool result${ev.results === 1 ? '' : 's'} · ${kilo(ev.tokens_before)} → ${kilo(ev.tokens_after)} tokens` }] }
    case 'next_suggested':
      return { ...t, next: { text: ev.text, act: !!ev.act } }
    case 'turn_ended': {
      // The latest turn with that number: an older one that shares it has already ended.
      const at = t.turns.map((u) => u.turn).lastIndexOf(ev.turn)
      const turns = t.turns.map((u, i) => (i === at ? { ...u, usage: ev.usage, reason: ev.reason } : u))
      return { ...t, turns, running: false, ask: null, question: null, elicitation: null, ended: ev.reason, activity: null }
    }
    case 'progress':
      return t.running ? { ...t, activity: { text: ev.label, warn: false } } : t
    case 'notice':
      return t.running ? { ...t, activity: { text: humanize(ev.message), warn: ev.level === 'warn' } } : t
    case 'item_started': {
      const k = ev.kind
      const entry: Entry = k.type === 'tool_call'
        ? { id: ev.id, kind: 'tool', text: '', name: k.name, arg: k.arg, output: '', done: false }
        : { id: ev.id, kind: k.type, text: '', output: '', done: false }
      const last = t.turns[t.turns.length - 1]
      if (!last) return t
      const terminal = k.type === 'tool_call' && k.name === 'Bash' ? t.terminal + `$ ${k.arg}\n` : t.terminal
      return { ...t, terminal, turns: [...t.turns.slice(0, -1), { ...last, entries: [...last.entries, entry] }] }
    }
    case 'item_delta': {
      const d = ev.delta
      if (t.activity) t = { ...t, activity: null }
      if (d.type === 'image_preview') return t
      const next = patch(t, ev.id, (e) => (d.type === 'output' ? { ...e, output: e.output + d.text } : { ...e, text: e.text + d.text }))
      return d.type === 'output' ? { ...next, terminal: next.terminal + d.text } : next
    }
    case 'item_completed': {
      const it = ev.item
      const next = patch(t, ev.id, (e) => it.type === 'tool_call'
        ? { ...e, done: true, outcome: it.outcome, display: it.display, diff: it.diff, output: it.output }
        : { ...e, done: true, text: it.text })
      if (it.type === 'tool_call' && it.diff && it.outcome === 'ok') {
        // A file edited several times keeps every edit's hunks and the summed counts.
        const d = it.diff
        const was = next.changes.find((c) => c.path === d.path)
        const merged = was ? { ...d, created: was.created || d.created, added: was.added + d.added, removed: was.removed + d.removed, hunks: [...was.hunks, ...d.hunks] } : d
        return { ...next, changes: [...next.changes.filter((c) => c.path !== d.path), merged] }
      }
      return next
    }
    case 'permission_request':
      return { ...t, ask: { id: ev.id, item: ev.item, name: ev.name, arg: ev.arg, always: ev.always, preview: ev.preview, reason: ev.reason } }
    case 'status':
      return { ...t, model: ev.model, mode: ev.mode, context: { used: ev.context_tokens, window: ev.context_window }, todos: ev.todos ?? t.todos, vision: ev.vision ?? t.vision }
    case 'pane_opened':
      return { ...t, panes: { ...t.panes, [ev.id]: { id: ev.id, kind: ev.kind, title: ev.title, cwd: ev.cwd, url: ev.url, closed: false } } }
    case 'pane_closed': {
      const p = t.panes[ev.id]
      return p ? { ...t, panes: { ...t.panes, [ev.id]: { ...p, closed: true, exit: ev.exit } } } : t
    }
    case 'pane_screen': {
      const p = t.panes[ev.id]
      // Screens can arrive out of order across a reconnect; keep the newest.
      if (!p || (p.screen && p.screen.seq >= ev.screen_seq)) return t
      return { ...t, panes: { ...t.panes, [ev.id]: { ...p, screen: { cols: ev.cols, rows: ev.rows, lines: ev.lines, cursor: ev.cursor, seq: ev.screen_seq } } } }
    }
    case 'question':
      return { ...t, question: { id: ev.id, item: ev.item, question: ev.question, options: ev.options ?? [], multi: !!ev.multi, allowOther: !!ev.allow_other } }
    case 'question_resolved':
      return t.question?.id === ev.id ? { ...t, question: null } : t
    case 'elicitation':
      return { ...t, elicitation: { id: ev.id, server: ev.server, message: ev.message, schema: ev.schema, url: ev.url } }
    case 'elicitation_done':
      return t.elicitation?.id === ev.id ? { ...t, elicitation: null } : t
    case 'model_changed':
      return { ...t, model: ev.model }
    case 'mode_changed':
      return { ...t, mode: ev.mode }
    case 'titled':
      return { ...t, title: ev.title }
    case 'permission_resolved':
      return { ...t, ask: null }
    default:
      return t
  }
}

export function reduce(t: Thread, env: Envelope): Thread {
  // Already seen: a replay overlapping live. Unless it's newer than anything taken, which is a
  // woken engine numbering from 0 again; those come in time order, so take them.
  const at = t.lastAt
  const fresh = env.seq > t.lastSeq || (at !== undefined && (env.created > at || (env.created === at && env.seq > (t.lastRaw ?? 0))))
  if (!fresh) return t
  return { ...apply(t, env, env.created), lastSeq: Math.max(t.lastSeq, env.seq), lastAt: Math.max(at ?? 0, env.created), lastRaw: env.seq }
}

/** The engine's notices, in words: a model call it's retrying reads as what happened and when
 * it tries again, not as an HTTP status and a JSON body. Anything else passes through. */
export function humanize(message: string): string {
  // Engines before quiet retries said "retrying in 4s (2/6)" on every retry; newer ones stay
  // quiet for the first two and then say "still trying (3/6)".
  const retry = message.match(/retrying in (\d+)s \((\d+)\/(\d+)\)/)
  const still = message.match(/still trying \((\d+)\/(\d+)\)/)
  const when = retry ? ` Trying again in ${retry[1]}s (${retry[2]} of ${retry[3]}).` : still ? ` Still trying (${still[1]} of ${still[2]}).` : ''
  if (/\b429\b|too many concurrent|rate[_ ]limit|\bbusy\b/i.test(message)) return `Frog Cloud is busy right now.${when}`
  if (/\b503\b|no inference capacity|service_unavailable/i.test(message)) return `No model is free on Frog Cloud right now.${when}`
  if (/\b502\b|\b504\b|timed? ?out|connection (reset|refused)/i.test(message)) return `Couldn't reach the model.${when}`
  if (retry || still) return `The model call failed.${when}`
  return message
}
