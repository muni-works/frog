// A sheet (frames 4 and 5): on a phone it rises from the bottom over the page, closes by a swipe
// down, a tap outside, Escape, or the back gesture; wider, the same content is a centred card.
//
// The back gesture: opening pushes a history entry (same URL, `sheet` in its state), so Back closes
// the sheet instead of leaving the page. Closing any other way takes that entry back off, and a
// row that goes somewhere (a session) waits for that before it navigates, so it never leaves a
// stray entry behind. App's own popstate handler skips pops while a sheet is open (sheetOpen()).
import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { useFocusTrap, useLayer } from './layers'

let open = 0
/** A sheet is on screen: the next popstate is closing it, not navigating. */
export const sheetOpen = () => open > 0

let seq = 0

/** The sheet's history entry and its closing. `close()` takes the entry off (Back), `closeThen(f)`
 *  runs `f` once it's gone. Without history.back (the node harness) both act at once. */
function useBackClose(onClose: () => void) {
  const id = useRef(`sheet-${++seq}`).current
  const pending = useRef<(() => void) | null>(null)
  const closed = useRef(false)
  const done = useRef(onClose)
  done.current = onClose
  useEffect(() => {
    open++
    closed.current = false
    const canBack = typeof history !== 'undefined' && typeof history.back === 'function'
    if (canBack) history.pushState({ ...(history.state ?? {}), sheet: id }, '', location.href)
    const pop = () => {
      if ((history.state as { sheet?: string } | null)?.sheet === id || closed.current) return
      closed.current = true
      const after = pending.current
      pending.current = null
      done.current()
      after?.()
    }
    addEventListener('popstate', pop)
    return () => {
      removeEventListener('popstate', pop)
      // Unmounted by the app itself (signed out, a session switch from elsewhere): its entry goes too.
      if (!closed.current && canBack && (history.state as { sheet?: string } | null)?.sheet === id) { closed.current = true; history.back() }
      // After the pop it caused has been seen: the count drops a frame later.
      setTimeout(() => { open-- }, 0)
    }
  }, [id])
  const closeThen = useCallback((after?: () => void) => {
    if (closed.current) { after?.(); return }
    const ours = typeof history !== 'undefined' && typeof history.back === 'function' && (history.state as { sheet?: string } | null)?.sheet === id
    if (!ours) { closed.current = true; done.current(); after?.(); return }
    pending.current = after ?? null
    history.back()
  }, [id])
  return closeThen
}

export interface SheetApi { close: () => void; closeThen: (after: () => void) => void }

/** A sheet with its content. `children` gets the closers, so a row can close it and then go. */
export function Sheet({ label, onClose, children, className = '', tall }: { label: string; onClose: () => void; children: (api: SheetApi) => ReactNode; className?: string; tall?: boolean }) {
  const closeThen = useBackClose(onClose)
  const close = useCallback(() => closeThen(), [closeThen])
  useLayer(true, close)
  const trap = useFocusTrap(true, () => null)
  // Swipe down from the handle (or anywhere while the content is scrolled to its top) to close.
  const [dy, setDy] = useState(0)
  const drag = useRef<{ y: number; t: number; id: number } | null>(null)
  const body = useRef<HTMLDivElement>(null)
  const down = (e: React.PointerEvent) => {
    if (e.pointerType === 'mouse' && e.button !== 0) return
    const inHandle = (e.target as HTMLElement).closest('.sheet-grab, .sheet-head')
    if (!inHandle && (body.current?.scrollTop ?? 0) > 0) return
    drag.current = { y: e.clientY, t: Date.now(), id: e.pointerId }
  }
  const move = (e: React.PointerEvent) => {
    const d = drag.current
    if (!d || d.id !== e.pointerId) return
    const next = Math.max(0, e.clientY - d.y)
    if (next > 6 && !(e.currentTarget as HTMLElement).hasPointerCapture?.(e.pointerId)) (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId)
    setDy(next)
  }
  const up = (e: React.PointerEvent) => {
    const d = drag.current
    drag.current = null
    if (!d || d.id !== e.pointerId) return
    const dist = Math.max(0, e.clientY - d.y)
    const fast = dist / Math.max(1, Date.now() - d.t) > 0.6
    if (dist > 90 || (fast && dist > 30)) close()
    setDy(0)
  }
  return (
    <div className="sheet-layer">
      <div className="sheet-scrim" onClick={close} aria-hidden="true" />
      <div role="dialog" aria-modal="true" aria-label={label} className={`sheet${tall ? ' sheet--tall' : ''} ${className}`}
        style={dy ? { transform: `translateY(${dy}px)`, transition: 'none' } : undefined}
        onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={() => { drag.current = null; setDy(0) }}
        ref={trap.ref} onKeyDown={trap.onKeyDown} tabIndex={trap.tabIndex}>
        <div className="sheet-grab" aria-hidden="true"><i /></div>
        <div className="sheet-body" ref={body}>{children({ close, closeThen })}</div>
      </div>
    </div>
  )
}
