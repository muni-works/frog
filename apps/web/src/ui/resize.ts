import { useState } from 'react'

// A column's width, dragged from its inner edge and kept per browser: the sidebar (its right
// edge) and the inspector (its left). Double-click forgets the stored width.

export interface Span { initial: number; min: number; max: number }

export const clampWidth = (s: Span, w: number) => Math.round(Math.min(s.max, Math.max(s.min, w)))
export function loadWidth(key: string, s: Span) { try { return clampWidth(s, Number(localStorage.getItem(key)) || s.initial) } catch { return s.initial } }
export function saveWidth(key: string, w: number) { try { localStorage.setItem(key, String(w)) } catch { /* private mode */ } }
export function clearWidth(key: string) { try { localStorage.removeItem(key) } catch { /* private mode */ } }

/** `edge`: which side of the column the grip is on, so dragging outward widens it.
 *  `grab(e, from)` starts a drag; `from` is the width on screen, if it differs from the stored one. */
export function useResizable(key: string, span: Span, edge: 'left' | 'right') {
  const [width, setWidth] = useState(() => loadWidth(key, span))
  const [dragging, setDragging] = useState(false)
  const grab = (e: React.PointerEvent, from = width) => {
    e.preventDefault()
    const x0 = e.clientX, w0 = clampWidth(span, from), sign = edge === 'right' ? 1 : -1
    setDragging(true); document.body.classList.add('resizing')
    const move = (ev: PointerEvent) => setWidth(clampWidth(span, w0 + sign * (ev.clientX - x0)))
    const up = () => {
      setDragging(false); document.body.classList.remove('resizing')
      removeEventListener('pointermove', move); removeEventListener('pointerup', up)
      setWidth((w) => { saveWidth(key, w); return w })
    }
    addEventListener('pointermove', move); addEventListener('pointerup', up)
  }
  const reset = () => { setWidth(span.initial); clearWidth(key) }
  return { width, dragging, grab, reset }
}
