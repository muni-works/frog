import { useCallback, useState } from 'react'
import type { Op } from '../cloud/protocol'
import type { Thread } from '../engine/thread'
import { TerminalPane } from './TerminalPane'

export function Inspector({ thread, branch, onCommit, onPr, hasPr, send }: { thread: Thread; branch: string; hasPr: boolean; onCommit: () => void; onPr: () => void; send: (op: Op) => void }) {
  const [pane, setPane] = useState<'changes' | 'terminal' | 'preview'>('changes')
  const [log, setLog] = useState(false)
  // The newest terminal pane that's still open, else the newest one.
  const terms = Object.values(thread.panes).filter((p) => p.kind === 'terminal')
  const term = [...terms].reverse().find((p) => !p.closed) ?? terms[terms.length - 1]
  const resize = useCallback((cols: number, rows: number) => { if (term && !term.closed) send({ op: 'pane_resize', id: term.id, cols, rows }) }, [term?.id, term?.closed, send]) // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <section className="insp" aria-label="Inspector">
      <div className="insp-top">
        <div className="seg" role="tablist" style={{ flex: 1 }}>
          {(['changes', 'terminal', 'preview'] as const).map((p) => (
            <button key={p} type="button" role="tab" aria-selected={pane === p} onClick={() => setPane(p)}>
              {p[0].toUpperCase() + p.slice(1)}
            </button>
          ))}
        </div>
      </div>
      {pane === 'changes' && (
        <div className="insp-body">
          <div className="insp-h">Made by this session</div>
          {thread.changes.length === 0 && <div className="det" style={{ padding: '4px 14px' }}>No changes yet.</div>}
          <div className="insp-files">
            {thread.changes.map((c) => (
              <div key={c.path} style={{ display: 'flex' }}>
                <span style={{ flex: 1 }}>{c.path}</span>
                <span style={{ color: 'var(--frog)' }}>+{c.added}</span>&nbsp;<span style={{ color: 'var(--warn)' }}>−{c.removed}</span>
              </div>
            ))}
          </div>
          <span style={{ flex: 1 }} />
          <div className="insp-acts">
            <button type="button" className="f-btn f-btn--bordered" disabled={!thread.changes.length} onClick={onCommit}>Commit</button>
            <button type="button" className="f-btn f-btn--prominent" disabled={!thread.changes.length} onClick={onPr}>{hasPr ? 'Push' : 'Open PR'}</button>
          </div>
        </div>
      )}
      {pane === 'terminal' && (
        <div className="insp-body">
          <div className="term-bar">
            <div className="seg" role="tablist" style={{ width: 200 }}>
              <button type="button" role="tab" aria-selected={!log} onClick={() => setLog(false)}>Shell</button>
              <button type="button" role="tab" aria-selected={log} onClick={() => setLog(true)}>Frog's commands</button>
            </div>
            <span style={{ flex: 1 }} />
            {!log && term && !term.closed && <button type="button" className="f-btn f-btn--plain" onClick={() => send({ op: 'pane_close', id: term.id })}>Close</button>}
          </div>
          {log ? (
            <pre className="term">{thread.terminal || `sandbox (${branch}) $ `}<span className="cursor"> </span></pre>
          ) : term && !term.closed ? (
            <TerminalPane pane={term} onInput={(data) => send({ op: 'pane_input', id: term.id, data })} onResize={resize} />
          ) : (
            <div className="term" style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: 10 }}>
              {term?.closed && <span className="det">Shell exited{term.exit != null ? ` (${term.exit})` : ''}.</span>}
              <span style={{ color: '#9a9a96' }}>A shell in this session's sandbox, in the repo.</span>
              <button type="button" className="f-btn f-btn--bordered" onClick={() => send({ op: 'pane_open', kind: 'terminal', cols: 80, rows: 24 })}>Open a terminal</button>
            </div>
          )}
        </div>
      )}
      {pane === 'preview' && (
        <div className="insp-body" style={{ alignItems: 'center', justifyContent: 'center', padding: 24 }}>
          <div className="det wrap" style={{ textAlign: 'center' }}>When Frog starts a dev server in the sandbox, its page shows up here.</div>
        </div>
      )}
    </section>
  )
}
