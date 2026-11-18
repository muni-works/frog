import type { Op, ReportKind, ReportLevel } from './cloud/protocol'

// The web Preview pane's brain, a port of the Mac's PaneHub (apps/FrogKit/Model/ToolPanes.swift)
// and PreviewHost (apps/macos/Frog/Views/PreviewPane.swift). The page runs in an iframe at its own
// origin (the gateway's preview host, zest sandbox/src/preview.ts), where public/preview.js
// reports what it does by postMessage. This turns those messages into the same `pane_report`s
// and `pane_mention`s the Mac sends, and answers the engine's `pane_request`s.
//
// The engine and the model only ever see the sandbox's own URLs (`http://localhost:5173/x`); the
// preview origin is the browser's business, swapped out of everything reported.

export interface PaneReport { id: string; kind: ReportKind; level?: ReportLevel; message: string; url?: string; status?: number }
export interface PaneRequest { call: string; id: string; action: string; args?: Record<string, unknown> }

/** One mounted iframe. */
export interface Frame {
  /** postMessage into the page (it only listens to its parent). */
  post(m: Record<string, unknown>): void
  /** Point the iframe at `src`. */
  load(src: string): void
}

/** What one preview pane shows, for its toolbar. */
export interface PreviewState {
  /** The page as the sandbox sees it (`http://localhost:5173/x`), or another URL as typed. */
  url?: string
  /** What the iframe loads. */
  src?: string
  title: string
  loading: boolean
  /** Why the last load failed, until the next one starts. */
  error?: string
  /** Pages committed, so Back knows whether there's somewhere to go. */
  pages: number
  /** Where in its history the page is (0 = the first page committed), and how many it has, so
   * Back and Forward know whether there's somewhere to go. -1 before anything commits. */
  index: number
  length: number
}

const LOCAL = /^https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):(\d{1,5})(\/.*)?$/i

/** A dev server in the sandbox: `http://localhost:5173/x?y` → its port and path. */
export function localTarget(url: string): { port: number; path: string } | null {
  const m = url.trim().match(LOCAL)
  if (!m) return null
  const port = Number(m[1])
  return port > 0 && port < 65536 ? { port, path: m[2] || '/' } : null
}

/** What's in the address field as a URL: a URL, a host without a scheme, or just a port (the Mac's `go()`). */
export function addressURL(raw: string): string | null {
  const s = raw.trim()
  if (!s) return null
  if (/^\d+$/.test(s)) return `http://localhost:${s}`
  if (s.includes('://')) return s
  if (s.startsWith(':')) return `http://localhost${s}`
  return `http://${s}`
}

/** The page's address as the address field shows it: host and path, port kept, no scheme and no
 * lone trailing slash (`http://localhost:5173/` → `localhost:5173`). Not a URL: as is. */
export function displayAddress(url: string | undefined): string {
  if (!url) return ''
  const m = url.match(/^https?:\/\/(.*)$/i)
  if (!m) return url
  const rest = m[1]
  const slash = rest.indexOf('/')
  if (slash < 0) return rest
  const host = rest.slice(0, slash), path = rest.slice(slash)
  return path === '/' ? host : host + path
}

/** What the engine gets when the web preview can't do something the Mac can. */
export const NO_SCREENSHOT = "the web preview can't take screenshots yet; use read to see the page"

const REQUEST_GIVE_UP_MS = 18_000 // the engine waits 20s
const NAVIGATE_WAIT_MS = 15_000
const MINT_MARGIN_MS = 10 * 60_000
/** Where a minted link enters the preview (zest sandbox/src/preview.ts ENTER_PATH): a one-minute
 * token that sets the preview host's owner cookie and lands on `/`. */
export const ENTER_PATH = '/__frog/enter'

/** What the gateway mints for a sandbox port. `url` is a one-minute entry link (never reused);
 * `origin` is the preview's own origin; `expires` is when the label behind both dies (8 h). */
export interface Minted { url: string; origin?: string; expires: number }

type Reply = (result: unknown, error?: string) => void

