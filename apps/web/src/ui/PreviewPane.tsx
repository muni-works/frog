import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from 'react'
import type { Op } from '../cloud/protocol'
import type { Pane } from '../engine/thread'
import type { Machine } from '../machines'
import { addressURL, displayAddress, type Frame, type PreviewHub } from '../preview'
import { DownloadAppChip } from './DownloadChip'
import { ICON, Icon } from './icons'
import { InspectorEmpty } from './Inspector'
import { useLayer, useMenu } from './layers'

// The web Preview pane, one design with the Mac's (apps/macos/Frog/Views/PreviewPane.swift; spec
// in docs/design/frog-web/README.md, "Preview"): one 38 px row of back, forward, reload (stop
// while loading), the address, then the tools (device size, pick an element, open in browser),
// which fold into one More menu below 400 px. Under it the page, in an iframe onto a dev server
// in the sandbox, at Fit or a device's shape scaled to the body. The page reports through
// public/preview.js; PreviewHub turns that into the engine's pane reports and answers its requests.

export type Device = 'fit' | 'phone' | 'tablet' | 'desktop'
export const DEVICES: readonly { id: Device; label: string; size?: [number, number] }[] = [
  { id: 'fit', label: 'Fit' },
  { id: 'phone', label: 'Phone', size: [390, 844] },
  { id: 'tablet', label: 'Tablet', size: [820, 1180] },
  { id: 'desktop', label: 'Desktop', size: [1280, 800] },
]

/** A device's frame in a body of `w` × `h`: its shape, scaled down (never up) to fit. */
export function fitDevice(device: Device, w: number, h: number): { width: number; height: number; scale: number } | null {
  const size = DEVICES.find((d) => d.id === device)?.size
  if (!size || w <= 0 || h <= 0) return null
  const scale = Math.min(1, w / size[0], h / size[1])
  return { width: size[0] * scale, height: size[1] * scale, scale }
}

export function usePreviewHub(hub: PreviewHub | undefined) {
  const v = () => hub?.version ?? 0
  useSyncExternalStore(hub?.subscribe ?? noop, v, v)
}
const noop = () => () => {}
const sentence = (s: string) => s[0].toUpperCase() + s.slice(1) + (/[.?!]$/.test(s) ? '' : '.')

const P = {
  back: 'M15 6l-6 6 6 6',
  forward: 'M9 6l6 6-6 6',
  reload: 'M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6',
  stop: 'M6 6l12 12M18 6L6 18',
  pick: 'M4 4l7 17 2.5-7.5L21 11 4 4zM14 14l5 5',
  open: 'M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  failed: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 8v5M12 16h.01',
}
const DEVICE_ICON: Record<Device, string> = {
  fit: 'M4 9V5h4M20 9V5h-4M4 15v4h4M20 15v4h-4',
  phone: 'M8 3h8a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H8a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM11 18h2',
  tablet: 'M6 3h12a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1zM11 18h2',
  desktop: 'M4 4h16a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zM9 20h6M12 16v4',
}

/** One of the row's icon buttons: the strip's 24 px plate, a reason in its tooltip when off. */
function Tool({ label, d, onClick, disabled, why, on, ...rest }: { label: string; d: string; onClick: () => void; disabled?: boolean; why?: string; on?: boolean } & React.ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button type="button" className={`icon-plate${on ? ' on' : ''}`} aria-label={label} title={disabled && why ? why : label} disabled={disabled} onClick={onClick} {...rest}>
      <Icon d={d} size={14} stroke={1.9} />
    </button>
  )
}

/** A small menu under the row, over a clear scrim (clicks on the page never reach the document). */
function Menu({ label, onClose, children }: { label: string; onClose: () => void; children: React.ReactNode }) {
  useLayer(true, onClose)
  const nav = useMenu(true)
  return (<>
    <div className="pv-scrim" onMouseDown={onClose} />
    <div className="cz-menu pv-menu" role="menu" aria-label={label} {...nav}>{children}</div>
  </>)
}

