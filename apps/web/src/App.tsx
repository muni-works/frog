import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useAlerts } from './alerts'
import { finishSignIn, firstName, me, savedKey, signIn, signOut, API, AuthError, type Account } from './auth'
import type { ConnectionState } from './cloud/client'
import type { SessionSummary } from './cloud/protocol'
import type { Image, Mode } from './cloud/protocol'
import { idOf, spec, useModels } from './models'
import { clearThreads, outOfCredits, pickStarters, useCloud, useRepos, useSessions, useThreads } from './store'
import { Composer } from './ui/Composer'
import { Pond, HowItWorks, Trust, Muni } from './ui/Pond'
import { Inspector } from './ui/Inspector'
import { SessionList } from './ui/SessionList'
import { Starting } from './ui/Starting'
import { creditLine, Palette, Settings, type Command } from './ui/Overlays'
import { Transcript } from './ui/Transcript'

/** `pick`: open the composer's repo menu (back from sign-in, or ⌘K Connect a repo). */
/** Placeholder session ids, shown while POST /v1/sessions is in flight. */
const PENDING = 'pending-'

type View = { kind: 'session'; id: string } | { kind: 'new'; repo?: string; pick?: boolean }

/** Dev only: a key for the mock gateway (any non-empty key is an account there). Skips sign-in. */
const DEV_KEY = import.meta.env.DEV ? (import.meta.env.VITE_DEV_KEY as string | undefined) : undefined

const Icon = ({ d }: { d: string }) => (
  <svg aria-hidden="true" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" style={{ flex: 'none' }}><path d={d} /></svg>
)
const icons = {
  new: 'M12 5v14M5 12h14',
  search: 'M11 4a7 7 0 1 0 0 14a7 7 0 1 0 0-14M20 20l-4-4',
}

function Mark({ size = 22 }: { size?: number }) {
  return <span className="mark" style={{ width: size, height: size }} aria-hidden="true" />
}