export class PreviewHub {
  private states = new Map<string, PreviewState>()
  private frames = new Map<string, Frame>()
  /** Per pane, the preview origin and the sandbox origin it stands for. */
  private origins = new Map<string, { preview: string; local: string }>()
  private reports = new Map<string, PaneReport[]>()
  /** The URL each pane last committed (the Mac's `currentURL`). */
  private committed = new Map<string, string>()
  private lastReport = new Map<string, { r: PaneReport; at: number }>()
  private reportTimes = new Map<string, number[]>()
  private calls = new Map<number, Reply>()
  private waiters = new Map<string, Reply>()
  /** Requests for a pane whose iframe isn't mounted yet (the inspector was closed). */
  private parked: { req: PaneRequest; run: () => void }[] = []
  /** Per pane, the label it entered with: its origin and when it dies. */
  private labels = new Map<string, { origin: string; expires: number }>()
  /** Per pane, the path to load once the entry link has landed on `/` (it can't go anywhere else). */
  private entering = new Map<string, string>()
  /** Panes that already minted again after a gateway error page, so one bad link isn't a loop. */
  private retried = new Set<string>()
  private listeners = new Set<() => void>()
  private n = 0
  /** Bumps on every change, for useSyncExternalStore. */
  version = 0

  /** The inspect toggle. */
  inspecting = false
  /** The mention token last picked, shown as a chip while it's in the composer. */
  mention: string | null = null
  /** Text the composer should insert at the caret; `n` makes each pick new. */
  insert: { text: string; n: number } | null = null
  /** Whether the mention is still in the draft. */
  mentionInDraft = false
  /** Bumped when the engine asks a preview for something, so the inspector brings it forward. */
  attention = 0
  /** Whether the gateway serves previews, as GET /v1/sessions says (CloudEngine.setPreviews):
   * unknown until the list answers. Only `true` shows the pane; `false` says so plainly. */
  available: boolean | undefined = undefined
  /** The last back/forward asked for, so the next commit moves through history, not onto it. */
  private moving = new Map<string, 'back' | 'forward' | 'reload'>()

  constructor(
    private send: (op: Op) => void,
    /** The gateway's preview URL for a sandbox port. */
    private mint: (port: number) => Promise<Minted>,
    private now: () => number = Date.now,
    private timer: (f: () => void, ms: number) => unknown = (f, ms) => setTimeout(f, ms),
  ) {}

  subscribe = (f: () => void) => { this.listeners.add(f); return () => { this.listeners.delete(f) } }
  private changed() { this.version++; this.listeners.forEach((f) => f()) }

  state(id: string): PreviewState { return this.states.get(id) ?? { title: '', loading: false, pages: 0, index: -1, length: 0 } }

  setAvailable(on: boolean) { if (this.available !== on) { this.available = on; this.changed() } }

  /** Whether a message from pane `id`'s iframe came from the page it was minted for: its origin
   * must be the minted preview origin. A page outside the sandbox (no minted origin) is never
   * listened to, so another site can't mention elements or answer the engine's calls. */
  accepts(id: string, origin: string): boolean {
    const o = this.origins.get(id)
    return !!o && o.preview === origin
  }

  /** Where postMessage into pane `id` may go: its minted preview origin, or nowhere. */
  target(id: string): string | undefined { return this.origins.get(id)?.preview }
  private patch(id: string, p: Partial<PreviewState>) { this.states.set(id, { ...this.state(id), ...p }); this.changed() }

  /** The iframe for `id` mounted: start at `url` if nothing's loaded yet, then answer what waited for it. */
  attach(id: string, frame: Frame, url?: string) {
    this.frames.set(id, frame)
    const s = this.state(id)
    // A new iframe for a sandbox page enters again: the last entry link was good for a minute.
    if (s.src && s.url && this.origins.has(id)) void this.load(id, s.url)
    else if (s.src) frame.load(s.src)
    else if (url && !s.url) void this.load(id, url)
    if (this.inspecting) frame.post({ frog: 1, type: 'inspect', on: true })
    const run = this.parked.filter((p) => p.req.id === id || this.frames.size === 1)
    this.parked = this.parked.filter((p) => !run.includes(p))
    run.forEach((p) => p.run())
  }

  detach(id: string, frame: Frame) { if (this.frames.get(id) === frame) this.frames.delete(id) }

  /** Show `url`: a sandbox dev server through the gateway, or any other http(s) page as is. */
  load(id: string, url: string) {
    this.retried.delete(id)
    return this.open(id, url)
  }

