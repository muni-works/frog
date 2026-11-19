import { useEffect, useRef, useState } from 'react'
import type { Provider } from '../auth'
import type { ChipSpec } from './ChipSlot'
import { gh, google } from './Composer'
import { useLayer, useMenu } from './layers'
import { LegalRow, SideNav, SidePill, Starters } from './Side'

// The sidebar a signed-out visitor sees: the same layout as signed in (the web home canvas, Final
// page). The top rows, starters where the session list goes, and the foot: the Mac app pill, Sign
// in, the legal row.

/** The Sign in row: a green Sign in and what it adds; opens the same GitHub / Google choice the
 *  composer's Sign in pill does. `open` lets the sidebar's Settings ask for it too. */
export function SignInRow({ onSignIn, open: asked, onOpenChange }: { onSignIn: (provider: Provider) => void; open?: boolean; onOpenChange?: (open: boolean) => void }) {
  const [own, setOwn] = useState(false)
  const open = asked ?? own
  const setOpen = (v: boolean) => { setOwn(v); onOpenChange?.(v) }
  const box = useRef<HTMLDivElement>(null)
  useLayer(open, () => setOpen(false))
  const nav = useMenu(open)
  useEffect(() => {
    if (!open) return
    const down = (e: MouseEvent) => { if (!box.current?.contains(e.target as Node)) setOpen(false) }
    addEventListener('mousedown', down)
    return () => removeEventListener('mousedown', down)
  })
  return (
    <div className="signin-row" ref={box}>
      {open && (
        <div className="cz-menu signin-menu" role="menu" aria-label="Sign in" {...nav}>
          <button type="button" role="menuitem" onClick={() => { setOpen(false); onSignIn('github') }}>{gh(14)}Continue with GitHub</button>
          <button type="button" role="menuitem" onClick={() => { setOpen(false); onSignIn('google') }}>{google(14)}Continue with Google</button>
        </div>
      )}
      <button type="button" className="side-acct" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className="go">Sign in</span>
        <span className="t">25¢ free, $1 with GitHub</span>
      </button>
    </div>
  )
}

interface Props {
  /** New session: the landing's composer. */
  onNew: () => void
  chip: ChipSpec | null
  onDocs: () => void
  /** Sign in, taking `prompt` along to start once back. */
  onSignIn: (provider: Provider, prompt?: string) => void
}

export function SignedOutSide({ onNew, chip, onDocs, onSignIn }: Props) {
  const [ask, setAsk] = useState(false)
  return (<>
    <SideNav onNew={onNew} newOn onSearch={onNew} onDocs={onDocs} onSettings={() => setAsk(true)} />
    <Starters onStart={(s) => onSignIn('github', s.prompt || undefined)} />
    <div className="side-foot">
      {chip && <SidePill dot="go" lead="Frog for Mac" rest="$0 a token" action="Get" href={chip.href} />}
      <SignInRow onSignIn={(p) => onSignIn(p)} open={ask} onOpenChange={setAsk} />
      <LegalRow />
    </div>
  </>)
}
