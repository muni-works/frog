import { useEffect, useRef, useState, type CSSProperties } from 'react'
import { composing } from './guards'
import type { Image, Mode } from '../cloud/protocol'
import { inOutPrice, modelName, placeColor, placeOf, spec, type Model } from '../models'
import { localRows, type Machine } from '../machines'
import { barTone, canCompact, ringLabel, ringTone } from '../usage'
import { parseRepo } from '../store'
import { moreLine, pickRepos, rankRepos } from '../repoRank'
import type { Provider } from '../auth'
import { safeHref } from './href'
import { DownloadAppChip, useDownloadChip, usePhone } from './DownloadChip'
import { hasThisMac, inviteFor, isMacVisitor, macHandoff } from './download'
import { useFocusTrap, useLayer, useMenu } from './layers'
import { useSuggestion, type Suggestion } from './suggestion'
import { derive, error as reducerError, reduce, type ComposerError, type Effect, type Intent, type Pr, type State as Tray } from '../composer'

export const gh = (n: number) => (
  <svg aria-hidden="true" width={n} height={n} viewBox="0 0 24 24" fill="currentColor"><path d="M12 .5a11.5 11.5 0 0 0-3.64 22.41c.58.1.79-.25.79-.56v-2c-3.2.7-3.88-1.37-3.88-1.37-.52-1.33-1.28-1.69-1.28-1.69-1.05-.71.08-.7.08-.7 1.16.08 1.77 1.19 1.77 1.19 1.03 1.77 2.7 1.26 3.36.96.1-.75.4-1.26.73-1.55-2.55-.29-5.24-1.28-5.24-5.69 0-1.26.45-2.29 1.19-3.1-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.17 1.18a11 11 0 0 1 5.77 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.81 1.19 1.84 1.19 3.1 0 4.42-2.7 5.39-5.26 5.68.41.36.78 1.06.78 2.14v3.17c0 .31.21.67.8.56A11.5 11.5 0 0 0 12 .5z" /></svg>
)
export const google = (n: number) => (
  <svg aria-hidden="true" width={n} height={n} viewBox="0 0 24 24"><path fill="#4285F4" d="M23.5 12.27c0-.85-.08-1.67-.22-2.45H12v4.64h6.45a5.52 5.52 0 0 1-2.4 3.62v3h3.88c2.27-2.09 3.57-5.17 3.57-8.81z" /><path fill="#34A853" d="M12 24c3.24 0 5.96-1.07 7.94-2.9l-3.88-3.02c-1.07.72-2.45 1.15-4.06 1.15-3.13 0-5.78-2.11-6.72-4.95H1.27v3.11A12 12 0 0 0 12 24z" /><path fill="#FBBC05" d="M5.28 14.28a7.2 7.2 0 0 1 0-4.56V6.61H1.27a12 12 0 0 0 0 10.78z" /><path fill="#EA4335" d="M12 4.77c1.76 0 3.34.61 4.59 1.8l3.44-3.44A11.97 11.97 0 0 0 12 0 12 12 0 0 0 1.27 6.61l4.01 3.11C6.22 6.88 8.87 4.77 12 4.77z" /></svg>
)

// The composer (docs/design/composer/spec.md): one card of two rows at rest, the field and its
// controls, with the status line above them only when there is something to say. What it does
// is the reducer in ../composer.ts, shared with the Mac through docs/design/composer/cases.json;
// this renders it and runs its effects through the props.

export interface ComposerProps {
  /** Context used of the window, from the engine's status: a ring beside the mode. */
  context?: { used: number | null; window: number } | null
  /** The account's plan usage and credit, shown in the ring's popover. */
  usage?: { sub: { name: string; windows: { kind: '5h' | 'weekly'; used: number; limit: number; resets_at: string }[]; over: boolean } | null; credit: string; onBilling: () => void; onOpen?: () => void }
  /** Summarize the conversation so far to free up context (the ring's button, or /compact). */
  onCompact?: (focus?: string) => void
  compacting?: boolean
  state?: 'idle' | 'working' | 'paused'
  repo?: string
  /** In an open session (not the landing or new-session page). */
  session?: boolean
  branch?: string
  pr?: string
  adds?: number
  dels?: number
  startedAt?: number
  /** The model's speed while working, in tokens per second. */
  speed?: number | null
  /** The running turn is blocked on a permission ask. */
  waiting?: boolean
  /** A permission card is on screen and the app answers it: ⌘. denies it there, so the
   * composer leaves ⌘. alone instead of also cycling the mode. */
  asking?: boolean
  draft?: string
  /** The model id (without `cloud/`) and the ones to pick from; the menu shows when there's a list. */
  model?: string | null
  models?: Model[]
  /** Signed out: the action is a Sign in pill opening a GitHub / Google menu, and what's typed goes along. */
  onSignIn?: (provider: Provider, text: string) => void
  /** Signed in without GitHub: the where menu offers to connect it, with what's typed. */
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
  /** `typed`: the person typed (or dictated) it in the field; a chip or a git action's turn isn't. */
  onSend: (text: string, images: Image[], typed?: boolean) => void
  /** Suggestion chips over the card while it's empty. `send` chips send on click; others fill
   * the field. `act` marks one that acts outside the project (push, deploy). */
  chips?: { text: string; send?: boolean; act?: boolean }[]
  /** One suggestion shown in the empty field, muted, with a "tab" hint: Tab (or the hint) puts it
   * in. A list cycles slowly until you type (ui/suggestion.ts); one string stays put. */
  suggestion?: Suggestion
  /** Messages sent while Frog works: they go together when the turn ends. × removes one. */
  queued?: { text: string; images: Image[] }[]
  onUnqueue?: (i: number) => void
  /** False when the session's model can't read images (the engine's status.vision). */
  vision?: boolean | null
  /** Text to put in at the caret: a mention picked in the preview. A new `n` inserts again. */
  insert?: { text: string; n: number } | null
  /** What's typed, as it changes (the preview's mention chip shows while its token is in it). */
  onText?: (text: string) => void
  /** Text and images to put back in the field. */
  restore?: { text: string; images: Image[] } | null
  onStop?: () => void
  /** A new session's where menu: the account's repos, search, or a pasted URL. Optional: a
   * session can start without a repo. */
  onRepo?: (repo: string | undefined) => void
  /** Repos used in Frog, most recent first. */
  recent?: string[]
  /** Repos the Frog GitHub App can reach, plus public ones (GET /v1/repos). */
  repos?: string[]
  /** Each repo's last push on GitHub (`pushed_at`), for the where menu's order. */
  pushed?: Readonly<Record<string, string | null>>
  /** The App's install page, to give Frog access to more repos. */
  install?: string
  /** The branch a new session starts from (the where menu's Branch); unset is the default branch. */
  base?: string
  onBase?: (branch: string | undefined) => void
  /** Open the where menu on mount (e.g. back from sign-in with a message but no repo). */
  pickRepo?: boolean
  /** Starting a session: the action waits. */
  busy?: boolean
  onGit?: () => void
  autoFocus?: boolean
  /** Bound PRs with their state (GET /v1/sessions/:id/prs; until the gateway serves it, none). */
  prs?: Pr[]
  /** Commits on the branch not yet pushed (a PR's Push). */
  ahead?: number
  /** Bind a PR by URL or #n (the PR list's last row). */
  onBindPr?: (ref: string) => void
  /** Parity shots and tests: composer state to show as is (an error, the PR list open). */
  tray?: Partial<Tray>
}

