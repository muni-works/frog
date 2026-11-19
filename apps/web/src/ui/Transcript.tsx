import { Fragment, memo, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import type { FileDiff, Image } from '../cloud/protocol'
import type { Ask, Entry, Question, Thread } from '../engine/thread'
import { type Model } from '../models'
import { ElicitationCard, QuestionCard } from './AskCards'
import type { StartInfo } from './Opening'
import { Markdown } from './Markdown'
import { Hunks } from './Diff'
import { ICON } from './icons'
import { endError } from '../store'
import { resumedLine } from '../wall'
import { TurnFooter } from './TurnFooter'
import { WidgetCard } from './Widget'
import { foldRuns, foldTime, lineOf, opensItself, rememberOpen, thinkMsOf, thoughtLabel, type Step } from './rows'
import { LiveContext, LiveTail, ThinkingLine, type LiveInfo } from './LiveRow'

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

// Each tool's mark: the icon hung in the gutter beside its line. Its words come from the shared
// verb table (rows.ts, docs/design/transcript/verbs.json), never from here.
const MARK: Record<string, string> = {
  bash: ICON.terminal, '!': ICON.terminal, read: ICON.doc,
  write: 'M6 3h8l4 4v14H6zM14 3v4h4M9 13h6M9 17h4',
  edit: 'M4 20h4L19 9l-4-4L4 16zM13.5 6.5l4 4', multiedit: 'M4 20h4L19 9l-4-4L4 16zM13.5 6.5l4 4',
  grep: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-4-4', glob: 'M3 7h6l2 2h10v10H3z',
  webfetch: ICON.globe, websearch: ICON.globe,
  todowrite: 'M9 6h11M9 12h11M9 18h11M4 6l1 1 2-2M4 12l1 1 2-2M4 18l1 1 2-2',
  visualize: 'M4 19V5M4 19h16M8 15l3-4 3 2 5-6', visualguide: ICON.doc,
  settitle: 'M4 7V5h16v2M12 5v14M9 19h6',
  task: 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 20c0-3 3-5 6-5s6 2 6 5M16 11a3 3 0 1 0 0-6M18 15c2 .6 3 2.4 3 5',
}
const OTHER_MARK = 'M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.6 2.6-2.4-.6-.6-2.4z'

function Glyph({ d }: { d: string }) {
  return <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d={d} /></svg>
}

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

export { splitCd } from './rows'

/** How many lines of a command's output its opened line shows before Show all. */
const TAIL = 12

/** One step as one line (spec, "Lines"): mark, verb, object, result at the right. One click (or
 * Return) opens it: a command's last lines, an edit's change, a search's results. A read has
 * nothing to open. A failed command opens itself, once. `diff` is an edit's change. */
export function ToolLine({ e, diff, onShowChange, startOpen }: { e: Entry; diff?: FileDiff; onShowChange?: (path: string) => void; /** Tests: draw it opened. */ startOpen?: boolean }) {
  const line = lineOf(e, diff ?? e.diff)
  const [open, setOpen] = useState<boolean>(() => opensItself(e, line) || !!startOpen)
  // A step that fails while drawn (it mounted running) opens when it turns failed, once.
  useEffect(() => { if (line.state === 'failed' && opensItself(e, line)) setOpen(true) }, [line.state]) // eslint-disable-line react-hooks/exhaustive-deps
  const [all, setAll] = useState(false)
  const name = (e.name ?? '').toLowerCase()
  const output = e.output.trim()
  // A short result is said on the line itself: no click, nothing to open.
  const said = line.state === 'ok' && INLINE_RESULTS.has(name) && !line.diff
    ? sessionCount(name, output) ?? saidLine(e.display, output)
    : ''
  const whole = said ? fits(e.display, sessionCount(name, output) ?? output) : false
  const d = diff ?? e.diff
  // What opening shows; nothing for a read, a whole inline result, or a step with nothing behind it.
  // A read has nothing to open, unless it failed: then its error is what's behind it.
  const opens = !whole && (line.kind !== 'read' || line.state === 'failed') && line.state !== 'run'
    && (!!d || !!output || !!e.tests || line.state === 'failed' || !!line.gist || !!line.title)
  // A running command shows its live output under the line, as before.
  const shown = (open && opens) || (line.state === 'run' && !!output)
  const result = said || line.result
  const lines = output ? clip(output).split('\n') : []
  const tail = all || lines.length <= TAIL ? lines : lines.slice(-TAIL)
  return (
    <div className="line-row" data-row="line" data-kind={line.kind} data-state={line.state} data-item={e.id}>
      <div className="line-plate">
        <button type="button" className="line" aria-expanded={opens ? shown : undefined} aria-disabled={opens ? undefined : true}
          title={line.title || undefined} onClick={() => { if (opens) { rememberOpen(e.id, !shown); setOpen(!shown) } }}>
          <span className="line-mark" aria-hidden="true">
            {line.state === 'run' ? <span className="tool-spin" /> : <Glyph d={MARK[name] ?? OTHER_MARK} />}
          </span>
          {line.gist
            ? <span className="line-gist">{line.gist}</span>
            : <>
              {line.verb && <span className="line-verb">{line.verb}</span>}
              {line.object && <span className={`line-obj${line.mono ? ' mono' : ''}`}>{line.object}</span>}
            </>}
          <span className="line-fill" />
          {result && <span className="line-result">{result}</span>}
          {line.diff && <span className="line-result"><span className="line-n add">+{line.diff.added}</span> <span className="line-n del">−{line.diff.removed}</span></span>}
        </button>
        {line.kind === 'command' && e.arg && line.state !== 'run' && <span className="line-acts"><CopyButton text={e.arg} label="Copy command" /></span>}
        {line.kind === 'edit' && d && onShowChange && line.state === 'ok' && (
          <span className="line-acts"><IconButton label="Show in Changes" icon="changes" onClick={() => onShowChange(d.path)} /></span>
        )}
      </div>
      {shown && (
        <div className="line-open">
          {(line.gist || line.title) && e.arg && <div className="line-arg">{e.arg}</div>}
          {e.tests?.failed_names?.length ? (
            <div className="line-failing" role="list" aria-label="Failing tests">
              {e.tests.failed_names.map((t) => <div key={t} role="listitem">{t}</div>)}
            </div>
          ) : null}
          {d && line.kind === 'edit'
            ? <div className="line-box"><Hunks diff={d} max={40} /></div>
            : INLINE_RESULTS.has(name) || line.kind === 'web'
              ? <div className="line-said">{output ? clip(output) : 'No output.'}</div>
              : output
                ? <pre className="line-out">{tail.join('\n')}</pre>
                : <div className="line-note">{e.done ? 'No output.' : 'Running…'}</div>}
          {line.kind === 'command' && line.state !== 'run' && (
            <div className="line-foot">
              <span>Ran in your Frog Cloud sandbox</span>
              {lines.length > TAIL && <button type="button" className="line-link" onClick={() => setAll(!all)}>{all ? 'Show less' : `Show all ${lines.length} lines`}</button>}
              {output && <CopyButton text={output} label="Copy output" />}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

/** Four or more finished steps in a row, folded into one line: a chevron, "12 steps", the time.
 * Opened, it lists its steps. */
function Fold({ steps, render }: { steps: Entry[]; render: (e: Entry) => ReactNode }) {
  const [open, setOpen] = useState(false)
  const time = foldTime(steps)
  return (
    <div className="line-row fold" data-row="line" data-kind="fold" data-state="ok" data-steps={steps.map((s) => s.id).join(' ')}>
      <div className="line-plate">
        <button type="button" className="line" aria-expanded={open} onClick={() => setOpen(!open)}>
          <span className="line-mark chev" aria-hidden="true">›</span>
          <span className="line-verb">{steps.length} steps</span>
          <span className="line-fill" />
          {time && <span className="line-result">{time}</span>}
        </button>
      </div>
      {open && <div className="fold-steps">{steps.map(render)}</div>}
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
        <span className="det ask-where">Runs in your Frog Cloud sandbox</span>
        <span style={{ flex: 1 }} />
        <button type="button" className="f-btn f-btn--bordered" title="Deny (⌘.)" onClick={() => onDecide(false)}>Deny</button>
        <button type="button" className="f-btn f-btn--prominent" title="Allow (⌘↩)" onClick={() => onDecide(true)}>Allow</button>
      </div>
    </div>
  )
}

const NO_MODELS: Model[] = []

export function Transcript({ thread, onDecide, onAnswer, onElicit, onRetry, models = NO_MODELS, outbox = [], onResend, onEdit, waiting, onContinue, onPrompt, onShowChange, credit, start }: {
  thread: Thread
  /** The account's credit left, for the turn-cost card. */
  credit?: string
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
  /** An edit line's "Show in Changes": open the inspector on Changes. */
  onShowChange?: (path: string) => void
  /** A new session still starting (ui/Opening.tsx): the live row says how far it's got. */
  start?: StartInfo
}) {
  // The live turn is the last one by position: turn numbers can repeat after a resume.
  const lastIdx = thread.turns.length - 1
  // Handlers change identity every render; turns read them through one stable ref so a
  // streamed delta redraws only the turn it touched.
  const latest = useRef({ onDecide, onAnswer, onRetry, onEdit, onContinue, onPrompt, onShowChange })
  latest.current = { onDecide, onAnswer, onRetry, onEdit, onContinue, onPrompt, onShowChange }
  const cb = useMemo<TurnCallbacks>(() => ({
    onDecide: (a, o) => latest.current.onDecide(a, o),
    onAnswer: (c, o) => latest.current.onAnswer(c, o),
    onRetry: () => latest.current.onRetry?.(),
    onEdit: (t) => latest.current.onEdit?.(t),
    onContinue: () => latest.current.onContinue?.(),
    onPrompt: (t) => latest.current.onPrompt?.(t),
    onShowChange: onShowChange ? (p) => latest.current.onShowChange?.(p) : undefined,
  }), [])
  const has = { retry: !!onRetry, edit: !!onEdit, cont: !!onContinue }
  // The live row's fast-changing inputs, through context so the memoized turns don't redraw.
  const live = useMemo<LiveInfo>(() => ({
    startedAt: thread.startedAt, live: thread.live ?? null, pulse: thread.pulse ?? 0, firstOutputAt: thread.firstOutputAt ?? null,
    askedAt: thread.askedAt ?? null, activity: thread.activity?.text ?? null, waitingElsewhere: !!thread.elicitation,
  }), [thread.startedAt, thread.live, thread.pulse, thread.firstOutputAt, thread.askedAt, thread.activity, thread.elicitation])
  return (
    <LiveContext.Provider value={live}>
      {(thread.marks ?? []).filter((m) => m.after === 0).map((m, i) => <Mark key={`m0-${i}`} m={m} />)}
      {/* The first turn keeps its node from Send on: drawn first from the sent message
          (ui/Opening.tsx), then from the engine's turn, whatever number the engine gives it. */}
      {thread.turns.map((turn, ti) => (<Fragment key={ti === 0 ? 'first' : `${ti}-${turn.turn}`}>
        <TurnView turn={turn} index={ti} live={ti === lastIdx} start={ti === lastIdx ? start : undefined} ask={ti === lastIdx ? thread.ask : null} question={ti === lastIdx ? thread.question : null}
          running={ti === lastIdx && thread.running} models={models} credit={credit} cb={cb} hasRetry={has.retry} hasEdit={has.edit} hasContinue={has.cont} />
        {(thread.marks ?? []).filter((m) => m.after === ti + 1).map((m, k) => <Mark key={`m${ti}-${k}`} m={m} />)}
      </Fragment>))}
      {thread.question && !thread.turns[thread.turns.length - 1]?.entries.some((e) => e.id === thread.question?.item) && (
        <QuestionCard q={thread.question} onAnswer={onAnswer} />
      )}
      {thread.elicitation && <ElicitationCard e={thread.elicitation} onReply={onElicit} />}
      {outbox.map((m) => (
        <div key={`out-${m.id}`} className="turn">
          <div className={`me${m.state === 'failed' ? ' failed' : ''}`}>
            {m.images.length ? <div className="me-imgs">{m.images.map((im, j) => <img key={j} src={`data:${im.mime};base64,${im.data}`} alt="" />)}</div> : null}
            {m.text}
          </div>
          {m.state !== 'failed' && (
            <div className="hover-row mine waiting">
              <span className="wait-why">{m.state === 'sent' ? `Sent, ${waiting ?? 'waiting for Frog to start'}` : waiting ? `Sending, ${waiting}` : 'Sending'}, <Elapsed since={m.at} /></span>
              <Ticks n={m.state === 'sent' ? 1 : 0} />
            </div>
          )}
          {m.state === 'failed' && <div className="me-fail">Frog didn't pick this up. <button type="button" onClick={() => onResend?.(m.id)}>Try again</button></div>}
        </div>
      ))}
    </LiveContext.Provider>
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
  onShowChange?: (path: string) => void
}

/** A turn's entries as foldable rows: a finished step that draws as a line is a step (a failed one
 * never folds); everything else (prose, thoughts, cards, a running step) breaks a run. */
function rows(entries: Entry[], ask: Ask | null, question: Question | null) {
  return entries.map((e, n): Step & { e: Entry; n: number } => {
    const line = e.kind === 'tool' && e.done && question?.item !== e.id && ask?.item !== e.id && !(e.widget && e.outcome === 'ok')
    return { kind: line ? 'step' : 'other', id: e.id, failed: line && e.outcome === 'error', e, n }
  })
}

/** One turn. Memoized: the reducer keeps untouched turns the same object, so while the last
 * turn streams the others don't redraw (or re-parse their markdown). Only the live turn gets
 * the session's ask, question and running state. */
const TurnView = memo(function TurnView({ turn, index, live, ask, question, running, models, credit, cb, hasRetry, hasEdit, hasContinue, start }: {
  turn: Turn; index: number; live: boolean; ask: Ask | null; question: Question | null; running: boolean; models: Model[]; start?: StartInfo
  credit?: string; cb: TurnCallbacks; hasRetry: boolean; hasEdit: boolean; hasContinue: boolean
}) {
  // One entry as its row. `data-row` says what it is (prose, line, box), and the gaps between
  // rows come from that alone (transcript.css): lines touch, prose to lines is `activity`, a box
  // is a `block` from anything.
  // The engine's quiet-call question (#426) is anchored on the reasoning or message streaming: the
  // card goes after that entry's own row (none while it's the live row), a block like any card.
  const draw = (e: Entry, entries: Entry[], n: number): ReactNode => {
    if (question?.item === e.id && e.kind !== 'tool') return (
      <>{drawOne(e, entries, n)}<div data-row="box"><QuestionCard q={question} onAnswer={cb.onAnswer} /></div></>
    )
    return drawOne(e, entries, n)
  }
  const drawOne = (e: Entry, entries: Entry[], n: number): ReactNode => {
    if (e.kind === 'reasoning') {
      // While it thinks, the live row is the think (LiveRow); it settles here as one line.
      if (!e.done && live && running) return null
      // An older log has no length: a short scratch thought alone between replies folds away.
      if (e.thinkMs == null && !e.thoughts && foldedThought(entries, n)) return null
      // An empty thought has nothing to open, and a blank reply nothing to read: neither draws.
      return e.text.trim() ? <ThinkingLine e={e} label={thoughtLabel(e, turn.reason?.type === 'cancelled' ? turn.endAt : undefined, thinkMsOf(turn, e.id))} /> : null
    }
    if (e.kind === 'message' && e.done && !e.text.trim()) return null
    if (e.kind === 'message') return <div className="say" data-row="prose" data-item={e.id}><Markdown text={e.text} />{!e.done && <span className="caret" />}</div>
    if (question?.item === e.id) return <div data-row="box"><QuestionCard q={question} onAnswer={cb.onAnswer} /></div>
    const asking = ask?.item === e.id ? ask : null
    const diff = e.diff ?? asking?.preview
    // Asking first, an edit's card shows whole; finished, it is a line that opens to its change.
    if (diff && asking) return (
      <div data-row="box"><DiffCard diff={diff} ask={asking} onDecide={cb.onDecide}
        note="Runs in your Frog Cloud sandbox. Nothing is pushed until you say so." /></div>
    )
    if (asking) return <div data-row="box"><AskCard ask={asking} onDecide={cb.onDecide} /></div>
    if (e.widget && e.outcome === 'ok') return <div data-row="box"><WidgetCard widget={e.widget} onPrompt={cb.onPrompt} /></div>
    // A step still running is the live row ("Editing src/retry.rs"); it becomes a line when done.
    if (!e.done && live && running) return null
    return <ToolLine e={e} diff={diff} onShowChange={cb.onShowChange} />
  }
  return (
    // data-turn-index: where the turn rail finds and jumps to a turn (docs/design/chrome/spec.md).
    <div className="turn" data-turn-index={index}>
      {/* A turn the credit wall resumed (Op::Continue with wall.ts's note) is one quiet line, not a message. */}
      {resumedLine(turn.input) ? <div className="turn-note" data-row="resumed" role="status">{resumedLine(turn.input)}</div> : (
      <div className="ask-block">
        {/* A blank message (whitespace, no images) draws no empty bubble. */}
        {/* The receipts and actions sit beside the last bubble, not under it, so the prompt is a
            block gap from the first row (spec, "Gaps"). */}
        {[{ text: turn.input, images: turn.images }, ...(turn.more ?? [])].filter((m) => m.text.trim() || m.images?.length).map((m, i, all) => (
          <div key={i} className="me" dir="auto">
            {m.images?.length ? <div className="me-imgs">{m.images.map((im, j) => <img key={j} src={`data:${im.mime};base64,${im.data}`} alt="" />)}</div> : null}
            {m.text}
            {i === all.length - 1 && (
              <div className="hover-row mine" dir="ltr">
                <Ticks n={2} />
                {turn.at ? <span className="when" title={new Date(turn.at).toLocaleString()}>{ago(turn.at)}</span> : null}
                <CopyButton text={[turn.input, ...(turn.more ?? []).map((m) => m.text)].join('\n\n')} />
                {hasEdit && <IconButton label="Edit (back to the composer)" onClick={() => cb.onEdit([turn.input, ...(turn.more ?? []).map((m) => m.text)].join('\n\n'))} icon="edit" />}
              </div>
            )}
          </div>
        ))}
      </div>)}
      <div className="reply-block">
      {foldRuns(rows(turn.entries, ask, question)).map((r) => r.kind === 'fold'
        ? <Fold key={r.id} steps={r.steps.map((x) => x.e)} render={(e) => <ToolLine key={e.id} e={e} onShowChange={cb.onShowChange} />} />
        : <Fragment key={r.id}>{draw(r.e, turn.entries, r.n)}</Fragment>)}
      {turn.usage && (turn.reason?.type === 'complete' || turn.reason?.type === 'denied') && (
        <TurnFooter usage={turn.usage} turn={turn} models={models} pinned={false} credit={credit}
          answer={[...turn.entries].reverse().find((e) => e.kind === 'message')?.text ?? ''}
          onRetry={live && !running && hasRetry ? cb.onRetry : undefined} />
      )}
      {/* One row from Send on: a new session's start, then the turn's live row (the same node). */}
      {live && (running || start) && <LiveTail entries={turn.entries} tl={turn.tl} waiting={!!ask || !!question} waitItem={ask?.item ?? question?.item} models={models} start={running ? undefined : start} />}
      </div>
      {/* How the turn ended stays with the turn: stopping a later one doesn't clear it. */}
      {/* A think stopped mid-way already says so on its own line ("Stopped after 12s"). */}
      {turn.reason?.type === 'cancelled' && !(turn.entries.at(-1)?.kind === 'reasoning' && !turn.entries.at(-1)?.done) && <div className="turn-note">Stopped</div>}
      {/* A denied step ends the turn: say so in words (the engine's own sentence when it sends one). */}
      {endNote(turn.reason) && <div className="det wrap turn-note">{endNote(turn.reason)}</div>}
      {/* Any other ending that isn't a finished answer says so, never silence. */}
      {/* Out of credit has its own card and composer strip; Continue would only be refused again. */}
      {turn.reason && !['complete', 'cancelled', 'error', 'denied', 'billing_limit'].includes(turn.reason.type) && (
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
  changes: <><path d="M12 4v8M8 8h8" /><path d="M8 18h8" /></>,
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

/** A plain line under a turn that ended on a denial, or with a sentence from the engine
 *  (`message` on the end reason, for any ending other than an error, which has its banner). */
export function endNote(reason: unknown): string | null {
  const r = reason as { type?: string; message?: unknown } | null | undefined
  if (!r || r.type === 'error') return null
  if (typeof r.message === 'string' && r.message.trim()) return r.message.trim()
  return r.type === 'denied' ? 'Frog stopped here because you denied a step. Say how to go on, or send a new task.' : null
}

/** Why a turn stopped without finishing, in a line. */
function ending(type: string, usage?: { output_tokens?: number; model_calls?: number }) {
  if (type === 'max_tokens') return `The reply hit the length limit before it finished${usage?.output_tokens ? ` (${usage.output_tokens.toLocaleString()} tokens written${usage.model_calls && usage.model_calls > 1 ? ` over ${usage.model_calls} tries` : ''})` : ''}.`
  if (type === 'looping') return 'Frog stopped because it was repeating itself.'
  if (type === 'blocked_on_approval') return 'Frog stopped: a step it needs was denied.'
  if (type === 'suspended') return 'Paused for an update; send anything to pick it up.'
  return `The turn stopped (${type.replace(/_/g, ' ')}).`
}
