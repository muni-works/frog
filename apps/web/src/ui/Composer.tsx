import { useEffect, useRef, useState } from 'react'
import { composing } from './guards'
import type { Image, Mode } from '../cloud/protocol'
import { modelName, modes, outputPrice, placeColor, placeOf, spec, type Model } from '../models'
import { machineModels, places, tag, useShowCloud, type Machine } from '../machines'
import { barTone, ringTone } from '../usage'
import { parseRepo } from '../store'
import type { Provider } from '../auth'
import { safeHref } from './href'
import { DownloadAppChip, useDownloadChip } from './DownloadChip'
import { useFocusTrap, useLayer, useMenu } from './layers'
import { derive, reduce, type ComposerError, type Effect, type Intent, type Pr, type State as Tray } from '../composer'

const gh = (n: number) => (
  <svg aria-hidden="true" width={n} height={n} viewBox="0 0 24 24" fill="currentColor"><path d="M12 .5a11.5 11.5 0 0 0-3.64 22.41c.58.1.79-.25.79-.56v-2c-3.2.7-3.88-1.37-3.88-1.37-.52-1.33-1.28-1.69-1.28-1.69-1.05-.71.08-.7.08-.7 1.16.08 1.77 1.19 1.77 1.19 1.03 1.77 2.7 1.26 3.36.96.1-.75.4-1.26.73-1.55-2.55-.29-5.24-1.28-5.24-5.69 0-1.26.45-2.29 1.19-3.1-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.17 1.18a11 11 0 0 1 5.77 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.81 1.19 1.84 1.19 3.1 0 4.42-2.7 5.39-5.26 5.68.41.36.78 1.06.78 2.14v3.17c0 .31.21.67.8.56A11.5 11.5 0 0 0 12 .5z" /></svg>
)
const google = (n: number) => (
  <svg aria-hidden="true" width={n} height={n} viewBox="0 0 24 24"><path fill="#4285F4" d="M23.5 12.27c0-.85-.08-1.67-.22-2.45H12v4.64h6.45a5.52 5.52 0 0 1-2.4 3.62v3h3.88c2.27-2.09 3.57-5.17 3.57-8.81z" /><path fill="#34A853" d="M12 24c3.24 0 5.96-1.07 7.94-2.9l-3.88-3.02c-1.07.72-2.45 1.15-4.06 1.15-3.13 0-5.78-2.11-6.72-4.95H1.27v3.11A12 12 0 0 0 12 24z" /><path fill="#FBBC05" d="M5.28 14.28a7.2 7.2 0 0 1 0-4.56V6.61H1.27a12 12 0 0 0 0 10.78z" /><path fill="#EA4335" d="M12 4.77c1.76 0 3.34.61 4.59 1.8l3.44-3.44A11.97 11.97 0 0 0 12 0 12 12 0 0 0 1.27 6.61l4.01 3.11C6.22 6.88 8.87 4.77 12 4.77z" /></svg>
)

// The tray (docs/plans/2026-11-12-composer-tray.md): one rounded surface with a top line (the git
// line in a session, the repo line on a new one), the field, and a rail of ＋, mode, model and one
// action button. What it does is the reducer in ../composer.ts, shared with the Mac through
// docs/design/composer/cases.json; this renders it and runs its effects through the props.

export interface ComposerProps {
  /** Context used of the window, from the engine's status: a ring by the send button. */
  context?: { used: number | null; window: number } | null
  /** The account's plan usage and credit, shown in the ring's popover as in Claude's. */
  usage?: { sub: { name: string; windows: { kind: '5h' | 'weekly'; used: number; limit: number; resets_at: string }[]; over: boolean } | null; credit: string; onBilling: () => void; onOpen?: () => void }
  /** Summarize the conversation so far to free up context (the ring's button, or /compact). */
  onCompact?: (focus?: string) => void
  compacting?: boolean
  state?: 'idle' | 'working' | 'paused'
  repo?: string
  /** In an open session (not the landing or new-session page): the reply placeholder. */
  session?: boolean
  branch?: string
  pr?: string
  adds?: number
  dels?: number
  startedAt?: number
  /** The running turn is blocked on a permission ask. */
  waiting?: boolean
  draft?: string
  /** The model id (without `cloud/`) and the ones to pick from; the menu shows when there's a list. */
  model?: string | null
  models?: Model[]
  /** Signed out: the send button (a sign-in button with nothing typed) and the repo chip open a
   * GitHub / Google menu instead, and what's typed goes along. */
  onSignIn?: (provider: Provider, text: string) => void
  /** Signed in without GitHub: the repo menu offers to connect it, with what's typed. */
  onConnectGithub?: (text: string) => void
  onModel?: (id: string) => void
  /** Your machines (none on the web until the gateway reports them), and Settings › Models. */
  machines?: Machine[]
  /** Open with the model menu showing (parity shots). */
  openModels?: boolean
  onManage?: () => void
  /** When the engine asks before acting; the chip shows once the engine (or a new session) says. */
  mode?: Mode | null
  onMode?: (mode: Mode) => void
  onSend: (text: string, images: Image[]) => void
  /** Suggestion chips over the box while it's empty. `send` chips send on click; others fill
   * the box. `act` marks one that acts outside the project (push, deploy). */
  chips?: { text: string; send?: boolean; act?: boolean }[]
  /** Messages sent while Frog works: they go together when the turn ends. × takes one back. */
  queued?: { text: string; images: Image[] }[]
  onUnqueue?: (i: number) => void
  /** False when the session's model can't read images (the engine's status.vision). */
  vision?: boolean | null
  /** A message taken back out of the queue, for the field. */
  restore?: { text: string; images: Image[] } | null
  onStop?: () => void
  /** A new session's repo picker, in the composer: recent repos, the account's repos, search, or
   * a pasted URL. Optional: a session can start without one. */
  onRepo?: (repo: string | undefined) => void
  recent?: string[]
  /** Repos the Frog GitHub App can reach, plus public ones (GET /v1/repos). */
  repos?: string[]
  /** The App's install page, to give Frog access to more repos. */
  install?: string
  /** Open the repo menu on mount (e.g. back from sign-in with a message but no repo). */
  pickRepo?: boolean
  /** Starting a session: the send button waits. */
  busy?: boolean
  onGit?: () => void
  autoFocus?: boolean
  /** Bound PRs with their state (GET /v1/sessions/:id/prs; until the gateway serves it, none). */
  prs?: Pr[]
  /** Commits on the branch not yet pushed (a PR's Push). */
  ahead?: number
  /** Bind a PR by URL or #n (the stack's "Bind a PR…"). */
  onBindPr?: (ref: string) => void
  /** Parity shots and tests: tray state to show as is (an error, the stack open). */
  tray?: Partial<Tray>
}

