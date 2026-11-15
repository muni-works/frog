// Keyboard plumbing for things that open over the page: menus, popovers, dialogs.
//
// Escape closes only the top layer. Every open layer registers here, and one capture-phase
// listener on window takes the Escape before anything else sees it (the composer's own Escape
// interrupts a turn, so a menu's Escape must not reach it), and closes just the newest layer.
import { useEffect, useRef, type KeyboardEvent as ReactKeyboardEvent } from 'react'

type Key = { key: string; preventDefault(): void; stopPropagation(): void }

const stack: { close: () => void }[] = []
let installed = false

/** The capture listener's body: true when a layer took the key. */
export function escape(e: Key): boolean {
  if (e.key !== 'Escape' || !stack.length) return false
  e.preventDefault()
  e.stopPropagation()
  stack[stack.length - 1].close()
  return true
}

/** Registers an open layer; returns its removal. */
export function pushLayer(close: () => void): () => void {
  if (!installed && typeof window !== 'undefined') {
    installed = true
    window.addEventListener('keydown', escape, true)
  }
  const layer = { close }
  stack.push(layer)
  return () => {
    const i = stack.indexOf(layer)
    if (i >= 0) stack.splice(i, 1)
  }
}

/** A layer while `open`: Escape calls `close` when it's on top. */
export function useLayer(open: boolean, close: () => void) {
  const latest = useRef(close)
  latest.current = close
  useEffect(() => (open ? pushLayer(() => latest.current()) : undefined), [open])
}

/** Where the arrow keys move in a list of n: wraps, Home and End jump. -1 = not a move. */
export function nextIndex(key: string, at: number, n: number): number {
  if (n <= 0) return -1
  if (key === 'ArrowDown') return at < 0 ? 0 : (at + 1) % n
  if (key === 'ArrowUp') return at < 0 ? n - 1 : (at - 1 + n) % n
  if (key === 'Home') return 0
  if (key === 'End') return n - 1
  return -1
}

const ITEMS = '[role="menuitem"]:not([disabled]),[role="menuitemradio"]:not([disabled]),[role="menuitemcheckbox"]:not([disabled])'

/** Roving focus: only the focused item is in the tab order. */
function rove(items: HTMLElement[], at: number) {
  items.forEach((el, i) => { el.tabIndex = i === at ? 0 : -1 })
  items[at]?.focus()
}

/** A `role="menu"`: on open, focus goes to the checked item (or the first), arrows, Home and End
 * move it, and on close it goes back to whatever opened the menu. A menu with its own search
 * field keeps focus there; arrows from the field step into the list. Spread the result on the
 * menu element: `<div role="menu" {...menu}>`. */
export function useMenu<T extends HTMLElement = HTMLDivElement>(open: unknown) {
  const ref = useRef<T>(null)
  useEffect(() => {
    if (!open) return
    const opener = document.activeElement as HTMLElement | null
    const el = ref.current
    if (el && !el.querySelector('input')) {
      const items = [...el.querySelectorAll<HTMLElement>(ITEMS)]
      const checked = items.findIndex((i) => i.getAttribute('aria-checked') === 'true')
      rove(items, checked >= 0 ? checked : 0)
    }
    return () => {
      // Back to the button that opened it, unless focus has already moved on elsewhere.
      if (opener?.isConnected && (!document.activeElement || document.activeElement === document.body || el?.contains(document.activeElement))) opener.focus()
    }
  }, [open])
  const onKeyDown = (e: ReactKeyboardEvent<T>) => {
    const items = [...e.currentTarget.querySelectorAll<HTMLElement>(ITEMS)]
    const to = nextIndex(e.key, items.indexOf(document.activeElement as HTMLElement), items.length)
    if (to < 0) return
    e.preventDefault()
    rove(items, to)
  }
  return { ref, onKeyDown }
}

const FOCUSABLE = 'button:not([disabled]),a[href],input:not([disabled]),select,textarea,[tabindex]:not([tabindex="-1"])'

/** Where Tab goes inside a trap of n focusables: wraps at both ends. -1 = let it be. */
export function trapIndex(at: number, n: number, back: boolean): number {
  if (n === 0) return -1
  if (back) return at <= 0 ? n - 1 : -1
  return at === n - 1 || at < 0 ? 0 : -1
}

/** A popover that holds focus while open: focus goes in on open, Tab cycles inside, and focus
 * returns to the opener on close. Spread on the popover: `<div {...trap}>`. */
export function useFocusTrap<T extends HTMLElement = HTMLDivElement>(open: boolean, returnTo: () => HTMLElement | null) {
  const ref = useRef<T>(null)
  const back = useRef(returnTo)
  back.current = returnTo
  useEffect(() => {
    if (!open) return
    const el = ref.current
    const first = el?.querySelector<HTMLElement>(FOCUSABLE)
    if (first) first.focus()
    else el?.focus()
    return () => {
      // Closed by a click elsewhere: focus stays where that click put it.
      const now = document.activeElement
      if (!now || now === document.body || el?.contains(now)) back.current()?.focus()
    }
  }, [open])
  const onKeyDown = (e: ReactKeyboardEvent<T>) => {
    if (e.key !== 'Tab') return
    const all = [...e.currentTarget.querySelectorAll<HTMLElement>(FOCUSABLE)]
    const to = trapIndex(all.indexOf(document.activeElement as HTMLElement), all.length, e.shiftKey)
    if (to < 0) return
    e.preventDefault()
    all[to].focus()
  }
  return { ref, onKeyDown, tabIndex: -1 }
}
