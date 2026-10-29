import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useAlerts } from './alerts'
import { finishSignIn, firstName, me, savedKey, signIn, signOut, API, AuthError, type Account } from './auth'
import type { ConnectionState } from './cloud/client'
import type { SessionSummary } from './cloud/protocol'
import type { Thread } from './engine/thread'
import type { Image, Mode } from './cloud/protocol'
import { idOf, spec, useModels } from './models'
import { outOfCredits, starters, turnError, useCloud, useRepos, useSessions, useThreads } from './store'
import { Composer } from './ui/Composer'
import { Inspector } from './ui/Inspector'
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

function age(ms: number) {
  const s = (Date.now() - ms) / 1000
  if (s < 60) return 'now'
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86_400) return `${Math.floor(s / 3600)}h`
  return new Date(ms).toLocaleDateString(undefined, { weekday: 'short' })
}

/** Status symbol for a session row: the live thread when we have one, else the sandbox state. */
function sym(s: SessionSummary, t: Thread) {
  if (t.ask) return { ch: '!', cls: 'sym ask', detail: `Waiting on you · ${t.ask.name.toLowerCase()} ${t.ask.arg}` }
  if (t.question) return { ch: '?', cls: 'sym ask', detail: `Asks: ${t.question.question}` }
  if (t.elicitation) return { ch: '!', cls: 'sym ask', detail: `${t.elicitation.server} needs your input` }
  if (outOfCredits(t)) return { ch: '', cls: 'sym paused', detail: 'Paused · out of credits' }
  if (t.running) return { ch: '', cls: 'sym ring', detail: 'Working…' }
  if (s.state === 'starting') return { ch: '', cls: 'sym ring', detail: 'Starting the sandbox…' }
  if (s.state === 'error') return { ch: '!', cls: 'sym paused', detail: s.error ?? "The sandbox couldn't start" }
  if (s.state === 'sleeping') return { ch: '', cls: 'sym merged', detail: s.pr ? `Sleeping · ${s.pr}` : 'Sleeping' }
  if (t.ended?.type === 'error') return { ch: '!', cls: 'sym paused', detail: 'Stopped on an error' }
  if (t.ended?.type === 'denied') return { ch: '✕', cls: 'sym merged', detail: 'Stopped · you denied a step' }
  if (t.ended) return { ch: '✓', cls: 'sym done', detail: 'Finished' }
  return { ch: '', cls: 'sym merged', detail: s.pr ? `Bound to ${s.pr}` : s.branch }
}

