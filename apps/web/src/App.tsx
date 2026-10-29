import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { finishSignIn, me, savedKey, signIn, signOut, API, AuthError, type Account } from './auth'
import type { ConnectionState } from './cloud/client'
import type { SessionSummary } from './cloud/protocol'
import type { Thread } from './engine/thread'
import type { Mode } from './cloud/protocol'
import { idOf, spec, useModels } from './models'
import { outOfCredits, starters, useCloud, useSessions, useThreads } from './store'
import { Composer } from './ui/Composer'
import { Inspector } from './ui/Inspector'
import { Palette, Settings, tasksLine, type Command } from './ui/Overlays'
import { Transcript } from './ui/Transcript'

/** `pick`: open the composer's repo menu (back from sign-in, or ⌘K Connect a repo). */
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
  if (outOfCredits(t)) return { ch: '', cls: 'sym paused', detail: 'Paused · out of credits' }
  if (t.running) return { ch: '', cls: 'sym ring', detail: 'Working…' }
  if (s.state === 'starting') return { ch: '', cls: 'sym ring', detail: 'Starting the sandbox…' }
  if (s.state === 'error') return { ch: '!', cls: 'sym paused', detail: 'The sandbox hit an error' }
  if (s.state === 'sleeping') return { ch: '', cls: 'sym merged', detail: s.pr ? `Sleeping · ${s.pr}` : 'Sleeping' }
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
  const [inspector, setInspector] = useState(true)
  const [banner, setBanner] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [draft, setDraft] = useState<string | undefined>()
  const [busy, setBusy] = useState(false)
  const [conn, setConn] = useState<Record<string, ConnectionState>>({})
  // What a new session starts with: null model = the gateway's default.
  const [newModel, setNewModel] = useState<string | null>(null)
  const [newMode, setNewMode] = useState<Mode>('auto')
  const toastTimer = useRef(0)

  const cloud = useCloud(key)
  const models = useModels(DEV_KEY ? null : key)
  const { sessions, error: listError, setSessions } = useSessions(cloud)
  const current = view.kind === 'session' ? sessions.find((s) => s.id === view.id) : undefined
  // Stream the open session and any with a live sandbox (for Needs you), not sleeping ones:
  // attaching would wake them.
  const live = useMemo(() => {
    const ids = sessions.filter((s) => s.state === 'running' || s.state === 'starting').slice(0, 8).map((s) => s.id)
    return current && !ids.includes(current.id) ? [current.id, ...ids] : ids
  }, [sessions, current])
  const thread = useThreads(cloud, live)
  const ct = current ? thread(current.id) : null

  const say = (t: string) => { setToast(t); clearTimeout(toastTimer.current); toastTimer.current = window.setTimeout(() => setToast(null), 3200) }

  // Sign-in: finish a GitHub round trip if the URL has one, else check the saved key.
  useEffect(() => {
    finishSignIn().then(async (done) => {
      if (done) {
        setKey(done.key); setAccount(done.account)
        setBanner(`Signed in as ${done.account.handle ?? done.account.email ?? 'you'}. ${tasksLine(done.account)}.`)
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

  const send = useCallback((id: string, text: string) => cloud?.send(id, { op: 'submit', text }), [cloud])

  const start = useCallback(async (text: string, repo: string) => {
    if (!cloud) return
    setBusy(true)
    try {
      const s = await cloud.gateway.create({ repo, ...(newModel ? { model: spec(newModel) } : {}) })
      setSessions((all) => [{ ...s, title: s.title || text }, ...all.filter((x) => x.id !== s.id)])
      setView({ kind: 'session', id: s.id })
      if (newMode !== 'default') cloud.send(s.id, { op: 'set_mode', mode: newMode })
      send(s.id, text) // queued until the session's socket is live
    } catch (e) {
      say(`Couldn't start a sandbox: ${e instanceof Error ? e.message : e}`)
    } finally {
      setBusy(false)
    }
  }, [cloud, send, setSessions, newModel, newMode])

  const decide = useCallback((id: string, allow: boolean) => {
    const ask = thread(id).ask
    if (ask) cloud?.send(id, { op: 'permission', id: ask.id, decision: allow ? 'allow' : 'deny' })
  }, [thread, cloud])

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
        <image href="/frog.svg" x="96" y="52" width="32" height="32" style={{ filter: 'invert(1)' }} />
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
    <div className="win">
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
  const byRepo = [...new Set(sessions.map((s) => s.repo))]
  const adds = ct?.changes.reduce((n, c) => n + c.added, 0) ?? 0
  const dels = ct?.changes.reduce((n, c) => n + c.removed, 0) ?? 0
  const paused = ct ? outOfCredits(ct) : false
  const cs = current ? conn[current.id] : undefined
  const title = (s: SessionSummary) => thread(s.id).title ?? s.title

  return (
    <div className="win">
      <aside className="side f-glass">
        <div className="brand"><Mark /><b>Frog</b></div>
        <Nav />
        {asks.length > 0 && <>
          <div className="h"><span>Needs you</span><span style={{ color: 'var(--notice)' }}>{asks.length}</span></div>
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
              <div className="h"><span>{repo.split('/')[1] ?? repo}</span></div>
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
        <div className="row maccta"><span style={{ color: 'var(--place-local)' }}>▭</span><div style={{ flex: 1 }}><div>Frog for Mac</div><div className="det">Local models, your files, free</div></div><a href="/mac" style={{ fontSize: 12 }}>Get it</a></div>
        <button type="button" className="row" onClick={() => setSettings(true)} title="Settings ⌘,">
          <Mark size={28} />
          <div style={{ flex: 1, textAlign: 'left', minWidth: 0 }}>
            <b>{account?.handle ?? account?.email ?? (DEV_KEY ? 'Dev key' : 'Signed in')}</b>
            <div className="det" style={{ color: account && account.tasks_left <= 0 ? 'var(--warn)' : undefined }}>{account ? tasksLine(account) : DEV_KEY ? 'mock gateway' : ''}</div>
          </div>
          <span className="det">⚙</span>
        </button>
      </aside>

      <main className="main">
        <div className="titlebar">
          <div style={{ flex: 1, minWidth: 0 }}>
            <b style={{ fontSize: 14 }}>{current ? title(current) : 'New session'}</b>
            <div className="det">{current ? `${current.repo} · ${current.branch}${current.pr ? ` · PR ${current.pr}` : ''}${paused ? ' · paused' : ''}${ct?.context?.used ? ` · ${Math.round(ct.context.used / 1000)}k of ${Math.round(ct.context.window / 1000)}k context` : ''}` : 'Runs in a private Frog Cloud sandbox'}</div>
          </div>
          {current && <span style={{ fontSize: 12, color: cs?.state === 'live' ? 'var(--place-cloud)' : 'var(--muted)' }}>{cs?.state === 'live' ? 'In Frog Cloud' : cs?.state === 'connecting' ? (cs.attempt ? 'Reconnecting…' : 'Connecting…') : cs?.state === 'refused' ? 'Update Frog to continue' : cs?.state === 'closed' ? (cs.code === 4004 ? 'Session deleted' : 'Disconnected') : ''}</span>}
          {current && <button type="button" className="f-btn f-btn--plain" onClick={() => setInspector(!inspector)} aria-pressed={inspector}>{inspector ? 'Hide inspector' : 'Inspector'}</button>}
        </div>

        {view.kind === 'session' && current && ct && (<>
          <div className="scroll" ref={(el) => { if (el) el.scrollTop = el.scrollHeight }}><div className="col">
            {banner && <div role="status" className="banner"><span style={{ color: 'var(--place-cloud)' }}>✓</span><span style={{ flex: 1 }}>{banner}</span><button type="button" className="f-btn f-btn--plain" aria-label="Dismiss" onClick={() => setBanner(null)}>✕</button></div>}
            {cs?.state === 'refused' && <div role="status" className="banner warn"><span style={{ flex: 1 }}>Update Frog to continue. This sandbox speaks a different protocol than this page.</span>{cs.refused.upgrade ? <a className="f-btn f-btn--bordered f-btn--small" href={cs.refused.upgrade} style={{ textDecoration: 'none' }}>Update</a> : <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => location.reload()}>Reload</button>}</div>}
            {cs?.state === 'closed' && cs.code === 4004 && <div role="status" className="banner warn">This session was deleted.</div>}
            {ct.turns.length === 0 && cs?.state !== 'refused' && <div className="det wrap" style={{ textAlign: 'center', padding: 24 }}>{current.state === 'starting' ? 'Starting the sandbox and cloning the repo…' : 'Nothing here yet.'}</div>}
            <Transcript thread={ct} onDecide={(a) => decide(current.id, a)} />
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
            <Composer key={current.id} state={ct.running ? 'working' : paused ? 'paused' : 'idle'} startedAt={ct.startedAt} waiting={!!ct.ask}
              repo={current.repo} branch={current.branch} pr={current.pr} adds={adds} dels={dels}
              model={idOf(ct.model)} models={models} onModel={(id) => cloud?.send(current.id, { op: 'set_model', spec: spec(id) })}
              mode={ct.mode ?? 'default'} onMode={(mode) => cloud?.send(current.id, { op: 'set_mode', mode })}
              onSend={(text) => send(current.id, text)} onStop={() => cloud?.send(current.id, { op: 'interrupt' })} onGit={() => push(current)} />
          </div>
        </>)}

        {view.kind === 'new' && (
          <div className="main home">
            {banner && <div role="status" className="banner"><span style={{ color: 'var(--place-cloud)' }}>✓</span><span style={{ flex: 1 }}>{banner}</span><button type="button" className="f-btn f-btn--plain" aria-label="Dismiss" onClick={() => setBanner(null)}>✕</button></div>}
            <Mark size={56} />
            <h1>What should we work on?</h1>
            <div style={{ width: '100%', maxWidth: 680 }}>
              <Composer repo={view.repo} draft={draft} autoFocus pickRepo={view.pick} busy={busy}
                recent={[...new Set(sessions.map((s) => s.repo))]} onRepo={(repo) => setView({ kind: 'new', repo })}
                model={newModel ?? models[0]?.id} models={models} onModel={setNewModel} mode={newMode} onMode={setNewMode}
                onSend={(text) => { setDraft(undefined); if (view.repo) start(text, view.repo) }} />
            </div>
            <div className="starters">
              {starters.map((t) => <button key={t.title} type="button" className="cz-chip" onClick={() => setDraft(t.title)}>{t.i} {t.title}</button>)}
            </div>
          </div>
        )}

      </main>

      {view.kind === 'session' && current && ct && inspector && (
        <Inspector thread={ct} branch={current.branch} hasPr={!!current.pr} onCommit={() => commit(current)} onPr={() => push(current)} />
      )}

      {palette && <Palette commands={commands} sessions={sessions} onOpen={(id) => setView({ kind: 'session', id })} onClose={() => setPalette(false)} />}
      {settings && <Settings account={account} onSignOut={() => { setSettings(false); signOut(); setKey(null); setAccount(null); setGate(null); setView({ kind: 'new' }) }} onClose={() => setSettings(false)} />}
      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  )
}
