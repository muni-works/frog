// Phone layout ("Frog on a phone"): narrow, below the app's 760 px breakpoint (app.css). Most of
// it is CSS; this is for the few places the phone draws something else (the sessions sheet in
// place of the sidebar drawer, Settings as a list you drill into). False where there's no
// matchMedia (node, the app harness), so the desktop is what tests render.
import { useEffect, useRef, useState } from 'react'

export const PHONE_QUERY = '(max-width: 760px)'
/** Touch first: keyboard hints (⌘K, "tab") and the Shortcuts section are no use here. */
export const TOUCH_QUERY = '(hover: none) and (pointer: coarse)'

function matches(q: string): boolean {
  try { return typeof matchMedia === 'function' && matchMedia(q).matches } catch { return false }
}

function useQuery(q: string): boolean {
  const [on, setOn] = useState(() => matches(q))
  useEffect(() => {
    if (typeof matchMedia !== 'function') return
    const m = matchMedia(q)
    const f = () => setOn(m.matches)
    f()
    m.addEventListener?.('change', f)
    return () => m.removeEventListener?.('change', f)
  }, [q])
  return on
}

export const useNarrow = () => useQuery(PHONE_QUERY)
export const useTouch = () => useQuery(TOUCH_QUERY)
export const isNarrow = () => matches(PHONE_QUERY)

/** The on-screen keyboard: iOS Safari shrinks the visual viewport, not the layout one, so `100dvh`
 *  stays tall and a pinned composer slides under the keyboard. The window's height follows the
 *  visual viewport instead (--vvh on <html>, read by app.css on phones). */
export function useVisualViewport(on: boolean, onResize?: () => void) {
  const after = useRef(onResize)
  after.current = onResize
  useEffect(() => {
    const vv = typeof window !== 'undefined' ? window.visualViewport : undefined
    const root = typeof document !== 'undefined' ? document.documentElement : undefined
    if (!on || !vv || !root) return
    let raf = 0
    const set = () => {
      cancelAnimationFrame(raf)
      raf = requestAnimationFrame(() => {
        root.style.setProperty('--vvh', `${Math.round(vv.height)}px`)
        root.style.setProperty('--vvtop', `${Math.round(vv.offsetTop)}px`)
        // The transcript under the composer doesn't jump: a pinned one stays at its end.
        requestAnimationFrame(() => after.current?.())
      })
    }
    set()
    vv.addEventListener('resize', set)
    vv.addEventListener('scroll', set)
    return () => {
      cancelAnimationFrame(raf)
      vv.removeEventListener('resize', set)
      vv.removeEventListener('scroll', set)
      root.style.removeProperty('--vvh')
      root.style.removeProperty('--vvtop')
    }
  }, [on])
}
