import { useState } from 'react'
import { downloadChipShown } from './download'
import { usePhone } from './DownloadChip'

// The sidebar's chip slot: one place directly above the Documentation row, holding at most one
// chip. On the web it holds the Mac app chip; the Mac app puts its "update available" chip in the
// same slot. An empty slot (no chip, or the chip dismissed) draws nothing and takes no space.

/** One chip: the frog mark, a title, a short second line, a link and a dismiss. */
export interface ChipSpec {
  /** Names the chip's remembered dismissal (`frog.chip.<id>`). */
  id: string
  title: string
  detail: string
  href: string
  /** The link's tooltip. */
  hint?: string
}

const KEY = (id: string) => `frog.chip.${id}`

/** Whether a chip was dismissed in this browser. */
export function chipDismissed(id: string): boolean {
  try { return localStorage.getItem(KEY(id)) === 'dismissed' } catch { return false }
}

/** A chip's dismissal, remembered per browser. */
export function useDismissed(id: string): [boolean, () => void] {
  const [gone, setGone] = useState(() => chipDismissed(id))
  const dismiss = () => {
    setGone(true)
    try { localStorage.setItem(KEY(id), 'dismissed') } catch { /* private mode: dismissed for this page */ }
  }
  return [gone, dismiss]
}

/** The web's chip: get the Mac app. The download chip's two gates (./download.ts) hold: not on a
 *  phone or tablet, and not once one of your machines is this Mac. */
export const MAC_APP_CHIP: ChipSpec = {
  id: 'mac-app',
  title: 'Get the Mac app',
  detail: 'Local models, $0 a token',
  href: '/download',
  hint: 'Download Frog for Mac',
}

/** The Mac app chip when it should show, else null; and its dismiss. `phone` overrides the live
 *  platform gate (tests). */
export function useMacAppChip(machines: readonly { thisMac?: boolean }[] = [], phone?: boolean): { chip: ChipSpec | null; dismiss: () => void } {
  const livePhone = usePhone()
  const [gone, dismiss] = useDismissed(MAC_APP_CHIP.id)
  const shown = !gone && downloadChipShown(machines, phone ?? livePhone)
  return { chip: shown ? MAC_APP_CHIP : null, dismiss }
}

/** The slot. Nothing at all when there's no chip. */
export function ChipSlot({ chip, onDismiss }: { chip: ChipSpec | null; onDismiss: () => void }) {
  if (!chip) return null
  return (
    <div className="chip-slot" data-chip={chip.id}>
      <a className="side-chip" href={chip.href} title={chip.hint} style={{ textDecoration: 'none' }}>
        <span className="mark" style={{ width: 22, height: 22 }} aria-hidden="true" />
        <span className="side-chip-text"><b>{chip.title}</b><span className="det">{chip.detail}</span></span>
      </a>
      <button type="button" className="ic-btn side-chip-x" aria-label={`Dismiss ${chip.title}`} title="Dismiss" onClick={onDismiss}>
        <svg aria-hidden="true" width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round"><path d="M6 6l12 12M18 6L6 18" /></svg>
      </button>
    </div>
  )
}
