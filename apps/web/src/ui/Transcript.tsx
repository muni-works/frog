import type { FileDiff } from '../engine/protocol'
import type { Ask, Entry, Thread } from '../engine/thread'

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

export function Transcript({ thread, onDecide }: { thread: Thread; onDecide: (allow: boolean) => void }) {
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
            const diff = e.diff ?? (thread.ask?.item === e.id ? thread.ask.preview : undefined)
            if (diff && e.outcome !== 'denied') return (
              <DiffCard key={e.id} diff={diff} ask={thread.ask?.item === e.id ? thread.ask : null} onDecide={onDecide}
                note="Runs in your cloud sandbox. Nothing is pushed until you say so." />
            )
            return <ToolLine key={e.id} e={e} />
          })}
        </div>
      ))}
    </>
  )
}
