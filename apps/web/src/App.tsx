import { useCallback, useEffect, useRef, useState } from 'react'
import type { Thread } from './engine/thread'
import { engine, outOfCredits, seedSessions, starters, useThreads, type Session } from './store'
import { Composer } from './ui/Composer'
import { Inspector } from './ui/Inspector'
import { Palette, RepoPicker, Settings, type Command } from './ui/Overlays'
import { Transcript } from './ui/Transcript'

type View = { kind: 'session'; id: string } | { kind: 'new'; repo?: string } | { kind: 'pickRepo' }

// `?demo=` opens a screen directly, for design review and screenshots:
// gate, workspace, credits, repos, palette, settings. Anything else (or nothing) is signed out.
const demo = new URLSearchParams(location.search).get('demo') ?? ''
const demoView: View = demo === 'credits' ? { kind: 'session', id: 's-temporal' } : demo === 'repos' ? { kind: 'pickRepo' } : demo ? { kind: 'session', id: 's-auth' } : { kind: 'new' }

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

/** Status symbol for a session row, from its thread. */
function sym(s: Session, t: Thread) {
  if (t.ask) return { ch: '!', cls: 'sym ask', detail: `Waiting on you · ${t.ask.name.toLowerCase()} ${t.ask.arg}` }
  if (outOfCredits(t)) return { ch: '', cls: 'sym paused', detail: 'Paused · out of credits' }
  if (t.running) return { ch: '', cls: 'sym ring', detail: 'Working…' }
  if (s.merged) return { ch: '✓', cls: 'sym merged', detail: s.pr ? `Merged · ${s.pr}` : 'Done' }
  if (t.ended?.type === 'denied') return { ch: '✕', cls: 'sym merged', detail: 'Stopped · you denied an edit' }
  return { ch: '✓', cls: 'sym done', detail: 'Finished' }
}

