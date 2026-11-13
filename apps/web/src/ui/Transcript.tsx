import { Fragment, memo, useEffect, useMemo, useRef, useState } from 'react'
import type { FileDiff, Image } from '../cloud/protocol'
import type { Ask, Entry, Question, Thread } from '../engine/thread'
import { type Model } from '../models'
import { ElicitationCard, QuestionCard } from './AskCards'
import { Markdown } from './Markdown'
import { Hunks } from './Diff'
import { endError } from '../store'
import { TurnFooter } from './TurnFooter'
import { WidgetCard } from './Widget'

// Draws a folded Thread: the user's message, tool lines, "Decided" steps (reasoning items),
// streamed replies, and a diff card per edit with Allow ⌘↩ / Deny ⌘. while it waits.

export function DiffCard({ diff, ask, onDecide, note }: { diff: FileDiff; ask?: Ask | null; onDecide?: Decide; note?: string }) {
  return (
    <div className="cardx">
      <div style={{ display: 'flex', justifyContent: 'space-between', padding: '10px 14px 6px' }}>
        <b>{ask ? 'Edit' : 'Edited'} {diff.path}</b>
        <span className="det">+{diff.added} −{diff.removed}</span>
      </div>
      <Hunks diff={diff} max={40} />
      {ask && onDecide && (
        <div className="diff-acts">
          <span style={{ flex: 1 }} className="det">{note}</span>
          <button type="button" className="f-btn f-btn--bordered" onClick={() => onDecide(false)}>Deny ⌘.</button>
          <button type="button" className="f-btn f-btn--prominent" onClick={() => onDecide(true)}>Allow ⌘↩</button>
        </div>
      )}
    </div>
  )
}

/** Output past this many lines is cut to its first and last parts, like the Mac's tool rows. */
const MAX_LINES = 400