export default function App() {
  const [key, setKey] = useState<string | null>(DEV_KEY ?? savedKey())
  const [account, setAccount] = useState<Account | null>(null)
  const [authError, setAuthError] = useState<string | null>(null)
  const [leaving, setLeaving] = useState(false)
  const [view, setView] = useState<View>({ kind: 'new' })
  const [palette, setPalette] = useState(false)
  const [settings, setSettings] = useState(false)
  const [inspector, setInspector] = useState(false)
  const [toast, setToast] = useState<string | null>(null)
  const [draft, setDraft] = useState<string | undefined>()
  /** Sessions still opening: their first message (and repo), from the moment you send until the
   * first turn starts. The placeholder and then the real session show the same bubble and one
   * status line, so the hand-over doesn't flicker between two different "starting" states. */
  const [opening, setOpening] = useState<Record<string, { text: string; repo?: string; at: number }>>({})
  // Follow-ups typed while Frog works wait here (per session) and go together, in order, as the
  // next turn once this one ends, like the Mac app. × takes one back into the field.
  const [queue, setQueue] = useState<Record<string, { text: string; images: Image[] }[]>>({})
  const [restore, setRestore] = useState<{ text: string; images: Image[] } | null>(null)
  const [conn, setConn] = useState<Record<string, ConnectionState>>({})
  const [menuOpen, setMenuOpen] = useState(false)
  // Phone layout: the sidebar is a drawer, closed whenever you go somewhere.
  const [drawer, setDrawer] = useState(false)
  const [renaming, setRenaming] = useState<string | null>(null)
  // What a new session starts with: null model = the gateway's default.
  // Kept across reloads (and the GitHub round trip), so what you picked signed out still holds.
  const [newModel, setNewModelState] = useState<string | null>(() => { try { return localStorage.getItem('frog.newModel') } catch { return null } })
  const [newMode, setNewModeState] = useState<Mode>(() => { try { return (localStorage.getItem('frog.newMode') as Mode) || 'auto' } catch { return 'auto' } })
  const setNewModel = (m: string | null) => { setNewModelState(m); try { if (m) localStorage.setItem('frog.newModel', m); else localStorage.removeItem('frog.newModel') } catch { /* private mode */ } }
  const setNewMode = (m: Mode) => { setNewModeState(m); try { localStorage.setItem('frog.newMode', m) } catch { /* private mode */ } }
  const toastTimer = useRef(0)

  const cloud = useCloud(key)
  const models = useModels(DEV_KEY ? null : key)
  const repoList = useRepos(cloud)
  const { sessions, error: listError, setSessions } = useSessions(cloud)
  const current = view.kind === 'session' ? sessions.find((s) => s.id === view.id) : undefined
  // Stream only the open session. Attaching to a session wakes its sandbox, and the sockets
  // reconnect after a sandbox sleeps, so streaming every running session kept them all awake
  // (and the account at its running-sandbox limit). Other sessions show the listed state.
  const live = useMemo(() => (current && !current.id.startsWith(PENDING) ? [current.id] : []), [current])
  const thread = useThreads(cloud, live)
  const ct = current ? thread(current.id) : null
  const title = (s: SessionSummary) => thread(s.id).title ?? s.title
  // The turn ended: what was queued goes as the next turn, one Submit with the rest as `more`.
  useEffect(() => {
    if (!current || !ct || ct.running || opening[current.id]) return
    const q = queue[current.id]
    if (!q?.length) return
    const [head, ...rest] = q
    cloud?.send(current.id, { op: 'submit', text: head.text, ...(head.images.length ? { images: head.images } : {}), ...(rest.length ? { more: rest.map((m) => ({ text: m.text, ...(m.images.length ? { images: m.images } : {}) })) } : {}) })
    setQueue((all) => ({ ...all, [current.id]: [] }))
  }, [current, ct, queue, opening, cloud])
  // The first turn started: the session is open.
  useEffect(() => {
    if (current && ct && ct.turns.length > 0 && opening[current.id]) setOpening(({ [current.id]: _, ...rest }) => rest)
  }, [current, ct, opening])
  // Alerts: the tab title's badge and background notifications, from every streamed session.
  useAlerts(useMemo(() => sessions.map((s) => {
    const t = thread(s.id)
    const waiting = t.ask ? `Can I ${t.ask.name.toLowerCase()} ${t.ask.arg}?` : t.question ? t.question.question : t.elicitation ? `${t.elicitation.server} needs your input` : null
    return { id: s.id, title: t.title ?? s.title, waiting, finished: !t.running && t.ended?.type === 'complete' }
  }), [sessions, thread]), useCallback((id: string) => setView({ kind: 'session', id }), []))

  useEffect(() => setDrawer(false), [view])
  const Burger = () => (
    <button type="button" className="burger" aria-label="Sessions" aria-expanded={drawer} onClick={() => setDrawer(!drawer)}>
      <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M4 7h16M4 12h16M4 17h16" /></svg>
    </button>
  )

  const say = (t: string) => { setToast(t); clearTimeout(toastTimer.current); toastTimer.current = window.setTimeout(() => setToast(null), 3200) }

  // Sign-in: finish a GitHub round trip if the URL has one, else check the saved key.
  useEffect(() => {
    finishSignIn().then(async (done) => {
      if (done) {
        setKey(done.key); setAccount(done.account)
        // The message typed before signing in starts its conversation as soon as we're in.
        if (done.after) setPending(done.after)
        return
      }
      const k = savedKey()
      if (!k || DEV_KEY) return
      setAccount(await me(k))
    }).catch((e) => {
      if (e instanceof AuthError && e.status === 401) { signOut(); clearThreads(); setKey(null); return }
      setAuthError(e instanceof AuthError ? e.code : String(e))
    })
  }, [])

  useEffect(() => cloud?.watch((id, s) => setConn((all) => ({ ...all, [id]: s }))), [cloud])

  // What you sent, shown at once: until the engine starts it as a turn it waits here, with a
  // clock (queued until the socket is up), one tick (on the wire), or Not sent.
  type Out = { id: number; text: string; images: Image[]; state: 'sending' | 'sent' | 'failed'; at: number; seen: number }
  const [outbox, setOutbox] = useState<Record<string, Out[]>>({})
  const outSeq = useRef(0)
  const send = useCallback((id: string, text: string, images: Image[] = []) => {
    setOutbox((o) => ({ ...o, [id]: [...(o[id] ?? []), { id: ++outSeq.current, text, images, state: 'sending', at: Date.now(), seen: thread(id).turns.filter((u) => u.input === text).length }] }))
    cloud?.send(id, { op: 'submit', text, ...(images.length ? { images } : {}) })
  }, [cloud, thread])


  const [pending, setPending] = useState<string | null>(null)
  const starterChips = useMemo(() => pickStarters(3, !key).map((text) => ({ text })), [key])
  const start = useCallback(async (text: string, repo?: string, images: Image[] = []) => {
    if (!cloud) return
    // Open the session at once, as a placeholder, and swap in the real one when the gateway
    // answers: starting a conversation should feel instant, not wait on a round trip.
    const temp = `${PENDING}${Date.now()}`
    setOpening((o) => ({ ...o, [temp]: { text, repo, at: Date.now() } }))
    setSessions((all) => [{ id: temp, title: text.length > 60 ? text.slice(0, 57) + '…' : text, repo: repo ?? '', branch: '', state: 'starting', updated: Date.now() }, ...all])
    setView({ kind: 'session', id: temp })
    try {
      const s0 = await cloud.gateway.create({ ...(repo ? { repo } : {}), ...(newModel ? { model: spec(newModel) } : {}) })
      // A session without a repo comes back titled "New session" until the engine names it.
      const s = { ...s0, title: s0.repo ? s0.title : text.length > 60 ? text.slice(0, 57) + '…' : text }
      setSessions((all) => [s, ...all.filter((x) => x.id !== s.id && x.id !== temp)])
      setOpening(({ [temp]: first, ...rest }) => ({ ...rest, [s.id]: first ?? { text, repo, at: Date.now() } }))
      setView((v) => (v.kind === 'session' && v.id === temp ? { kind: 'session', id: s.id } : v))
      if (newMode !== 'default') cloud.send(s.id, { op: 'set_mode', mode: newMode })
      send(s.id, text, images) // queued until the session's socket is live
    } catch (e) {
      setSessions((all) => all.filter((x) => x.id !== temp))
      setOpening(({ [temp]: _, ...rest }) => rest)
      setView((v) => (v.kind === 'session' && v.id === temp ? { kind: 'new', repo } : v))
      setDraft(text)
      say(`Couldn't start a sandbox: ${e instanceof Error ? e.message : e}`)
    }
  }, [cloud, send, setSessions, newModel, newMode])
  useEffect(() => { if (pending && cloud) { setPending(null); start(pending) } }, [pending, cloud, start])

  const decide = useCallback((id: string, allow: boolean) => {
    const ask = thread(id).ask
    if (ask) cloud?.send(id, { op: 'permission', id: ask.id, decision: allow ? 'allow' : 'deny' })
  }, [thread, cloud])

  const rename = (s: SessionSummary, to: string) => {
    const t = to.trim()
    setRenaming(null)
    if (!t || t === title(s)) return
    cloud?.send(s.id, { op: 'set_title', title: t }) // the engine's titled event renames it everywhere
    setSessions((all) => all.map((x) => (x.id === s.id ? { ...x, title: t } : x)))
  }
  const remove = async (s: SessionSummary) => {
    if (!confirm(`Delete "${title(s)}"? Its sandbox, changes and conversation are gone for good.`)) return
    try {
      await cloud?.gateway.remove(s.id)
      setSessions((all) => all.filter((x) => x.id !== s.id))
      setView({ kind: 'new' })
    } catch (e) {
      say(`Couldn't delete: ${e instanceof Error ? e.message : e}`)
    }
  }

  // Sandboxes that never started have nothing to lose: clear them together, without a prompt each.
  const clear = async (ids: string[]) => {
    const gone = (await Promise.allSettled(ids.map((id) => cloud!.gateway.remove(id)))).map((r, i) => (r.status === 'fulfilled' ? ids[i] : null)).filter(Boolean)
    setSessions((all) => all.filter((x) => !gone.includes(x.id)))
    if (gone.length < ids.length) say(`Couldn't clear ${ids.length - gone.length} of them. Try again.`)
  }

  // Commit and push are asks to the agent, so they show up in the conversation like any step.
  const commit = (s: SessionSummary) => send(s.id, 'Commit the changes with a clear message.')
  const push = (s: SessionSummary) => send(s.id, s.pr ? `Commit the changes and push to ${s.pr}.` : 'Commit the changes, push the branch and open a pull request.')

  const leave = (after: string | null) => { setLeaving(true); signIn(after ?? undefined).catch(() => setLeaving(false)) }

  // Keyboard: ⌘K palette, ⌘N new, ⌘, settings, ⌘↩ / ⌘. answer the current ask.
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey)) return
      if (e.key === 'k') { e.preventDefault(); setPalette((p) => !p) }
      if (!key) return
      if (e.key === 'n') { e.preventDefault(); setView({ kind: 'new' }) }
      if (e.key === ',') { e.preventDefault(); setSettings(true) }
      if (current && ct?.ask && e.key === 'Enter') { e.preventDefault(); decide(current.id, true) }
      if (current && ct?.ask && e.key === '.') { e.preventDefault(); decide(current.id, false) }
    }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [key, current, ct, decide])

  const commands: Command[] = [
    { id: 'c-new', label: 'New session', hint: '⌘N', run: () => key && setView({ kind: 'new' }) },
    { id: 'c-repo', label: 'Connect a repo', run: () => key && setView({ kind: 'new', pick: true }) },
    { id: 'c-settings', label: 'Settings', hint: '⌘,', run: () => key && setSettings(true) },
    ...(current ? [
      { id: 'c-rename', label: 'Rename session', run: () => setRenaming(current.id) },
      { id: 'c-delete', label: 'Delete session', run: () => remove(current) },
    ] : []),
    { id: 'c-insp', label: inspector ? 'Hide inspector' : 'Show inspector', run: () => setInspector(!inspector) },
    { id: 'c-theme', label: 'Toggle dark mode', run: () => { const r = document.documentElement; r.dataset.theme = r.dataset.theme === 'dark' ? 'light' : 'dark' } },
  ]

  const Nav = () => (
    <nav aria-label="Main" className="nav">
      <button type="button" className="row big" onClick={() => setView({ kind: 'new' })}><Icon d={icons.new} /><span style={{ flex: 1 }}>New session</span><span className="kb">⌘N</span></button>
    </nav>
  )




  // ---------- signed out ----------
  // Ticks follow the socket; a message leaves the outbox when its turn starts.
  useEffect(() => {
    setOutbox((o) => {
      let changed = false
      const next: typeof o = {}
      for (const [id, list] of Object.entries(o)) {
        const started = (text: string) => thread(id).turns.filter((u) => u.input === text).length
        const live = conn[id]?.state === 'live'
        const dead = conn[id]?.state === 'refused' || conn[id]?.state === 'closed'
        // Delivered: a turn with this text started since it was sent.
        const kept = list.filter((m) => started(m.text) <= m.seen).map((m) => {
          const state: Out['state'] = m.state === 'failed' || dead || (!live && Date.now() - m.at > 20_000) ? 'failed' : live ? 'sent' : 'sending'
          return state === m.state ? m : { ...m, state }
        })
        if (kept.length !== list.length || kept.some((m, i) => m !== list[i])) changed = true
        if (kept.length) next[id] = kept
      }
      return changed ? next : o
    })
  })
  const resend = (id: string, n: number) => {
    const m = outbox[id]?.find((x) => x.id === n)
    if (!m) return
    setOutbox((o) => ({ ...o, [id]: (o[id] ?? []).filter((x) => x.id !== n) }))
    send(id, m.text, m.images)
  }

  if (!key) return (
    <div className="win">
      <main className="main home">
        {authError && <div role="status" className="banner warn">Sign-in didn't finish ({authError}). Try again.</div>}
        <div className="home-hero">
          <Pond />
          <Mark size={56} />
          <span className="beta-pill"><i />Now in beta · $5 free to start</span>
          <h1>What should we work on?</h1>
          <HowItWorks />
          <Trust />
        </div>
        <div className="dock"><div>
          <Composer repo="Connect a repo" onSend={(text) => leave(text)} onConnect={(text) => leave(text || null)} onSignIn={() => leave(null)} autoFocus chips={starterChips}
            model={newModel ?? models[0]?.id} models={models} onModel={setNewModel} mode={newMode} onMode={setNewMode} />
          {leaving && <div className="det" style={{ textAlign: 'center' }}>Opening GitHub… your message is saved.</div>}
        </div></div>
        <footer className="muni-foot"><a href="https://muni.works" target="_blank" rel="noreferrer" aria-label="Municipal Robotics"><Muni /></a></footer>
      </main>
    </div>
  )

  // ---------- signed in ----------
  const running = sessions.filter((s) => thread(s.id).running || s.state === 'running' || s.state === 'starting').length
  const adds = ct?.changes.reduce((n, c) => n + c.added, 0) ?? 0
  const dels = ct?.changes.reduce((n, c) => n + c.removed, 0) ?? 0
  const paused = ct ? outOfCredits(ct) : false
  const cs = current ? conn[current.id] : undefined

  return (
    <div className={`win ${drawer ? 'drawer' : ''}`}>
      <div className="side-scrim" onClick={() => setDrawer(false)} />
      <aside className="side f-glass">
        <div className="brand"><Mark /><b>Frog</b></div>
        <Nav />
        <SessionList sessions={sessions} thread={thread} title={title} current={current?.id ?? null} error={listError}
          onOpen={(id) => { setView({ kind: 'session', id }); setDrawer(false) }} onClear={clear} />
        <button type="button" className="row" onClick={() => setSettings(true)} title="Settings ⌘,">
          {account?.handle ? <img className="avatar" src={`https://github.com/${encodeURIComponent(account.handle)}.png?size=56`} alt="" width={28} height={28} /> : <Mark size={28} />}
          <div style={{ flex: 1, textAlign: 'left', minWidth: 0 }}>
            <b>{firstName(account) ?? (DEV_KEY ? 'Dev key' : 'Signed in')}</b>
            <div className="det" style={{ color: account && account.credit_cents <= 0 ? 'var(--warn)' : undefined }}>{account ? creditLine(account) : DEV_KEY ? 'local gateway' : ''}{running ? ` · ${running} running` : ''}</div>
          </div>
          <span className="det">⚙</span>
        </button>
      </aside>

      <main className="main">
        {current ? (<div className="titlebar">
          <Burger />
          <div style={{ flex: 1, minWidth: 0 }}>
            {current && renaming === current.id ? (
              <input className="f-field title-edit" autoFocus defaultValue={title(current)} aria-label="Session name"
                onBlur={(e) => rename(current, e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter') rename(current, (e.target as HTMLInputElement).value); if (e.key === 'Escape') setRenaming(null) }} />
            ) : (
              <b style={{ fontSize: 14 }} onDoubleClick={() => current && setRenaming(current.id)} title={current ? 'Double-click to rename' : undefined}>{current ? title(current) : 'New session'}</b>
            )}
            <div className="det">{current ? `${current.repo || 'No repo'} · ${current.branch}${current.pr ? ` · PR ${current.pr}` : ''}${paused ? ' · paused' : ''}${ct?.context?.used ? ` · ${Math.round(ct.context.used / 1000)}k of ${Math.round(ct.context.window / 1000)}k context` : ''}` : 'Runs in a private Frog Cloud sandbox'}</div>
          </div>
          {current && <span style={{ fontSize: 12, color: cs?.state === 'live' ? 'var(--place-cloud)' : 'var(--muted)' }}>{cs?.state === 'live' ? 'In Frog Cloud' : cs?.state === 'connecting' ? (cs.attempt ? 'Reconnecting…' : 'Connecting…') : cs?.state === 'refused' ? 'Update Frog to continue' : cs?.state === 'closed' ? (cs.code === 4004 ? 'Session deleted' : 'Disconnected') : ''}</span>}
          {current && <button type="button" className="ic-btn" onClick={() => setInspector(!inspector)} aria-pressed={inspector} aria-label={inspector ? 'Hide inspector' : 'Show inspector'} title={inspector ? 'Hide inspector' : 'Inspector'}>
            <svg aria-hidden="true" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="4" width="18" height="16" rx="3" /><path d="M15 4v16" />{inspector && <path d="M15 4h3a3 3 0 0 1 3 3v10a3 3 0 0 1-3 3h-3z" fill="currentColor" stroke="none" opacity=".35" />}</svg>
          </button>}
          {current && (
            <div className="title-menu">
              <button type="button" className="ic-btn" aria-label="Session menu" title="Session menu" aria-expanded={menuOpen} onClick={() => setMenuOpen(!menuOpen)}>
                <svg aria-hidden="true" width="17" height="17" viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.7" /><circle cx="12" cy="12" r="1.7" /><circle cx="19" cy="12" r="1.7" /></svg>
              </button>
              {menuOpen && (
                <div className="f-card cz-menu" role="menu" style={{ top: 30, bottom: 'auto', right: 0, left: 'auto', width: 180 }} onMouseLeave={() => setMenuOpen(false)}>
                  <button type="button" role="menuitem" onClick={() => { setMenuOpen(false); setRenaming(current.id) }}>Rename</button>
                  <button type="button" role="menuitem" style={{ color: 'var(--warn)' }} onClick={() => { setMenuOpen(false); remove(current) }}>Delete session</button>
                </div>
              )}
            </div>
          )}
        </div>) : <div className="phone-bar floating"><Burger /><b>Frog</b></div>}

        {view.kind === 'session' && current && ct && (<>
          <div className="scroll" ref={(el) => { if (el) el.scrollTop = el.scrollHeight }}><div className="col">
            {cs?.state === 'refused' && <div role="status" className="banner warn"><span style={{ flex: 1 }}>Update Frog to continue. This sandbox speaks a different protocol than this page.</span>{cs.refused.upgrade ? <a className="f-btn f-btn--bordered f-btn--small" href={cs.refused.upgrade} style={{ textDecoration: 'none' }}>Update</a> : <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => location.reload()}>Reload</button>}</div>}
            {cs?.state === 'closed' && cs.code === 4004 && <div role="status" className="banner warn">This session was deleted.</div>}
            {ct.turns.length === 0 && !opening[current.id] && cs?.state !== 'refused' && current.state !== 'error' && (
              <div className="ghost" role="status" aria-label={current.state === 'starting' ? 'Starting the sandbox' : 'Loading'}>
                <div className="ghost-me" />
                <div className="ghost-line" style={{ width: '92%' }} />
                <div className="ghost-line" style={{ width: '78%' }} />
                <div className="ghost-line" style={{ width: '54%' }} />
              </div>
            )}
            {opening[current.id] && ct.turns.length === 0 && !outbox[current.id]?.length && current.state !== 'error' && (
              <div className="turn"><div className="me">{opening[current.id].text}</div></div>
            )}
            <Transcript thread={ct} models={models} onDecide={(a) => decide(current.id, a)}
              onAnswer={(choices, other) => ct.question && cloud?.send(current.id, { op: 'answer', id: ct.question.id, choices, ...(other ? { other } : {}) })}
              onElicit={(action, content) => ct.elicitation && cloud?.send(current.id, { op: 'elicit', id: ct.elicitation.id, action, ...(content ? { content } : {}) })}
              onRetry={() => send(current.id, 'Try that again.')}
              outbox={outbox[current.id]} onResend={(n) => resend(current.id, n)}
              onEdit={(text) => setRestore({ text, images: [] })} />
            {opening[current.id] && ct.turns.length === 0 && current.state !== 'error' && (
              <Starting repo={opening[current.id].repo} since={opening[current.id].at}
                step={current.id.startsWith(PENDING) ? 0 : cs?.state === 'live' ? 2 : 1} />
            )}
            {/* A sandbox that couldn't start says so here, by the composer, not above the conversation. */}
            {current.state === 'error' && <div role="status" className="banner warn"><span style={{ flex: 1 }}>{current.error ?? "The sandbox couldn't start."}</span><button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => remove(current)}>Delete</button></div>}
            {paused && (
              <section className="cardx outs" aria-label="Out of credits">
                <b style={{ fontSize: 15 }}>You're out of cloud credits</b>
                <div className="det wrap" style={{ marginTop: -4 }}>Nothing is lost. The sandbox, the changes and this conversation stay put.</div>
                <div className="out" style={{ borderColor: 'var(--frog)' }}>
                  <div style={{ flex: 1 }}><b>Add credit</b><div className="det wrap">Pay as you go, or go Pro for cloud usage every month. Then keep going here.</div></div>
                  <a className="f-btn f-btn--prominent" href={`${API}/billing`} target="_blank" rel="noreferrer" style={{ textDecoration: 'none' }}>Billing</a>
                </div>
                <div className="out" style={{ borderColor: 'var(--line)' }}>
                  <div style={{ flex: 1 }}><b>Finish on your Mac</b><div className="det wrap">Frog for Mac runs local models for free.</div></div>
                  <a className="f-btn f-btn--bordered" href="/mac" style={{ textDecoration: 'none' }}>Get it</a>
                </div>
                <div style={{ display: 'flex', justifyContent: 'flex-end' }}><button type="button" className="f-btn f-btn--plain" onClick={() => send(current.id, 'Keep going.')}>I added credit, keep going</button></div>
              </section>
            )}
          </div></div>
          <div className="dock">
            {ct.todos.length > 0 && ct.todos.some((t) => t.status !== 'completed') && (
              <div className="plan" aria-label="Plan">
                {ct.todos.map((t, i) => (
                  <div key={i} className={`plan-item ${t.status}`}>
                    <span aria-hidden="true">{t.status === 'completed' ? '✓' : t.status === 'in_progress' ? '●' : '○'}</span>{t.content}
                  </div>
                ))}
              </div>
            )}
            <Composer key={current.id} autoFocus chips={ct.next && !ct.running ? [{ text: ct.next.text, send: true, act: ct.next.act }] : undefined} state={ct.running || opening[current.id] ? 'working' : paused ? 'paused' : 'idle'} startedAt={ct.startedAt} waiting={!!(ct.ask || ct.question || ct.elicitation)}
              repo={current.repo} branch={current.branch} pr={current.pr} adds={adds} dels={dels}
              model={idOf(ct.model)} models={models} onModel={(id) => cloud?.send(current.id, { op: 'set_model', spec: spec(id) })}
              mode={ct.mode ?? 'default'} onMode={(mode) => cloud?.send(current.id, { op: 'set_mode', mode })}
              queued={queue[current.id]} restore={restore} vision={ct.vision}
              onUnqueue={(i) => { const q = queue[current.id] ?? []; setRestore(q[i]); setQueue({ ...queue, [current.id]: q.filter((_, j) => j !== i) }) }}
              onSend={(text, images) => (ct.running || opening[current.id]
                ? setQueue((all) => ({ ...all, [current.id]: [...(all[current.id] ?? []), { text, images }] }))
                : send(current.id, text, images))} onStop={() => cloud?.send(current.id, { op: 'interrupt' })} onGit={() => push(current)} />
          </div>
        </>)}

        {view.kind === 'new' && (
          <div className="main home">
            <div className="home-hero">
              <Pond />
              <Mark size={56} />
              <h1>What should we work on?</h1>
              <HowItWorks />
            </div>
            <div className="dock">
              <Composer repo={view.repo} draft={draft} autoFocus pickRepo={view.pick} chips={starterChips}
                recent={[...new Set(sessions.map((s) => s.repo).filter(Boolean))]} repos={repoList.repos.map((r) => r.name)} install={repoList.install} onRepo={(repo) => setView({ kind: 'new', repo })}
                model={newModel ?? models[0]?.id} models={models} onModel={setNewModel} mode={newMode} onMode={setNewMode}
                onSend={(text, images) => { setDraft(undefined); start(text, view.repo, images) }} />
            </div>
          </div>
        )}

      </main>

      {view.kind === 'session' && current && ct && inspector && (
        <Inspector thread={ct} branch={current.branch} hasPr={!!current.pr} onCommit={() => commit(current)} onPr={() => push(current)} send={(op) => cloud?.send(current.id, op)} />
      )}

      {palette && <Palette commands={commands} sessions={sessions} onOpen={(id) => setView({ kind: 'session', id })} onClose={() => setPalette(false)}
        text={(id) => thread(id).turns.flatMap((u) => [u.input, ...u.entries.filter((e) => e.kind === 'message').map((e) => e.text)]).join('\n')} />}
      {settings && <Settings account={account} models={models} onSignOut={() => { setSettings(false); signOut(); clearThreads(); setKey(null); setAccount(null); setView({ kind: 'new' }) }} onClose={() => setSettings(false)} />}
      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  )
}
