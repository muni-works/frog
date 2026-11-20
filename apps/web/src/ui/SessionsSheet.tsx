// The sheet replaces the sidebar on a phone (frame 4): tapping the title opens it over the
// conversation. The account first, with the plan or credit in words and Get a plan when there's
// no plan; New session and Search; the sessions by day, each one's state in words and the orange
// dot when it needs you; Settings at the foot. Signed out, Sign in. The open session's own
// actions (the desktop's title menu and the inspector's door) are on its row's ⋯.
import { useMemo, useState } from 'react'
import type { Account, Provider } from '../auth'
import { firstName } from '../auth'
import type { SessionSummary } from '../cloud/protocol'
import type { Thread } from '../engine/thread'
import { leftLine } from '../wall'
import { FREE_CENTS, FREE_GITHUB_CENTS, weekShare } from '../plans'
import { day, look } from './SessionList'
import { Sheet } from './Sheet'

export interface SessionsSheetProps {
  account: Account | null
  signedIn: boolean
  /** On the free credit (plans.ts onFreeCredit): "Free, 19¢ left". */
  free: boolean
  sessions: SessionSummary[]
  thread: (id: string) => Thread
  title: (s: SessionSummary) => string
  current: string | null
  onClose: () => void
  onOpen: (id: string) => void
  onNew: () => void
  onSearch: () => void
  onSettings: () => void
  onDocs: () => void
  onPlans: () => void
  onSignIn: (provider: Provider) => void
  /** The open session's actions. */
  onRename?: () => void
  onArchive?: () => void
  onDelete?: () => void
  onInspector?: () => void
}

/** The account row's second line: the plan and the week, or the credit. */
export function accountLine(a: Account | null, free: boolean): string {
  if (!a) return ''
  const sub = a.subscription
  if (sub) {
    const w = weekShare(sub)
    return sub.over ? `${sub.name}, on credit, ${leftLine(Math.max(0, a.credit_cents))} left` : w ? `${sub.name}, ${Math.round(w.share * 100)}% of ${w.kind === 'weekly' ? 'week' : '5 hours'} used` : sub.name
  }
  if (a.credit_cents <= 0) return free ? 'Free, out of credit' : 'Out of credit'
  return free ? `Free, ${leftLine(a.credit_cents)} left` : `${leftLine(a.credit_cents)} of credit`
}

/** A row's state in words: what it asks, that it's working, paused, stopped, or done. */
function stateWords(s: SessionSummary, t: Thread): { text: string; needs: boolean } {
  const l = look(s, t, false)
  if (l.glyph === 'ask') return { text: l.detail ?? 'Needs you', needs: true }
  if (l.glyph === 'paused') return { text: 'Paused, out of credit', needs: true }
  if (l.glyph === 'run') return { text: l.detail ? `Working, ${l.detail.replace(/…$/, '')}` : 'Working', needs: false }
  if (l.glyph === 'fail') return { text: s.state === 'error' ? "Couldn't start" : 'Stopped on an error', needs: false }
  if (!t.turns.length && s.state !== 'error' && !s.last_turn) return { text: s.repo ? s.repo : 'Not started', needs: false }
  return { text: s.pr ? 'Done, opened a pull request' : 'Done', needs: false }
}