  private async open(id: string, url: string) {
    this.patch(id, { url, loading: true, error: undefined })
    this.entering.delete(id)
    const local = localTarget(url)
    let src: string
    if (local) {
      // Minted fresh for every iframe load: the entry link is good for a minute, and only once.
      let m: Minted
      try {
        m = await this.mint(local.port)
      } catch (e) {
        // A 503 here (no preview host) while the list says previews are on is this load failing,
        // not the feature going away: availability is the list's alone, so the tab doesn't flap.
        return this.failed(id, e instanceof Error ? e.message : String(e))
      }
      if (this.state(id).url !== url) return // superseded while minting
      const origin = m.origin ?? new URL(m.url).origin
      const entry = new URL(m.url).pathname === ENTER_PATH
      // An entry link lands on `/`; the page asked for follows once it has (see `loaded`). An
      // older gateway's link is the page itself.
      src = entry ? m.url : m.url.replace(/\/$/, '') + local.path
      if (entry && local.path !== '/') this.entering.set(id, local.path)
      this.labels.set(id, { origin, expires: m.expires })
      this.origins.set(id, { preview: origin, local: `http://localhost:${local.port}` })
    } else if (/^https?:\/\//i.test(url)) {
      src = url
      this.origins.delete(id)
      this.labels.delete(id)
    } else {
      return this.failed(id, `the web preview shows dev servers in the sandbox, not ${url.split(':')[0]}: pages. Serve it (for example \`npx serve\`) and open its port`)
    }
    this.patch(id, { src })
    this.frames.get(id)?.load(src)
  }

  /** Whether pane `id`'s label (and so its owner cookie) is past, or near, its 8 h life. */
  private expired(id: string): boolean {
    if (!this.origins.has(id)) return false
    const l = this.labels.get(id)
    return !l || l.expires - MINT_MARGIN_MS <= this.now()
  }

  reload(id: string) {
    const s = this.state(id)
    if (s.error && s.url) return void this.load(id, s.url)
    // The page reloads itself while its label lives (the owner cookie is already set in this
    // frame); past it, enter again with a fresh link rather than reload into the gateway's 403.
    if (s.url && this.expired(id)) return void this.load(id, s.url)
    this.patch(id, { loading: true, error: undefined })
    // A page outside the sandbox has no capture script to ask: load it again from here.
    if (!this.origins.has(id) && s.src) return this.frames.get(id)?.load(s.src)
    this.moving.set(id, 'reload')
    this.frames.get(id)?.post({ frog: 1, type: 'reload' })
  }

  back(id: string) { this.moving.set(id, 'back'); this.frames.get(id)?.post({ frog: 1, type: 'back' }) }
  forward(id: string) { this.moving.set(id, 'forward'); this.frames.get(id)?.post({ frog: 1, type: 'forward' }) }

  /** Stop a load: before the gateway answers, forget it; after, ask the page to stop. */
  stop(id: string) {
    const s = this.state(id)
    if (!s.loading) return
    if (!s.src) this.patch(id, { loading: false, url: this.committed.get(id) })
    else { this.frames.get(id)?.post({ frog: 1, type: 'stop' }); this.patch(id, { loading: false }) }
  }

  /** Whether Back and Forward have somewhere to go. */
  canBack(id: string) { return this.state(id).index > 0 }
  canForward(id: string) { const s = this.state(id); return s.index >= 0 && s.index < s.length - 1 }
  /** Whether the page is a dev server in the sandbox, which Frog can read, drive and pick from. */
  drivable(id: string) { return this.origins.has(id) && !!this.state(id).src }

  /** Whether there's a page to open in a browser tab. */
  canOpen(id: string) { return !!this.state(id).src }

  /** A URL for Open in Browser: a sandbox page gets its own fresh entry link (a new tab has no
   * owner cookie, and the iframe's link is spent), which lands on the dev server's `/`. */
  async browserURL(id: string): Promise<string | undefined> {
    const s = this.state(id)
    const local = s.url && this.origins.has(id) ? localTarget(s.url) : null
    if (!local) return s.src
    const m = await this.mint(local.port)
    return new URL(m.url).pathname === ENTER_PATH ? m.url : m.url.replace(/\/$/, '') + local.path
  }

  setInspecting(on: boolean) {
    if (this.inspecting === on) return
    this.inspecting = on
    this.frames.forEach((f) => f.post({ frog: 1, type: 'inspect', on }))
    this.changed()
  }

  /** The composer's text changed: is the mention still in it? */
  noteDraft(text: string) {
    const has = this.mention ? text.includes(this.mention) : false
    if (has !== this.mentionInDraft) { this.mentionInDraft = has; this.changed() }
  }

  // MARK: The page

