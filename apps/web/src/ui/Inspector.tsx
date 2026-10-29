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
        <pre className="term">{thread.terminal.replace(/~\/ledger \$/g, `~/ledger (${branch}) $`) || `sandbox ~/ledger (${branch}) $ `}<span className="cursor"> </span></pre>
      )}
      {pane === 'preview' && (
        <div className="insp-body">
          <div style={{ display: 'flex', gap: 6, padding: 8, borderBottom: '1px solid var(--line)', alignItems: 'center' }}>
            <span className="det">‹ ↻</span>
            <input className="f-field" defaultValue="sandbox · :5173/login" aria-label="URL or port" style={{ flex: 1 }} />
          </div>
          <div style={{ flex: 1, background: 'var(--well)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <div className="cardx" style={{ width: 210, padding: 16, display: 'flex', flexDirection: 'column', gap: 8 }}>
              <b>ledger</b>
              <input className="f-field" placeholder="Email" aria-label="Email" />
              <input className="f-field" placeholder="Password" type="password" aria-label="Password" />
              <button type="button" className="f-btn f-btn--prominent" style={{ justifyContent: 'center' }}>Log in</button>
            </div>
          </div>
          <div className="det" style={{ padding: '8px 12px', borderTop: '1px solid var(--line)' }}>Inspect: click an element to mention it</div>
        </div>
      )}
    </section>
  )
}
