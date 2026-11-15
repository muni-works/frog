import { useEffect, useState } from 'react'
import { COARSE_POINTER, downloadChipShown, isPhone } from './download'

/** The platform gate, kept current: a tablet with a mouse, or a phone rotated. */
export function usePhone(): boolean {
  const [phone, setPhone] = useState(() => isPhone())
  useEffect(() => {
    const mq = typeof matchMedia === 'function' ? matchMedia(COARSE_POINTER) : null
    const read = () => setPhone(isPhone())
    mq?.addEventListener?.('change', read)
    addEventListener('resize', read)
    return () => {
      mq?.removeEventListener?.('change', read)
      removeEventListener('resize', read)
    }
  }, [])
  return phone
}

/** Both gates, live, for a site that also has to hide something else when the chip is there. */
export function useDownloadChip(machines: readonly { thisMac?: boolean }[] = []): boolean {
  return downloadChipShown(machines, usePhone())
}

/** The destination for every "from the Mac app" dead end in the web app: a quiet inline hint with
 *  the frog mark, pointing at /download (site/worker.js redirects it to the latest Frog.dmg — not
 *  install.sh, and not a tarball: releases have shipped without them). One component, so the copy
 *  and both gates (./download.ts) live in one place: nothing on iOS/Android, and nothing once a
 *  paired local machine says they already have it. Each site keeps its own short label. */
export function DownloadAppChip({ label, machines = [], phone, className = 'f-pill det' }: {
  label: string
  /** Your machines, so a paired This Mac suppresses the chip. */
  machines?: readonly { thisMac?: boolean }[]
  /** Override the platform gate (tests). Default: the live `isPhone()`. */
  phone?: boolean
  className?: string
}) {
  const livePhone = usePhone()
  if (!downloadChipShown(machines, phone ?? livePhone)) return null
  return (
    <a className={className} href="/download" title="Download Frog for Mac" style={{ textDecoration: 'none' }}>
      <span className="mark" style={{ width: 12, height: 12 }} aria-hidden="true" />
      {label}
    </a>
  )
}