  /** The iframe's load event (the Mac's didFinish). */
  loaded(id: string) {
    const s = this.state(id)
    if (s.error) return
    // The entry link landed on `/` with the owner cookie set: now the page that was asked for.
    const path = this.entering.get(id), o = this.origins.get(id)
    if (path && o) { this.entering.delete(id); return this.frames.get(id)?.load(o.preview + path) }
    this.patch(id, { loading: false })
    if (this.inspecting) this.frames.get(id)?.post({ frog: 1, type: 'inspect', on: true })
    const w = this.waiters.get(id)
    if (w) { this.waiters.delete(id); w({ url: s.url ?? '', title: s.title, loaded: true }) }
  }

  private failed(id: string, message: string) {
    this.patch(id, { loading: false, error: message })
    this.report({ id, kind: 'error', level: 'error', message: `Couldn't load: ${message}`, url: this.state(id).url })
    const w = this.waiters.get(id)
    if (w) { this.waiters.delete(id); w(null, message) }
  }

  /** A message from the page's capture script (the Mac's `received`). */
  received(id: string, raw: unknown) {
    if (!raw || typeof raw !== 'object' || (raw as { frog?: unknown }).frog !== 1) return
    const m = this.fromPreview(id, raw as Record<string, unknown>) as Record<string, unknown>
    // The entry's own landing on `/` isn't the page anyone asked for: only its failure counts.
    if (this.entering.has(id) && m.type !== 'load_failed') return
    const text = typeof m.message === 'string' ? m.message : ''
    const url = typeof m.url === 'string' ? m.url : undefined
    switch (m.type) {
      case 'console': {
        const level = m.level === 'warn' || m.level === 'error' ? m.level : 'info'
        const src = typeof m.source === 'string' && m.source ? `  (${m.source})` : ''
        return this.report({ id, kind: 'console', level, message: text + src })
      }
      case 'error':
        return this.report({ id, kind: 'error', level: 'error', message: text, url })
      case 'network':
        return this.report({ id, kind: 'network', level: 'error', message: text, url, ...(typeof m.status === 'number' ? { status: m.status } : {}) })
      case 'title':
        this.patch(id, { title: text })
        return this.report({ id, kind: 'title', message: text, url: this.state(id).url })
      case 'mention':
        return this.pick(id, typeof m.token === 'string' ? m.token : '@element', typeof m.context === 'string' ? m.context : undefined)
      case 'navigated': {
        // The Mac's noteURL: reported when the committed page changes (not when a load starts).
        const s = this.state(id), move = this.moving.get(id)
        this.moving.delete(id)
        this.retried.delete(id)
        const index = move === 'back' ? Math.max(0, s.index - 1) : move === 'forward' ? Math.min(s.length - 1, s.index + 1) : move === 'reload' ? Math.max(0, s.index) : s.index + 1
        const length = move ? Math.max(s.length, index + 1) : index + 1
        this.patch(id, { pages: s.pages + 1, index, length, ...(url ? { url } : {}) })
        if (!url || url === this.committed.get(id)) return
        this.committed.set(id, url)
        return this.report({ id, kind: 'navigated', message: url, url })
      }
      case 'load_failed': {
        // A gateway error page (frog-preview-error): most likely a spent link or a lost owner
        // cookie, so enter again with a fresh one, once; a second failure is the answer.
        const s = this.state(id)
        if (this.origins.has(id) && s.url && !this.retried.has(id)) { this.retried.add(id); return void this.open(id, s.url) }
        return this.failed(id, text || "the page didn't load")
      }
      case 'inspect':
        if (m.on === false && this.inspecting) { this.inspecting = false; this.changed() }
        return
      case 'reply': {
        const r = this.calls.get(m.n as number)
        if (!r) return
        this.calls.delete(m.n as number)
        return typeof m.error === 'string' ? r(null, m.error) : r(m.result ?? null)
      }
    }
  }

  /** The user picked an element: tell the engine, and put it in the composer. */
  private pick(id: string, token: string, context?: string) {
    this.send({ op: 'pane_mention', id, mention: token, ...(context ? { context } : {}) })
    this.mention = token
    this.insert = { text: token + ' ', n: (this.insert?.n ?? 0) + 1 }
    this.mentionInDraft = true
    this.setInspecting(false)
    this.changed()
  }

