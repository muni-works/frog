import { useEffect, useRef, useState } from 'react'
import type { Provider } from '../auth'
import { ChipSlot, type ChipSpec } from './ChipSlot'
import { gh, google } from './Composer'
import { DocsRow } from './Docs'
import { useLayer, useMenu } from './layers'

// The sidebar a signed-out visitor sees: the same shell as signed in, with what can work signed
// out. New session (the composer), one line where the session list goes, the chip slot, the
// Documentation row, and a Sign in row where the account button sits. No Search: there's nothing
// to search yet.

/** The Sign in row: opens the same GitHub / Google choice the composer's Sign in pill does. */
export function SignInRow({ onSignIn }: { onSignIn: (provider: Provider) => void }) {
  const [open, setOpen] = useState(false)
  const box = useRef<HTMLDivElement>(null)
  useLayer(open, () => setOpen(false))
  const nav = useMenu(open)
  useEffect(() => {
    if (!open) return
    const down = (e: MouseEvent) => { if (!box.current?.contains(e.target as Node)) setOpen(false) }
    addEventListener('mousedown', down)
    return () => removeEventListener('mousedown', down)
  }, [open])
  return (
    <div className="signin-row" ref={box}>
      {open && (
        <div className="cz-menu signin-menu" role="menu" aria-label="Sign in" {...nav}>
          <button type="button" role="menuitem" onClick={() => { setOpen(false); onSignIn('github') }}>{gh(14)}Continue with GitHub</button>
          <button type="button" role="menuitem" onClick={() => { setOpen(false); onSignIn('google') }}>{google(14)}Continue with Google</button>
        </div>
      )}
      <button type="button" className="row" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className="mark" style={{ width: 28, height: 28 }} aria-hidden="true" />
        <div style={{ flex: 1, textAlign: 'left', minWidth: 0 }}>
          <b>Sign in</b>
          <div className="det wrap">25¢ of Frog Cloud credit free, $1 when you connect GitHub</div>
        </div>
      </button>
    </div>
  )
}

const plus = 'M12 5v14M5 12h14'

interface Props {
  /** New session: the landing's composer. */
  onNew: () => void
  chip: ChipSpec | null
  onDismissChip: () => void
  onDocs: () => void
  onSignIn: (provider: Provider) => void
}

export function SignedOutSide({ onNew, chip, onDismissChip, onDocs, onSignIn }: Props) {
  return (<>
    <nav aria-label="Main" className="nav">
      <button type="button" className="row big" onClick={onNew}>
        <svg aria-hidden="true" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" style={{ flex: 'none' }}><path d={plus} /></svg>
        <span style={{ flex: 1 }}>New session</span>
      </button>
    </nav>
    <div className="side-quiet det wrap">Your sessions appear here once you sign in, on this and your other devices.</div>
    <ChipSlot chip={chip} onDismiss={onDismissChip} />
    <DocsRow onOpen={onDocs} />
    <SignInRow onSignIn={onSignIn} />
  </>)
}
