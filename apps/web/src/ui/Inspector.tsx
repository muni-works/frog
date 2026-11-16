import { useCallback, useEffect, useRef, useState } from 'react'
import type { Op } from '../cloud/protocol'
import type { Thread } from '../engine/thread'
import type { Machine } from '../machines'
import type { PreviewHub } from '../preview'
import { DownloadAppChip } from './DownloadChip'
import { FileRow } from './Diff'
import { ICON, Icon } from './icons'
import { PreviewPane, usePreviewHub } from './PreviewPane'
import { TerminalPane } from './TerminalPane'

type Tab = 'changes' | 'terminal' | 'preview'

// Width: 420 by default, dragged between 360 and 560 (the Mac's PaneArea uses the same).
const WIDTH = 420, MIN_WIDTH = 360, MAX_WIDTH = 560
const clampWidth = (w: number) => Math.round(Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, w)))
const TABS: readonly { id: Tab; label: string; icon: string }[] = [
  { id: 'changes', label: 'Changes', icon: ICON.plusMinus },
  { id: 'terminal', label: 'Terminal', icon: ICON.terminalBox },
  { id: 'preview', label: 'Preview', icon: ICON.globe },
]

/** The one empty state for every tab: an icon, a title, a line, and an action if there is one. */
export function InspectorEmpty({ icon, title, children, action }: { icon: string; title: string; children: React.ReactNode; action?: React.ReactNode }) {
  return (
    <div className="insp-empty">
      <Icon d={icon} size={24} stroke={1.6} />
      <b>{title}</b>
      <span className="wrap">{children}</span>
      {action}
    </div>
  )
}

interface InspectorProps {
  onClose: () => void
  thread: Thread
  branch?: string
  hasPr: boolean
  onCommit: () => void
  /** Absent in a session without a repo: there's nowhere to push. */
  onPr?: () => void
  send: (op: Op) => void
  machines?: readonly Machine[]
  /** The session's preview panes (CloudEngine.preview). Absent: Preview points at the Mac app. */
  preview?: PreviewHub
  /** Open on this tab (tests); default: the one remembered for this browser. */
  pane?: Tab
}