export default function App() {
  const [signedIn, setSignedIn] = useState(!!demo && demo !== 'gate')
  const [signingIn, setSigningIn] = useState(false)
  const [gate, setGate] = useState<string | null>(demo === 'gate' ? 'Fix the failing tests' : null)
  const [sessions, setSessions] = useState<Session[]>(seedSessions)
  const [view, setView] = useState<View>(demoView)
  const [credits, setCredits] = useState(demo === 'credits' ? 0 : 3.2)
  const [model, setModel] = useState('dart')
  const [palette, setPalette] = useState(demo === 'palette')
  const [settings, setSettings] = useState(demo === 'settings')
  const [inspector, setInspector] = useState(true)
  const [banner, setBanner] = useState<string | null>(null)
  const [toast, setToast] = useState<string | null>(null)
  const [draft, setDraft] = useState<string | undefined>()
  const [pending, setPending] = useState<string | null>(null)
  const thread = useThreads(sessions.map((s) => s.id))
  const toastTimer = useRef(0)

  const say = (t: string) => { setToast(t); clearTimeout(toastTimer.current); toastTimer.current = window.setTimeout(() => setToast(null), 2600) }
  const update = (id: string, f: (s: Session) => Session) => setSessions((all) => all.map((s) => (s.id === id ? f(s) : s)))

  const current = view.kind === 'session' ? sessions.find((s) => s.id === view.id) : undefined
  const ct = current ? thread(current.id) : null

  const start = useCallback((text: string, repo: string) => {
    const id = `s-${Date.now()}`
    const review = /review|pr\b/i.test(text)
    const s: Session = {
      id, title: text.length > 44 ? text.slice(0, 42) + '…' : text, repo, age: 'now',
      branch: review ? 'dates-to-temporal' : `frog/${text.toLowerCase().split(/[^a-z]+/).filter((w) => w.length > 2 && w !== 'the').slice(0, 3).join('-')}`,
      ...(review ? { pr: '#212', checks: 'failing' as const } : {}),
    }
    setSessions((all) => [s, ...all])
    setView({ kind: 'session', id })
    setCredits((c) => Math.max(0, c - 0.06))
    // Subscribe happens on the next render; give it a tick so the live turn is streamed, not replayed.
    setTimeout(() => engine.send(id, { op: 'submit', text }), 50)
  }, [])

  const decide = useCallback((id: string, allow: boolean) => {
    const ask = thread(id).ask
    if (ask) engine.send(id, { op: 'permission', id: ask.id, decision: allow ? 'allow' : 'deny' })
  }, [thread])

  const push = (s: Session) => {
    if (!s.pr) { update(s.id, (x) => ({ ...x, pr: '#215', checks: 'running' })); say(`Opened PR #215 from ${s.branch}`) }
    else { update(s.id, (x) => ({ ...x, checks: 'running' })); say(`Pushed ${s.branch} to ${s.pr}`) }
    setTimeout(() => update(s.id, (x) => ({ ...x, checks: 'passing' })), 3000)
  }

  const signIn = (text: string | null) => {
    setSigningIn(true)
    setTimeout(() => {
      setSigningIn(false); setSignedIn(true); setGate(null); setCredits(5)
      setBanner('Signed in as samr. $5.00 in credits, no card.' + (text ? ' Picking up where you left off.' : ''))
      if (text) start(text, 'ecto/ledger')
      else setView({ kind: 'new' })
    }, 900)
  }

  // Keyboard: ⌘K palette, ⌘N new, ⌘, settings, ⌘↩ / ⌘. answer the current ask.
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey)) return
      if (e.key === 'k') { e.preventDefault(); setPalette((p) => !p) }
      if (!signedIn) return
      if (e.key === 'n') { e.preventDefault(); setView({ kind: 'new' }) }
      if (e.key === ',') { e.preventDefault(); setSettings(true) }
      if (current && ct?.ask && e.key === 'Enter') { e.preventDefault(); decide(current.id, true) }
      if (current && ct?.ask && e.key === '.') { e.preventDefault(); decide(current.id, false) }
    }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [signedIn, current, ct, decide])

  const commands: Command[] = [
    { id: 'c-new', label: 'New session', hint: '⌘N', run: () => (signedIn ? setView({ kind: 'new' }) : undefined) },
    { id: 'c-repo', label: 'Connect a repo', run: () => signedIn && setView({ kind: 'pickRepo' }) },
    { id: 'c-settings', label: 'Settings', hint: '⌘,', run: () => signedIn && setSettings(true) },
    { id: 'c-insp', label: inspector ? 'Hide inspector' : 'Show inspector', run: () => setInspector(!inspector) },
    { id: 'c-theme', label: 'Toggle dark mode', run: () => { const r = document.documentElement; r.dataset.theme = r.dataset.theme === 'dark' ? 'light' : 'dark' } },
  ]

  const Nav = () => (
    <nav aria-label="Main" className="nav">
      <button type="button" className="row big" onClick={() => (signedIn ? setView({ kind: 'new' }) : setGate(null))}><Icon d={icons.new} /><span style={{ flex: 1 }}>New session</span><span className="kb">⌘N</span></button>
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

  // ---------- signed out ----------
  if (!signedIn) return (
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
          <button type="button" className="f-btn f-btn--prominent" style={{ justifyContent: 'center' }} disabled={signingIn} onClick={() => signIn(gate)}>{signingIn ? 'Signing in…' : 'Sign up with GitHub'}</button>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12 }}><a href="#" onClick={(e) => e.preventDefault()}>Use email instead</a><a href="#" style={{ color: 'var(--muted)' }} onClick={(e) => { e.preventDefault(); signIn(gate) }}>Sign in</a></div>
        </div>
      </aside>
      {gate ? (
        <main className="main">
          <div className="scroll"><div className="col">
            <div className="me">{gate}</div>
            <section className="cardx gate" aria-label="Sign up to run this">
              <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}><Mark size={34} /><div><b style={{ fontSize: 15 }}>Sign up and Frog starts on this</b><div className="det wrap">Every session runs in its own private Frog Cloud sandbox. You get $5 of credits, no card.</div></div></div>
              <button type="button" className="f-btn f-btn--prominent" style={{ justifyContent: 'center', padding: '9px 14px' }} disabled={signingIn} onClick={() => signIn(gate)}>
                <svg aria-hidden="true" width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38v-1.33c-2.23.48-2.7-1.07-2.7-1.07-.36-.92-.89-1.17-.89-1.17-.73-.5.05-.49.05-.49.8.06 1.23.83 1.23.83.72 1.22 1.88.87 2.33.66.07-.52.28-.87.5-1.07-1.78-.2-3.65-.89-3.65-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48v2.2c0 .21.15.46.55.38A8 8 0 0 0 16 8c0-4.42-3.58-8-8-8" /></svg>
                {signingIn ? 'Signing in…' : 'Sign in with GitHub'}
              </button>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12 }}><a href="#" onClick={(e) => e.preventDefault()}>Use email instead</a><span className="det">Your message is saved</span></div>
            </section>
          </div></div>
          <div className="dock"><Composer model={model} onModel={setModel} repo="Connect a repo" onSend={setGate} /></div>
        </main>
      ) : (
        <main className="main hero">
          <Mark size={56} />
          <h1>What should we work on?</h1>
          <div style={{ width: '100%', maxWidth: 680 }}><Composer model={model} onModel={setModel} repo="Connect a repo" onSend={setGate} autoFocus /></div>
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
                  <Mark size={26} /><div style={{ flex: 1, minWidth: 0, textAlign: 'left' }}><b>Can I {a.name.toLowerCase()} {a.arg}?</b>
                    <div className="det">{s.title}{a.preview && <> · <span style={{ color: 'var(--frog)' }}>+{a.preview.added}</span> <span style={{ color: 'var(--warn)' }}>−{a.preview.removed}</span></>}</div></div>
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
          {byRepo.map((repo) => {
            const list = sessions.filter((s) => s.repo === repo)
            const live = list.filter((s) => !s.merged).length
            return (
              <div key={repo}>
                <div className="h"><span>{repo.split('/')[1]}</span><span style={{ fontWeight: 400 }}>{live ? `● ${live}` : '· clean'}</span></div>
                {list.map((s) => {
                  const y = sym(s, thread(s.id))
                  return (
                    <button key={s.id} type="button" className={`row ${current?.id === s.id ? 'on' : ''}`} onClick={() => setView({ kind: 'session', id: s.id })}>
                      <span className={y.cls}>{y.ch}</span>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 6 }}><span className="ellip" style={{ color: s.merged ? 'var(--muted)' : 'var(--fg)' }}>{s.title}</span><span className="det" style={{ flex: 'none' }}>☁ {s.age}</span></div>
                        <div className="det">{y.detail}</div>
                      </div>
                    </button>
                  )
                })}
              </div>
            )
          })}
        </div>
        <div className="row maccta"><span style={{ color: 'var(--place-local)' }}>▭</span><div style={{ flex: 1 }}><div>Frog for Mac</div><div className="det">Local models, your files, free</div></div><a href="/mac" style={{ fontSize: 12 }}>Get it</a></div>
        <button type="button" className="row" onClick={() => setSettings(true)} title="Settings ⌘,">
          <Mark size={28} /><div style={{ flex: 1, textAlign: 'left' }}><b>Pip</b><div className="det" style={{ color: credits <= 0 ? 'var(--warn)' : undefined }}>samr · ${credits.toFixed(2)} credits</div></div><span className="det">⚙</span>
        </button>
      </aside>

      <main className="main">
        <div className="titlebar">
          <div style={{ flex: 1, minWidth: 0 }}>
            <b style={{ fontSize: 14 }}>{current ? current.title : 'New session'}</b>
            <div className="det">{current ? `${current.repo.split('/')[1]} · ${current.branch}${current.pr ? ` · PR ${current.pr}` : ''}${paused ? ' · paused' : ''}` : view.kind === 'pickRepo' ? 'Pick a repo to start' : 'Runs in a private Frog Cloud sandbox'}</div>
          </div>
          {current && <span style={{ fontSize: 12, color: 'var(--place-cloud)' }}>$0.06 · in Frog Cloud</span>}
          {current && <button type="button" className="f-btn f-btn--plain" onClick={() => setInspector(!inspector)} aria-pressed={inspector}>{inspector ? 'Hide inspector' : 'Inspector'}</button>}
        </div>

        {view.kind === 'session' && current && ct && (<>
          <div className="scroll" ref={(el) => { if (el) el.scrollTop = el.scrollHeight }}><div className="col">
            {banner && <div role="status" className="banner"><span style={{ color: 'var(--place-cloud)' }}>✓</span><span style={{ flex: 1 }}>{banner}</span><button type="button" className="f-btn f-btn--plain" aria-label="Dismiss" onClick={() => setBanner(null)}>✕</button></div>}
            <Transcript thread={ct} onDecide={(a) => decide(current.id, a)} />
            {paused && (
              <section className="cardx outs" aria-label="Out of credits">
                <b style={{ fontSize: 15 }}>You're out of cloud credits</b>
                <div className="det wrap" style={{ marginTop: -4 }}>Nothing is lost. The sandbox, the changes and this conversation stay put.</div>
                {[
                  { title: 'Finish on your Mac', body: "Sam's MacBook Pro is online. It picks up this session with qwen3-4b, free.", cta: 'Move to my Mac', prom: true, run: () => say("Sent to Sam's MacBook Pro") },
                  { title: 'Add credit', body: 'Pay as you go. No subscription.', cta: 'Add $10', run: () => { setCredits((c) => c + 10); engine.send(current.id, { op: 'submit', text: 'Keep going: fix the 3 failing tests in reports/' }) } },
                  { title: 'Go Pro', body: 'Cloud usage included every month, plus routines while you sleep.', cta: 'See plans', run: () => setSettings(true) },
                ].map((o) => (
                  <div key={o.title} className="out" style={{ borderColor: o.prom ? 'var(--frog)' : 'var(--line)' }}>
                    <div style={{ flex: 1 }}><b>{o.title}</b><div className="det wrap">{o.body}</div></div>
                    <button type="button" className={`f-btn ${o.prom ? 'f-btn--prominent' : 'f-btn--bordered'}`} onClick={o.run}>{o.cta}</button>
                  </div>
                ))}
                <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--muted)' }}><a href="#" onClick={(e) => e.preventDefault()}>Download the patch</a><span>Or open a PR with what's done</span></div>
              </section>
            )}
          </div></div>
          <div className="dock">
            <Composer key={current.id} model={model} onModel={setModel} state={ct.running ? 'working' : paused ? 'paused' : 'idle'} startedAt={ct.startedAt} waiting={!!ct.ask}
              repo={current.repo} branch={current.branch} pr={current.pr} checks={current.checks} adds={adds} dels={dels}
              onSend={(text) => engine.send(current.id, { op: 'submit', text })} onStop={() => engine.send(current.id, { op: 'interrupt' })} onGit={() => push(current)} />
          </div>
        </>)}

        {view.kind === 'new' && (
          <div className="main hero">
            <Mark size={56} />
            <h1>What should we work on?</h1>
            <div style={{ width: '100%', maxWidth: 680 }}>
              <Composer model={model} onModel={setModel} repo={view.repo} draft={draft} autoFocus onRepo={() => setView({ kind: 'pickRepo' })}
                onSend={(text) => { setDraft(undefined); if (view.repo) start(text, view.repo); else { setPending(text); setView({ kind: 'pickRepo' }) } }} />
            </div>
            <div className="starters">
              {starters.map((t) => <button key={t.title} type="button" className="cz-chip" onClick={() => setDraft(t.title)}>{t.i} {t.title}</button>)}
            </div>
          </div>
        )}

        {view.kind === 'pickRepo' && (
          <div className="main" style={{ alignItems: 'center', padding: '60px 22px 0', gap: 14 }}>
            <Mark size={44} />
            <h2 style={{ margin: 0, fontSize: 22, letterSpacing: '-0.02em' }}>Which repo?</h2>
            {pending && <div className="me" style={{ alignSelf: 'center' }}>{pending}</div>}
            <RepoPicker onPick={(r) => { if (pending) { start(pending, r); setPending(null) } else setView({ kind: 'new', repo: r }) }} />
            <div className="det">Frog clones it into a private cloud sandbox. Nothing is pushed until you say so.</div>
          </div>
        )}
      </main>

      {view.kind === 'session' && current && ct && inspector && (
        <Inspector thread={ct} branch={current.branch} hasPr={!!current.pr} onCommit={() => say(`Committed ${ct.changes.length} files on ${current.branch}`)} onPr={() => push(current)} />
      )}

      {palette && <Palette commands={commands} sessions={sessions} onOpen={(id) => setView({ kind: 'session', id })} onClose={() => setPalette(false)} />}
      {settings && <Settings credits={credits} model={model} onModel={setModel} onAddCredit={() => setCredits((c) => c + 10)} onSignOut={() => { setSettings(false); setSignedIn(false); setGate(null) }} onClose={() => setSettings(false)} />}
      {toast && <div className="toast" role="status">{toast}</div>}
    </div>
  )
}
