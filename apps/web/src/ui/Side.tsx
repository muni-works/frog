import type { ReactNode } from 'react'
import { Muni } from './Pond'

// The sidebar's shared pieces, signed out and signed in alike (design: the web home canvas,
// Final page; the Mac sidebar draws the same): the top rows, the starters for an empty list,
// and the foot (one status pill, the account row, the legal row).

/** 16 px stroke icons on a 16 grid, as drawn in the design. */
const IC = {
  new: 'M8 3.5v9M3.5 8h9',
  search: 'M7 3a4 4 0 1 0 0 8a4 4 0 1 0 0-8M10 10l3 3',
  customize: 'M3 5h5M12 5h1M3 11h1M8 11h5M10 3.4a1.6 1.6 0 1 0 0 3.2a1.6 1.6 0 1 0 0-3.2M6 9.4a1.6 1.6 0 1 0 0 3.2a1.6 1.6 0 1 0 0-3.2',
  docs: 'M3 3.5h4a1.5 1.5 0 0 1 1.5 1.5v8A1.5 1.5 0 0 0 7 11.5H3zM13 3.5H9.5A1.5 1.5 0 0 0 8 5M13 3.5v8H9.5',
  settings: 'M8 6a2 2 0 1 0 0 4a2 2 0 1 0 0-4M8 2.5v1.5M8 12v1.5M2.5 8H4M12 8h1.5M4.1 4.1l1 1M10.9 10.9l1 1M4.1 11.9l1-1M10.9 5.1l1-1',
}

function SideIcon({ d }: { d: string }) {
  return (
    <svg className="side-ic" aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor"
      strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"><path d={d} /></svg>
  )
}

function SideRow({ icon, label, kb, on, onClick, title }: { icon: string; label: string; kb?: string; on?: boolean; onClick: () => void; title?: string }) {
  return (
    <button type="button" className={`side-row${on ? ' on' : ''}`} onClick={onClick} title={title}>
      <SideIcon d={icon} />
      <span className="side-row-t">{label}</span>
      {kb && <span className="kb">{kb}</span>}
    </button>
  )
}

/** The Documentation row, hidden for now. */
const SHOW_DOCS = false

/** New session and Search, then Customize and Settings (Documentation when it's back). */
export function SideNav({ onNew, onSearch, onCustomize, onDocs, onSettings, newOn }: {
  onNew: () => void
  onSearch: () => void
  onCustomize: () => void
  onDocs: () => void
  onSettings: () => void
  newOn?: boolean
}) {
  return (
    <nav aria-label="Main" className="side-nav">
      <SideRow icon={IC.new} label="New session" kb="⌘N" on={newOn} onClick={onNew} />
      <SideRow icon={IC.search} label="Search" kb="⌘K" onClick={onSearch} />
      <SideRow icon={IC.customize} label="Customize" onClick={onCustomize} title="Theme, density and detail" />
      {/* Documentation is hidden for now (Cam, 2026-11-19); `onDocs` stays wired for its return. */}
      {SHOW_DOCS && <SideRow icon={IC.docs} label="Documentation" onClick={onDocs} />}
      <SideRow icon={IC.settings} label="Settings" kb="⌘," onClick={onSettings} />
    </nav>
  )
}

export interface Starter {
  title: string
  /** The muted second line: how long and what it costs, or what it needs first. */
  detail: string
  /** What the session starts with. */
  prompt: string
  /** Needs GitHub connected first. */
  github?: boolean
}

/** Signed out, or signed in with nothing yet: a first session a click away. Costs are what a
 *  run typically spends at Frog Cloud's per-token prices. */
export const STARTERS: Starter[] = [
  { title: 'Make a tiny pomodoro timer', detail: 'About a minute   about 4¢', prompt: 'Make a tiny pomodoro timer' },
  { title: 'Build a Markdown notes app', detail: 'About two minutes   about 9¢', prompt: 'Build a Markdown notes app that saves locally' },
  { title: 'Write a CLI that renames photos', detail: 'About a minute   about 5¢', prompt: 'Write a CLI that renames photos by date taken' },
  { title: 'Fix a bug in one of my repos', detail: 'Connects GitHub first', prompt: '', github: true },
]

export function Starters({ items = STARTERS, onStart }: { items?: Starter[]; onStart: (s: Starter) => void }) {
  return (
    <div className="side-starters" role="group" aria-label="Start with one of these">
      <span className="side-gl">Start with one of these</span>
      {items.map((s) => (
        <button key={s.title} type="button" className="side-st" onClick={() => onStart(s)}>
          <b>{s.title}</b><span>{s.detail}</span>
        </button>
      ))}
    </div>
  )
}

export type PillDot = 'go' | 'wait' | 'update'

/** The foot's one capsule: a dot, one line, a small action. Nothing to say, no pill. */
export function SidePill({ dot, lead, rest, action, href, onAction }: {
  dot: PillDot
  lead: string
  rest?: string
  action: string
  href?: string
  onAction?: () => void
}) {
  const body: ReactNode = (<>
    <span className={`side-pill-dot ${dot}`} aria-hidden="true" />
    <span className="side-pill-t"><b>{lead}</b>{rest && <>&ensp;{rest}</>}</span>
    <span className="side-pill-go">{action}</span>
  </>)
  return href
    ? <a className="side-pill" href={href}>{body}</a>
    : <button type="button" className="side-pill" onClick={onAction}>{body}</button>
}

/** Pricing, Privacy, Terms, and the muni mark: always at the very bottom. */
export function LegalRow() {
  return (
    <div className="side-legal">
      <a href="https://frog.toys/pricing">Pricing</a>
      <a href="https://frog.toys/privacy">Privacy</a>
      <a href="https://frog.toys/terms">Terms</a>
      <a className="side-legal-muni" href="https://muni.works" target="_blank" rel="noreferrer" aria-label="Municipal Robotics"><Muni /></a>
    </div>
  )
}