function DeviceItems({ device, pick }: { device: Device; pick: (d: Device) => void }) {
  return (<>
    {DEVICES.map((d) => (
      <button key={d.id} type="button" role="menuitemradio" aria-checked={device === d.id} data-device={d.id} onClick={() => pick(d.id)}>
        <Icon d={DEVICE_ICON[d.id]} size={13} stroke={1.9} />{d.label}{d.size && <span className="cz-r">{d.size[0]} × {d.size[1]}</span>}
      </button>
    ))}
  </>)
}

export function PreviewPane({ hub, pane, send, machines = [] }: { hub: PreviewHub; pane?: Pane; send: (op: Op) => void; machines?: readonly Machine[] }) {
  usePreviewHub(hub)
  const id = pane?.id
  const s = id ? hub.state(id) : undefined
  const url = s?.url ?? pane?.url
  const [device, setDevice] = useState<Device>('fit')
  const [menu, setMenu] = useState<'device' | 'more' | null>(null)
  // The field shows the address plainly; focused, it holds the whole URL to edit.
  const [draft, setDraft] = useState<string | null>(null)
  const input = useRef<HTMLInputElement>(null)
  const frame = useRef<HTMLIFrameElement>(null)
  const stage = useRef<HTMLDivElement>(null)
  const [box, setBox] = useState({ w: 0, h: 0 })

  // Does the gateway serve previews at all? Production's doesn't yet; the tab then says so.
  useEffect(() => { void hub.probe() }, [hub])

  useLayoutEffect(() => {
    const el = stage.current
    if (!el) return
    // The content box: what's inside the stage's padding.
    const measure = () => {
      const cs = getComputedStyle(el)
      const px = (v: string) => parseFloat(v) || 0
      setBox({ w: el.clientWidth - px(cs.paddingLeft) - px(cs.paddingRight), h: el.clientHeight - px(cs.paddingTop) - px(cs.paddingBottom) })
    }
    measure()
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    return () => ro.disconnect()
  }, [hub.available])

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
  }, [hub, id, hub.available]) // eslint-disable-line react-hooks/exhaustive-deps

  if (hub.available === false) {
    return (
      <div className="insp-body pv">
        <InspectorEmpty icon={ICON.globe} title="Preview isn’t on the web yet" action={<DownloadAppChip label="The Mac app has Preview" machines={machines} />}>
          Frog Cloud can’t show a sandbox’s dev server in the browser yet. Open the session in the Mac app to preview it.
        </InspectorEmpty>
      </div>
    )
  }

  const go = (e: React.FormEvent) => {
    e.preventDefault()
    const next = addressURL(draft ?? '')
    if (!next) return
    setDraft(null)
    input.current?.blur()
    // No pane yet: ask the engine for one, as the Mac's openPreview does; it answers with pane_opened.
    if (id) void hub.load(id, next)
    else send({ op: 'pane_open', kind: 'preview', url: next })
  }
  const page = !!s?.src
  const drivable = !!id && hub.drivable(id)
  const browser = id ? hub.browserURL(id) : undefined
  const pickDevice = (d: Device) => { setDevice(d); setMenu(null) }
  const pickWhy = page ? 'Frog can pick elements on a dev server in the sandbox' : 'Open a page to pick an element on it'
  const togglePick = () => { hub.setInspecting(!hub.inspecting); setMenu(null) }
  const openBrowser = () => { if (browser) open(browser, '_blank', 'noopener'); setMenu(null) }
  const fitted = fitDevice(device, box.w, box.h)
  const failed = !!s?.error
  const empty = !failed && !page && !s?.loading && !url

  return (
    <div className="insp-body pv">
      <form className="pv-bar" onSubmit={go}>
        <Tool label="Back" d={P.back} disabled={!id || !hub.canBack(id)} onClick={() => id && hub.back(id)} />
        <Tool label="Forward" d={P.forward} disabled={!id || !hub.canForward(id)} onClick={() => id && hub.forward(id)} />
        {s?.loading
          ? <Tool label="Stop" d={P.stop} onClick={() => id && hub.stop(id)} />
          : <Tool label="Reload" d={P.reload} disabled={!url} onClick={() => id && hub.reload(id)} />}
        <label className="pv-addr">
          <Icon d={ICON.globe} size={12} stroke={1.8} />
          <input ref={input} value={draft ?? displayAddress(url)} placeholder="URL or port" aria-label="Address" spellCheck={false} autoCapitalize="off" autoCorrect="off"
            onChange={(e) => setDraft(e.target.value)}
            onFocus={(e) => { const el = e.currentTarget; setDraft(url ?? ''); requestAnimationFrame(() => el.select()) }}
            onBlur={() => setDraft(null)}
            onKeyDown={(e) => { if (e.key === 'Escape' && draft !== null) { e.preventDefault(); e.stopPropagation(); setDraft(null); e.currentTarget.blur() } }} />
        </label>
        {hub.mention && hub.mentionInDraft && <span className="pv-mention" title="In your message">{hub.mention}</span>}
        <div className="pv-tools">
          <Tool label="Device size" d={DEVICE_ICON[device]} aria-haspopup="menu" aria-expanded={menu === 'device'} onClick={() => setMenu(menu === 'device' ? null : 'device')} />
          <Tool label="Pick an element" d={P.pick} aria-pressed={hub.inspecting} on={hub.inspecting} disabled={!drivable} why={pickWhy} onClick={togglePick} />
          <Tool label="Open in browser" d={P.open} disabled={!browser} why="Open a page first" onClick={openBrowser} />
        </div>
        <div className="pv-more">
          <Tool label="More" d={P.more} aria-haspopup="menu" aria-expanded={menu === 'more'} on={hub.inspecting} onClick={() => setMenu(menu === 'more' ? null : 'more')} />
        </div>
        {menu === 'device' && <Menu label="Device size" onClose={() => setMenu(null)}><DeviceItems device={device} pick={pickDevice} /></Menu>}
        {menu === 'more' && (
          <Menu label="More" onClose={() => setMenu(null)}>
            <button type="button" role="menuitemcheckbox" aria-checked={hub.inspecting} disabled={!drivable} title={drivable ? undefined : pickWhy} onClick={togglePick}><Icon d={P.pick} size={13} stroke={1.9} />Pick an element</button>
            <button type="button" role="menuitem" disabled={!browser} onClick={openBrowser}><Icon d={P.open} size={13} stroke={1.9} />Open in browser</button>
            <div className="cz-menu-sep" />
            <div className="cz-menu-h">Device size</div>
            <DeviceItems device={device} pick={pickDevice} />
          </Menu>
        )}
        {s?.loading && <div className="pv-progress" role="progressbar" aria-label="Loading" />}
      </form>
      <div className="pv-stage" ref={stage}>
        <div className={`pv-frame${fitted ? ' pv-device' : ''}${empty || failed ? ' pv-idle' : ''}`} style={fitted ? { width: fitted.width, height: fitted.height } : undefined}>
          {/* Its own origin, and sandboxed so it can't navigate the app away. */}
          <iframe ref={frame} title={s?.title || 'Preview'} className={page && !failed ? '' : 'pv-hidden'} onLoad={() => id && hub.loaded(id)}
            style={fitted ? { width: fitted.width / fitted.scale, height: fitted.height / fitted.scale, transform: `scale(${fitted.scale})` } : undefined}
            sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-modals allow-downloads" allow="clipboard-write" referrerPolicy="same-origin" />
          {hub.inspecting && <div className="pv-toast" role="status">Click an element to mention it · Esc to stop</div>}
        </div>
        {empty && (
          <InspectorEmpty icon={ICON.globe} title="Nothing to preview yet">Run your dev server, then enter its URL or port, or ask Frog to open it.</InspectorEmpty>
        )}
        {failed && (
          <InspectorEmpty icon={P.failed} title={`Couldn’t load ${displayAddress(url) || 'the page'}`}
            action={<button type="button" className="f-btn f-btn--bordered" onClick={() => id && hub.reload(id)}>Retry</button>}>
            {sentence(s!.error!)}
          </InspectorEmpty>
        )}
      </div>
    </div>
  )
}