export function SessionsSheet(p: SessionsSheetProps) {
  const [acts, setActs] = useState(false)
  const groups = useMemo(() => {
    const now = Date.now()
    const out: { name: string; rows: SessionSummary[] }[] = []
    for (const s of [...p.sessions].filter((s) => !s.archived || s.id === p.current).sort((a, b) => b.updated - a.updated).slice(0, 60)) {
      const name = day(s.updated, now)
      const g = out.find((x) => x.name === name)
      if (g) g.rows.push(s)
      else out.push({ name, rows: [s] })
    }
    return out
  }, [p.sessions, p.current])
  const a = p.account
  const who = firstName(a) ?? (p.signedIn ? 'Signed in' : 'Frog')
  return (
    <Sheet label="Sessions" onClose={p.onClose} className="ss" tall>
      {({ closeThen }) => (<>
        {p.signedIn ? (
          <div className="ss-acct sheet-head">
            {a?.handle ? <img className="ss-av" src={`https://github.com/${encodeURIComponent(a.handle)}.png?size=72`} alt="" width={36} height={36} />
              : a?.image ? <img className="ss-av" src={a.image} alt="" width={36} height={36} referrerPolicy="no-referrer" />
              : <span className="ss-av" aria-hidden="true">{who.slice(0, 1)}</span>}
            <button type="button" className="ss-who" onClick={() => closeThen(p.onSettings)} aria-label={`${who}, ${accountLine(a, p.free)}, open Settings`}>
              <b>{who}</b><span>{accountLine(a, p.free)}</span>
            </button>
            {a && !a.subscription && <button type="button" className="f-btn f-btn--prominent ss-get" onClick={() => closeThen(p.onPlans)}>Get a plan</button>}
          </div>
        ) : (
          <div className="ss-acct sheet-head">
            <span className="mark ss-av" aria-hidden="true" />
            <span className="ss-who"><b>Frog</b><span>{leftLine(FREE_CENTS)} free to start, {leftLine(FREE_GITHUB_CENTS)} with GitHub</span></span>
            <button type="button" className="f-btn f-btn--prominent ss-get" onClick={() => closeThen(() => p.onSignIn('github'))}>Sign in</button>
          </div>
        )}
        <div className="ss-two">
          <button type="button" className="f-btn f-btn--bordered" onClick={() => closeThen(p.onNew)}>New session</button>
          {p.signedIn ? <button type="button" className="f-btn f-btn--bordered" onClick={() => closeThen(p.onSearch)}>Search</button>
            : <button type="button" className="f-btn f-btn--bordered" onClick={() => closeThen(p.onDocs)}>Documentation</button>}
        </div>
        {p.signedIn && !groups.length && <p className="det wrap ss-none">No sessions yet. What you start shows up here, on every device you sign in on.</p>}
        {groups.map((g) => (
          <div key={g.name} className="ss-group" role="group" aria-label={g.name}>
            <div className="ss-gl">{g.name}</div>
            {g.rows.map((s) => {
              const st = stateWords(s, p.thread(s.id))
              const on = s.id === p.current
              return (
                <div key={s.id} className={`ss-item${on ? ' on' : ''}`}>
                  <button type="button" className="ss-row" aria-current={on ? 'page' : undefined} onClick={() => closeThen(() => p.onOpen(s.id))}>
                    {st.needs && <span className="ss-dot" role="img" aria-label="Needs you" />}
                    <span className="ss-l"><b>{p.title(s)}</b><span>{st.text}</span></span>
                  </button>
                  {on && (p.onRename || p.onInspector) && (
                    <button type="button" className="ss-more" aria-label="This session's actions" aria-expanded={acts} onClick={() => setActs(!acts)}>
                      <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.8" /><circle cx="12" cy="12" r="1.8" /><circle cx="19" cy="12" r="1.8" /></svg>
                    </button>
                  )}
                  {on && acts && (
                    <div className="ss-acts" role="group" aria-label="This session">
                      {p.onInspector && <button type="button" className="f-btn f-btn--bordered" onClick={() => closeThen(p.onInspector!)}>Preview and changes</button>}
                      {p.onRename && <button type="button" className="f-btn f-btn--bordered" onClick={() => closeThen(p.onRename!)}>Rename</button>}
                      {p.onArchive && <button type="button" className="f-btn f-btn--bordered" onClick={() => closeThen(p.onArchive!)}>{s.archived ? 'Unarchive' : 'Archive'}</button>}
                      {p.onDelete && <button type="button" className="f-btn f-btn--bordered ss-del" onClick={() => closeThen(p.onDelete!)}>Delete</button>}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        ))}
        <div className="ss-foot">
          {p.signedIn && <button type="button" className="ss-row" onClick={() => closeThen(p.onSettings)}><span className="ss-l"><b>Settings</b></span><span className="ss-ch" aria-hidden="true">›</span></button>}
          <button type="button" className="ss-row" onClick={() => closeThen(p.onDocs)}><span className="ss-l"><b>Documentation</b></span><span className="ss-ch" aria-hidden="true">›</span></button>
        </div>
      </>)}
    </Sheet>
  )
}
