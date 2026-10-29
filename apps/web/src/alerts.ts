// Needs-you alerts: a badge in the tab title, and a browser notification when a session asks
// for you or finishes while this tab isn't in front. Notifications are opt-in (Settings).
import { useEffect, useRef } from 'react'

const KEY = 'frog.notify'

export const notifySupported = () => typeof Notification !== 'undefined'
export function notifyOn(): boolean {
  try { return notifySupported() && Notification.permission === 'granted' && localStorage.getItem(KEY) !== 'off' } catch { return false }
}
export async function setNotify(on: boolean): Promise<boolean> {
  try { localStorage.setItem(KEY, on ? 'on' : 'off') } catch { /* private mode */ }
  if (!on || !notifySupported()) return false
  return (Notification.permission === 'granted' ? 'granted' : await Notification.requestPermission()) === 'granted'
}

export interface Signal { id: string; title: string; waiting: string | null; finished: boolean }

/** Keeps document.title's "(n)" badge and fires notifications on a session's edges: it starts
 * waiting on you, or its turn finishes, while the tab is hidden. Clicking one opens the session. */
export function useAlerts(signals: Signal[], open: (id: string) => void) {
  const seen = useRef(new Map<string, { waiting: string | null; finished: boolean }>())
  const waiting = signals.filter((s) => s.waiting).length
  useEffect(() => {
    document.title = waiting ? `(${waiting}) Frog` : 'Frog'
  }, [waiting])
  useEffect(() => {
    for (const s of signals) {
      const before = seen.current.get(s.id)
      seen.current.set(s.id, { waiting: s.waiting, finished: s.finished })
      if (!before || document.visibilityState === 'visible' || !notifyOn()) continue
      const body = s.waiting && s.waiting !== before.waiting ? s.waiting : s.finished && !before.finished ? 'Finished' : null
      if (!body) continue
      const n = new Notification(s.title, { body, tag: s.id, icon: '/frog.svg' })
      n.onclick = () => { window.focus(); open(s.id); n.close() }
    }
  }, [signals, open])
}