const toTray = (m?: Mode | null): Tray['mode'] => (m === 'accept-edits' ? 'accept_edits' : m ?? 'auto')
const fromTray = (m: Tray['mode']): Mode => (m === 'accept_edits' ? 'accept-edits' : m)
const MODE_LABEL: Record<Tray['mode'], string> = { auto: 'Auto', default: 'Ask', accept_edits: 'Accept edits', yolo: 'Yolo' }
const GIT_LABEL = { commit: 'Commit', open_pr: 'Open PR', push: 'Push', fix: 'Fix', merge: 'Merge', archive: 'Archive', reopen: 'Reopen' } as const
const PR_WORD = { failing: 'Failing', checks: 'Checks running', draft: 'Draft', approved: 'Approved', closed: 'Closed', merged: 'Merged' } as const
const ACTION_WORD: Record<string, string> = { restart_engine: 'Restart engine', sign_in: 'Sign in', add_credit: 'Add credit', retry: 'Retry', open_settings: 'Allow microphone', use_checkout: 'Use checkout instead', pull_retry: 'Pull & retry', connect_github: 'Connect GitHub', show_output: 'Show output', resolve_conflicts: 'Resolve conflicts' }
const prDot = (s: Pr['state']) => `var(--pr-${s})`


function useTimer(since?: number) {
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    if (!since) return
    const t = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(t)
  }, [since])
  if (!since) return ''
  const s = Math.max(0, Math.floor((now - since) / 1000))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

