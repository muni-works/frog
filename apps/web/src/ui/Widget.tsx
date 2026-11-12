import { useEffect, useRef, useState } from 'react'
import type { Widget } from '../cloud/protocol'
import { promptGate } from './widgetGate'

// A visual the model made with `Visualize`: its HTML runs in an iframe sandboxed to scripts
// only (an opaque origin: no cookies, storage, or reach into the app), under the engine's CSP
// (no network but pinned CDNs). The shell inside reports its height and may ask a follow-up
// with `sendPrompt`, which only a click can trigger and which is rate-limited here.

const MIN_H = 120
const MAX_INLINE_H = 1400

export function WidgetCard({ widget, onPrompt }: { widget: Widget; onPrompt?: (text: string) => void }) {
  const [source, setSource] = useState(false)
  const [full, setFull] = useState(false)
  const [asked, setAsked] = useState<string | null>(null)
  const gate = useRef(promptGate())

  useEffect(() => {
    if (!full) return
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') setFull(false) }
    window.addEventListener('keydown', esc)
    return () => window.removeEventListener('keydown', esc)
  }, [full])

  const ask = (text: string) => {
    if (!onPrompt || !gate.current(Date.now())) return
    setAsked(text)
    onPrompt(text)
  }

  const body = source
    ? <pre className="widget-src">{widget.code}</pre>
    : <WidgetFrame html={widget.html} title={widget.title} onPrompt={ask} fill={full} />

  return (
    <>
      <div className="widget">
        <div className="widget-h">
          <span className="widget-ic" aria-hidden="true">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M4 19V5M4 19h16M8 15l3-4 3 2 5-6" /></svg>
          </span>
          <span className="widget-verb">Made a visual</span>
          <span className="widget-title">{pretty(widget.title)}</span>
          <span style={{ flex: 1 }} />
          <button type="button" className={`widget-btn${source ? ' on' : ''}`} aria-pressed={source} onClick={() => setSource(!source)}>Source</button>
          <button type="button" className="widget-btn icon" aria-label="Expand" title="Expand" onClick={() => setFull(true)}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7" /></svg>
          </button>
        </div>
        {!full && body}
        {asked && <div className="widget-asked" role="status">Asked Frog: “{asked}”</div>}
      </div>
      {full && (
        <div className="widget-full" role="dialog" aria-modal="true" aria-label={pretty(widget.title)} onClick={(e) => { if (e.target === e.currentTarget) setFull(false) }}>
          <div className="widget-full-card">
            <div className="widget-h">
              <span className="widget-title">{pretty(widget.title)}</span>
              <span style={{ flex: 1 }} />
              <button type="button" className={`widget-btn${source ? ' on' : ''}`} aria-pressed={source} onClick={() => setSource(!source)}>Source</button>
              <button type="button" className="widget-btn" onClick={() => setFull(false)}>Close</button>
            </div>
            <div className="widget-full-body">{body}</div>
          </div>
        </div>
      )}
    </>
  )
}

/** The sandboxed frame. Messages count only when they come from this frame's window. */
export function WidgetFrame({ html, title, onPrompt, fill }: { html: string; title: string; onPrompt: (text: string) => void; fill?: boolean }) {
  const ref = useRef<HTMLIFrameElement>(null)
  const [h, setH] = useState(320)
  const latest = useRef(onPrompt)
  latest.current = onPrompt
  useEffect(() => {
    const on = (e: MessageEvent) => {
      if (!ref.current || e.source !== ref.current.contentWindow) return
      const d = e.data
      if (!d || d.frogWidget !== 1) return
      if (d.type === 'height' && typeof d.height === 'number') setH(Math.min(Math.max(Math.ceil(d.height), MIN_H), MAX_INLINE_H))
      else if (d.type === 'prompt' && typeof d.text === 'string') latest.current(d.text.slice(0, 2000))
    }
    window.addEventListener('message', on)
    return () => window.removeEventListener('message', on)
  }, [])
  return (
    <iframe ref={ref} className="widget-frame" title={pretty(title)} srcDoc={html}
      sandbox="allow-scripts" referrerPolicy="no-referrer" loading="lazy"
      allow="camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'"
      style={fill ? { height: '100%' } : { height: h }} />
  )
}

/** `casimir_plate_modes` → "Casimir plate modes"; titles already in words stay as they are. */
export function pretty(t: string) {
  if (/\s/.test(t) || !/[_-]/.test(t)) return t
  const s = t.replace(/[_-]+/g, ' ').trim()
  return s.charAt(0).toUpperCase() + s.slice(1)
}
