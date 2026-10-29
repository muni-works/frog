import type { FileDiff } from '../cloud/protocol'
import type { Ask, Entry, Thread } from '../engine/thread'
import type { Model } from '../models'
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

function ToolLine({ e }: { e: Entry }) {
  const mark = !e.done ? '…' : e.outcome === 'denied' ? '✕' : e.outcome === 'error' ? '!' : '✓'
  const label = e.display ?? `${e.name?.toLowerCase()} ${e.arg}`
  return <div className="tool">{mark} {e.done ? label : `${e.name} ${e.arg}`}{e.outcome === 'denied' && ' · denied'}</div>
}

export function Transcript({ thread, onDecide, models = [] }: { thread: Thread; onDecide: (allow: boolean) => void; models?: Model[] }) {
  const lastTurn = thread.turns[thread.turns.length - 1]?.turn
  const lastDone = [...thread.turns].reverse().find((u) => u.usage)?.turn
  return (
    <>
      {thread.turns.map((turn) => (
        <div key={turn.turn} className="turn">
          <div className="me">{turn.input}</div>
          {turn.entries.map((e) => {
            if (e.kind === 'reasoning') return (
              <div key={e.id} className="decided"><b>Decided</b> · {e.text}</div>
            )
            if (e.kind === 'message') return <div key={e.id} className="say">{e.text}{!e.done && <span className="caret" />}</div>
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
      {thread.running && thread.activity && !thread.ask && (
        <div className="tool" style={{ color: thread.activity.warn ? 'var(--notice)' : undefined }}>… {thread.activity.text}</div>
      )}
    </>
  )
}
