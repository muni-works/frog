import { useCallback, useEffect, useState } from 'react'
import type { Op } from '../cloud/protocol'
import type { Thread } from '../engine/thread'
import type { Machine } from '../machines'
import { DownloadAppChip } from './DownloadChip'
import { FileRow } from './Diff'
import { TerminalPane } from './TerminalPane'

type Tab = 'changes' | 'terminal' | 'preview'

interface InspectorProps {
  onClose: () => void
  thread: Thread
  branch?: string
  hasPr: boolean
  onCommit: () => void
  onPr: () => void
  send: (op: Op) => void
  machines?: readonly Machine[]
  /** Open on this tab (tests); default: the one remembered for this browser. */
  pane?: Tab
}

export function Inspector({ thread, onCommit, onPr, hasPr, send, onClose, machines = [], pane: initialPane }: InspectorProps) {
  // Width, dragged from the left edge and kept per browser.
  const [width, setWidth] = useState(() => { try { return Number(localStorage.getItem('frog.inspectorWidth')) || 330 } catch { return 330 } })
  const [dragging, setDragging] = useState(false)
  const grab = (e: React.PointerEvent) => {
    e.preventDefault()
    const x0 = e.clientX, w0 = width
    setDragging(true); document.body.classList.add('resizing')
    const move = (ev: PointerEvent) => setWidth(Math.round(Math.min(Math.max(260, w0 + x0 - ev.clientX), Math.min(720, innerWidth * 0.6))))
    const up = () => {
      setDragging(false); document.body.classList.remove('resizing')
      removeEventListener('pointermove', move); removeEventListener('pointerup', up)
      setWidth((w) => { try { localStorage.setItem('frog.inspectorWidth', String(w)) } catch { /* private mode */ } return w })
    }
    addEventListener('pointermove', move); addEventListener('pointerup', up)
  }
  const [pane, setPane] = useState<Tab>(() => {
    if (initialPane) return initialPane
    try { const t = localStorage.getItem('frog.inspectorTab'); return t === 'terminal' || t === 'preview' ? t : 'changes' } catch { return 'changes' }
  })
  // Which changed files are open to their hunks; the only one opens by itself.
  const [open, setOpen] = useState<Set<string>>(new Set())
  useEffect(() => { if (thread.changes.length === 1) setOpen(new Set([thread.changes[0].path])) }, [thread.changes.length === 1 ? thread.changes[0].path : '']) // eslint-disable-line react-hooks/exhaustive-deps
  // The newest terminal pane that's still open, else the newest one.
  const terms = Object.values(thread.panes).filter((p) => p.kind === 'terminal')
  const term = [...terms].reverse().find((p) => !p.closed) ?? terms[terms.length - 1]
  const resize = useCallback((cols: number, rows: number) => { if (term && !term.closed) send({ op: 'pane_resize', id: term.id, cols, rows }) }, [term?.id, term?.closed, send]) // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <section className="insp f-glass" aria-label="Inspector" style={{ width }}>
      <div className={`insp-grip${dragging ? ' on' : ''}`} role="separator" aria-orientation="vertical" aria-label="Resize the inspector" onPointerDown={grab}
        onDoubleClick={() => { setWidth(330); try { localStorage.removeItem('frog.inspectorWidth') } catch { /* private mode */ } }} />
      <div className="insp-top">
        <div className="seg" role="tablist" style={{ flex: 1 }}>
          {(['changes', 'terminal', 'preview'] as const).map((p) => (
            <button key={p} type="button" role="tab" aria-selected={pane === p} onClick={() => { setPane(p); try { localStorage.setItem('frog.inspectorTab', p) } catch { /* private mode */ } }}>
              {{ changes: 'Changes', terminal: 'Terminal', preview: 'Preview' }[p]}
            </button>
          ))}
        </div>
        <button type="button" className="ic-btn insp-x" aria-label="Close the inspector" title="Close" onClick={onClose}>
          <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M6 6l12 12M18 6L6 18" /></svg>
        </button>
      </div>
      {pane === 'changes' && (
        <div className="insp-body">
          {thread.changes.length === 0 && <div className="insp-empty det wrap">Files Frog changes in this session show up here, ready to commit or open as a PR.</div>}
          {thread.changes.length > 0 && (
            <div className="files-head">
              <b>{thread.changes.length} file{thread.changes.length === 1 ? '' : 's'}</b>
              <span className="file-add">+{thread.changes.reduce((n, c) => n + c.added, 0)}</span>
              <span className="file-del">−{thread.changes.reduce((n, c) => n + c.removed, 0)}</span>
              <span style={{ flex: 1 }} />
              <button type="button" className="f-btn f-btn--plain" onClick={() => setOpen(open.size ? new Set() : new Set(thread.changes.map((c) => c.path)))}>{open.size ? 'Collapse all' : 'Expand all'}</button>
            </div>
          )}
          <div className="files">
            {thread.changes.map((c) => (
              <FileRow key={c.path} diff={c} open={open.has(c.path)} onToggle={() => setOpen((o) => { const n = new Set(o); if (n.has(c.path)) n.delete(c.path); else n.add(c.path); return n })} />
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
      {/* Sandbox ports aren't reachable from the browser yet, so Preview says so rather than
       * pretending. The Mac app's Preview pane is the place for it today. */}
      {pane === 'preview' && (
        <div className="insp-body">
          <div className="term-empty">
            <svg aria-hidden="true" width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="4" width="18" height="16" rx="3" /><path d="M3 9h18M7 6.5h.01M10 6.5h.01" /></svg>
            <b>Preview isn't on the web yet</b>
            <span className="det wrap">Frog Cloud can't show a sandbox's dev server in the browser yet. Run it in Terminal for now, or open the session in the Mac app.</span>
            <DownloadAppChip label="The Mac app has Preview" machines={machines} />
          </div>
        </div>
      )}
    </section>
  )
}
