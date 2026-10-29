import { useCallback, useState } from 'react'
import type { Op } from '../cloud/protocol'
import type { Thread } from '../engine/thread'
import { TerminalPane } from './TerminalPane'

export function Inspector({ thread, onCommit, onPr, hasPr, send }: { thread: Thread; branch?: string; hasPr: boolean; onCommit: () => void; onPr: () => void; send: (op: Op) => void }) {
  const [pane, setPane] = useState<'changes' | 'terminal' | 'log'>('changes')
  // The newest terminal pane that's still open, else the newest one.
  const terms = Object.values(thread.panes).filter((p) => p.kind === 'terminal')
  const term = [...terms].reverse().find((p) => !p.closed) ?? terms[terms.length - 1]
  const resize = useCallback((cols: number, rows: number) => { if (term && !term.closed) send({ op: 'pane_resize', id: term.id, cols, rows }) }, [term?.id, term?.closed, send]) // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <section className="insp f-glass" aria-label="Inspector">
      <div className="insp-top">
        <div className="seg" role="tablist" style={{ flex: 1 }}>
          {(['changes', 'terminal', 'log'] as const).map((p) => (
            <button key={p} type="button" role="tab" aria-selected={pane === p} onClick={() => setPane(p)}>
              {{ changes: 'Changes', terminal: 'Terminal', log: 'Frog’s log' }[p]}
            </button>
          ))}
        </div>
      </div>
      {pane === 'changes' && (
        <div className="insp-body">
          {thread.changes.length === 0 && <div className="insp-empty det wrap">Files Frog changes in this session show up here, ready to commit or open as a PR.</div>}
          <div className="insp-files">
            {thread.changes.map((c) => (
              <div key={c.path} style={{ display: 'flex' }}>
                <span style={{ flex: 1 }}>{c.path}</span>
                <span style={{ color: 'var(--frog)' }}>+{c.added}</span>&nbsp;<span style={{ color: 'var(--warn)' }}>−{c.removed}</span>
              </div>
            ))}
          </div>
          <span style={{ flex: 1 }} />
          {thread.changes.length > 0 && (
            <div className="insp-acts">
              <button type="button" className="f-btn f-btn--bordered" onClick={onCommit}>Commit</button>
              <button type="button" className="f-btn f-btn--prominent" onClick={onPr}>{hasPr ? 'Push' : 'Open PR'}</button>
            </div>
          )}
        </div>
      )}
      {pane === 'terminal' && (
        <div className="insp-body">
          {term && !term.closed ? (<>
            <div className="term-head">
              <span className="term-dot" aria-hidden="true" />
              <span className="term-title">{term.title || 'bash'}</span>
              <span className="term-cwd">{term.cwd?.replace(/^\/workspace\/?/, '~/') || '~/'}</span>
              <span style={{ flex: 1 }} />
              <button type="button" className="icon-plate" aria-label="Close the shell" title="Close the shell" onClick={() => send({ op: 'pane_close', id: term.id })}>
                <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M6 6l12 12M18 6L6 18" /></svg>
              </button>
            </div>
            <TerminalPane pane={term} onInput={(data) => send({ op: 'pane_input', id: term.id, data })} onResize={resize} />
          </>) : (
            <div className="term-empty">
              <svg aria-hidden="true" width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="4" width="18" height="16" rx="3" /><path d="M7 9l3 3-3 3M12 15h5" /></svg>
              <b>{term?.closed ? `The shell exited${term.exit != null ? ` (${term.exit})` : ''}` : 'A shell in the sandbox'}</b>
              <span className="det wrap">Same machine Frog works in, at the repo. Nothing here touches your computer.</span>
              <button type="button" className="f-btn f-btn--bordered" onClick={() => send({ op: 'pane_open', kind: 'terminal', cols: 80, rows: 24 })}>{term?.closed ? 'Open another' : 'Open a terminal'}</button>
            </div>
          )}
        </div>
      )}
      {pane === 'log' && (
        <div className="insp-body">
          {thread.terminal
            ? <pre className="term">{thread.terminal}</pre>
            : <div className="term-empty"><b>Nothing run yet</b><span className="det wrap">Commands Frog runs in this session, and what they print, collect here.</span></div>}
        </div>
      )}

    </section>
  )
}