  /** Send a report, at most ~10 a second per pane and never the same line twice in a row. */
  report(r: PaneReport) {
    const now = this.now()
    const last = this.lastReport.get(r.id)
    if (last && same(last.r, r) && now - last.at < 2000) return
    const recent = (this.reportTimes.get(r.id) ?? []).filter((t) => now - t < 1000)
    if (recent.length >= 10) return
    recent.push(now)
    this.reportTimes.set(r.id, recent)
    this.lastReport.set(r.id, { r, at: now })
    const kept = [...(this.reports.get(r.id) ?? []), r]
    this.reports.set(r.id, kept.slice(-200))
    this.send({ op: 'pane_report', ...r })
  }

  // MARK: The engine's requests

  /** A `pane_request`: answered with exactly one `pane_reply`, within the engine's 20s. */
  request(req: PaneRequest) {
    let answered = false
    const reply: Reply = (result, error) => {
      if (answered) return
      answered = true
      this.send({ op: 'pane_reply', call: req.call, result: result ?? null, ...(error ? { error } : {}) })
    }
    if (req.action === 'console') {
      const lines = (this.reports.get(req.id) ?? []).slice(-100).map(({ id: _, ...r }) => r)
      return reply(lines)
    }
    // Before bringing anything forward: the engine asks for one at every turn's end while a
    // preview is open (its checkpoint), and that mustn't pop the inspector open each time.
    if (req.action === 'screenshot') return reply(null, NO_SCREENSHOT)
    this.timer(() => reply(null, "the preview didn't answer in time"), REQUEST_GIVE_UP_MS)
    // The engine is looking at the preview: bring it forward so the user sees what it sees.
    this.attention++
    this.changed()
    const run = () => this.handle(req, reply)
    if (this.frames.has(req.id) || this.frames.size === 1) return run()
    this.parked.push({ req, run })
  }

  private handle(req: PaneRequest, reply: Reply) {
    const id = this.frames.has(req.id) ? req.id : [...this.frames.keys()][0]
    const frame = this.frames.get(id)
    if (!frame) return reply(null, `no preview pane ${req.id} is open`)
    const args = req.args ?? {}
    const s = this.state(id)
    const call = (fn: string, a: Record<string, unknown> = {}) => {
      if (!s.src) return reply(null, "the preview hasn't loaded a page")
      if (!this.origins.has(id)) return reply(null, "the web preview can only read and drive dev servers in the sandbox")
      const n = ++this.n
      this.calls.set(n, reply)
      frame.post({ frog: 1, type: 'call', n, fn, ...a })
    }
    switch (req.action) {
      case 'read': return call('read')
      case 'click':
        if (typeof args.selector !== 'string') return reply(null, 'click needs a selector')
        return call('click', { selector: args.selector })
      case 'type':
        if (typeof args.selector !== 'string') return reply(null, 'type needs a selector')
        return call('type', { selector: args.selector, text: typeof args.text === 'string' ? args.text : '' })
      case 'eval':
        if (typeof args.js !== 'string') return reply(null, 'eval needs js')
        return call('eval', { js: args.js })
      case 'navigate': {
        if (typeof args.url !== 'string') return reply(null, 'navigate needs a url')
        // `wait`: the pane was just opened at this URL; answer when that load settles rather
        // than loading it again.
        if (args.wait === true) {
          if (s.error) return reply(null, s.error)
          if (!s.loading && s.url) return reply({ url: s.url, title: s.title, loaded: true })
        }
        this.waiters.get(id)?.(null, 'superseded by another navigation')
        this.waiters.set(id, reply)
        if (args.wait !== true || !s.url) void this.load(id, args.url)
        this.timer(() => {
          if (this.waiters.get(id) !== reply) return
          this.waiters.delete(id)
          const now = this.state(id)
          reply({ url: now.url ?? args.url, title: now.title, loaded: false })
        }, NAVIGATE_WAIT_MS)
        return
      }
      default:
        return reply(null, `unknown pane action ${req.action}`)
    }
  }

  // MARK: Origins

  /** Swap the preview origin for the sandbox's in everything a page says. */
  private fromPreview(id: string, v: unknown): unknown {
    const o = this.origins.get(id)
    if (!o) return v
    if (typeof v === 'string') return v.split(o.preview).join(o.local)
    if (Array.isArray(v)) return v.map((x) => this.fromPreview(id, x))
    if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, this.fromPreview(id, x)]))
    return v
  }

}

function same(a: PaneReport, b: PaneReport) {
  return a.kind === b.kind && a.level === b.level && a.message === b.message && a.url === b.url && a.status === b.status
}
