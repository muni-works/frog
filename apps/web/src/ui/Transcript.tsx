import { useState } from 'react'
import type { FileDiff } from '../cloud/protocol'
import type { Ask, Entry, Thread } from '../engine/thread'
import type { Model } from '../models'
import { ElicitationCard, QuestionCard } from './AskCards'
import { Markdown } from './Markdown'
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
      <div className="diff">
        {diff.hunks.flatMap((h) => h.lines).map((l, i) => (
          <div key={i} className={l.kind}>{l.kind === 'add' ? '+ ' : l.kind === 'remove' ? '- ' : '  '}{l.text}</div>
        ))}
      </div>
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
function ToolLine({ e }: { e: Entry }) {
  const [open, setOpen] = useState<boolean | null>(null)
  const mark = !e.done ? '…' : e.outcome === 'denied' ? '✕' : e.outcome === 'error' ? '!' : '✓'
  const label = e.done ? e.display ?? `${e.name?.toLowerCase()} ${e.arg}` : `${e.name} ${e.arg}`
  const output = e.output.trim()
  const shown = open ?? (e.outcome === 'error' || (!e.done && !!output))
  return (
    <div className={`tool-row ${e.outcome === 'error' ? 'err' : ''}`}>
      <button type="button" className="tool" aria-expanded={shown} onClick={() => setOpen(!shown)}>
        <span className="tool-chev">{shown ? '▾' : '▸'}</span>{mark} {label}{e.outcome === 'denied' && ' · denied'}
      </button>
      {shown && (
        <div className="tool-body">
          {e.arg && <div className="tool-arg"><span className="det">{e.name}</span> {e.arg}</div>}
          {output ? <pre className="tool-out">{clip(output)}</pre> : <div className="det">{e.done ? 'No output.' : 'Running…'}</div>}
        </div>
      )}
    </div>
  )
}

export function Transcript({ thread, onDecide, onAnswer, onElicit, models = [] }: {
  thread: Thread
  onDecide: (allow: boolean) => void
  onAnswer: (choices: string[], other?: string) => void
  onElicit: (action: 'accept' | 'decline' | 'cancel', content?: Record<string, string | number | boolean>) => void
  models?: Model[]
}) {
  const lastTurn = thread.turns[thread.turns.length - 1]?.turn
  const lastDone = [...thread.turns].reverse().find((u) => u.usage && (u.reason?.type === 'complete' || u.reason?.type === 'denied'))?.turn
  return (
    <>
      {thread.turns.map((turn) => (
        <div key={turn.turn} className="turn">
          <div className="me">{turn.input}</div>
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
            <TurnFooter usage={turn.usage} models={models} pinned={turn.turn === lastDone}
              answer={[...turn.entries].reverse().find((e) => e.kind === 'message')?.text ?? ''} />
          )}
        </div>
      ))}
      {thread.question && !thread.turns[thread.turns.length - 1]?.entries.some((e) => e.id === thread.question?.item) && (
        <QuestionCard q={thread.question} onAnswer={onAnswer} />
      )}
      {thread.elicitation && <ElicitationCard e={thread.elicitation} onReply={onElicit} />}
      {thread.running && thread.activity && !thread.ask && !thread.question && !thread.elicitation && (
        <div className="tool" style={{ color: thread.activity.warn ? 'var(--notice)' : undefined }}>… {thread.activity.text}</div>
      )}
    </>
  )
}
