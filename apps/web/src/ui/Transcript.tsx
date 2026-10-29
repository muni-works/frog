import { Fragment, useEffect, useState } from 'react'
import type { FileDiff, Image } from '../cloud/protocol'
import type { Ask, Entry, Thread } from '../engine/thread'
import type { Model } from '../models'
import { ElicitationCard, QuestionCard } from './AskCards'
import { Markdown } from './Markdown'
import { Hunks } from './Diff'
import { endError } from '../store'
import { TurnFooter } from './TurnFooter'

// Draws a folded Thread: the user's message, tool lines, "Decided" steps (reasoning items),
// streamed replies, and a diff card per edit with Allow ⌘↩ / Deny ⌘. while it waits.

export function DiffCard({ diff, ask, onDecide, note }: { diff: FileDiff; ask?: Ask | null; onDecide?: (allow: boolean) => void; note?: string }) {
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
  settitle: { verb: ['Naming', 'Named'], icon: 'M4 7V5h16v2M12 5v14M9 19h6' },
}
const OTHER = { verb: ['Using', 'Used'] as [string, string], icon: 'M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18l3 3 6.3-6.3a4 4 0 0 0 5.4-5.4l-2.6 2.6-2.4-.6-.6-2.4z' }

function ToolLine({ e }: { e: Entry }) {
  const [open, setOpen] = useState<boolean | null>(null)
  const name = (e.name ?? '').toLowerCase()
  const look = TOOL_LOOK[name] ?? OTHER
  const output = e.output.trim()
  const shown = open ?? (e.outcome === 'error' || (!e.done && !!output))
  const state = !e.done ? 'run' : e.outcome === 'error' ? 'err' : e.outcome === 'denied' ? 'denied' : 'ok'
  // The engine's one-line gist (display) when it has one, else the argument.
  const what = (e.done && e.display) || e.arg || (TOOL_LOOK[name] ? '' : e.name)
  return (
    <div className={`tool-row ${state}`}>
      <button type="button" className="tool" aria-expanded={shown} onClick={() => setOpen(!shown)}>
        <span className="tool-ic" aria-hidden="true">
          {state === 'run'
            ? <span className="tool-spin" />
            : <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d={look.icon} /></svg>}
        </span>
        <span className="tool-verb">{look.verb[e.done ? 1 : 0]}</span>
        {what && <span className="tool-what">{what}</span>}
        {state === 'err' && <span className="tool-tag err">failed</span>}
        {state === 'denied' && <span className="tool-tag">denied</span>}
        <span className="tool-chev" aria-hidden="true">›</span>
      </button>
      {shown && (
        <div className="tool-body">
          {e.arg && e.display && <div className="tool-arg">{e.arg}</div>}
          {output ? <pre className="tool-out">{clip(output)}</pre> : <div className="det">{e.done ? 'No output.' : 'Running…'}</div>}
        </div>
      )}
    </div>
  )
}

export function Transcript({ thread, onDecide, onAnswer, onElicit, onRetry, models = [], outbox = [], onResend, onEdit, waiting, onContinue }: {
  thread: Thread
  onDecide: (allow: boolean) => void
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
}) {
  const lastTurn = thread.turns[thread.turns.length - 1]?.turn
  return (
    <>
      {(thread.marks ?? []).filter((m) => m.after === 0).map((m, i) => <Mark key={`m0-${i}`} m={m} />)}
      {thread.turns.map((turn, ti) => (<Fragment key={turn.turn}>
        <div className="turn">
          <div className="ask-block">
            {[{ text: turn.input, images: turn.images }, ...(turn.more ?? [])].map((m, i) => (
              <div key={i} className="me">
                {m.images?.length ? <div className="me-imgs">{m.images.map((im, j) => <img key={j} src={`data:${im.mime};base64,${im.data}`} alt="" />)}</div> : null}
                {m.text}
              </div>
            ))}
            <div className="hover-row mine">
              <Ticks n={2} />
              {turn.at ? <span className="when" title={new Date(turn.at).toLocaleString()}>{ago(turn.at)}</span> : null}
              <span className="sep" aria-hidden="true">·</span>
              <CopyButton text={[turn.input, ...(turn.more ?? []).map((m) => m.text)].join('\n\n')} />
              {onEdit && <IconButton label="Edit (back to the composer)" onClick={() => onEdit([turn.input, ...(turn.more ?? []).map((m) => m.text)].join('\n\n'))} icon="edit" />}
            </div>
          </div>
          <div className="reply-block">
          {turn.entries.map((e) => {
            if (e.kind === 'reasoning') return (
              <div key={e.id} className="decided"><b>Decided</b> · {e.text}</div>
            )
            if (e.kind === 'message') return <div key={e.id} className="say"><Markdown text={e.text} />{!e.done && <span className="caret" />}</div>
            if (turn.turn === lastTurn && thread.question?.item === e.id) return <QuestionCard key={e.id} q={thread.question} onAnswer={onAnswer} />
            const asking = turn.turn === lastTurn && thread.ask?.item === e.id ? thread.ask : null
            const diff = e.diff ?? asking?.preview
            if (diff && e.outcome !== 'denied') return (
              <DiffCard key={e.id} diff={diff} ask={asking} onDecide={onDecide}
                note="Runs in your cloud sandbox. Nothing is pushed until you say so." />
            )
            const ask = asking
            if (ask) return (
              <div key={e.id} className="cardx">
                <div style={{ padding: '10px 14px 6px' }}><b>Can I {ask.name.toLowerCase()} this?</b>{ask.reason && <div className="det wrap">{ask.reason}</div>}</div>
                <div className="diff">{ask.arg}</div>
                <div className="diff-acts">
                  <span style={{ flex: 1 }} className="det">Runs in your cloud sandbox.</span>
                  <button type="button" className="f-btn f-btn--bordered" onClick={() => onDecide(false)}>Deny ⌘.</button>
                  <button type="button" className="f-btn f-btn--prominent" onClick={() => onDecide(true)}>Allow ⌘↩</button>
                </div>
              </div>
            )
            return <ToolLine key={e.id} e={e} />
          })}
          {turn.usage && (turn.reason?.type === 'complete' || turn.reason?.type === 'denied') && (
            <TurnFooter usage={turn.usage} models={models} pinned={false}
              answer={[...turn.entries].reverse().find((e) => e.kind === 'message')?.text ?? ''}
              onRetry={turn.turn === lastTurn && !thread.running ? onRetry : undefined} />
          )}
          </div>
          {/* How the turn ended stays with the turn: stopping a later one doesn't clear it. */}
          {turn.reason?.type === 'cancelled' && <div className="tool">Stopped</div>}
          {/* Any other ending that isn't a finished answer says so, never silence. */}
          {turn.reason && !['complete', 'cancelled', 'error', 'denied'].includes(turn.reason.type) && (
            <div role="status" className="banner warn">
              <span style={{ flex: 1 }}>{ending(turn.reason.type, turn.usage)}</span>
              {turn.turn === lastTurn && !thread.running && onContinue && <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={onContinue}>Continue</button>}
            </div>
          )}
          {endError(turn.reason) && !/insufficient_credit|out_of_credits|402/.test(JSON.stringify(turn.reason)) && (
            <div role="status" className="banner warn">
              <span style={{ flex: 1 }}>{endError(turn.reason)}</span>
              {turn.turn === lastTurn && !thread.running && onRetry && <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={onRetry}>Try again</button>}
            </div>
          )}
        </div>
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
