import { useState } from 'react'
import type { Thread } from '../engine/thread'

export function Inspector({ thread, branch, onCommit, onPr, hasPr }: { thread: Thread; branch: string; hasPr: boolean; onCommit: () => void; onPr: () => void }) {
  const [pane, setPane] = useState<'changes' | 'terminal' | 'preview'>('changes')
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
        <pre className="term">{thread.terminal || `sandbox (${branch}) $ `}<span className="cursor"> </span></pre>
      )}
      {pane === 'preview' && (
        <div className="insp-body" style={{ alignItems: 'center', justifyContent: 'center', padding: 24 }}>
          <div className="det wrap" style={{ textAlign: 'center' }}>When Frog starts a dev server in the sandbox, its page shows up here.</div>
        </div>
      )}
    </section>
  )
}