const toTray = (m?: Mode | null): Tray['mode'] => (m === 'accept-edits' ? 'accept_edits' : m ?? 'auto')
const fromTray = (m: Tray['mode']): Mode => (m === 'accept_edits' ? 'accept-edits' : m)
/** The mode menu, in the order and words of the design (board 4). */
const MODES: { id: Tray['mode']; name: string; note: string }[] = [
  { id: 'default', name: 'Ask', note: 'Asks before edits and commands' },
  { id: 'accept_edits', name: 'Accept edits', note: 'Edits run; commands still ask' },
  { id: 'auto', name: 'Auto', note: 'Runs what plainly serves the task' },
  { id: 'yolo', name: 'Yolo', note: 'Runs every step without asking' },
]
const MODE_NAME = Object.fromEntries(MODES.map((m) => [m.id, m.name])) as Record<Tray['mode'], string>
const GIT_LABEL = { commit: 'Commit', open_pr: 'Open PR', push: 'Push', fix: 'Fix', merge: 'Merge', archive: 'Archive', reopen: 'Reopen' } as const
const PR_WORD = { failing: 'failing', checks: 'checking', draft: 'draft', approved: 'approved', closed: 'closed', merged: 'merged' } as const
/** Error buttons, a verb in three words or fewer (board 5). */
const ACTION_WORD: Record<string, string> = { restart_engine: 'Restart engine', sign_in: 'Sign in', add_credit: 'Add credit', use_local: 'Use local model', retry: 'Retry', open_settings: 'Open Settings', use_checkout: 'Use checkout', pull_retry: 'Pull and retry', connect_github: 'Connect GitHub', show_output: 'Show output', resolve_conflicts: 'Resolve conflicts' }
/** A PR's dot: grey for draft and closed, so the word, not the colour, carries closed. */
const prDot = (s: Pr['state']) => `var(--pr-${s === 'closed' ? 'draft' : s})`
const PLACEHOLDER = { new: 'What should we work on?', session: 'Reply to Frog', working: 'Add a follow-up' } as const
const kb = (n: number) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1e3))} KB`)

/** 16-box stroke icons, drawn at 14 with a 1.4 stroke (spec: Chip). */
const P = {
  plus: 'M8 3v10M3 8h10',
  cloud: 'M4.6 12.5a3 3 0 0 1-.5-6A4 4 0 0 1 11.8 6a3.25 3.25 0 0 1 .3 6.5z',
  folder: 'M2 4.5A1.5 1.5 0 0 1 3.5 3h3L8 4.5h4.5A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5z',
  chevron: 'M5 6.5l3 3 3-3',
  chevronRight: 'M6.5 5l3 3-3 3',
  out: 'M6 10l4.5-4.5M6.5 5.5h4v4',
  laptop: 'M3.5 4h9v6.5h-9zM2 12.5h12',
  server: 'M3 3h10v4.5H3zM3 8.5h10V13H3zM5.5 5.25h.01M5.5 10.75h.01',
  bolt: 'M9 1.5L3.5 9H8l-1 5.5L12.5 7H8z',
  mic: 'M8 2a2 2 0 0 1 2 2v3.5a2 2 0 0 1-4 0V4a2 2 0 0 1 2-2zM4.5 7.5a3.5 3.5 0 0 0 7 0M8 11v2.5',
  wave: 'M3 7v2M5.5 5v6M8 3v10M10.5 5v6M13 7v2',
  up: 'M8 13V3.5M4 7.5l4-4 4 4',
  warn: 'M8 2.5l6 10.5H2zM8 6.5v3M8 11.4h.01',
  x: 'M4.5 4.5l7 7M11.5 4.5l-7 7',
  check: 'M3.5 8.5l3 3 6-6.5',
  search: 'M7 3.5a3.5 3.5 0 1 0 0 7a3.5 3.5 0 1 0 0-7M12.5 12.5L9.6 9.6',
  file: 'M4.5 2.5h5l3 3v8h-8zM9.5 2.5v3h3',
  shot: 'M2.5 3.5h11v9h-11zM2.5 10l3-3 2.5 2.5 2-2 3.5 3.5',
} as const
function I({ d, className, style }: { d: string; className?: string; style?: CSSProperties }) {
  return <svg aria-hidden="true" className={`cz-i${className ? ` ${className}` : ''}`} style={style} viewBox="0 0 16 16"><path d={d} /></svg>
}

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

type SpeechLike = { start(): void; stop(): void; continuous: boolean; interimResults: boolean; onresult: ((e: { resultIndex: number; results: ArrayLike<{ isFinal: boolean; 0: { transcript: string } }> }) => void) | null; onerror: ((e: { error: string }) => void) | null; onend: (() => void) | null }
/** The browser's speech recognition, where it has one (Chrome, Safari). */
const speech = (): (new () => SpeechLike) | null => {
  if (typeof window === 'undefined') return null
  const w = window as unknown as { SpeechRecognition?: new () => SpeechLike; webkitSpeechRecognition?: new () => SpeechLike }
  return w.SpeechRecognition ?? w.webkitSpeechRecognition ?? null
}

type MenuName = 'plus' | 'model' | 'mode' | 'repo' | 'branch' | 'signin'

export function Composer(p: ComposerProps) {
  const [text, setText] = useState(p.draft ?? '')
  const [menu, setMenu] = useState<MenuName | null>(p.pickRepo ? 'repo' : p.openModels ? 'model' : null)
  // Local models run from the Mac app: the menu lists them all the same, and picking one hands
  // off to the app (or to getting it), with one quiet download line after them.
  const machineChip = useDownloadChip(p.machines ?? [])
  const phone = usePhone()
  const handoff = macHandoff(inviteFor({ mac: isMacVisitor(), thisMac: hasThisMac(p.machines ?? []) }))
  const [q, setQ] = useState('')
  // Where the open menu's chip sits, so the menu opens right above it.
  const [at, setAt] = useState<{ left?: number; right?: number }>({ left: 8 })
  const anchor = (e: { currentTarget: Element }, width: number) => {
    const box = root.current?.getBoundingClientRect()
    const r = e.currentTarget.getBoundingClientRect()
    const w = box?.width ?? 720
    const left = r.left - (box?.left ?? 0)
    setAt(left + width > w ? { right: Math.max(0, (box?.right ?? w) - r.right) } : { left: Math.max(0, left) })
  }
  const ref = useRef<HTMLTextAreaElement>(null)
  // One line until you write more, then it grows to ten lines, then scrolls inside.
  // Empty, it's the stylesheet's one line: Chrome counts the placeholder in scrollHeight.
  const grow = (el: HTMLTextAreaElement) => {
    el.style.height = 'auto'
    el.style.height = el.value ? `${Math.min(el.scrollHeight, 226)}px` : ''
  }
  const working = p.state === 'working', paused = p.state === 'paused'
  // Typing stops the cycle for good; autofocus alone doesn't.
  const [typed, setTyped] = useState(false)
  const sug = useSuggestion(p.suggestion, !typed && !text)
  const timer = useTimer(working ? p.startedAt : undefined)
  useEffect(() => { if (p.draft !== undefined) setText(p.draft) }, [p.draft])
  useEffect(() => { if (ref.current) grow(ref.current) }, [text])
  useEffect(() => { if (p.autoFocus) ref.current?.focus() }, [p.autoFocus])
  useEffect(() => { if (p.pickRepo) setMenu('repo') }, [p.pickRepo])
  // The menus share one filter: each opens with it empty.
  useEffect(() => { setQ('') }, [menu])
  // A menu closes on any click outside it (its own chip toggles it), or Escape.
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
    stackOpen: false, lastSent: '', yoloConfirmed: false, dictating: false, memory: { modelByPlace: {}, worktreeByRepo: {}, branchByRepo: {} } as Tray['memory'],
  })
  // Out of credit (the engine paused the turn) is the status line's no_credit error until dismissed.
  const [pausedSeen, setPausedSeen] = useState(false)
  useEffect(() => { if (!paused) setPausedSeen(false) }, [paused])
  const [bindRef, setBindRef] = useState('')
  const recog = useRef<SpeechLike | null>(null)
  useEffect(() => () => recog.current?.stop(), [])

  const [images, setImages] = useState<Image[]>([])
  const file = useRef<HTMLInputElement>(null)
  useEffect(() => {
    if (!p.restore) return
    setText((t) => (t ? `${p.restore!.text}\n${t}` : p.restore!.text))
    setImages((im) => [...p.restore!.images, ...im])
  }, [p.restore])
  useEffect(() => {
    if (!p.insert) return
    const el = ref.current
    const add = p.insert.text
    setText((t) => {
      const at = el && document.activeElement === el ? el.selectionStart : t.length
      const before = t.slice(0, at), after = t.slice(at)
      const pad = before && !/\s$/.test(before) ? ' ' : ''
      const next = before + pad + add + after
      requestAnimationFrame(() => { if (!el) return; el.focus(); const c = before.length + pad.length + add.length; el.setSelectionRange(c, c) })
      return next
    })
  }, [p.insert?.n]) // eslint-disable-line react-hooks/exhaustive-deps
  const onText = p.onText
  useEffect(() => { onText?.(text) }, [text, onText])
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
  const pasteShot = async () => {
    ref.current?.focus()
    try {
      const items = await navigator.clipboard.read()
      const blobs: File[] = []
      for (const it of items) for (const t of it.types) if (t.startsWith('image/')) blobs.push(new File([await it.getType(t)], 'screenshot', { type: t }))
      if (blobs.length) attach(blobs)
    } catch { /* no clipboard access: ⌘V into the field still works */ }
  }
  const putIn = (s: string, atStart = false) => {
    setText((t) => (atStart ? s + t : t && !/\s$/.test(t) ? `${t} ${s}` : t + s))
    requestAnimationFrame(() => ref.current?.focus())
  }
  const send = () => {
    const t = text.trim()
    if (p.onSignIn) { setMenu('signin'); return }
    // Out of credit the turn can't run: the draft stays, and the status line says why.
    if ((!t && !images.length) || p.busy || paused) return
    // "/compact [what to keep]" asks the engine to summarize rather than sending a message.
    const c = t.match(/^\/compact\b\s*(.*)$/s)
    // While a turn runs it stays typed; compacting mid-turn isn't possible.
    if (c && p.onCompact) { if (!working) { p.onCompact(c[1].trim() || undefined); setText('') } return }
    p.onSend(t, images, true)
    // A notice is about the last thing Frog did for you; it clears on the next send.
    setLocal((l) => ({ ...l, lastSent: t, notice: null }))
    setText('')
    setImages([])
  }
  const cloudModel = { id: p.model ?? '', name: p.model ? modelName(p.model) : 'Default model', place: 'cloud' as const, node: null }
  const hasGit = (p.adds ?? 0) + (p.dels ?? 0) > 0
  const repoKey = p.repo ?? 'No repo'
  const tray: Tray = {
    draft: { text, attachments: images.map((im) => ({ name: 'image', size: Math.floor(im.data.length * 0.75), type: im.mime })), caret: text.length },
    lastSent: local.lastSent,
    mode: toTray(p.mode),
    yoloConfirmed: local.yoloConfirmed,
    model: cloudModel,
    defaults: { local: null, cloud: cloudModel },
    signedIn: !p.onSignIn,
    where: p.session
      ? { kind: 'session', repo: p.repo || null, branch: p.branch ?? '', worktree: false, worktreePath: null, diff: { add: p.adds ?? 0, del: p.dels ?? 0, files: hasGit ? 1 : 0 }, dirty: hasGit, ahead: p.ahead ?? 0, prs: p.prs ?? [] }
      : { kind: 'cloud', repo: repoKey, branch: p.base ?? local.memory.branchByRepo[repoKey] ?? 'main' },
    busy: p.busy ? 'sending' : working ? 'working' : 'idle',
    pending: null,
    queued: (p.queued ?? []).map((x) => ({ text: x.text, attachments: x.images.map((im) => ({ name: 'image', size: Math.floor(im.data.length * 0.75), type: im.mime })) })),
    dictating: local.dictating,
    error: local.error ?? (paused && !pausedSeen ? reducerError({ defaults: { local: null } } as Tray, 'no_credit') : null),
    notice: local.notice,
    confirm: local.confirm,
    stackOpen: local.stackOpen,
    memory: local.memory,
    ...p.tray,
  }
  const d = derive(tray)
  // The suggestion, while the field is empty, takes the placeholder's place: the placeholder
  // carries its words for screen readers, and the overlay draws them so they can fade.
  const ghost = !text && !images.length && !working ? sug.text : null
  const take = () => { if (!ghost) return; setText(ghost); setTyped(true); ref.current?.focus() }
  const placeholder = ghost ?? (working ? PLACEHOLDER.working : p.session ? PLACEHOLDER.session : PLACEHOLDER.new)
  const dictate = () => {
    const Rec = speech()
    // Without the browser's recognition, the field takes focus for the OS keyboard's own mic.
    if (!Rec) { ref.current?.focus(); return }
    const r = new Rec()
    r.continuous = true
    r.interimResults = false
    const start = text
    let said = ''
    r.onresult = (e) => {
      for (let i = e.resultIndex; i < e.results.length; i++) if (e.results[i].isFinal) said += e.results[i][0].transcript
      setText(start && said ? `${start.replace(/\s*$/, ' ')}${said.trim()}` : said.trim() || start)
    }
    // The browser calls these renders later: they go through the latest dispatch, so they reduce
    // the state as it is then (a refused mic fires error, then end).
    r.onerror = (e) => { if (e.error === 'not-allowed' || e.error === 'service-not-allowed') latest.current({ type: 'mic_denied' }) }
    r.onend = () => { recog.current = null; latest.current({ type: 'dictation_ended' }) }
    recog.current = r
    try { r.start(); dispatch({ type: 'dictation_started' }) } catch { recog.current = null }
  }
  const run = (e: Effect, next: Tray) => {
    switch (e.type) {
      case 'submit': case 'start_session':
        if (next.pending === 'aside') p.onSend(String(e.text ?? ''), [])
        else send()
        break
      // The app routes a send while working onto its queue, and the field clears as send clears it.
      case 'queued':
        if ((e.attachments as unknown[] | undefined)?.length === images.length && e.text === text.trim()) send()
        else p.onSend(String(e.text ?? ''), [])
        break
      case 'remove_queued': p.onUnqueue?.(Number(e.index)); break
      case 'interrupt': p.onStop?.(); break
      case 'set_mode': p.onMode?.(fromTray(e.mode as Tray['mode'])); break
      case 'open_login': setMenu('signin'); break
      case 'open_billing': p.usage?.onBilling(); break
      case 'draft_commit': case 'open_pr': case 'push': case 'pull_push': p.onGit?.(); break
      case 'open_url': window.open(String(e.url), '_blank', 'noopener'); break
      case 'copy': navigator.clipboard?.writeText(String(e.text)).catch(() => {}); break
      case 'bind_pr': p.onBindPr?.(String(e.ref)); break
      case 'start_dictation': dictate(); break
      case 'stop_dictation': recog.current?.stop(); break
    }
  }
  function dispatch(i: Intent) {
    const [next, effects] = reduce(tray, i)
    if (i.type === 'dismiss_error' || i.type === 'esc' || i.type === 'error_action') if (paused) setPausedSeen(true)
    setLocal((l) => ({ ...l, error: next.error === tray.error && !local.error ? null : next.error, notice: next.notice, confirm: next.confirm, stackOpen: next.stackOpen, lastSent: next.lastSent, yoloConfirmed: next.yoloConfirmed, dictating: next.dictating, memory: next.memory }))
    if ((i.type === 'recall' || i.type === 'suggestion') && next.draft.text !== text) setText(next.draft.text)
    for (const e of effects) run(e, next)
  }
  const latest = useRef(dispatch)
  latest.current = dispatch
  const marked = (control: string) => (tray.error?.control === control ? ' cz-marked' : '')
  const toggle = (m: MenuName) => setMenu(menu === m ? null : m)

  // The session summary's bound PR (a string, with no state yet) is git state to show too.
  const status = d.status === 'none' && tray.where.kind === 'session' && tray.where.repo && p.pr && !d.prSummary ? 'git' : d.status
  const statusLine = (() => {
    switch (status) {
      case 'error': {
        const e = tray.error!
        // The button that fixes it most directly is last and has the plate (board 5).
        // No local model on the web: never offer one, even from an error made elsewhere.
        const [first, second] = e.actions.filter((a) => a !== 'use_local' || !!tray.defaults.local)
        const word = (a: string) => (a === 'retry' && e.retryIn ? `Retry in ${e.retryIn}s` : ACTION_WORD[a] ?? a)
        return (
          <div className="cz-status" role="alert">
            <I d={P.warn} className="cz-warn" />
            <b className="cz-st-text" title={e.detail ?? undefined}>{e.message}</b>
            <span className="cz-sp" />
            {second && <button type="button" className="cz-tb cz-tb--quiet" onClick={() => dispatch({ type: 'error_action', action: second })}>{word(second)}</button>}
            {first && <button type="button" className="cz-tb" onClick={() => dispatch({ type: 'error_action', action: first })}>{word(first)}</button>}
            {!first && <button type="button" className="cz-x" aria-label="Dismiss" onClick={() => dispatch({ type: 'dismiss_error' })}><I d={P.x} /></button>}
          </div>
        )
      }
      case 'confirm': {
        const top = tray.where.kind === 'session' ? tray.where.prs.find((x) => x.state === 'approved') ?? tray.where.prs[0] : undefined
        const [say, yes] = tray.confirm === 'yolo' ? ['Yolo runs every step without asking', 'Use Yolo']
          : tray.confirm === 'merge' ? [`Merge ${top ? `#${top.number}` : 'this PR'}?`, 'Merge']
          : ['Archive and delete the worktree, changes and all?', 'Archive']
        return (
          <div className="cz-status" role="alertdialog" aria-label="Confirm">
            <b className="cz-st-text">{say}</b>
            <span className="cz-sp" />
            <button type="button" className="cz-tb cz-tb--quiet" onClick={() => dispatch({ type: 'cancel_confirm' })}>Cancel</button>
            <button type="button" className="cz-tb" onClick={() => dispatch({ type: 'confirm' })}>{yes}</button>
          </div>
        )
      }
      case 'notice':
        return (
          <div className="cz-status" role="status">
            <b className="cz-st-text">{tray.notice}</b>
            <span className="cz-sp" />
            <button type="button" className="cz-x" aria-label="Dismiss" onClick={() => setLocal((l) => ({ ...l, notice: null }))}><I d={P.x} /></button>
          </div>
        )
      case 'git': {
        const w = tray.where
        if (w.kind !== 'session') return null
        const one = d.prSummary?.count === 1 ? w.prs[0] : null
        return (
          <div className="cz-status cz-git" aria-label="This session's repository">
            <I d={P.folder} />
            {w.repo && <a className="cz-st-repo" href={`https://github.com/${w.repo}`} target="_blank" rel="noreferrer" title={w.repo}>{w.repo.split('/')[1] ?? w.repo}</a>}
            {w.branch && <span className="cz-st-branch" title={w.branch}>{w.branch}</span>}
            {w.diff.add + w.diff.del > 0 && (
              <button type="button" className="cz-st-diff" onClick={p.onGit} title="Uncommitted changes"><span className="cz-add">+{w.diff.add}</span> <span className="cz-del">−{w.diff.del}</span></button>
            )}
            {w.ahead > 0 && !(w.diff.add + w.diff.del) && <span className="cz-st-ahead">{w.ahead} ahead</span>}
            <span className="cz-sp" />
            {one && (
              <button type="button" className="cz-st-pr" title={`${one.title}. Alt-click copies the link`} onClick={(e) => dispatch({ type: 'pr_click', index: 0, alt: e.altKey })}>
                <span className="cz-prdot" style={{ background: prDot(one.state) }} aria-hidden="true" />#{one.number} {one.access === false ? 'no access' : PR_WORD[one.state]}
              </button>
            )}
            {d.prSummary && d.prSummary.count > 1 && (
              <button type="button" className="cz-st-pr" aria-expanded={tray.stackOpen} onClick={() => dispatch({ type: tray.stackOpen ? 'close_stack' : 'open_stack' })}>
                <span className="cz-prdot" style={{ background: prDot(d.prSummary.worst) }} aria-hidden="true" />{d.prSummary.label}<I d={P.chevron} />
              </button>
            )}
            {!d.prSummary && p.pr && <span className="cz-st-branch" title={`Bound to ${p.pr}`}>{p.pr}</span>}
            {d.gitAction && (
              <button type="button" className={`cz-tb${d.openPr ? ' cz-tb--go' : ''}${marked('git_action')}`} disabled={tray.busy === 'sending'}
                title={d.openPr ? 'The work is done: push this branch and open a pull request' : undefined}
                onClick={() => dispatch({ type: 'git_action' })}>{GIT_LABEL[d.gitAction]}</button>
            )}
          </div>
        )
      }
    }
    return null
  })()

  const where = tray.where.kind === 'cloud' ? tray.where : null
  const whereName = p.repo || 'Scratch sandbox'
  const model = p.model ? modelName(p.model) : 'Default model'
  const modelPlace = placeOf(p.model ? spec(p.model) : null)
  const signedOut = !!p.onSignIn

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
        <div className="cz-menu" role="menu" aria-label="Attach" style={{ left: 8, width: 240 }} {...nav}>
          <button type="button" role="menuitem" onClick={() => { setMenu(null); file.current?.click() }}><I d={P.file} />Attach a file…</button>
          <button type="button" role="menuitem" onClick={() => { setMenu(null); pasteShot() }}><I d={P.shot} />Paste a screenshot</button>
          <button type="button" role="menuitem" onClick={() => { setMenu(null); putIn('@') }}><span className="cz-i" />Mention a file<span className="cz-k">@</span></button>
          <button type="button" role="menuitem" onClick={() => { setMenu(null); putIn('!', true) }}><span className="cz-i" />Run a command<span className="cz-k">!</span></button>
        </div>
      )}

      {menu === 'model' && (() => {
        const match = (s: string) => s.toLowerCase().includes(q.trim().toLowerCase())
        const cloud = (p.models ?? []).filter((m) => match(modelName(m.id)))
        const local = localRows(p.machines ?? []).filter((m) => match(m.name))
        return (
          <div className="cz-menu cz-models" role="menu" aria-label="Model" style={{ ...at, width: 'min(400px, calc(100vw - 32px))' }} {...nav}>
            <label className="cz-filter"><I d={P.search} /><input autoFocus value={q} placeholder="Search models" aria-label="Search models" onChange={(e) => setQ(e.target.value)} /></label>
            {/* The web runs sessions in Frog Cloud, so a local model can't run here: its row is
             * a link to Frog for Mac (or to getting it), never a cloud pick and never dead. */}
            {(local.length > 0 || !q.trim()) && <div className="cz-menu-h">Run it on your Mac</div>}
            {local.map((m) => (
              <a key={m.key} className="cz-row cz-local" role="menuitem" href={handoff.href} title={handoff.title}
                aria-label={`${m.name}, runs on your Mac${m.on ? ` (${m.on})` : ''}, ${handoff.does}`}
                onClick={() => { setMenu(null); setQ('') }}>
                <I d={P.laptop} style={{ color: placeColor('local') }} />
                <span className="cz-mname">{m.name}</span>{m.on && <span className="cz-on">{m.on}</span>}
                <span className="cz-r">$0 a token</span>
                <I d={P.out} className="cz-out" />
              </a>
            ))}
            {!q.trim() && !hasThisMac(p.machines ?? []) && (machineChip
              ? <div className="cz-menu-note"><DownloadAppChip label="Runs from the Mac app" machines={p.machines} /></div>
              : phone && <div className="cz-menu-note">Runs from the Mac app. <a href="/mac">Get the Mac app</a></div>)}
            {cloud.length > 0 && <div className="cz-menu-h">Frog Cloud</div>}
            {cloud.map((m) => (
              <button key={m.id} type="button" role="menuitemradio" aria-checked={m.id === p.model} onClick={() => { p.onModel?.(m.id); setMenu(null); setQ('') }}>
                <I d={P.cloud} style={{ color: placeColor('cloud') }} />
                <span className="cz-mname">{modelName(m.id)}</span><span className="cz-r">{inOutPrice(m)}</span>
                <I d={P.check} className={`cz-check${m.id === p.model ? '' : ' off'}`} />
              </button>
            ))}
            {p.onManage && (<>
              <div className="cz-menu-sep" />
              <button type="button" role="menuitem" onClick={() => { setMenu(null); p.onManage!() }}>Manage…</button>
            </>)}
          </div>
        )
      })()}

      {menu === 'repo' && signedOut && (
        <div className="cz-menu cz-repos" role="menu" aria-label="Where it runs" style={{ left: 8, width: 300 }} {...nav}>
          <div className="cz-menu-h">Frog Cloud</div>
          <button type="button" role="menuitem" className="cz-dim" onClick={() => setMenu('signin')}><I d={P.cloud} />Sign in to use Frog Cloud</button>
        </div>
      )}
      {menu === 'repo' && !signedOut && p.onRepo && (() => {
        const typed = parseRepo(q)
        // The best few (repoRank.ts); the rest are a search away, with one line saying how many.
        const ranked = rankRepos(p.repo, p.recent ?? [], (p.repos ?? []).map((name) => ({ name, pushed_at: p.pushed?.[name] ?? null })))
        const { shown: list, more } = pickRepos(ranked, q)
        const line = moreLine(more, !!q.trim())
        const same = (r: string) => r.toLowerCase() === p.repo?.toLowerCase()
        const pick = (r: string | undefined) => { p.onRepo!(r); setMenu(null); setQ(''); ref.current?.focus() }
        const tick = (on: boolean) => <I d={P.check} className={`cz-check${on ? '' : ' off'}`} />
        return (
          <div className="cz-menu cz-repos" role="menu" aria-label="Where it runs" style={{ left: 8, width: 340 }} {...nav}>
            <label className="cz-filter"><I d={P.search} />
              <input autoFocus value={q} placeholder="Search your repos" aria-label="Search your repos, or paste a GitHub URL"
                onChange={(e) => setQ(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); const r = typed ?? list[0]; if (r) pick(r) } }} />
            </label>
            {typed && !list.some((r) => r.toLowerCase() === typed.toLowerCase()) && <button type="button" role="menuitem" onClick={() => pick(typed)}><I d={P.cloud} />{typed}<span className="cz-r">from GitHub</span></button>}
            {!q && <button type="button" role="menuitemradio" aria-checked={!p.repo} onClick={() => pick(undefined)}><I d={P.cloud} />Scratch sandbox{tick(!p.repo)}</button>}
            {list.length > 0 && <div className="cz-menu-h">Your repos</div>}
            <div className="cz-list">
              {list.map((r) => (
                <button key={r} type="button" role="menuitemradio" aria-checked={same(r)} onClick={() => pick(r)}><I d={P.cloud} /><span className="cz-mname">{r}</span>{tick(same(r))}</button>
              ))}
            </div>
            {line && <div className="cz-menu-note cz-more">{line}</div>}
            {!typed && list.length === 0 && q && <div className="cz-menu-note">No match. Type owner/name or paste a GitHub URL.</div>}
            {p.onConnectGithub && <button type="button" role="menuitem" className="cz-dim" onClick={() => p.onConnectGithub!(text)}>{gh(14)}Connect GitHub to see your repos</button>}
            {/* No repos yet: say why, and make giving access the way on. Before GitHub is connected there's nothing to give access to. */}
            {!q && list.length === 0 && !p.onConnectGithub && <div className="cz-menu-note">Frog sees only the repos you give it access to.</div>}
            {safeHref(p.install) && !p.onConnectGithub && <a className={`${!q && list.length === 0 ? '' : 'cz-dim '}cz-row`} role="menuitem" href={safeHref(p.install)!.href} target="_blank" rel="noreferrer"><I d={P.plus} />{!q && list.length === 0 ? 'Pick repos on GitHub' : 'Give Frog access to more repos'}</a>}
            {p.repo && (<>
              <div className="cz-menu-sep" />
              <button type="button" role="menuitem" onClick={() => { setQ(''); setMenu('branch') }}>Branch<span className="cz-r">{where?.branch ?? 'main'}</span><I d={P.chevronRight} className="cz-dim" /></button>
            </>)}
          </div>
        )
      })()}
      {menu === 'branch' && where && (() => {
        const name = q.trim()
        const pick = (b: string) => { dispatch({ type: 'pick_branch', branch: b }); p.onBase?.(b === 'main' ? undefined : b); setMenu(null); setQ(''); ref.current?.focus() }
        const rows = [...new Set(['main', where.branch])].filter((b) => b.toLowerCase().includes(name.toLowerCase()))
        return (
          <div className="cz-menu" role="menu" aria-label="Branch" style={{ left: 8, width: 300 }} {...nav}>
            <label className="cz-filter"><I d={P.search} />
              <input autoFocus value={q} placeholder="Search branches" aria-label="Search branches" onChange={(e) => setQ(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); if (name) pick(name) } }} />
            </label>
            {rows.map((b) => <button key={b} type="button" role="menuitemradio" aria-checked={b === where.branch} onClick={() => pick(b)}><span className="cz-mname">{b}</span><I d={P.check} className={`cz-check${b === where.branch ? '' : ' off'}`} /></button>)}
            {name && !rows.includes(name) && <button type="button" role="menuitem" onClick={() => pick(name)}>Start from {name}</button>}
          </div>
        )
      })()}
      {menu === 'signin' && p.onSignIn && (
        <div className="cz-menu" role="menu" aria-label="Sign in" style={{ right: 8, width: 230 }} {...nav}>
          <button type="button" role="menuitem" onClick={() => p.onSignIn!('github', text.trim())}>{gh(14)}Continue with GitHub</button>
          <button type="button" role="menuitem" onClick={() => p.onSignIn!('google', text.trim())}>{google(14)}Continue with Google</button>
        </div>
      )}
      {menu === 'mode' && (
        <div className="cz-menu cz-modes" role="menu" aria-label="When Frog asks" style={{ ...at, width: 280 }} {...nav}>
          <div className="cz-menu-h">When Frog asks</div>
          {MODES.map((m) => (
            <button key={m.id} type="button" role="menuitemradio" aria-checked={m.id === tray.mode} onClick={() => { dispatch({ type: 'set_mode', mode: m.id }); setMenu(null) }}>
              <span className="cz-m2">
                <span className="cz-m2-name">{m.id === 'yolo' && <I d={P.bolt} className="cz-bolt" />}{m.name}</span>
                <span className="cz-m2-note">{m.note}</span>
              </span>
              <I d={P.check} className={`cz-check${m.id === tray.mode ? '' : ' off'}`} />
            </button>
          ))}
        </div>
      )}
      {tray.stackOpen && tray.where.kind === 'session' && (
        <div className="cz-menu cz-stack" role="menu" aria-label="Bound PRs" style={{ right: 8, width: 440 }}>
          {tray.where.prs.map((pr, i) => (
            <button key={`${pr.repo}#${pr.number}`} type="button" role="menuitem" onClick={(e) => dispatch({ type: 'pr_click', index: i, alt: e.altKey })}>
              <span className="cz-prdot" style={{ background: prDot(pr.state) }} aria-hidden="true" />
              <span>#{pr.number}</span><span className="cz-mname">{pr.title}</span>
              <span className="cz-r">{pr.access === false ? 'no access' : `${PR_WORD[pr.state]}${pr.state === 'checks' || pr.state === 'failing' ? `, ${pr.checks.ok} of ${pr.checks.total}` : ''}`}</span>
            </button>
          ))}
          <input className="cz-bind" value={bindRef} placeholder="Bind a PR by URL or number…" aria-label="Bind a PR by URL or number"
            onChange={(e) => setBindRef(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); dispatch({ type: 'bind_pr', ref: bindRef }); setBindRef('') } }} />
        </div>
      )}

      <div className={`cz-card${tray.busy === 'sending' ? ' cz-sending' : ''}`}
        onDragOver={(e) => { if ([...e.dataTransfer.items].some((i) => i.type.startsWith('image/'))) e.preventDefault() }}
        onDrop={(e) => { if (e.dataTransfer.files.length) { e.preventDefault(); attach(e.dataTransfer.files) } }}>
        <input ref={file} type="file" accept="image/*" multiple hidden onChange={(e) => { if (e.target.files) attach(e.target.files); e.target.value = '' }} />
        {statusLine}
        {(tray.queued.length > 0 || images.length > 0) && (
          <div className="cz-q">
            {tray.queued.map((x, i) => (
              <span key={`q${i}`} className="cz-qi cz-qi--queued" title="Goes in with the next turn">
                <span className="cz-qi-text">{x.text || `${x.attachments.length} image${x.attachments.length === 1 ? '' : 's'}`}</span>
                {x.text && x.attachments.length > 0 && <span className="cz-qi-meta">+{x.attachments.length}</span>}
                <button type="button" className="cz-qx" aria-label={`Remove queued message ${i + 1}`} onClick={() => dispatch({ type: 'remove_queued', index: i })}><I d={P.x} /></button>
              </span>
            ))}
            {images.map((im, i) => (
              <span key={`a${i}`} className="cz-qi">
                <span className="cz-qi-text">image{images.length > 1 ? ` ${i + 1}` : ''}.{im.mime.split('/')[1] ?? 'png'}</span>
                <span className="cz-qi-meta">{kb(Math.floor(im.data.length * 0.75))}</span>
                <button type="button" className="cz-qx" aria-label="Remove image" onClick={() => setImages(images.filter((_, j) => j !== i))}><I d={P.x} /></button>
              </span>
            ))}
            {images.length > 0 && p.vision === false && <span className="cz-qi-meta">This model can't see images; it gets a note that one was attached.</span>}
          </div>
        )}
        <label htmlFor="cz" className="sr">Message Frog</label>
        <div className={`cz-field${ghost ? ' cz-field--sug' : ''}`}>
        {ghost && (
          <div className={`cz-sg${sug.out ? ' out' : ''}`}>
            <span className="cz-sg-text" aria-hidden="true">{ghost}</span>
            <button type="button" className="cz-tab" tabIndex={-1} aria-label={`Use suggestion: ${ghost}`} onClick={take}>tab</button>
          </div>
        )}
        <textarea
          id="cz" ref={ref} rows={1} placeholder={placeholder} value={text} aria-label="Message Frog"
          onChange={(e) => { setText(e.target.value); if (e.target.value) setTyped(true); grow(e.target) }}
          onPaste={(e) => { const fs = [...e.clipboardData.files].filter((f) => f.type.startsWith('image/')); if (fs.length) { e.preventDefault(); attach(fs) } }}
          onKeyDown={(e) => {
            if (composing(e)) return
            // Tab takes the suggestion only while it shows; otherwise it moves focus as ever.
            if (e.key === 'Tab' && ghost && !e.shiftKey && !e.altKey && !e.ctrlKey && !e.metaKey) { e.preventDefault(); take(); return }
            if (e.key === 'Enter' && !e.shiftKey && !e.metaKey) { e.preventDefault(); send() }
            if (e.key === 'Escape') dispatch({ type: 'esc' })
            if (e.key === 'ArrowUp' && !text) dispatch({ type: 'recall' })
            // ⌘. does one thing: with a permission card on screen the app's handler denies it;
            // otherwise it cycles the mode here.
            if (e.key === '.' && (e.ctrlKey || e.metaKey) && !p.asking) { e.preventDefault(); dispatch({ type: 'cycle_mode' }) }
          }}
        />
        </div>
        <div className="cz-controls">
          <button type="button" className={`cz-chip cz-attach${menu === 'plus' ? ' open' : ''}`} onClick={() => toggle('plus')} aria-label="Attach" aria-expanded={menu === 'plus'}>
            <I d={P.plus} />
          </button>
          {where && (
            <button type="button" className={`cz-chip cz-where${menu === 'repo' || menu === 'branch' ? ' open' : ''}${marked('where')}`} disabled={!p.onRepo && !signedOut}
              aria-expanded={menu === 'repo' || menu === 'branch'} aria-label={`Where it runs: ${whereName}${p.repo ? `, ${where.branch}` : ''}`}
              onClick={() => setMenu(menu === 'repo' || menu === 'branch' ? null : 'repo')}>
              <I d={P.cloud} />
              {/* Truncates in the middle on a narrow card: the head shrinks, the tail stays. */}
              <b className="cz-where-name"><span className="cz-where-head">{whereName.slice(0, -4)}</span><span className="cz-where-tail">{whereName.slice(-4)}</span></b>
              {p.repo && <span className="cz-where-branch">{where.branch}</span>}
              <I d={P.chevron} />
            </button>
          )}
          <span className="cz-sp" />
          {working && !p.waiting && <span className="cz-meta" aria-live="off">{timer}{p.speed && p.speed > 0 ? `, ${Math.round(p.speed)} tok/s` : ''}</span>}
          {p.context?.window || p.usage?.sub ? <ContextRing used={p.context?.used ?? null} window={p.context?.window ?? 0} usage={p.usage} onCompact={p.onCompact && !working ? () => p.onCompact!() : undefined} compacting={p.compacting} /> : null}
          {p.onMode && (
            <button type="button" className={`cz-chip${menu === 'mode' ? ' open' : ''}`} aria-expanded={menu === 'mode'} aria-label={`When Frog asks: ${MODE_NAME[tray.mode]}`}
              title="When Frog asks before acting (⌘.)" onClick={(e) => { anchor(e, 280); toggle('mode') }}>
              {tray.mode === 'yolo' && <I d={P.bolt} className="cz-bolt" />}{MODE_NAME[tray.mode]}
            </button>
          )}
          {(!!p.model || !!p.models?.length) && (
            <button type="button" className={`cz-chip cz-model${menu === 'model' ? ' open' : ''}`} aria-label={`Model: ${model}`} aria-expanded={menu === 'model'}
              disabled={!p.models?.length || !p.onModel} onClick={(e) => { anchor(e, 320); setQ(''); toggle('model') }}>
              <I d={modelPlace === 'cloud' ? P.cloud : P.laptop} style={{ color: placeColor(modelPlace) }} />
              <span className="cz-model-name">{model}</span>
            </button>
          )}
          {signedOut ? (
            <button type="button" className="cz-signin" aria-expanded={menu === 'signin'} onClick={() => toggle('signin')}>Sign in</button>
          ) : tray.busy === 'sending' ? (
            <span className="cz-act cz-act--sending" role="img" aria-label="Sending" />
          ) : (
            <button type="button" className={`cz-act cz-act--${d.action}${marked('action')}`} disabled={d.action === 'send' && paused}
              aria-label={d.action === 'dictate' ? 'Dictate' : d.action === 'listening' ? 'Stop dictation' : d.action === 'stop' ? 'Stop (Esc)' : d.action === 'queue' ? 'Queue a follow-up' : 'Send'}
              onClick={() => (d.action === 'send' || d.action === 'queue' ? send() : dispatch({ type: 'action' }))}>
              <span className="cz-glyph" key={d.action}>
                {d.action === 'dictate' && <I d={P.mic} />}
                {d.action === 'listening' && <I d={P.wave} />}
                {d.action === 'stop' && <svg aria-hidden="true" className="cz-i" viewBox="0 0 16 16"><rect x="5" y="5" width="6" height="6" rx="1.2" fill="currentColor" stroke="none" /></svg>}
                {(d.action === 'send' || d.action === 'queue') && <I d={P.up} />}
              </span>
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
      <button type="button" ref={button} className="ctx-ring" aria-haspopup="dialog" aria-expanded={open} onClick={() => { if (!open) usage?.onOpen?.(); setOpen(!open) }} aria-label={ringLabel(sub ? plan : null, window > 0 ? ctx : null)} title={ringLabel(sub ? plan : null, window > 0 ? ctx : null)}>
        <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
          <circle cx="9" cy="9" r={r} fill="none" stroke="var(--line-strong)" strokeWidth="2.5" />
          <circle cx="9" cy="9" r={r} fill="none" stroke={color} strokeWidth="2.5" strokeLinecap="round"
            strokeDasharray={`${f * c} ${c}`} transform="rotate(-90 9 9)" style={{ transition: 'stroke-dasharray .4s' }} />
        </svg>
      </button>
      {open && (
        <div className="f-card ctx-card" role="dialog" aria-label="Usage and context" {...trap}>
          {sub && (<>
            <div className="ctx-h"><span className="det">Plan usage, {sub.name}</span>{usage && <button type="button" className="ctx-link" onClick={() => { setOpen(false); usage.onBilling() }}>See all →</button>}</div>
            {sub.windows.filter((w) => w.limit > 0).map((w) => {
              const x = Math.min(1, w.used / w.limit)
              const when = new Date(w.resets_at).toLocaleString(undefined, w.kind === '5h' ? { hour: 'numeric', minute: '2-digit' } : { weekday: 'short', hour: 'numeric', minute: '2-digit' })
              return (
                <div key={w.kind} className="ctx-row">
                  <div className="ctx-h"><span>{w.kind === '5h' ? 'Session limit' : 'Weekly'}</span><span className="det">{w.resets_at ? `Resets ${when}` : 'Starts when a message is sent'}, {Math.round(x * 100)}%</span></div>
                  <div className="ctx-bar"><span style={{ width: `${x * 100}%`, background: barTone(x) }} /></div>
                </div>
              )
            })}
          </>)}
          {usage && (
            <div className="ctx-h"><span>Usage credits</span><span className="det">{sub?.over ? `paying now, ${usage.credit} left` : `${usage.credit} left`}</span></div>
          )}
          {window > 0 && (<>
            {usage && <div className="ctx-sep" />}
            <div className="ctx-h"><span>Context</span><span className="det">{(used ?? 0).toLocaleString()} of {window.toLocaleString()} tokens, {Math.round(ctx * 100)}%</span></div>
            <div className="ctx-bar"><span style={{ width: `${ctx * 100}%`, background: barTone(ctx) }} /></div>
            {(compacting || (onCompact && canCompact(used, window))) && (
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
