import { useEffect, useRef, useState, useSyncExternalStore } from 'react'
import type { Op } from '../cloud/protocol'
import type { Pane } from '../engine/thread'
import { addressURL, type Frame, type PreviewHub } from '../preview'

// The web Preview pane, as on the Mac (apps/macos/Frog/Views/PreviewPane.swift): back, reload, an
// address field, device widths, inspect (click an element to mention it) and Open in Browser,
// over an iframe onto a dev server in the sandbox. The page reports through public/preview.js;
// PreviewHub turns that into the engine's pane reports and answers its requests.

type Device = 'phone' | 'tablet' | 'desktop'
const WIDTH: Record<Device, number | null> = { phone: 390, tablet: 820, desktop: null }
const DEVICE_LABEL: Record<Device, string> = { phone: 'Phone', tablet: 'Tablet', desktop: 'Desktop' }

export function usePreviewHub(hub: PreviewHub | undefined) {
  const v = () => hub?.version ?? 0
  useSyncExternalStore(hub?.subscribe ?? noop, v, v)
}
const noop = () => () => {}

const Icon = ({ d, size = 14 }: { d: string; size?: number }) => (
  <svg aria-hidden="true" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round"><path d={d} /></svg>
)
const DEVICE_ICON: Record<Device, string> = {
  phone: 'M8 3h8a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM11 18h2',
  tablet: 'M6 3h12a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM11 18h2',
  desktop: 'M4 4h16a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zM9 20h6M12 16v4',
}

export function PreviewPane({ hub, pane, send }: { hub: PreviewHub; pane?: Pane; send: (op: Op) => void }) {
  usePreviewHub(hub)
  const id = pane?.id
  const s = id ? hub.state(id) : undefined
  const [device, setDevice] = useState<Device>('desktop')
  const [address, setAddress] = useState(s?.url ?? pane?.url ?? '')
  // The URL the field mirrors, so a navigation rewrites it once and typing isn't clobbered.
  const shown = useRef(address)
  useEffect(() => {
    const url = s?.url ?? pane?.url
    if (url && url !== shown.current) { shown.current = url; setAddress(url) }
  }, [s?.url, pane?.url])
  const frame = useRef<HTMLIFrameElement>(null)

  // One iframe per pane: attached to the hub while mounted, so the engine's requests reach it.
  useEffect(() => {
    const el = frame.current
    if (!id || !el) return
    const origin = () => { try { return new URL(el.src).origin } catch { return null } }
    const f: Frame = {
      post: (m) => { const o = origin(); if (o) el.contentWindow?.postMessage(m, o) },
      load: (src) => { el.src = src },
    }
    const onMessage = (e: MessageEvent) => { if (e.source === el.contentWindow && e.origin === origin()) hub.received(id, e.data) }
    addEventListener('message', onMessage)
    hub.attach(id, f, pane?.url)
    return () => { removeEventListener('message', onMessage); hub.detach(id, f) }
  }, [hub, id]) // eslint-disable-line react-hooks/exhaustive-deps

  const go = (e: React.FormEvent) => {
    e.preventDefault()
    const url = addressURL(address)
    if (!url) return
    setAddress(url); shown.current = url
    // No pane yet: ask the engine for one, as the Mac's openPreview does; it answers with pane_opened.
    if (id) void hub.load(id, url)
    else send({ op: 'pane_open', kind: 'preview', url })
  }
  const width = WIDTH[device]
  const page = !!s?.src
  return (
    <div className="insp-body pv">
      <form className="pv-bar" onSubmit={go}>
        <button type="button" className="icon-plate" aria-label="Back" title="Back" disabled={!id || (s?.pages ?? 0) < 2} onClick={() => id && hub.back(id)}><Icon d="M15 6l-6 6 6 6" /></button>
        <button type="button" className="icon-plate" aria-label="Reload" title="Reload" disabled={!s?.url} onClick={() => id && hub.reload(id)}><Icon d="M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6" /></button>
        <label className="pv-addr">
          {s?.loading ? <span className="pv-spin" aria-hidden="true" /> : <Icon size={12} d="M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.7 2.5 15.3 0 18M12 3c-2.5 2.7-2.5 15.3 0 18" />}
          <input value={address} onChange={(e) => setAddress(e.target.value)} placeholder="URL or port" aria-label="Address" spellCheck={false} autoCapitalize="off" autoCorrect="off" />
        </label>
        <div className="seg pv-devices" role="radiogroup" aria-label="Device width">
          {(['phone', 'tablet', 'desktop'] as const).map((d) => (
            <button key={d} type="button" role="radio" aria-checked={device === d} aria-selected={device === d} aria-label={DEVICE_LABEL[d]} title={DEVICE_LABEL[d]} onClick={() => setDevice(d)}><Icon size={13} d={DEVICE_ICON[d]} /></button>
          ))}
        </div>
        <button type="button" className={`icon-plate${hub.inspecting ? ' on' : ''}`} aria-pressed={hub.inspecting} aria-label="Inspect" title="Inspect: click an element to mention it" disabled={!page} onClick={() => hub.setInspecting(!hub.inspecting)}>
          <Icon d="M4 4l7 17 2.5-7.5L21 11 4 4zM14 14l5 5" />
        </button>
        {hub.mention && hub.mentionInDraft && <span className="pv-mention" title="In your message">{hub.mention}</span>}
        <button type="button" className="icon-plate" aria-label="Open in browser" title="Open in browser" disabled={!id || !hub.browserURL(id)} onClick={() => { const u = id && hub.browserURL(id); if (u) open(u, '_blank', 'noopener') }}>
          <Icon d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5" />
        </button>
      </form>
      <div className="pv-stage">
        <div className="pv-frame" style={width ? { width, maxWidth: '100%' } : undefined}>
          {/* Its own origin, and sandboxed so it can't navigate the app away. */}
          <iframe ref={frame} title={s?.title || 'Preview'} className={page && !s?.error ? '' : 'pv-hidden'} onLoad={() => id && hub.loaded(id)}
            sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-modals allow-downloads" allow="clipboard-write" referrerPolicy="same-origin" />
          {!s?.error && !page && !s?.loading && (
            <div className="term-empty pv-over">
              <Icon size={28} d="M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.7 2.5 15.3 0 18M12 3c-2.5 2.7-2.5 15.3 0 18" />
              <span className="det wrap">Run your dev server, then enter its URL, or ask Frog to open it.</span>
            </div>
          )}
          {s?.error && (
            <div className="term-empty pv-over">
              <b>Couldn’t load</b>
              <span className="det wrap">{s.error[0].toUpperCase() + s.error.slice(1).replace(/\.?$/, '.')}</span>
              <button type="button" className="f-btn f-btn--bordered" onClick={() => id && hub.reload(id)}>Try again</button>
            </div>
          )}
          {hub.inspecting && <div className="pv-toast" role="status">Click an element to mention it · Esc to stop</div>}
        </div>
      </div>
    </div>
  )
}