export function Composer(p: ComposerProps) {
  const [text, setText] = useState(p.draft ?? '')
  const [menu, setMenu] = useState<'plus' | 'model' | 'mode' | 'repo' | 'signin' | null>(p.pickRepo ? 'repo' : p.openModels ? 'model' : null)
  const showCloudModels = useShowCloud()
  // A machine's model runs from the Mac app; where there's an app to send them to, its rows give
  // way to one download hint, and on a phone (or once they have the app) they stay as they were.
  const machineChip = useDownloadChip(p.machines ?? [])
  const machineRows = machineChip ? [] : machineModels(p.machines ?? [])
  const [q, setQ] = useState('')
  // Where the open menu's button sits, so the menu opens right above it.
  const [at, setAt] = useState(8)
  const anchor = (e: { currentTarget: Element }) => {
    const box = root.current?.getBoundingClientRect()
    setAt(Math.max(0, Math.min(e.currentTarget.getBoundingClientRect().left - (box?.left ?? 0), (box?.width ?? 300) - 300)))
  }
  const ref = useRef<HTMLTextAreaElement>(null)
  // One line until you write more, then it grows (to a cap, then scrolls), like Claude's.
  // Empty, it's the stylesheet's one line: Chrome counts the placeholder in scrollHeight, and
  // measured before the column has its width (the landing's first paint) that wrapped to 220px.
  const grow = (el: HTMLTextAreaElement) => {
    el.style.height = 'auto'
    el.style.height = el.value ? `${Math.min(el.scrollHeight, 220)}px` : ''
  }
  const working = p.state === 'working', paused = p.state === 'paused'
  const timer = useTimer(working ? p.startedAt : undefined)
  useEffect(() => { if (p.draft !== undefined) setText(p.draft) }, [p.draft])
  useEffect(() => { if (ref.current) grow(ref.current) }, [text])
  useEffect(() => { if (p.autoFocus) ref.current?.focus() }, [p.autoFocus])
  useEffect(() => { if (p.pickRepo) setMenu('repo') }, [p.pickRepo])
  // A menu closes on any click outside it (its own toggle chip toggles it), or Escape.
  const root = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!menu) return
    const down = (e: MouseEvent) => {
      const t = e.target as Element
      if (root.current?.contains(t) && t.closest('.cz-menu, [aria-expanded]')) return
      setMenu(null)
    }
    document.addEventListener('mousedown', down)
    return () => document.removeEventListener('mousedown', down)
  }, [menu])
  useLayer(!!menu, () => setMenu(null))
  const nav = useMenu(menu)
  const [local, setLocal] = useState({
    error: null as ComposerError | null, notice: null as string | null, confirm: null as Tray['confirm'],
    stackOpen: false, lastSent: '', yoloConfirmed: false, memory: { modelByPlace: {}, worktreeByRepo: {}, branchByRepo: {} } as Tray['memory'],
  })
  const [bindRef, setBindRef] = useState('')

  const [images, setImages] = useState<Image[]>([])
  const file = useRef<HTMLInputElement>(null)
  useEffect(() => {
    if (!p.restore) return
    setText((t) => (t ? `${p.restore!.text}\n${t}` : p.restore!.text))
    setImages((im) => [...p.restore!.images, ...im])
  }, [p.restore])
  /** Images from paste, drop or the file picker, as base64 (Op::Submit images). Up to 8, 5 MB each. */
  const attach = async (files: Iterable<File>) => {
    const add: Image[] = []
    for (const f of files) {
      if (!f.type.startsWith('image/') || f.size > 5 * 1024 * 1024) continue
      const data = await new Promise<string>((res) => { const r = new FileReader(); r.onload = () => res(String(r.result).split(',')[1] ?? ''); r.readAsDataURL(f) })
      add.push({ mime: f.type, data })
    }
    if (add.length) setImages((im) => [...im, ...add].slice(0, 8))
  }
  const send = () => {
    const t = text.trim()
    if (p.onSignIn) { setMenu('signin'); return }
    if ((!t && !images.length) || paused || p.busy) return
    // "/compact [what to keep]" asks the engine to summarize rather than sending a message.
    const c = t.match(/^\/compact\b\s*(.*)$/s)
    // While a turn runs it stays typed; compacting mid-turn isn't possible.
    if (c && p.onCompact) { if (!working) { p.onCompact(c[1].trim() || undefined); setText('') } return }
    p.onSend(t, images)
    setLocal((l) => ({ ...l, lastSent: t }))
    setText('')
    setImages([])
  }
  /** The queued effect: the entry (text and images) goes onto the queue prop — the app
   * routes a send while working there — and the field clears, the way send clears it. */
  const queueDraft = (e: Effect) => {
    const files = (e.attachments as unknown[] | undefined)?.length === images.length ? images : []
    p.onSend?.(String(e.text ?? ''), files)
    setText('')
    setImages([])
  }
  const placeholder = working ? 'Working… Esc interrupts · Return queues a follow-up'
    : paused ? 'Paused · out of credits'
    : p.session ? 'Reply to Frog, @ a file, ! a command'
    : 'Ask Frog to do something, or paste a GitHub repo'
  const hasGit = (p.adds ?? 0) + (p.dels ?? 0) > 0
  const cloudModel = { id: p.model ?? '', name: p.model ? modelName(p.model) : 'Default model', place: 'cloud' as const, node: null }
  const tray: Tray = {
    draft: { text, attachments: images.map((im) => ({ name: 'image', size: Math.floor(im.data.length * 0.75), type: im.mime })), caret: text.length },
    lastSent: local.lastSent,
    mode: toTray(p.mode),
    yoloConfirmed: local.yoloConfirmed,
    model: cloudModel,
    defaults: { local: null, cloud: cloudModel },
    signedIn: !p.onSignIn,
    where: p.session
      ? { kind: 'session', repo: p.repo ?? null, branch: p.branch ?? '', worktree: false, worktreePath: null, diff: { add: p.adds ?? 0, del: p.dels ?? 0, files: hasGit ? 1 : 0 }, dirty: hasGit, ahead: p.ahead ?? 0, prs: p.prs ?? [] }
      : { kind: 'cloud', repo: p.repo ?? 'No repo', branch: 'main' },
    busy: p.busy ? 'sending' : working ? 'working' : 'idle',
    pending: null,
    queued: p.queued?.length ?? 0,
    error: local.error,
    notice: local.notice,
    confirm: local.confirm,
    stackOpen: local.stackOpen,
    memory: local.memory,
    ...p.tray,
  }
  const d = derive(tray)
  const run = (e: Effect, next: Tray) => {
    switch (e.type) {
      case 'submit': case 'start_session':
        if (next.pending === 'aside') p.onSend(String(e.text ?? ''), [])
        else send()
        break
      case 'queued': queueDraft(e); break
      case 'interrupt': p.onStop?.(); break
      case 'set_mode': p.onMode?.(fromTray(e.mode as Tray['mode'])); break
      case 'open_login': setMenu('signin'); break
      case 'open_billing': p.usage?.onBilling(); break
      case 'draft_commit': case 'open_pr': case 'push': case 'pull_push': p.onGit?.(); break
      case 'open_url': window.open(String(e.url), '_blank', 'noopener'); break
      case 'copy': navigator.clipboard?.writeText(String(e.text)).catch(() => {}); break
      case 'bind_pr': p.onBindPr?.(String(e.ref)); break
      // Dictation on the web is the browser's own (the OS keyboard's mic); none here yet.
      case 'start_dictation': ref.current?.focus(); break
    }
  }
  function dispatch(i: Intent) {
    const [next, effects] = reduce(tray, i)
    setLocal({ error: next.error, notice: next.notice, confirm: next.confirm, stackOpen: next.stackOpen, lastSent: next.lastSent, yoloConfirmed: next.yoloConfirmed, memory: next.memory })
    if ((i.type === 'recall' || i.type === 'suggestion') && next.draft.text !== text) setText(next.draft.text)
    for (const e of effects) run(e, next)
  }
  const outline = (control: string) => (tray.error?.control === control ? ' cz-bad' : '')

  return (
    <div className="cz" ref={root}>
      {!text && !images.length && !working && !menu && !!p.chips?.length && (
        <div className="cz-chips">
          {p.chips.map((c) => (
            <button key={c.text} type="button" className={`cz-sug${c.act ? ' act' : ''}`}
              onClick={() => { if (c.send && p.onSignIn) { setText(c.text); setMenu('signin') } else if (c.send) p.onSend(c.text, []); else { setText(c.text); ref.current?.focus() } }}>
              {c.act ? <span aria-hidden="true">↗ </span> : null}{c.text}
            </button>
          ))}
        </div>
      )}
      {menu === 'plus' && (
        <div className="f-card cz-menu" role="menu" aria-label="Attach" style={{ left: 8 }} {...nav}>
          <button type="button" role="menuitem" onClick={() => { setMenu(null); file.current?.click() }}><span>▣</span>Attach images…</button>
          <button type="button" role="menuitem" onClick={() => { setText(text + '@'); setMenu(null); ref.current?.focus() }}><span>@</span>Mention a file</button>
        </div>
      )}

      {menu === 'model' && (
        <div className="f-card cz-menu cz-models" role="menu" aria-label="Model" style={{ left: at, width: 320 }} {...nav}>
          {/* The web runs sessions in Frog Cloud, so a machine's model can't be picked here: it
           * runs from the Mac app. Where there's an app to send them to, one hint; on a phone, or
           * once they have it, the rows stay as they were. */}
          <div className="cz-menu-h">{machineChip ? 'Run it on your Mac' : 'Your machines'}</div>
          {machineChip
            ? <div className="cz-menu-note"><DownloadAppChip label="Runs from the Mac app" machines={p.machines} /></div>
            : machineRows.length === 0 && <div className="det cz-menu-note">No models on your machines yet.</div>}
          {machineRows.map((m) => (
            <button key={m.spec} type="button" role="menuitemradio" aria-checked={false} disabled title="Runs from the Mac app">
              <span className="cz-dot" style={{ background: placeColor('local') }} aria-hidden="true" />
              <span className="cz-mname">{m.name}</span><span className="det cz-mdetail">{places(m)}</span>
              <span className="cz-mtag">{tag(m) ?? ''}</span>
            </button>
          ))}
          {showCloudModels && !!p.models?.length && <div className="cz-menu-h">Frog Cloud</div>}
          {showCloudModels && p.models?.map((m) => (
            <button key={m.id} type="button" role="menuitemradio" aria-checked={m.id === p.model} onClick={() => { p.onModel?.(m.id); setMenu(null) }}>
              <span className="cz-dot" style={{ background: placeColor('cloud') }} aria-hidden="true" />
              <span className="cz-mname">{modelName(m.id)}</span><span className="det cz-mdetail">{outputPrice(m)}</span>
              <span className="cz-mtag" style={{ opacity: m.id === p.model ? 1 : 0 }}>✓</span>
            </button>
          ))}
          {p.onManage && (<>
            <div className="cz-menu-sep" />
            <button type="button" role="menuitem" onClick={() => { setMenu(null); p.onManage!() }}>Manage…</button>
          </>)}
        </div>
      )}
      {menu === 'repo' && p.onRepo && (() => {
        const typed = parseRepo(q)
        const match = (r: string) => r.toLowerCase().includes(q.trim().toLowerCase())
        const recent = (p.recent ?? []).filter(match)
        const yours = (p.repos ?? []).filter((r) => match(r) && !recent.includes(r))
        const list = [...recent, ...yours]
        const pick = (r: string | undefined) => { p.onRepo!(r); setMenu(null); setQ(''); ref.current?.focus() }
        return (
          <div className="f-card cz-menu cz-repos" role="menu" aria-label="Repo" style={{ left: 150, width: 320 }} {...nav}>
            <input className="cz-search" autoFocus value={q} placeholder="Search repos, or paste a GitHub URL" aria-label="Repo"
              onChange={(e) => setQ(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') { e.preventDefault(); const r = typed ?? list[0]; if (r) pick(r) }
              }} />
            {typed && !list.includes(typed) && <button type="button" role="menuitem" onClick={() => pick(typed)}><span style={{ flex: 1 }}>{typed}</span><span className="det">from GitHub</span></button>}
            {!q && (
              <button type="button" role="menuitemradio" aria-checked={!p.repo} onClick={() => pick(undefined)}>
                <span style={{ flex: 1 }}>No repo</span><span style={{ color: 'var(--frog)', opacity: !p.repo ? 1 : 0 }}>✓</span>
              </button>
            )}
            <div className="cz-list">
              {([['Recent', recent], ['Your repos', yours]] as const).map(([h, rs]) => rs.length > 0 && (
                <div key={h}>
                  <div className="cz-menu-h">{h}</div>
                  {rs.map((r) => (
                    <button key={r} type="button" role="menuitemradio" aria-checked={r === p.repo} onClick={() => pick(r)}>
                      <span style={{ flex: 1 }}>{r}</span><span style={{ color: 'var(--frog)', opacity: r === p.repo ? 1 : 0 }}>✓</span>
                    </button>
                  ))}
                </div>
              ))}
            </div>
            {!typed && list.length === 0 && q && <div className="det wrap" style={{ padding: '6px 10px' }}>No match. Type owner/name or paste a GitHub URL.</div>}
            {p.onConnectGithub && <button type="button" role="menuitem" className="cz-more" onClick={() => p.onConnectGithub!(text)}>{gh(14)}<span style={{ flex: 1 }}>Connect GitHub to see your repos</span></button>}
            {safeHref(p.install) && <a className="cz-more" href={safeHref(p.install)!.href} target="_blank" rel="noreferrer">Give Frog access to more repos</a>}
          </div>
        )
      })()}
      {menu === 'signin' && p.onSignIn && (
        <div className="f-card cz-menu" role="menu" aria-label="Sign in" style={{ right: 8, left: 'auto', width: 230 }} {...nav}>
          <button type="button" role="menuitem" onClick={() => p.onSignIn!('github', text.trim())}>{gh(14)}Continue with GitHub</button>
          <button type="button" role="menuitem" onClick={() => p.onSignIn!('google', text.trim())}>{google(14)}Continue with Google</button>
        </div>
      )}
      {menu === 'mode' && (
        <div className="f-card cz-menu" role="menu" aria-label="When Frog asks" style={{ left: at, width: 300 }} {...nav}>
          <div className="cz-menu-h">When Frog asks</div>
          {modes.map((m) => (
            <button key={m.id} type="button" role="menuitemradio" aria-checked={m.id === p.mode} onClick={() => { dispatch({ type: 'set_mode', mode: toTray(m.id) }); setMenu(null) }}>
              <span style={{ flex: 1, minWidth: 0 }}><b style={{ fontWeight: 600 }}>{MODE_LABEL[toTray(m.id)]}{m.id === 'auto' ? ' (default)' : ''}</b><br /><span className="det wrap">{m.note}</span></span>
              <span style={{ color: 'var(--frog)', opacity: m.id === p.mode ? 1 : 0 }}>✓</span>
            </button>
          ))}
        </div>
      )}

      {!!p.queued?.length && (
        <div className="cz-queue" aria-label="Queued messages">
          <div className="cz-qhead">
            <span className="cz-qtitle">Queued · {p.queued.length}</span>
            <span className="cz-qwhen">{working ? 'goes in at the next tool step' : 'sends when the turn ends'}</span>
          </div>
          {p.queued.map((q, i) => (
            <div key={i} className="cz-queued">
              <svg className="cz-qclip" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true"><path d="M21 12.8l-8.5 8.4a5 5 0 0 1-7-7l8.4-8.5a3.3 3.3 0 0 1 4.7 4.7l-8.5 8.4a1.7 1.7 0 0 1-2.4-2.4l7.8-7.8"/></svg>
              <span className="ellip">{q.text || `${q.images.length} image${q.images.length === 1 ? '' : 's'}`}</span>
              {!!q.images.length && (
                <span className="cz-qimgs">{q.images.map((im, j) => (
                  <img key={j} className="cz-qimg" src={`data:${im.mime};base64,${im.data}`} alt="" />
                ))}</span>
              )}
              <button type="button" className="cz-qx" aria-label="Take back to the field" title="Take back to edit" onClick={() => p.onUnqueue?.(i)}>✕</button>
            </div>
          ))}
        </div>
      )}
      <div className="f-glass cz-box cz-tray"
        onDragOver={(e) => { if ([...e.dataTransfer.items].some((i) => i.type.startsWith('image/'))) e.preventDefault() }}
        onDrop={(e) => { if (e.dataTransfer.files.length) { e.preventDefault(); attach(e.dataTransfer.files) } }}>
        <input ref={file} type="file" accept="image/*" multiple hidden onChange={(e) => { if (e.target.files) attach(e.target.files); e.target.value = '' }} />
        {tray.where.kind === 'session' && (tray.where.repo || tray.where.branch) && (() => {
          const w = tray.where
          return (
            <div className="cz-top" aria-label="This session's repository">
              {w.repo && <a className="cz-repo" href={`https://github.com/${w.repo}`} target="_blank" rel="noreferrer" title={w.repo}>{w.repo.split('/')[1] ?? w.repo}</a>}
              {w.branch && <span className="cz-branch" title={w.branch}>⎇ {w.branch}</span>}
              {(w.diff.add + w.diff.del > 0) && (
                <button type="button" className="cz-diff num" onClick={p.onGit} title="Uncommitted changes"><span style={{ color: 'var(--frog)' }}>+{w.diff.add}</span> <span style={{ color: 'var(--warn)' }}>−{w.diff.del}</span></button>
              )}
              <span style={{ flex: 1 }} />
              {d.prSummary && d.prSummary.count === 1 && (
                <button type="button" className="cz-pill" title={`${w.prs[0].title} · ${PR_WORD[w.prs[0].state]}. Alt-click copies the link`}
                  onClick={(e) => dispatch({ type: 'pr_click', index: 0, alt: e.altKey })}>
                  <span className="cz-prdot" style={{ background: prDot(w.prs[0].state) }} aria-hidden="true" /><span className="num">{d.prSummary.label}</span>
                </button>
              )}
              {d.prSummary && d.prSummary.count > 1 && (
                <span className="cz-stackwrap">
                  <button type="button" className="cz-pill" aria-expanded={tray.stackOpen} onClick={() => dispatch({ type: tray.stackOpen ? 'close_stack' : 'open_stack' })}>
                    <span className="cz-prdot" style={{ background: prDot(d.prSummary.worst) }} aria-hidden="true" />{d.prSummary.label} <span className="chev">▾</span>
                  </button>
                  {tray.stackOpen && (
                    <div className="f-card cz-stack" role="menu" aria-label="Bound PRs">
                      {w.prs.map((pr, i) => (
                        <button key={`${pr.repo}#${pr.number}`} type="button" role="menuitem" onClick={(e) => dispatch({ type: 'pr_click', index: i, alt: e.altKey })}>
                          <span className="cz-prdot" style={{ background: prDot(pr.state) }} aria-hidden="true" />
                          <span className="det num">{pr.repo.split('/')[1] ?? pr.repo}#{pr.number}</span>
                          <span className="ellip" style={{ flex: 1 }}>{pr.title}</span>
                          <span style={{ color: pr.access === false ? 'var(--faint)' : prDot(pr.state) }}>{pr.access === false ? 'no access' : PR_WORD[pr.state]}</span>
                        </button>
                      ))}
                      <div className="cz-menu-sep" />
                      <input className="cz-search" value={bindRef} placeholder="Bind a PR… (URL or #n)" aria-label="Bind a PR"
                        onChange={(e) => setBindRef(e.target.value)}
                        onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); dispatch({ type: 'bind_pr', ref: bindRef }); setBindRef('') } }} />
                    </div>
                  )}
                </span>
              )}
              {!d.prSummary && p.pr && <span className="cz-pill num" title={`Bound to ${p.pr}`}>{p.pr}</span>}
              {d.gitAction && (
                <button type="button" className={`cz-act${outline('git_action')}`} disabled={tray.busy === 'sending'} onClick={() => dispatch({ type: 'git_action' })}>{GIT_LABEL[d.gitAction]}</button>
              )}
            </div>
          )
        })()}
        {tray.where.kind === 'cloud' && (
          <div className="cz-top" aria-label="Where this session works">
            <button type="button" className={`cz-where${outline('where')}`} disabled={!p.onRepo && !p.onSignIn} aria-expanded={menu === 'repo'}
              onClick={() => (p.onSignIn ? setMenu('signin') : setMenu(menu === 'repo' ? null : 'repo'))}>
              <svg aria-hidden="true" width="13" height="13" viewBox="0 0 24 24" fill="currentColor" style={{ color: placeColor('cloud') }}><path d="M7 18a5 5 0 0 1-.6-9.96A6 6 0 0 1 18 9a4.5 4.5 0 0 1-.5 9z" /></svg>
              {p.repo || 'No repo'} <span className="chev">▾</span>
            </button>
            {p.repo && <span className="cz-branch">⎇ {tray.where.branch}</span>}
            <span style={{ flex: 1 }} />
          </div>
        )}
        {images.length > 0 && (
          <div className="cz-imgs">
            {images.map((im, i) => (
              <div key={i} className="cz-img">
                <img src={`data:${im.mime};base64,${im.data}`} alt="" />
                <button type="button" aria-label="Remove image" onClick={() => setImages(images.filter((_, j) => j !== i))}>✕</button>
              </div>
            ))}
            {p.vision === false && <span className="det wrap" style={{ color: 'var(--notice)' }}>This model can't see images; it gets a note that one was attached.</span>}
          </div>
        )}
        <label htmlFor="cz" className="sr">Message Frog</label>
        <textarea
          id="cz" ref={ref} rows={1} placeholder={placeholder} value={text} aria-label="Message Frog"
          onChange={(e) => { setText(e.target.value); grow(e.target) }}
          onPaste={(e) => { const fs = [...e.clipboardData.files].filter((f) => f.type.startsWith('image/')); if (fs.length) { e.preventDefault(); attach(fs) } }}
          onKeyDown={(e) => {
            if (composing(e)) return
            if (e.key === 'Enter' && !e.shiftKey && !e.metaKey) { e.preventDefault(); send() }
            if (e.key === 'Escape') dispatch({ type: 'esc' })
            if (e.key === 'ArrowUp' && !text) dispatch({ type: 'recall' })
            if (e.key === '.' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); dispatch({ type: 'cycle_mode' }) }
          }}
        />
        {tray.notice && <div className="cz-notice det">{tray.notice}</div>}
        {tray.confirm && (
          <div className="cz-err" role="alertdialog" aria-label="Confirm">
            <span style={{ flex: 1 }}>{tray.confirm === 'yolo' ? 'Turn on Yolo? Frog never asks; the sandbox still applies.' : tray.confirm === 'merge' ? 'Merge this pull request?' : 'Archive and delete the worktree, changes and all?'}</span>
            <button type="button" className="cz-errbtn" onClick={() => dispatch({ type: 'confirm' })}>{tray.confirm === 'yolo' ? 'Turn on' : tray.confirm === 'merge' ? 'Merge' : 'Archive'}</button>
            <button type="button" className="cz-errx" aria-label="Cancel" onClick={() => dispatch({ type: 'cancel_confirm' })}>✕</button>
          </div>
        )}
        {tray.error && (
          <div className="cz-err" role="alert">
            <span className="cz-erricon" aria-hidden="true">!</span>
            <span style={{ flex: 1 }}>{tray.error.message}{tray.error.retryIn ? ` · retrying in ${tray.error.retryIn}s` : ''}</span>
            {tray.error.actions.map((a) => (
              <button key={a} type="button" className="cz-errbtn" onClick={() => dispatch({ type: 'error_action', action: a })}>{a === 'use_local' ? `Use ${tray.defaults.local?.name ?? 'a local model'}` : ACTION_WORD[a] ?? a}</button>
            ))}
            <button type="button" className="cz-errx" aria-label="Dismiss" onClick={() => dispatch({ type: 'dismiss_error' })}>✕</button>
          </div>
        )}
        <div className="cz-rail">
          <button type="button" className="cz-ic" onClick={() => setMenu(menu === 'plus' ? null : 'plus')} aria-label="Add files or images, or mention a file" aria-expanded={menu === 'plus'}>
            <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><path d="M12 5v14M5 12h14" /></svg>
          </button>
          {p.onMode && (
            <button type="button" className="f-pill" style={{ color: tray.mode === 'yolo' ? 'var(--notice)' : 'var(--muted)' }} aria-expanded={menu === 'mode'}
              title="When Frog asks before acting (Ctrl-.)" onClick={(e) => { anchor(e); setMenu(menu === 'mode' ? null : 'mode') }}>
              {MODE_LABEL[tray.mode]} <span className="chev">▾</span>
            </button>
          )}
          {(!!p.model || !!p.models?.length) && (
            <button type="button" className="f-pill cz-model" aria-label={`Model: ${p.model ? modelName(p.model) : 'default'}`} aria-expanded={menu === 'model'}
              disabled={!p.models?.length || !p.onModel} onClick={(e) => { anchor(e); setMenu(menu === 'model' ? null : 'model') }}>
              <span className="cz-dot" style={{ background: placeColor(placeOf(p.model ? spec(p.model) : null)) }} aria-hidden="true" />
              <span className="cz-pill-model">{p.model ? modelName(p.model) : 'Default model'}</span>
              {p.models?.length ? <span className="chev">▾</span> : null}
            </button>
          )}
          {p.context?.window || p.usage?.sub ? <ContextRing used={p.context?.used ?? null} window={p.context?.window ?? 0} usage={p.usage} onCompact={p.onCompact && !working ? () => p.onCompact!() : undefined} compacting={p.compacting} /> : null}
          <span style={{ flex: 1 }} />
          <span style={{ fontSize: 12, color: paused ? 'var(--warn)' : p.waiting ? 'var(--notice)' : 'var(--muted)', whiteSpace: 'nowrap' }}>
            {working && p.waiting ? '' : working ? `Working · ${timer}` : paused ? 'Out of credits' : ''}
          </span>
          {p.onSignIn && !text.trim() && !images.length ? (
            <button type="button" className="cz-signin" aria-expanded={menu === 'signin'} onClick={() => setMenu(menu === 'signin' ? null : 'signin')}>
              {gh(14)}
              Sign in
            </button>
          ) : (
            <button type="button" className={`cz-send cz-action-${d.action}${outline('action')}`} disabled={d.action === 'send' && (d.sendDisabled || paused)}
              aria-label={d.action === 'dictate' ? 'Dictate' : d.action === 'stop' ? 'Stop (Esc)' : d.action === 'queue' ? 'Queue a follow-up' : 'Send'}
              onClick={() => (d.action === 'send' || d.action === 'queue' ? send() : dispatch({ type: 'action' }))}>
              {d.action === 'dictate' && <svg aria-hidden="true" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5 11a7 7 0 0 0 14 0M12 18v3" /></svg>}
              {d.action === 'stop' && <svg aria-hidden="true" width="11" height="11" viewBox="0 0 24 24" fill="currentColor"><rect x="5" y="5" width="14" height="14" rx="2" /></svg>}
              {d.action === 'queue' && <svg aria-hidden="true" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><path d="M4 6h16M4 12h10M4 18h7M17 15v6M14 18h6" /></svg>}
              {d.action === 'send' && <svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"><path d="M12 19V5M5 12l7-7 7 7" /></svg>}
              {tray.queued > 0 && <span className="cz-qcount">{tray.queued}</span>}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

/** How full the context is, as a ring (the Mac's ContextRing); click it for the numbers. */
function ContextRing({ used, window, usage, onCompact, compacting }: { used: number | null; window: number; usage?: ComposerProps['usage']; onCompact?: () => void; compacting?: boolean }) {
  const [open, setOpen] = useState(false)
  const root = useRef<HTMLSpanElement>(null)
  const button = useRef<HTMLButtonElement>(null)
  useEffect(() => {
    if (!open) return
    const down = (e: MouseEvent) => { if (!root.current?.contains(e.target as Node)) setOpen(false) }
    addEventListener('mousedown', down)
    return () => removeEventListener('mousedown', down)
  }, [open])
  useLayer(open, () => setOpen(false))
  const trap = useFocusTrap(open, () => button.current)
  const sub = usage?.sub
  const plan = sub ? Math.max(0, ...sub.windows.filter((w) => w.limit > 0).map((w) => Math.min(1, w.used / w.limit))) : 0
  const ctx = used && window ? Math.min(1, used / window) : 0
  // The ring shows whichever is fuller, the plan or the context; red once the plan is used up.
  const f = Math.max(plan, ctx)
  const color = ringTone(plan, ctx, !!sub?.over)
  const r = 6.5, c = 2 * Math.PI * r
  return (
    <span className="ctx" ref={root}>
      <button type="button" ref={button} className="ctx-ring" aria-haspopup="dialog" aria-expanded={open} onClick={() => { if (!open) usage?.onOpen?.(); setOpen(!open) }} aria-label={`Usage and context, ${Math.round(f * 100)}%`}>
        <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
          <circle cx="9" cy="9" r={r} fill="none" stroke="var(--line-strong)" strokeWidth="2.5" />
          <circle cx="9" cy="9" r={r} fill="none" stroke={color} strokeWidth="2.5" strokeLinecap="round"
            strokeDasharray={`${f * c} ${c}`} transform="rotate(-90 9 9)" style={{ transition: 'stroke-dasharray .4s' }} />
        </svg>
      </button>
      {open && (
        <div className="f-card ctx-card" role="dialog" aria-label="Usage and context" {...trap}>
          {sub && (<>
            <div className="ctx-h"><span className="det">Plan usage · {sub.name}</span>{usage && <button type="button" className="ctx-link" onClick={() => { setOpen(false); usage.onBilling() }}>See all →</button>}</div>
            {sub.windows.filter((w) => w.limit > 0).map((w) => {
              const x = Math.min(1, w.used / w.limit)
              const when = new Date(w.resets_at).toLocaleString(undefined, w.kind === '5h' ? { hour: 'numeric', minute: '2-digit' } : { weekday: 'short', hour: 'numeric', minute: '2-digit' })
              return (
                <div key={w.kind} className="ctx-row">
                  <div className="ctx-h"><span>{w.kind === '5h' ? 'Session limit' : 'Weekly'}</span><span className="det">{w.resets_at ? `Resets ${when}` : 'Starts when a message is sent'} · {Math.round(x * 100)}%</span></div>
                  <div className="ctx-bar"><span style={{ width: `${x * 100}%`, background: barTone(x) }} /></div>
                </div>
              )
            })}
          </>)}
          {usage && (
            <div className="ctx-h"><span>Usage credits</span><span className="det">{sub?.over ? `paying now · ${usage.credit} left` : `${usage.credit} left`}</span></div>
          )}
          {window > 0 && (<>
            {usage && <div className="ctx-sep" />}
            <div className="ctx-h"><span>Context</span><span className="det">{(used ?? 0).toLocaleString()} of {window.toLocaleString()} tokens · {Math.round(ctx * 100)}%</span></div>
            <div className="ctx-bar"><span style={{ width: `${ctx * 100}%`, background: barTone(ctx) }} /></div>
            {(onCompact || compacting) && (
              <button type="button" className="f-btn f-btn--bordered ctx-compact" disabled={compacting || !onCompact} onClick={() => { onCompact?.(); setOpen(false) }}>
                {compacting ? 'Compacting…' : 'Compact now'}
              </button>
            )}
          </>)}
          {!usage && !sub && window === 0 && <div className="det">Nothing to show yet.</div>}
        </div>
      )}
    </span>
  )
}