export function Inspector({ thread, onCommit, onPr, hasPr, send, onClose, machines = [], preview, pane: initialPane }: InspectorProps) {
  // Width, dragged from the left edge and kept per browser.
  const [width, setWidth] = useState(() => { try { return clampWidth(Number(localStorage.getItem('frog.inspectorWidth')) || WIDTH) } catch { return WIDTH } })
  const [dragging, setDragging] = useState(false)
  const grab = (e: React.PointerEvent) => {
    e.preventDefault()
    const x0 = e.clientX, w0 = width
    setDragging(true); document.body.classList.add('resizing')
    const move = (ev: PointerEvent) => setWidth(clampWidth(w0 + x0 - ev.clientX))
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
  // The engine is looking at the preview: bring it forward (the Mac's PaneHub.attention).
  usePreviewHub(preview)
  const attention = preview?.attention ?? 0
  const seen = useRef(attention)
  useEffect(() => { if (attention !== seen.current) { seen.current = attention; setPane('preview') } }, [attention])
  const previews = Object.values(thread.panes).filter((p) => p.kind === 'preview' && !p.closed)
  // Which changed files are open to their hunks; the only one opens by itself.
  const [open, setOpen] = useState<Set<string>>(new Set())
  useEffect(() => { if (thread.changes.length === 1) setOpen(new Set([thread.changes[0].path])) }, [thread.changes.length === 1 ? thread.changes[0].path : '']) // eslint-disable-line react-hooks/exhaustive-deps
  // The newest terminal pane that's still open, else the newest one.
  const terms = Object.values(thread.panes).filter((p) => p.kind === 'terminal')
  const term = [...terms].reverse().find((p) => !p.closed) ?? terms[terms.length - 1]
  const resize = useCallback((cols: number, rows: number) => { if (term && !term.closed) send({ op: 'pane_resize', id: term.id, cols, rows }) }, [term?.id, term?.closed, send]) // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <section className="insp f-glass" aria-label="Inspector" style={{ '--insp-w': `${width}px` } as React.CSSProperties}>
      <div className={`insp-grip${dragging ? ' on' : ''}`} role="separator" aria-orientation="vertical" aria-label="Resize the inspector" onPointerDown={grab}
        onDoubleClick={() => { setWidth(WIDTH); try { localStorage.removeItem('frog.inspectorWidth') } catch { /* private mode */ } }} />
      <div className="insp-top">
        <div className="insp-tabs" role="tablist">
          {TABS.map((t) => (
            <button key={t.id} type="button" role="tab" className="insp-tab" aria-selected={pane === t.id} onClick={() => { setPane(t.id); try { localStorage.setItem('frog.inspectorTab', t.id) } catch { /* private mode */ } }}>
              <Icon d={t.icon} size={13} stroke={2} />{t.label}
            </button>
          ))}
        </div>
        <button type="button" className="ic-btn insp-x" aria-label="Close the inspector" title="Close" onClick={onClose}>
          <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M6 6l12 12M18 6L6 18" /></svg>
        </button>
      </div>
      {pane === 'changes' && (
        <div className="insp-body">
          {thread.changes.length === 0 && <InspectorEmpty icon={ICON.plusMinus} title="No changes yet">Files Frog edits show up here.</InspectorEmpty>}
          {thread.changes.length > 0 && (
            <div className="files-head">
              <span className="files-count">{thread.changes.length} file{thread.changes.length === 1 ? '' : 's'}</span>
              <span className="file-add">+{thread.changes.reduce((n, c) => n + c.added, 0)}</span>
              <span className="file-del">−{thread.changes.reduce((n, c) => n + c.removed, 0)}</span>
              <span style={{ flex: 1 }} />
              <button type="button" className="files-toggle" onClick={() => setOpen(open.size ? new Set() : new Set(thread.changes.map((c) => c.path)))}>{open.size ? 'Collapse all' : 'Expand all'}</button>
            </div>
          )}
          {thread.changes.length > 0 && <div className="files">
            {thread.changes.map((c) => (
              <FileRow key={c.path} diff={c} open={open.has(c.path)} onToggle={() => setOpen((o) => { const n = new Set(o); if (n.has(c.path)) n.delete(c.path); else n.add(c.path); return n })} />
            ))}
          </div>}
          {thread.changes.length > 0 && (
            <div className="insp-acts">
              <button type="button" className="f-btn f-btn--bordered" onClick={onCommit}>Commit</button>
              {onPr && <button type="button" className="f-btn f-btn--prominent" onClick={onPr}>{hasPr ? 'Push' : 'Open PR'}</button>}
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
            <InspectorEmpty icon={ICON.terminalBox} title={term?.closed ? `The shell exited${term.exit != null ? ` (${term.exit})` : ''}` : 'A shell in the sandbox'}
              action={<button type="button" className="f-btn f-btn--bordered" onClick={() => send({ op: 'pane_open', kind: 'terminal', cols: 80, rows: 24 })}>{term?.closed ? 'Open another' : 'Open a terminal'}</button>}>
              Same machine Frog works in, at the repo. Nothing here touches your computer.
            </InspectorEmpty>
          )}
        </div>
      )}
      {pane === 'preview' && preview && <PreviewPane hub={preview} pane={previews[previews.length - 1]} send={send} />}
      {pane === 'preview' && !preview && (
        <div className="insp-body">
          <InspectorEmpty icon={ICON.globe} title="Preview isn't here yet" action={<DownloadAppChip label="The Mac app has Preview" machines={machines} />}>
            Open the session in the Mac app to preview it.
          </InspectorEmpty>
        </div>
      )}
    </section>
  )
}