function clip(out: string) {
  const ls = out.replace(/\x1b\[[0-9;]*m/g, '').split('\n')
  if (ls.length <= MAX_LINES) return ls.join('\n')
  const half = MAX_LINES / 2
  return [...ls.slice(0, half), `… ${ls.length - MAX_LINES} more lines …`, ...ls.slice(-half)].join('\n')
}

/** One step: a summary line that opens to what it ran and what came back. A running shell
 * command shows its live output; a failure opens by itself. */
// What each tool did, as a verb and an icon: "Ran git status", "Read src/a.ts".
const TOOL_LOOK: Record<string, { verb: [string, string]; icon: string }> = {
  bash: { verb: ['Running', 'Ran'], icon: 'M4 6l5 5-5 5M11 17h8' },
  read: { verb: ['Reading', 'Read'], icon: 'M6 3h8l4 4v14H6zM14 3v4h4' },
  write: { verb: ['Writing', 'Wrote'], icon: 'M6 3h8l4 4v14H6zM14 3v4h4M9 13h6M9 17h4' },
  edit: { verb: ['Editing', 'Edited'], icon: 'M4 20h4L19 9l-4-4L4 16zM13.5 6.5l4 4' },
  grep: { verb: ['Searching', 'Searched'], icon: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-4-4' },
  glob: { verb: ['Finding', 'Found'], icon: 'M3 7h6l2 2h10v10H3z' },
  webfetch: { verb: ['Fetching', 'Fetched'], icon: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18' },
  websearch: { verb: ['Searching the web for', 'Searched the web for'], icon: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18' },
  todowrite: { verb: ['Planning', 'Planned'], icon: 'M9 6h11M9 12h11M9 18h11M4 6l1 1 2-2M4 12l1 1 2-2M4 18l1 1 2-2' },
  visualize: { verb: ['Making a visual', 'Made a visual'], icon: 'M4 19V5M4 19h16M8 15l3-4 3 2 5-6' },
  visualguide: { verb: ['Reading the visual guide', 'Read the visual guide'], icon: 'M6 3h8l4 4v14H6zM14 3v4h4' },
  settitle: { verb: ['Naming', 'Named'], icon: 'M4 7V5h16v2M12 5v14M9 19h6' },
  // A child session, as on Mac (ActivityLine): "Ran an agent <what it was asked>".
  task: { verb: ['Running an agent', 'Ran an agent'], icon: 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 20c0-3 3-5 6-5s6 2 6 5M16 11a3 3 0 1 0 0-6M18 15c2 .6 3 2.4 3 5' },
}
const OTHER = { verb: ['Using', 'Used'] as [string, string], icon: 'M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.6 2.6-2.4-.6-.6-2.4z' }

/** Tools whose result is a sentence, not a payload: a `SendMessage` result is one line. These
 * say it on their row with no click at all. The Mac's `ToolLook.inlineResults` is the same set,
 * so the two transcripts keep one look. Everything else — a command's output, a file, a diff —
 * is a payload and stays behind the row's chevron. */
const INLINE_RESULTS = new Set([
  'sendmessage', 'ask', 'todowrite', 'skill', 'usefolder',
  'renamesession', 'movesession', 'archivesession', 'unarchivesession', 'listsessions',
])

/** How much of a short result the row's own line shows before the rest is worth a click. */
export const LINE_CAP = 90

/** The phrase a short result reads as on its row: the engine's display when it sent one
 * ("chose: Send now"), else the result's first sentence ("Sent to ops; delivered"). */
export function saidLine(display: string | null | undefined, output: string): string {
  const full = (display || output).trim()
  if (!full) return ''
  const first = full.split('\n').map((l) => l.trim()).find(Boolean) ?? full
  // A sentence often trails advice ("…delivered. It reads the message at its next boundary"):
  // the first sentence is the meat, and the rest lives behind the row. Its full stop is
  // dropped — the row sets it off with " · ".
  if (first.length > 24) {
    const m = /[.!?] /.exec(first)
    if (m && m.index < LINE_CAP) return first.slice(0, m.index)
  }
  return first.length > LINE_CAP ? `${first.slice(0, LINE_CAP - 1)}…` : first
}

/** Whether the line says the whole of it: nothing is left behind the row, so it gets no chevron
 * (a click that reveals nothing is the same wasted click). True when the row's own text is the
 * whole result, not a first-sentence cut or a clip of it. */
export function fits(display: string | null | undefined, output: string): boolean {
  const full = (display || output).trim()
  return !full || saidLine(display, output) === full
}

/** "12 sessions" from `ListSessions`' JSON array: the row's worth of a page of JSON. */
export function sessionCount(name: string, output: string): string | null {
  if (name !== 'listsessions') return null
  try {
    const rows = JSON.parse(output)
    if (!Array.isArray(rows)) return null
    return `${rows.length} session${rows.length === 1 ? '' : 's'}`
  } catch {
    return null
  }
}

/** Exported for `test/toolrow-render.test.ts`, which draws this row and reads the DOM back:
 * the only way a test can see what the browser is actually handed, since the helpers above can
 * stay correct while the row stops using them. */
export function ToolLine({ e }: { e: Entry }) {
  const [open, setOpen] = useState<boolean | null>(null)
  const name = (e.name ?? '').toLowerCase()
  const look = TOOL_LOOK[name] ?? OTHER
  const output = e.output.trim()
  // A short result is said on the row itself: no click, no chevron, no body to open.
  const said = e.done && e.outcome === 'ok' && INLINE_RESULTS.has(name) && !e.diff
    ? sessionCount(name, output) ?? saidLine(e.display, output)
    : ''
  const whole = said ? fits(e.display, sessionCount(name, output) ?? output) : false
  const shown = open ?? (e.outcome === 'error' || (!e.done && !!output))
  const state = !e.done ? 'run' : e.outcome === 'error' ? 'err' : e.outcome === 'denied' ? 'denied' : 'ok'
  // What it touched ("Read src/retry.rs", as on the Mac), or the side-model's gist when one
  // arrived: a raw shell command or MCP arguments read as nothing, and the gist says what the
  // call did. The engine's own one-line display ("Read 54 lines") goes in the opened detail,
  // so the verb isn't said twice.
  const what = (e.done && e.gist) || e.arg || (e.done && e.display) || (TOOL_LOOK[name] ? '' : e.name)
  return (
    <div className={`tool-row ${state}`}>
      <button type="button" className="tool" aria-expanded={whole ? false : shown} onClick={() => { if (!whole) setOpen(!shown) }}>
        <span className="tool-ic" aria-hidden="true">
          {state === 'run'
            ? <span className="tool-spin" />
            : <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d={look.icon} /></svg>}
        </span>
        <span className="tool-verb">{look.verb[e.done ? 1 : 0]}</span>
        {what && <span className={`tool-what${e.done && e.gist ? ' gist' : ''}`}>{what}</span>}
        {said && <span className="tool-said">· {said}</span>}
        {state === 'err' && <span className="tool-tag err">failed</span>}
        {state === 'denied' && <span className="tool-tag">denied</span>}
        {!whole && <span className="tool-chev" aria-hidden="true">›</span>}
      </button>
      {shown && !whole && (
        <div className="tool-body">
          {/* The raw call stays readable when the row's line is something else: with a gist on
              the row, this is the argument it summarized. The engine's own display leads, as
              upstream had it ("Read 54 lines"), with the argument under it. */}
          {e.arg && (e.gist || e.display) && (
            <>
              {e.display && <div className="tool-arg">{e.display}</div>}
              <div className="tool-arg">{e.arg}</div>
            </>
          )}
          {/* An inline tool's body is its sentence, as text — never a terminal block: one line
              in a <pre> reads as a payload it isn't. */}
          {INLINE_RESULTS.has(name) && !e.diff
            ? <div className="tool-said-body">{output ? clip(output) : 'No output.'}</div>
            : output ? <pre className="tool-out">{clip(output)}</pre> : <div className="det">{e.done ? 'No output.' : 'Running…'}</div>}
        </div>
      )}
    </div>
  )
}

/** A finished edit: its line, opening to the diff card. */
function EditLine({ diff }: { diff: FileDiff }) {
  const [open, setOpen] = useState(false)
  return (
    <div className="tool-row ok">
      <button type="button" className="tool" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className="tool-ic" aria-hidden="true">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d={TOOL_LOOK.edit.icon} /></svg>
        </span>
        <span className="tool-verb">{diff.created ? 'Created' : 'Edited'}</span>
        <span className="tool-what">{diff.path}</span>
        <span className="tool-n add">+{diff.added}</span>
        <span className="tool-n del">−{diff.removed}</span>
        <span className="tool-chev" aria-hidden="true">›</span>
      </button>
      {open && <DiffCard diff={diff} />}
    </div>
  )
}

/** A thought: one quiet line, collapsed with a ›, opening to what it thought (the Mac's too). */
/** A short finished thought alone between replies (no tool beside it) folds away, as on Mac
 * (TurnFlow: a model's scratch line before answering isn't worth a line of its own). */
function foldedThought(entries: Entry[], n: number): boolean {
  let a = n, b = n
  while (a > 0 && entries[a - 1].kind !== 'message') a--
  while (b < entries.length - 1 && entries[b + 1].kind !== 'message') b++
  return entries.slice(a, b + 1).every((x) => x.kind === 'reasoning' && x.done && x.text.trim().length <= 200 && !x.text.trim().includes('\n\n'))
}

function ThoughtLine({ text }: { text: string }) {
  const [open, setOpen] = useState(false)
  return (
    <div className="thought">
      <button type="button" className="tool" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className="tool-verb">Thought</span>
        <span className="tool-chev" aria-hidden="true">›</span>
      </button>
      {open && <div className="thought-body">{text}</div>}
    </div>
  )
}

export type DecideOpts = { always?: boolean; note?: string }
type Decide = (allow: boolean, opts?: DecideOpts) => void

/** The ask card, one design with the Mac's: the title, the command in a well, where it runs,
 * then the answers. Allow is the green primary (⌘↩), Deny keeps ⌘., the rest are secondary. */
function AskCard({ ask, onDecide }: { ask: Ask; onDecide: Decide }) {
  const [noting, setNoting] = useState(false)
  const [note, setNote] = useState('')
  const always = ask.always ? ask.always[0].toUpperCase() + ask.always.slice(1) : ''
  return (
    <div className="cardx ask">
      <div className="ask-h"><b>{ask.name === 'Bash' || ask.name === '!' ? 'Allow this command?' : `Allow ${ask.name}?`}</b>{ask.reason && <div className="det wrap">{ask.reason}</div>}</div>
      <div className="diff">{ask.arg}</div>
      {noting && (
        <form className="ask-note" onSubmit={(ev) => { ev.preventDefault(); if (note.trim()) onDecide(false, { note }) }}>
          <input className="f-input" autoFocus value={note} onChange={(ev) => setNote(ev.target.value)} placeholder="Tell the agent why, or what to do instead" />
          <button type="submit" className="f-btn f-btn--bordered" disabled={!note.trim()}>Deny</button>
        </form>
      )}
      {/* Two answers, as a Mac alert has; the rest behind ⋯, shortcuts in the tooltips. */}
      <div className="diff-acts">
        <details className="ask-more">
          <summary className="f-btn f-btn--bordered" aria-label="More choices" title="More choices">⋯</summary>
          <div className="f-card ask-more-menu" role="menu">
            {always && <button type="button" role="menuitem" onClick={() => onDecide(true, { always: true })}>{always}</button>}
            <button type="button" role="menuitem" onClick={() => setNoting(true)}>Deny with a note…</button>
          </div>
        </details>
        <span className="det ask-where">Runs in your cloud sandbox</span>
        <span style={{ flex: 1 }} />
        <button type="button" className="f-btn f-btn--bordered" title="Deny (⌘.)" onClick={() => onDecide(false)}>Deny</button>
        <button type="button" className="f-btn f-btn--prominent" title="Allow (⌘↩)" onClick={() => onDecide(true)}>Allow</button>
      </div>
    </div>
  )
}

const NO_MODELS: Model[] = []

export function Transcript({ thread, onDecide, onAnswer, onElicit, onRetry, models = NO_MODELS, outbox = [], onResend, onEdit, waiting, onContinue, onPrompt }: {
  thread: Thread
  onDecide: Decide
  onAnswer: (choices: string[], other?: string) => void
  onElicit: (action: 'accept' | 'decline' | 'cancel', content?: Record<string, string | number | boolean>) => void
  /** Try again, offered on the last turn when it ended on an error. */
  onRetry?: () => void
  models?: Model[]
  /** Messages sent but not yet started as a turn: shown at once, with a tick once on the wire. */
  outbox?: { id: number; text: string; images: Image[]; state: 'sending' | 'sent' | 'failed'; at: number }[]
  onResend?: (id: number) => void
  /** Put one of your messages back in the composer to change and resend. */
  onEdit?: (text: string) => void
  /** Ask Frog to carry on, offered when the last turn stopped short (length limit, a loop). */
  onContinue?: () => void
  /** What a sent message is waiting on, in a few words ("waking the sandbox"). */
  waiting?: string
  /** A visual's `sendPrompt`: send this as the user's next message. */
  onPrompt?: (text: string) => void
}) {
  // The live turn is the last one by position: turn numbers can repeat after a resume.
  const lastIdx = thread.turns.length - 1
  // Handlers change identity every render; turns read them through one stable ref so a
  // streamed delta redraws only the turn it touched.
  const latest = useRef({ onDecide, onAnswer, onRetry, onEdit, onContinue, onPrompt })
  latest.current = { onDecide, onAnswer, onRetry, onEdit, onContinue, onPrompt }
  const cb = useMemo<TurnCallbacks>(() => ({
    onDecide: (a, o) => latest.current.onDecide(a, o),
    onAnswer: (c, o) => latest.current.onAnswer(c, o),
    onRetry: () => latest.current.onRetry?.(),
    onEdit: (t) => latest.current.onEdit?.(t),
    onContinue: () => latest.current.onContinue?.(),
    onPrompt: (t) => latest.current.onPrompt?.(t),
  }), [])
  const has = { retry: !!onRetry, edit: !!onEdit, cont: !!onContinue }
  return (
    <>
      {(thread.marks ?? []).filter((m) => m.after === 0).map((m, i) => <Mark key={`m0-${i}`} m={m} />)}
      {thread.turns.map((turn, ti) => (<Fragment key={`${ti}-${turn.turn}`}>
        <TurnView turn={turn} live={ti === lastIdx} ask={ti === lastIdx ? thread.ask : null} question={ti === lastIdx ? thread.question : null}
          running={ti === lastIdx && thread.running} models={models} cb={cb} hasRetry={has.retry} hasEdit={has.edit} hasContinue={has.cont} />
        {(thread.marks ?? []).filter((m) => m.after === ti + 1).map((m, k) => <Mark key={`m${ti}-${k}`} m={m} />)}
      </Fragment>))}
      {thread.question && !thread.turns[thread.turns.length - 1]?.entries.some((e) => e.id === thread.question?.item) && (
        <QuestionCard q={thread.question} onAnswer={onAnswer} />
      )}
      {thread.elicitation && <ElicitationCard e={thread.elicitation} onReply={onElicit} />}
      {thread.running && thread.activity && !thread.ask && !thread.question && !thread.elicitation && (
        <div className={`thinking${thread.activity.warn ? ' warn' : ''}`} role="status"><span className="thinking-dot" aria-hidden="true" />{thread.activity.text}</div>
      )}
      {outbox.map((m) => (
        <div key={`out-${m.id}`} className="turn">
          <div className={`me${m.state === 'failed' ? ' failed' : ''}`}>
            {m.images.length ? <div className="me-imgs">{m.images.map((im, j) => <img key={j} src={`data:${im.mime};base64,${im.data}`} alt="" />)}</div> : null}
            {m.text}
          </div>
          {m.state !== 'failed' && (
            <div className="hover-row mine waiting">
              <span className="wait-why">{m.state === 'sent' ? `Sent · ${waiting ?? 'waiting for Frog to start'}` : waiting ? `Sending · ${waiting}` : 'Sending'} · <Elapsed since={m.at} /></span>
              <Ticks n={m.state === 'sent' ? 1 : 0} />
            </div>
          )}
          {m.state === 'failed' && <div className="me-fail">Frog didn't pick this up · <button type="button" onClick={() => onResend?.(m.id)}>Try again</button></div>}
        </div>
      ))}
    </>
  )
}

type Turn = Thread['turns'][number]
interface TurnCallbacks {
  onDecide: Decide
  onAnswer: (choices: string[], other?: string) => void
  onRetry: () => void
  onEdit: (text: string) => void
  onContinue: () => void
  onPrompt: (text: string) => void
}

/** One turn. Memoized: the reducer keeps untouched turns the same object, so while the last
 * turn streams the others don't redraw (or re-parse their markdown). Only the live turn gets
 * the session's ask, question and running state. */
const TurnView = memo(function TurnView({ turn, live, ask, question, running, models, cb, hasRetry, hasEdit, hasContinue }: {
  turn: Turn; live: boolean; ask: Ask | null; question: Question | null; running: boolean; models: Model[]
  cb: TurnCallbacks; hasRetry: boolean; hasEdit: boolean; hasContinue: boolean
}) {
  return (
    <div className="turn">
      <div className="ask-block">
        {/* A blank message (whitespace, no images) draws no empty bubble. */}
        {[{ text: turn.input, images: turn.images }, ...(turn.more ?? [])].map((m, i) => !m.text.trim() && !m.images?.length ? null : (
          <div key={i} className="me" dir="auto">
            {m.images?.length ? <div className="me-imgs">{m.images.map((im, j) => <img key={j} src={`data:${im.mime};base64,${im.data}`} alt="" />)}</div> : null}
            {m.text}
          </div>
        ))}
        <div className="hover-row mine">
          <Ticks n={2} />
          {turn.at ? <span className="when" title={new Date(turn.at).toLocaleString()}>{ago(turn.at)}</span> : null}
          <span className="sep" aria-hidden="true">·</span>
          <CopyButton text={[turn.input, ...(turn.more ?? []).map((m) => m.text)].join('\n\n')} />
          {hasEdit && <IconButton label="Edit (back to the composer)" onClick={() => cb.onEdit([turn.input, ...(turn.more ?? []).map((m) => m.text)].join('\n\n'))} icon="edit" />}
        </div>
      </div>
      <div className="reply-block">
      {turn.entries.map((e, n) => {
        if (e.kind === 'reasoning' && foldedThought(turn.entries, n)) return null
        // An empty thought has nothing to open, and a blank reply nothing to read: neither draws.
        if (e.kind === 'reasoning') return e.text.trim() ? <ThoughtLine key={e.id} text={e.text} /> : null
        if (e.kind === 'message' && e.done && !e.text.trim()) return null
        if (e.kind === 'message') return <div key={e.id} className="say"><Markdown text={e.text} />{!e.done && <span className="caret" />}</div>
        if (question?.item === e.id) return <QuestionCard key={e.id} q={question} onAnswer={cb.onAnswer} />
        const asking = ask?.item === e.id ? ask : null
        const diff = e.diff ?? asking?.preview
        // A finished edit is one activity line ("Edited src/a.ts +3 −2 ›", the One look), the
        // Mac's too; it opens to the diff card. Asking first, the card shows whole.
        if (diff && e.outcome !== 'denied' && !asking) return <EditLine key={e.id} diff={diff} />
        if (diff && e.outcome !== 'denied') return (
          <DiffCard key={e.id} diff={diff} ask={asking} onDecide={cb.onDecide}
            note="Runs in your cloud sandbox. Nothing is pushed until you say so." />
        )
        if (asking) return <AskCard key={e.id} ask={asking} onDecide={cb.onDecide} />
        if (e.widget && e.outcome === 'ok') return <WidgetCard key={e.id} widget={e.widget} onPrompt={cb.onPrompt} />
        return <ToolLine key={e.id} e={e} />
      })}
      {turn.usage && (turn.reason?.type === 'complete' || turn.reason?.type === 'denied') && (
        <TurnFooter usage={turn.usage} models={models} pinned={false}
          answer={[...turn.entries].reverse().find((e) => e.kind === 'message')?.text ?? ''}
          onRetry={live && !running && hasRetry ? cb.onRetry : undefined} />
      )}
      </div>
      {/* How the turn ended stays with the turn: stopping a later one doesn't clear it. */}
      {turn.reason?.type === 'cancelled' && <div className="tool">Stopped</div>}
      {/* Any other ending that isn't a finished answer says so, never silence. */}
      {turn.reason && !['complete', 'cancelled', 'error', 'denied'].includes(turn.reason.type) && (
        <div role="status" className="banner warn">
          <span style={{ flex: 1 }}>{ending(turn.reason.type, turn.usage)}</span>
          {live && !running && hasContinue && <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={cb.onContinue}>Continue</button>}
        </div>
      )}
      {endError(turn.reason) && !/insufficient_credit|out_of_credits|402/.test(JSON.stringify(turn.reason)) && (
        <div role="status" className="banner warn">
          <span style={{ flex: 1 }}>{endError(turn.reason)}</span>
          {live && !running && hasRetry && <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={cb.onRetry}>Try again</button>}
        </div>
      )}
    </div>
  )
})

/** WhatsApp-style receipts on your messages: a clock while sending, one tick on the wire, two
 * once Frog has started on it. */
function Ticks({ n }: { n: 0 | 1 | 2 }) {
  const label = n === 2 ? 'Received' : n === 1 ? 'Sent' : 'Sending'
  return (
    <span className={`ticks t${n}`} role="img" aria-label={label} title={label}>
      {n === 0 ? (
        <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></svg>
      ) : (
        <svg width={n === 2 ? 16 : 11} height="11" viewBox={n === 2 ? '0 0 34 24' : '0 0 24 24'} fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round">
          <path d="M3 13l5 5L20 6" />{n === 2 && <path d="M15 17l1 1L31 6" />}
        </svg>
      )}
    </span>
  )
}

const ICONS = {
  copy: <><rect x="8" y="8" width="12" height="12" rx="2.5" /><path d="M16 8V6.5A2.5 2.5 0 0 0 13.5 4h-7A2.5 2.5 0 0 0 4 6.5v7A2.5 2.5 0 0 0 6.5 16H8" /></>,
  check: <path d="M5 12.5l4.5 4.5L19 7.5" />,
  edit: <><path d="M4 20h4L19 9l-4-4L4 16z" /><path d="M13.5 6.5l4 4" /></>,
  retry: <><path d="M4 12a8 8 0 0 1 14-5.3L20 9" /><path d="M20 4v5h-5" /><path d="M20 12a8 8 0 0 1-14 5.3L4 15" /><path d="M4 20v-5h5" /></>,
}

export function IconButton({ label, onClick, icon, on }: { label: string; onClick: () => void; icon: keyof typeof ICONS; on?: boolean }) {
  return (
    <button type="button" className={`icon-plate${on ? ' on' : ''}`} aria-label={label} title={label} onClick={onClick}>
      <svg aria-hidden="true" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">{ICONS[icon]}</svg>
    </button>
  )
}

/** Copy, turning into a check for a moment. */
export function CopyButton({ text, label = 'Copy' }: { text: string; label?: string }) {
  const [done, setDone] = useState(false)
  return <IconButton label={done ? 'Copied' : label} icon={done ? 'check' : 'copy'} on={done}
    onClick={() => { navigator.clipboard?.writeText(text); setDone(true); setTimeout(() => setDone(false), 1200) }} />
}

/** "just now", "3 minutes ago", "2 hours ago", then a date, as Claude writes it. */
function ago(ms: number) {
  const s = Math.max(0, (Date.now() - ms) / 1000)
  if (s < 45) return 'just now'
  if (s < 3600) { const m = Math.max(1, Math.round(s / 60)); return `${m} minute${m === 1 ? '' : 's'} ago` }
  if (s < 86_400) { const h = Math.round(s / 3600); return `${h} hour${h === 1 ? '' : 's'} ago` }
  return new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

/** Where the context was shrunk: a quiet rule across the conversation, with what it saved. */
function Mark({ m }: { m: { text: string; failed?: boolean } }) {
  return <div className={`ctx-mark${m.failed ? ' failed' : ''}`} role="note"><span>{m.text}</span></div>
}

/** Seconds since `since`, ticking. */
function Elapsed({ since }: { since: number }) {
  const [now, setNow] = useState(Date.now())
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(t) }, [])
  const s = Math.max(0, Math.floor((now - since) / 1000))
  return <>{s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`}</>
}

/** Why a turn stopped without finishing, in a line. */
function ending(type: string, usage?: { output_tokens?: number; model_calls?: number }) {
  if (type === 'max_tokens') return `The reply hit the length limit before it finished${usage?.output_tokens ? ` (${usage.output_tokens.toLocaleString()} tokens written${usage.model_calls && usage.model_calls > 1 ? ` over ${usage.model_calls} tries` : ''})` : ''}.`
  if (type === 'looping') return 'Frog stopped because it was repeating itself.'
  if (type === 'blocked_on_approval') return 'Frog stopped: a step it needs was denied.'
  if (type === 'suspended') return 'Paused for an update; send anything to pick it up.'
  return `The turn stopped (${type.replace(/_/g, ' ')}).`
}