export default function App() {
  const [key, setKey] = useState<string | null>(DEV_KEY ?? savedKey())
  const [account, setAccount] = useState<Account | null>(null)
  const [authError, setAuthError] = useState<string | null>(null)
  const [leaving, setLeaving] = useState(false)
  const [gate, setGate] = useState<string | null>(null)
  const [view, setView] = useState<View>({ kind: 'new' })
  const [palette, setPalette] = useState(false)
  const [settings, setSettings] = useState(false)
  const [inspector, setInspector] = useState(false)
  const [banner, setBanner] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [draft, setDraft] = useState<string | undefined>()
  /** Sessions shown before the gateway has created them: placeholder id → the first message. */
  const [pending, setPending] = useState<Record<string, string>>({})
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
  const [newModel, setNewModel] = useState<string | null>(null)
  const [newMode, setNewMode] = useState<Mode>('auto')
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
    if (!current || !ct || ct.running || pending[current.id]) return
    const q = queue[current.id]
    if (!q?.length) return
    const [head, ...rest] = q
    cloud?.send(current.id, { op: 'submit', text: head.text, ...(head.images.length ? { images: head.images } : {}), ...(rest.length ? { more: rest.map((m) => ({ text: m.text, ...(m.images.length ? { images: m.images } : {}) })) } : {}) })
    setQueue((all) => ({ ...all, [current.id]: [] }))
  }, [current, ct, queue, pending, cloud])
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
        setBanner(`Hi ${firstName(done.account) ?? 'there'}. ${creditLine(done.account)} to spend on Frog Cloud.`)
        if (done.after) { setDraft(done.after); setView({ kind: 'new', pick: true }) }
        return
      }
      const k = savedKey()
      if (!k || DEV_KEY) return
      setAccount(await me(k))
    }).catch((e) => {
      if (e instanceof AuthError && e.status === 401) { signOut(); setKey(null); return }
      setAuthError(e instanceof AuthError ? e.code : String(e))
    })
  }, [])

  useEffect(() => cloud?.watch((id, s) => setConn((all) => ({ ...all, [id]: s }))), [cloud])

  const send = useCallback((id: string, text: string, images: Image[] = []) =>
    cloud?.send(id, { op: 'submit', text, ...(images.length ? { images } : {}) }), [cloud])


  const start = useCallback(async (text: string, repo?: string, images: Image[] = []) => {
    if (!cloud) return
    // Open the session at once, as a placeholder, and swap in the real one when the gateway
    // answers: starting a conversation should feel instant, not wait on a round trip.
    const temp = `${PENDING}${Date.now()}`
    setPending((p) => ({ ...p, [temp]: text }))
    setSessions((all) => [{ id: temp, title: text.length > 60 ? text.slice(0, 57) + '…' : text, repo: repo ?? '', branch: '', state: 'starting', updated: Date.now() }, ...all])
    setView({ kind: 'session', id: temp })
    try {
      const s0 = await cloud.gateway.create({ ...(repo ? { repo } : {}), ...(newModel ? { model: spec(newModel) } : {}) })
      // A session without a repo comes back titled "New session" until the engine names it.
      const s = { ...s0, title: s0.repo ? s0.title : text.length > 60 ? text.slice(0, 57) + '…' : text }
      setSessions((all) => [s, ...all.filter((x) => x.id !== s.id && x.id !== temp)])
      setView((v) => (v.kind === 'session' && v.id === temp ? { kind: 'session', id: s.id } : v))
      if (newMode !== 'default') cloud.send(s.id, { op: 'set_mode', mode: newMode })
      send(s.id, text, images) // queued until the session's socket is live
    } catch (e) {
      setSessions((all) => all.filter((x) => x.id !== temp))
      setView((v) => (v.kind === 'session' && v.id === temp ? { kind: 'new', repo } : v))
      setDraft(text)
      say(`Couldn't start a sandbox: ${e instanceof Error ? e.message : e}`)
    } finally {
      setPending((p) => { const { [temp]: _, ...rest } = p; return rest })
    }
  }, [cloud, send, setSessions, newModel, newMode])

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
      <button type="button" className="row big" onClick={() => (key ? setView({ kind: 'new' }) : setGate(null))}><Icon d={icons.new} /><span style={{ flex: 1 }}>New session</span><span className="kb">⌘N</span></button>
      <button type="button" className="row big" onClick={() => setPalette(true)}><Icon d={icons.search} /><span style={{ flex: 1 }}>Search</span><span className="kb">⌘K</span></button>
    </nav>
  )

  const MacCard = () => (
    <div className="promo">
      <svg viewBox="0 0 224 120" role="img" aria-label="Frog on a MacBook on a lily pad, with its tools orbiting" style={{ display: 'block', margin: '0 -12px', width: 'calc(100% + 24px)', height: 'auto', background: 'linear-gradient(180deg, var(--frog-pad), transparent 85%)' }}>
        <ellipse cx="112" cy="104" rx="88" ry="13" fill="var(--frog)" opacity=".18" />
        <ellipse cx="112" cy="58" rx="86" ry="26" fill="none" stroke="var(--fg)" strokeOpacity=".12" strokeDasharray="2 5" />
        <circle cx="31" cy="52" r="4" fill="var(--place-local)" /><circle cx="186" cy="74" r="3.5" fill="var(--notice)" /><circle cx="166" cy="36" r="3" fill="var(--frog)" />
        <rect x="66" y="40" width="92" height="56" rx="6" fill="var(--icon-ground)" /><rect x="70" y="44" width="84" height="48" rx="3" fill="#20251f" />
        <image href="/frog-mark.svg" x="96" y="52" width="32" height="32" />
        <path d="M54 96 h116 a4 4 0 0 1 -4 6 h-108 a4 4 0 0 1 -4 -6z" fill="var(--line-strong)" />
        <text x="31" y="66" textAnchor="middle" fontSize="7" fill="var(--muted)" fontFamily="var(--font-mono)">model</text>
        <text x="186" y="88" textAnchor="middle" fontSize="7" fill="var(--muted)" fontFamily="var(--font-mono)">repo</text>
        <text x="166" y="28" textAnchor="middle" fontSize="7" fill="var(--muted)" fontFamily="var(--font-mono)">tools</text>
      </svg>
      <div style={{ fontWeight: 600, fontSize: 14 }}>Frog runs best on your Mac</div>
      <div className="det wrap">Free and private, with local models and your real repos.</div>
      <a href="/mac" className="f-btn f-btn--bordered" style={{ textDecoration: 'none', justifyContent: 'center', color: 'var(--fg)' }}>Download for Mac</a>
    </div>
  )

  const GitHub = () => (
    <svg aria-hidden="true" width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38v-1.33c-2.23.48-2.7-1.07-2.7-1.07-.36-.92-.89-1.17-.89-1.17-.73-.5.05-.49.05-.49.8.06 1.23.83 1.23.83.72 1.22 1.88.87 2.33.66.07-.52.28-.87.5-1.07-1.78-.2-3.65-.89-3.65-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48v2.2c0 .21.15.46.55.38A8 8 0 0 0 16 8c0-4.42-3.58-8-8-8" /></svg>
  )

  // ---------- signed out ----------
  if (!key) return (
    <div className={`win ${drawer ? 'drawer' : ''}`}>
      <div className="side-scrim" onClick={() => setDrawer(false)} />
      <aside className="side f-glass">
        <div className="brand"><Mark /><b>Frog</b></div>
        <Nav />
        <div className="h"><span>Try one</span></div>
        {starters.map((t) => (
          <button key={t.title} type="button" className="row" onClick={() => setGate(t.title)}>
            <span className="sym starter">{t.i}</span><div style={{ flex: 1, minWidth: 0 }}><div>{t.title}</div><div className="det">{t.detail}</div></div>
          </button>
        ))}
        <div style={{ margin: '14px 2px 0' }}><MacCard /></div>
        <span style={{ flex: 1 }} />
        <div className="signup">
          <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}><Mark size={30} /><div><b style={{ fontSize: 14 }}>Sign up to start</b><div className="det">$5 of Frog Cloud, no card</div></div></div>
          <button type="button" className="f-btn f-btn--prominent" style={{ justifyContent: 'center' }} disabled={leaving} onClick={() => leave(gate)}><GitHub />{leaving ? 'Opening GitHub…' : 'Sign up with GitHub'}</button>
          <div style={{ display: 'flex', justifyContent: 'flex-end', fontSize: 12 }}><a href="#" style={{ color: 'var(--muted)' }} onClick={(e) => { e.preventDefault(); leave(gate) }}>Sign in</a></div>
        </div>
      </aside>
      {gate ? (
        <main className="main">
          <div className="phone-bar"><Burger /><b>Frog</b></div>
          <div className="scroll"><div className="col">
            {authError && <div role="status" className="banner warn">Sign-in didn't finish ({authError}). Try again.</div>}
            <div className="me">{gate}</div>
            <section className="cardx gate" aria-label="Sign up to run this">
              <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Mark size={34} /><div><b style={{ fontSize: 15 }}>Sign up and Frog starts on this</b><div className="det wrap">Every session runs in its own private Frog Cloud sandbox. You get $5 of credits, no card.</div></div></div>
              <button type="button" className="f-btn f-btn--prominent" style={{ justifyContent: 'center', padding: '9px 14px' }} disabled={leaving} onClick={() => leave(gate)}>
                <GitHub />{leaving ? 'Opening GitHub…' : 'Sign in with GitHub'}
              </button>
              <div className="det" style={{ textAlign: 'right' }}>Your message is saved</div>
            </section>
          </div></div>
          <div className="dock"><Composer repo="Connect a repo" onSend={setGate} /></div>
        </main>
      ) : (
        <main className="main home">
          <div className="phone-bar floating"><Burger /><b>Frog</b></div>
          {authError && <div role="status" className="banner warn">Sign-in didn't finish ({authError}). Try again.</div>}
          <Mark size={56} />
          <h1>What should we work on?</h1>
          <div style={{ width: '100%', maxWidth: 680 }}><Composer repo="Connect a repo" onSend={setGate} autoFocus /></div>
          <div className="det">Sending asks you to sign up first.</div>
        </main>
      )}
      {palette && <Palette commands={commands.slice(3)} sessions={[]} onOpen={() => undefined} onClose={() => setPalette(false)} />}
    </div>
  )

  // ---------- signed in ----------
  const asks = sessions.filter((s) => thread(s.id).ask)
  // Questions and MCP prompts need you too; they're answered in the session, not inline.
  const queries = sessions.filter((s) => !thread(s.id).ask && (thread(s.id).question || thread(s.id).elicitation))
  const byRepo = [...new Set(sessions.map((s) => s.repo))]
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
        {asks.length + queries.length > 0 && <>
          <div className="h"><span>Needs you</span><span style={{ color: 'var(--notice)' }}>{asks.length + queries.length}</span></div>
          {queries.map((s) => {
            const t = thread(s.id)
            return (
              <button key={s.id} type="button" className="needs needs-top" onClick={() => setView({ kind: 'session', id: s.id })}>
                <Mark size={26} /><div style={{ flex: 1, minWidth: 0, textAlign: 'left' }}>
                  <b className="ellip" style={{ display: 'block' }}>{t.question ? t.question.question : `${t.elicitation!.server} needs your input`}</b>
                  <div className="det">{title(s)} · Answer in the session</div></div>
              </button>
            )
          })}
          {asks.map((s) => {
            const a = thread(s.id).ask!
            return (
              <div key={s.id} className="needs">
                <button type="button" className="needs-top" onClick={() => setView({ kind: 'session', id: s.id })}>
                  <Mark size={26} /><div style={{ flex: 1, minWidth: 0, textAlign: 'left' }}><b className="ellip" style={{ display: 'block' }}>Can I {a.name.toLowerCase()} {a.arg}?</b>
                    <div className="det">{title(s)}{a.preview && <> · <span style={{ color: 'var(--frog)' }}>+{a.preview.added}</span> <span style={{ color: 'var(--warn)' }}>−{a.preview.removed}</span></>}</div></div>
                </button>
                <div style={{ display: 'flex', gap: 6 }}>
                  <button type="button" className="pill deny" onClick={() => decide(s.id, false)}>Deny</button>
                  <button type="button" className="pill allow" onClick={() => decide(s.id, true)}>Allow ⌘↩</button>
                </div>
              </div>
            )
          })}
        </>}
        <div className="sessions">
          {listError && <div className="det wrap" style={{ padding: '10px 8px', color: 'var(--warn)' }}>Couldn't load sessions: {listError}</div>}
          {!listError && sessions.length === 0 && <div className="det wrap" style={{ padding: '14px 8px' }}>No sessions yet. Start one and it shows up here, and in Frog on your other devices.</div>}
          {byRepo.map((repo) => (
            <div key={repo}>
              <div className="h"><span>{repo ? (repo.split('/')[1] ?? repo) : 'No repo'}</span></div>
              {sessions.filter((s) => s.repo === repo).map((s) => {
                const y = sym(s, thread(s.id))
                return (
                  <button key={s.id} type="button" className={`row ${current?.id === s.id ? 'on' : ''}`} onClick={() => setView({ kind: 'session', id: s.id })}>
                    <span className={y.cls}>{y.ch}</span>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 6 }}><span className="ellip">{title(s)}</span><span className="det" style={{ flex: 'none' }}>☁ {age(s.updated)}</span></div>
                      <div className="det">{y.detail}</div>
                    </div>
                  </button>
                )
              })}
            </div>
          ))}
        </div>
        <button type="button" className="row" onClick={() => setSettings(true)} title="Settings ⌘,">
          <Mark size={28} />
          <div style={{ flex: 1, textAlign: 'left', minWidth: 0 }}>
            <b>{firstName(account) ?? (DEV_KEY ? 'Dev key' : 'Signed in')}</b>
            <div className="det" style={{ color: account && account.credit_cents <= 0 ? 'var(--warn)' : undefined }}>{account ? creditLine(account) : DEV_KEY ? 'local gateway' : ''}</div>
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
          {current && <button type="button" className="f-btn f-btn--plain" onClick={() => setInspector(!inspector)} aria-pressed={inspector}>{inspector ? 'Hide inspector' : 'Inspector'}</button>}
          {current && (
            <div className="title-menu">
              <button type="button" className="f-btn f-btn--plain" aria-label="Session menu" aria-expanded={menuOpen} onClick={() => setMenuOpen(!menuOpen)}>⋯</button>
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
            {banner && <div role="status" className="banner"><span style={{ color: 'var(--place-cloud)' }}>✓</span><span style={{ flex: 1 }}>{banner}</span><button type="button" className="f-btn f-btn--plain" aria-label="Dismiss" onClick={() => setBanner(null)}>✕</button></div>}
            {cs?.state === 'refused' && <div role="status" className="banner warn"><span style={{ flex: 1 }}>Update Frog to continue. This sandbox speaks a different protocol than this page.</span>{cs.refused.upgrade ? <a className="f-btn f-btn--bordered f-btn--small" href={cs.refused.upgrade} style={{ textDecoration: 'none' }}>Update</a> : <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => location.reload()}>Reload</button>}</div>}
            {cs?.state === 'closed' && cs.code === 4004 && <div role="status" className="banner warn">This session was deleted.</div>}
            {current.state === 'error' && <div role="status" className="banner warn"><span style={{ flex: 1 }}>{current.error ?? "The sandbox couldn't start."}</span><button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => remove(current)}>Delete</button></div>}
            {ct.turns.length === 0 && !pending[current.id] && cs?.state !== 'refused' && current.state !== 'error' && <div className="det wrap" style={{ textAlign: 'center', padding: 24 }}>{current.state === 'starting' ? (current.repo ? 'Starting the sandbox and cloning the repo…' : 'Starting the sandbox…') : 'Nothing here yet.'}</div>}
            {pending[current.id] && <div className="turn"><div className="me">{pending[current.id]}</div><div className="tool">… Starting the sandbox</div></div>}
            <Transcript thread={ct} models={models} onDecide={(a) => decide(current.id, a)}
              onAnswer={(choices, other) => ct.question && cloud?.send(current.id, { op: 'answer', id: ct.question.id, choices, ...(other ? { other } : {}) })}
              onElicit={(action, content) => ct.elicitation && cloud?.send(current.id, { op: 'elicit', id: ct.elicitation.id, action, ...(content ? { content } : {}) })} />
            {turnError(ct) && (
              <div role="status" className="banner warn">
                <span style={{ flex: 1 }}>{turnError(ct)}</span>
                <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => send(current.id, 'Try that again.')}>Try again</button>
              </div>
            )}
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
            <Composer key={current.id} state={ct.running || pending[current.id] ? 'working' : paused ? 'paused' : 'idle'} startedAt={ct.startedAt} waiting={!!(ct.ask || ct.question || ct.elicitation)}
              repo={current.repo} branch={current.branch} pr={current.pr} adds={adds} dels={dels}
              model={idOf(ct.model)} models={models} onModel={(id) => cloud?.send(current.id, { op: 'set_model', spec: spec(id) })}
              mode={ct.mode ?? 'default'} onMode={(mode) => cloud?.send(current.id, { op: 'set_mode', mode })}
              queued={queue[current.id]} restore={restore} vision={ct.vision}
              onUnqueue={(i) => { const q = queue[current.id] ?? []; setRestore(q[i]); setQueue({ ...queue, [current.id]: q.filter((_, j) => j !== i) }) }}
              onSend={(text, images) => (ct.running || pending[current.id]
                ? setQueue((all) => ({ ...all, [current.id]: [...(all[current.id] ?? []), { text, images }] }))
                : send(current.id, text, images))} onStop={() => cloud?.send(current.id, { op: 'interrupt' })} onGit={() => push(current)} />
          </div>
        </>)}

        {view.kind === 'new' && (
          <div className="main home">
            {banner && <div role="status" className="banner"><span style={{ color: 'var(--place-cloud)' }}>✓</span><span style={{ flex: 1 }}>{banner}</span><button type="button" className="f-btn f-btn--plain" aria-label="Dismiss" onClick={() => setBanner(null)}>✕</button></div>}
            <Mark size={56} />
            <h1>What should we work on?</h1>
            <div style={{ width: '100%', maxWidth: 680 }}>
              <Composer repo={view.repo} draft={draft} autoFocus pickRepo={view.pick}
                recent={[...new Set(sessions.map((s) => s.repo).filter(Boolean))]} repos={repoList.repos.map((r) => r.name)} install={repoList.install} onRepo={(repo) => setView({ kind: 'new', repo })}
                model={newModel ?? models[0]?.id} models={models} onModel={setNewModel} mode={newMode} onMode={setNewMode}
                onSend={(text, images) => { setDraft(undefined); start(text, view.repo, images) }} />
            </div>
            <div className="starters">
              {starters.map((t) => <button key={t.title} type="button" className="cz-chip" onClick={() => setDraft(t.title)}>{t.i} {t.title}</button>)}
            </div>
          </div>
        )}

      </main>

      {view.kind === 'session' && current && ct && inspector && (
        <Inspector thread={ct} branch={current.branch} hasPr={!!current.pr} onCommit={() => commit(current)} onPr={() => push(current)} send={(op) => cloud?.send(current.id, op)} />
      )}

      {palette && <Palette commands={commands} sessions={sessions} onOpen={(id) => setView({ kind: 'session', id })} onClose={() => setPalette(false)}
        text={(id) => thread(id).turns.flatMap((u) => [u.input, ...u.entries.filter((e) => e.kind === 'message').map((e) => e.text)]).join('\n')} />}
      {settings && <Settings account={account} models={models} onSignOut={() => { setSettings(false); signOut(); setKey(null); setAccount(null); setGate(null); setView({ kind: 'new' }) }} onClose={() => setSettings(false)} />}
      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  )
}
