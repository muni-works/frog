import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useAlerts } from './alerts'
import { finishSignIn, firstName, me, savedKey, signIn, signOut, subscribe, topUp, AuthError, type Account, type Provider } from './auth'
import { friendly, type ConnectionState } from './cloud/client'
import type { SessionSummary } from './cloud/protocol'
import type { Image, Mode } from './cloud/protocol'
import { changeSig, keepTitle, keptTitle } from './titles'
import { defaultModel, idOf, spec, useModels } from './models'
import { plainError } from './errors'
import type { DecideOpts } from './ui/Transcript'
import { clearThreads, outOfCredits, pickStarters, useCloud, useRepos, useSessions, useThreads } from './store'
import { once } from './live'
import { useLayer, useMenu } from './ui/layers'
import { Composer } from './ui/Composer'
import { Pond, HowItWorks, Trust, Muni } from './ui/Pond'
import { Inspector } from './ui/Inspector'
import { usePreviewHub } from './ui/PreviewPane'
import type { PreviewHub } from './preview'
import { SessionList } from './ui/SessionList'
import { firstTitle, stuck, provisional, undelivered, withOpening, type Opening } from './ui/Opening'
import { useMachines } from './machines'
import { creditLine, Palette, type Command } from './ui/Overlays'
import { SettingsPage, SettingsRow, SettingsSidebar } from './ui/Settings'
import { pinModel, pinnedModel, rememberPick, sectionOfQuery, setTheme, settingsMovedTo, settingsPath, settingsSectionOf, startingModel, toggledTheme, WEB_SECTIONS, type Section } from './settings'
import { CustomizePage, CustomizeSidebar } from './ui/Customize'
import { CUSTOMIZE_SECTIONS, customizeAtOf, customizePath, customizePathIsCanonical, FIRST_CUSTOMIZE, shownAt, type Automation, type CustomizeAt, type Report } from './customize'
import { Transcript } from './ui/Transcript'
import { safeHref } from './ui/href'
import { askLine } from './ui/ask'
import { sessionMissing, viewAfterArchive } from './ui/guards'
import { DocsPage, DocsRow, DocsSidebar, Shell, type ShellMode } from './ui/Docs'
import { DOCS, VERSION } from './docs/bundle'
import { ChipSlot, useMacAppChip } from './ui/ChipSlot'
import { SignedOutSide } from './ui/SignedOut'
import { docsPath, docsSlugOf } from './docs/docs'
import { accountTag, connectCard, finishedTurn, loadMemo, saveMemo, type CardMemo } from './connectCard'
import { ConnectCard } from './ui/ConnectCard'
import { CreditWall } from './ui/CreditWall'
import { CreditWarning, useLastAdded } from './ui/CreditWarning'
import { useWallResume } from './ui/wallResume'
import { averageTurn } from './wall'

/** `pick`: open the composer's repo menu (back from sign-in, or ⌘K Connect a repo). */
/** Placeholder session ids, shown while POST /v1/sessions is in flight. */
const PENDING = 'pending-'

type View = { kind: 'session'; id: string } | { kind: 'new'; repo?: string; pick?: boolean; base?: string }

/** Dev only: a key for the mock gateway (any non-empty key is an account there). Skips sign-in. */
const DEV_KEY = import.meta.env.DEV ? (import.meta.env.VITE_DEV_KEY as string | undefined) : undefined

const Icon = ({ d }: { d: string }) => (
  <svg aria-hidden="true" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" style={{ flex: 'none' }}><path d={d} /></svg>
)
const icons = {
  new: 'M12 5v14M5 12h14',
  search: 'M11 4a7 7 0 1 0 0 14a7 7 0 1 0 0-14M20 20l-4-4',
}

/** The view a path names: /s/<id> is that session, anything else the new-session page. */
function viewOf(path: string): View {
  const m = path.match(/^\/s\/([\w-]+)\/?$/)
  return m ? { kind: 'session', id: m[1] } : { kind: 'new' }
}

/** A view's own path, or null for a session still being created (it has no URL yet). */
function pathOfView(view: View): string | null {
  return view.kind === 'session' ? (view.id.startsWith(PENDING) ? null : `/s/${view.id}`) : '/'
}

/** Where "Back to app" goes from a docs or settings URL: the thread it was opened from, kept in
 *  the history entry so a refresh still knows it. */
function backOf(state: unknown): string {
  const back = (state as { back?: unknown } | null)?.back
  return typeof back === 'string' && !modePath(back) ? back : '/'
}

/** A path that's one of the shell's other modes rather than a view. */
function modePath(path: string) { return docsSlugOf(path) !== null || settingsSectionOf(path) !== null || customizeAtOf(path) !== null }

/** The mode and settings section a first load opens on. Settings needs a key: signed out, a
 *  /settings URL or a ?settings= link opens the app. */
function firstMode(signedIn: boolean): { mode: ShellMode; section: Section; customize: CustomizeAt } {
  const path = location.pathname
  const at = settingsSectionOf(path)
  const asked = sectionOfQuery(location.search)
  // Customize, like Settings, needs a key. Settings' old Connections links open it there.
  const moved = settingsMovedTo(path, location.search)
  const cz = moved ? { section: moved } : customizeAtOf(path)
  if (docsSlugOf(path) !== null) return { mode: 'docs', section: asked ?? 'account', customize: FIRST_CUSTOMIZE }
  if (cz && signedIn) return { mode: 'customize', section: 'account', customize: cz }
  if ((at !== null || asked) && signedIn) return { mode: 'settings', section: at || asked || 'account', customize: FIRST_CUSTOMIZE }
  return { mode: 'threads', section: 'account', customize: FIRST_CUSTOMIZE }
}

const FIRST_DOC = DOCS[0]?.slug ?? ''

function Mark({ size = 22 }: { size?: number }) {
  return <span className="mark" style={{ width: size, height: size }} aria-hidden="true" />
}



export default function App() {
  const [key, setKey] = useState<string | null>(DEV_KEY ?? savedKey())
  const [account, setAccount] = useState<Account | null>(null)
  const [authError, setAuthError] = useState<string | null>(null)
  const [leaving, setLeavingFor] = useState<Provider | null>(null)
  const keyNow = useRef(key)
  keyNow.current = key
  // Each conversation has its own URL (/s/<id>), so refresh, back and links return to it.
  // Documentation (/docs/<slug>) and Settings (/settings/<section>) are the shell showing pages
  // over the same view: the view (and its thread, socket and draft) stays as it was underneath.
  const [view, setView] = useState<View>(() => viewOf(modePath(location.pathname) ? backOf(history.state) : location.pathname))
  const [first] = useState(() => firstMode(!!key))
  const [mode, setMode] = useState<ShellMode>(first.mode)
  // The last page and section, for the life of the window.
  const [docPage, setDocPage] = useState(() => docsSlugOf(location.pathname) || FIRST_DOC)
  const [section, setSection] = useState<Section>(first.section)
  const [cz, setCz] = useState<CustomizeAt>(first.customize)
  // Customize's figures come from an engine report (docs/customize-api.md), which no cloud path
  // answers yet: none, so nothing is guessed. Dev only, ?customize=sample draws the designs.
  const [czSample, setCzSample] = useState<{ report: Report; automations: Automation[] } | null>(null)
  useEffect(() => {
    if (import.meta.env.DEV && new URLSearchParams(location.search).get('customize') === 'sample') import('./customize.sample').then((m) => setCzSample(m.SAMPLE))
  }, [])
  // A detail page with nothing to show opens its list (or Add), and the URL says so.
  const czAt = shownAt(cz, czSample?.report)
  useEffect(() => {
    // A session still being created (a placeholder id) waits for its real id.
    const viewPath = pathOfView(view)
    const path = mode === 'docs' ? docsPath(docPage) : mode === 'settings' ? settingsPath(section) : mode === 'customize' ? customizePath(czAt) : viewPath
    // api.frog.toys/account and /billing (and Stripe) land on ?settings=account|billing: the
    // section is open now, so the query goes, and anything else in it stays.
    const q = new URLSearchParams(location.search)
    const asked = q.has('settings')
    q.delete('settings')
    if (path === null || (location.pathname === path && !asked)) return
    const state = mode === 'threads' ? null : { back: viewPath ?? '/' }
    // Bare /docs and /settings name a page: replace them, so Back doesn't land on them again.
    // Settings without a key (signed out from it, or a /settings link signed out) is the app:
    // replaced too, so Back doesn't land on it and bounce.
    const stale = (mode !== 'settings' && settingsSectionOf(location.pathname) !== null && !keyNow.current)
      || (mode !== 'customize' && customizeAtOf(location.pathname) !== null && !keyNow.current)
    // Bare /customize, an old name and Settings' moved Connections are replaced the same way.
    const czUrl = customizeAtOf(location.pathname)
    const renamed = (czUrl !== null && !customizePathIsCanonical(location.pathname)) || (mode === 'customize' && settingsMovedTo(location.pathname) !== null)
      || (mode === 'customize' && !!czUrl?.page && customizePath(czUrl) !== path)
    if (asked || stale || renamed || docsSlugOf(location.pathname) === '' || settingsSectionOf(location.pathname) === '') history.replaceState(state, '', path + (q.size ? `?${q}` : ''))
    else history.pushState(state, '', path)
  }, [view, mode, docPage, section, czAt.section, czAt.page, customizePath(czAt)])
  useEffect(() => {
    const back = () => {
      const slug = docsSlugOf(location.pathname)
      if (slug !== null) { setMode('docs'); setDocPage(slug || FIRST_DOC); return }
      const moved = settingsMovedTo(location.pathname)
      const c = moved ? { section: moved } : customizeAtOf(location.pathname)
      if (c && keyNow.current) { setMode('customize'); setCz(c); return }
      const at = settingsSectionOf(location.pathname)
      if (at !== null && keyNow.current) { setMode('settings'); if (at) setSection(at); return }
      setMode('threads')
      setView(viewOf(at !== null || c ? backOf(history.state) : location.pathname))
    }
    addEventListener('popstate', back)
    return () => removeEventListener('popstate', back)
  }, [])
  // The transcript's scroll position, kept while another mode hides it.
  const threadScroll = useRef<HTMLDivElement | null>(null)
  const savedScroll = useRef<number | null>(null)
  const enter = (m: 'docs' | 'settings' | 'customize') => {
    if (mode === 'threads') savedScroll.current = threadScroll.current?.scrollTop ?? null
    setMode(m)
  }
  const openDocs = (slug?: string) => { if (slug) setDocPage(slug); enter('docs') }
  // Billing's "Have a code?" takes the cursor when the out-of-credit card's link opens it.
  const [couponAsk, setCouponAsk] = useState(0)
  /** Settings mode, on a section or the last one. Only with a key. */
  const openSettings = (s?: Section, opts?: { coupon?: boolean }) => {
    if (!keyNow.current) return
    if (s) setSection(s)
    // Only that visit takes the cursor: a later plain one to Billing doesn't.
    if (opts?.coupon) setCouponAsk((n) => n + 1)
    else setCouponAsk(0)
    enter('settings')
  }
  /** Customize mode, on a page or the last one. Only with a key, like Settings. */
  const openCustomize = (at?: CustomizeAt) => {
    if (!keyNow.current) return
    if (at) setCz(at)
    enter('customize')
  }
  const backToApp = () => { setCouponAsk(0); setMode('threads') }
  /** Somewhere in Threads mode (a session, a new one): leaves the other modes on the way. */
  const go = (v: View) => { setMode('threads'); setView(v) }
  // Escape is Back to app, after any menu or palette open over the page has closed.
  useLayer(mode !== 'threads', backToApp)
  const [palette, setPalette] = useState(false)
  // Open or closed, kept per browser like its tab and width.
  const [inspector, setInspectorState] = useState(() => { try { return localStorage.getItem('frog.inspector') === '1' } catch { return false } })
  const setInspector = (v: boolean) => { setInspectorState(v); try { localStorage.setItem('frog.inspector', v ? '1' : '0') } catch { /* private mode */ } }
  const [toast, setToast] = useState<string | null>(null)
  const [draft, setDraft] = useState<string | undefined>()
  /** Sessions still opening: their first message (and repo), from the moment you send until the
   * first turn starts. The placeholder and then the real session show the same bubble and one
   * status line, so the hand-over doesn't flicker between two different "starting" states. */
  const [opening, setOpening] = useState<Record<string, Opening>>({})
  /** Per session, the key its composer was first drawn under (the placeholder's id), so the
   * composer, and what you're typing in it, stays put when the real id arrives. */
  const slots = useRef<Record<string, string>>({})
  /** Per session, its first message as a title, until the engine names it. */
  const firsts = useRef<Record<string, string>>({})
  // Follow-ups typed while Frog works wait here (per session) and go together, in order, as the
  // next turn once this one ends, like the Mac app. × takes one back into the field.
  const [queue, setQueue] = useState<Record<string, { text: string; images: Image[] }[]>>({})
  const [restore, setRestore] = useState<{ text: string; images: Image[] } | null>(null)
  const [conn, setConn] = useState<Record<string, ConnectionState>>({})
  const [menuOpen, setMenuOpen] = useState(false)
  // Sessions with a compaction in flight: how many marks there'll be when it's answered.
  const [compacting, setCompacting] = useState<Record<string, number>>({})
  // The title menu closes on Escape, a click outside it, or a session switch.
  useEffect(() => {
    if (!menuOpen) return
    const down = (e: MouseEvent) => { if (!(e.target as Element).closest('.title-menu')) setMenuOpen(false) }
    addEventListener('mousedown', down)
    return () => removeEventListener('mousedown', down)
  }, [menuOpen])
  useLayer(menuOpen, () => setMenuOpen(false))
  const titleNav = useMenu(menuOpen)
  // Phone layout: the sidebar is a drawer, closed whenever you go somewhere.
  const [drawer, setDrawer] = useState(false)
  const [renaming, setRenaming] = useState<string | null>(null)
  // What a new session starts with: null model = the gateway's default.
  // Kept across reloads (and the GitHub round trip), so what you picked signed out still holds.
  // Settings › Models › New conversations use: a pinned model, else the last one picked here.
  const [newModel, setNewModelState] = useState<string | null>(() => startingModel())
  const [pinned, setPinnedState] = useState<string | null>(() => pinnedModel())
  const setPinned = (m: string | null) => { pinModel(m); setPinnedState(m); setNewModelState(startingModel()) }
  const [newMode, setNewModeState] = useState<Mode>(() => { try { return (localStorage.getItem('frog.newMode') as Mode) || 'auto' } catch { return 'auto' } })
  const setNewModel = (m: string | null) => { setNewModelState(m); rememberPick(m) }
  const setNewMode = (m: Mode) => { setNewModeState(m); try { localStorage.setItem('frog.newMode', m) } catch { /* private mode */ } }
  const toastTimer = useRef(0)

  // Signed out, on purpose or because the key stopped working: nothing of the account stays.
  const signedOut = useCallback(() => {
    signOut(); clearThreads(); setKey(null); setAccount(null); setMode('threads'); setView({ kind: 'new' })
  }, [])
  const cloud = useCloud(key, DEV_KEY ? undefined : signedOut)
  const models = useModels(DEV_KEY ? null : key)
  const machines = useMachines(key)
  // The remembered pick only while Frog Cloud still lists it (Qwen3 Coder Next drops out when no GPU node
  // runs): otherwise the default, never a model nothing would answer.
  const chosenModel = newModel && models.some((m) => m.id === idOf(newModel)) ? idOf(newModel) : defaultModel(models)
  const repoList = useRepos(cloud)
  const { sessions: listed, loaded: sessionsLoaded, error: listError, setSessions, refresh: refreshSessions } = useSessions(cloud)
  const sessions = useMemo(() => withOpening(listed, opening), [listed, opening])
  const current = view.kind === 'session' ? sessions.find((s) => s.id === view.id) : undefined
  // The transcript's scroller: opens at the newest message, or where you were back from
  // Documentation mode. Stable per session and mode: an inline ref ran on every render and threw
  // the reader to the end whenever anything set state (opening a fold, Show in Changes).
  const currentId = current?.id
  // How tall the transcript was at the last render: you were following if you were at its end.
  const lastHeight = useRef(0)
  // Where the scroller was when it last unmounted: the shell remounts it when a column opens (the
  // inspector, from an edit's Show in Changes), and the same session should keep its place.
  const lastScroll = useRef<{ id?: string; top: number } | null>(null)
  const pinScroll = useCallback((el: HTMLDivElement | null) => {
    if (!el) {
      if (threadScroll.current) lastScroll.current = { id: currentId, top: threadScroll.current.scrollTop }
      threadScroll.current = null
      return
    }
    threadScroll.current = el
    if (mode !== 'threads') return
    if (savedScroll.current !== null) { el.scrollTop = savedScroll.current; savedScroll.current = null; lastHeight.current = el.scrollHeight; return }
    const last = lastScroll.current
    if (last && last.id === currentId) { el.scrollTop = last.top; lastHeight.current = el.scrollHeight; return }
    el.scrollTop = el.scrollHeight
    lastHeight.current = el.scrollHeight
  }, [mode, currentId]) // eslint-disable-line react-hooks/exhaustive-deps
  // Following: if you were at the end of what was there at the last render (within a line), new
  // output keeps you at the end; scrolled up, nothing moves you. Checked after every render.
  useEffect(() => {
    const el = threadScroll.current
    if (!el || mode !== 'threads') return
    if (el.scrollTop + el.clientHeight >= lastHeight.current - 40) el.scrollTop = el.scrollHeight
    lastHeight.current = el.scrollHeight
  })
  useEffect(() => setMenuOpen(false), [view])
  // Stream only the open session. Attaching to a session wakes its sandbox, and the sockets
  // reconnect after a sandbox sleeps, so streaming every running session kept them all awake
  // (and the account at its running-sandbox limit). Other sessions show the listed state.
  const live = useMemo(() => (current && !current.id.startsWith(PENDING) ? [current.id] : []), [current])
  const { thread, threads } = useThreads(cloud, live)
  const ct = current ? thread(current.id) : null
  // Still opening: no turn yet. Its sent message and status row stand in (ui/Opening.tsx).
  const op = current && ct && ct.turns.length === 0 ? opening[current.id] : undefined
  const failedStart = !!op && (!!op.failed || current?.state === 'error' || stuck(op))
  // "Try it on your own code": once per account, after its first finished turn without GitHub.
  const tag = account ? accountTag(account) : null
  // Read in render, not an effect: a first render with no memo would claim the card again.
  const [cardTick, setCardTick] = useState(0)
  const cardMemo = useMemo(() => (tag ? loadMemo(globalThis.localStorage, tag) : null), [tag, cardTick]) // eslint-disable-line react-hooks/exhaustive-deps
  const card = current && ct && account && tag && !DEV_KEY
    ? connectCard(cardMemo, { github: !!account.handle, session: current.id, finished: !current.id.startsWith(PENDING) && finishedTurn(ct) })
    : { show: false, claim: false }
  const remember = useCallback((m: CardMemo) => { if (!tag) return; saveMemo(globalThis.localStorage, tag, m); setCardTick((n) => n + 1) }, [tag])
  useEffect(() => { if (card.claim && current) remember({ session: current.id }) }, [card.claim, current?.id, remember]) // eslint-disable-line react-hooks/exhaustive-deps
  // The open session's preview panes. When the engine asks one for something with the
  // inspector closed, it opens on Preview, as the Mac brings its pane forward.
  const preview = current && cloud && !current.id.startsWith(PENDING) ? cloud.preview(current.id) : undefined
  usePreviewHub(preview)
  const [inspectorTab, setInspectorTab] = useState<'preview' | 'changes' | undefined>()
  // Bumped to reopen the inspector on a tab while it is already open (an edit's Show in Changes).
  const [inspectorNonce, setInspectorNonce] = useState(0)
  const seenAttention = useRef<{ hub?: PreviewHub; n: number }>({ n: 0 })
  useEffect(() => {
    const last = seenAttention.current
    const n = preview?.attention ?? 0
    seenAttention.current = { hub: preview, n }
    if (preview && last.hub === preview && n !== last.n && !inspector) { setInspectorTab('preview'); setInspector(true) }
  }, [preview, preview?.attention]) // eslint-disable-line react-hooks/exhaustive-deps
  // Plan usage and credit, near-live: after each turn (billing lands a moment later, through
  // the usage queue), every 20s while the tab is visible, and when the ring is opened.
  const refreshAccount = useCallback(() => {
    if (key && !DEV_KEY) me(key).then(setAccount).catch((e) => { if (e instanceof AuthError && e.status === 401) signedOut() })
  }, [key, signedOut])
  useEffect(() => {
    if (!ct || ct.running) return
    const t = [2000, 8000].map((ms) => setTimeout(refreshAccount, ms))
    return () => t.forEach(clearTimeout)
  }, [ct?.running, ct?.turns.length, refreshAccount]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    const t = setInterval(() => { if (!document.hidden) refreshAccount() }, 20_000)
    return () => clearInterval(t)
  }, [refreshAccount])
  // The open session's own changes show in the list at once, not at the next poll.
  useEffect(() => { refreshSessions() }, [ct?.running, ct?.turns.length]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (current && compacting[current.id] && (ct?.marks ?? []).length >= compacting[current.id]) setCompacting(({ [current.id]: _, ...rest }) => rest) }, [current, ct?.marks, compacting]) // eslint-disable-line react-hooks/exhaustive-deps
  // Until the engine names it, the gateway lists a session as its repo or "New session": its first
  // message, when this tab sent it, reads better and doesn't change when the id arrives.
  const title = (s: SessionSummary) => keptTitle(s.id, thread(s.id).title, firsts.current[s.id] && (s.title === 'New session' || s.title === s.repo) ? firsts.current[s.id] : s.title)
  // The turn ended: what was queued goes as the next turn, one Submit with the rest as `more`.
  const fresh = useRef(once<object>()).current
  useEffect(() => {
    if (!current || !ct || ct.running || opening[current.id]) return
    const q = queue[current.id]
    if (!q?.length || !fresh(q)) return
    const [head, ...rest] = q
    cloud?.send(current.id, { op: 'submit', text: head.text, ...(head.images.length ? { images: head.images } : {}), ...(rest.length ? { more: rest.map((m) => ({ text: m.text, ...(m.images.length ? { images: m.images } : {}) })) } : {}) })
    setQueue((all) => ({ ...all, [current.id]: [] }))
  }, [current, ct, queue, opening, cloud])
  // The first turn started: the session is open.
  useEffect(() => {
    if (current && ct && ct.turns.length > 0 && opening[current.id]) setOpening(({ [current.id]: _, ...rest }) => rest)
  }, [current, ct, opening])
  // While a new sandbox boots, its state (running, or error and why) is read every 2 s rather than
  // at the list's 10 s, so a boot that failed says so on the status row soon after.
  const booting = current && !current.id.startsWith(PENDING) && op && !op.failed && !op.runningAt && current.state !== 'error' ? current.id : null
  useEffect(() => {
    if (!booting || !cloud) return
    const t = setInterval(() => {
      cloud.gateway.get(booting).then((s) => {
        setSessions((all) => all.map((x) => (x.id === s.id ? { ...x, ...s } : x)))
        setOpening((o) => (o[s.id] ? { ...o, [s.id]: { ...o[s.id], row: { ...o[s.id].row, ...s } } } : o))
      }).catch(() => { /* the list's poll still runs */ })
    }, 2000)
    return () => clearInterval(t)
  }, [booting, cloud, setSessions])
  // When the gateway first says the sandbox is up. No turn 30 s after that and the status row says
  // the engine didn't pick the message up (zest only reports errors from the boot itself).
  const upId = op && !op.failed && !op.runningAt && current?.state === 'running' ? current.id : null
  useEffect(() => {
    if (upId) setOpening((all) => (all[upId] && !all[upId].runningAt ? { ...all, [upId]: { ...all[upId], runningAt: Date.now() } } : all))
  }, [upId])
  // Alerts: the tab title's badge and background notifications, from every streamed session.
  // Recomputed per frame (cheap), but handed on only when a signal actually changed.
  const signals = useMemo(() => sessions.map((s) => {
    const t = thread(s.id)
    const waiting = t.ask ? askLine(t.ask.name, t.ask.arg) : t.question ? t.question.question : t.elicitation ? `${t.elicitation.server} needs your input` : null
    return { id: s.id, title: keptTitle(s.id, t.title, s.title), waiting, finished: !t.running && t.ended?.type === 'complete' }
  }), [sessions, thread, threads])
  const signalKey = JSON.stringify(signals)
  useAlerts(useMemo(() => signals, [signalKey]), useCallback((id: string) => { setMode('threads'); setView({ kind: 'session', id }) }, [])) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => setDrawer(false), [view, mode, docPage, section])
  // The sidebar folds away on wide screens (⌘\\), as on the Mac; remembered per browser.
  const [collapsed, setCollapsedState] = useState(() => { try { return localStorage.getItem('frog.sidebarCollapsed') === '1' } catch { return false } })
  const setCollapsed = (v: boolean) => { setCollapsedState(v); try { localStorage.setItem('frog.sidebarCollapsed', v ? '1' : '0') } catch { /* private mode */ } }
  const sideToggle = (open: boolean) => (
    <button type="button" className={`ic-btn side-toggle${open ? '' : ' out'}`} aria-label={open ? 'Hide sidebar (⌘\\)' : 'Show sidebar (⌘\\)'} title={open ? 'Hide sidebar ⌘\\' : 'Show sidebar ⌘\\'} onClick={() => setCollapsed(open)}>
      <svg aria-hidden="true" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="4" width="18" height="16" rx="3" /><path d="M9 4v16" /></svg>
    </button>
  )
  const Burger = () => (
    <button type="button" className="burger" aria-label="Sessions" aria-expanded={drawer} onClick={() => setDrawer(!drawer)}>
      <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M4 7h16M4 12h16M4 17h16" /></svg>
    </button>
  )

  const say = (t: string) => { setToast(t); clearTimeout(toastTimer.current); toastTimer.current = window.setTimeout(() => setToast(null), 3200) }

  // Back from Stripe Checkout (?session_id): say so, and refresh the balance once the webhook lands.
  useEffect(() => {
    const q = new URLSearchParams(location.search)
    if (!q.get('session_id')) return
    history.replaceState(null, '', location.pathname)
    say('Payment received. Your credit updates in a moment.')
    const k = savedKey()
    if (!k) return
    const t = [3000, 8000].map((ms) => setTimeout(() => me(k).then(setAccount).catch(() => undefined), ms))
    return () => t.forEach(clearTimeout)
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  // ---------- the credit wall (wall.ts) ----------
  // The account's average turn, over every session this browser holds.
  const avgTurn = useMemo(() => averageTurn(sessions.map((s) => thread(s.id)), models), [sessions, threads, models]) // eslint-disable-line react-hooks/exhaustive-deps
  // When the account was last read, so the wall can tell a fresh balance from one before the stop.
  const [accountAt, setAccountAt] = useState(0)
  useEffect(() => { if (account) setAccountAt(Date.now()) }, [account])
  const lastAdded = useLastAdded(DEV_KEY ? undefined : key ?? undefined, account)
  // Pay and resume: a code resumes at once; Stripe comes back to the bare origin, and this reopens
  // the session and resumes once the credit is in (ui/wallResume.ts).
  const wall = useWallResume({
    session: current?.id ?? null, thread: ct, send: (id, op) => cloud?.send(id, op),
    fetchMe: key && !DEV_KEY ? () => me(key) : null, onAccount: setAccount,
    openSession: (id) => { setMode('threads'); setView({ kind: 'session', id }) },
    storage: globalThis.sessionStorage, search: globalThis.location?.search,
  })

  // Sign-in: finish a GitHub or Google round trip if the URL has one, else check the saved key.
  useEffect(() => {
    finishSignIn().then(async (done) => {
      if (done) {
        setKey(done.key); setAccount(done.account)
        // Back from connecting GitHub: the repo menu again, with what was typed.
        if (done.pick) { setDraft(done.after); setView({ kind: 'new', pick: true }); return }
        // The message typed before signing in starts its conversation as soon as we're in.
        if (done.after) setPending(done.after)
        return
      }
      const k = savedKey()
      if (!k || DEV_KEY) return
      setAccount(await me(k))
    }).catch((e) => {
      if (e instanceof AuthError && e.status === 401) { signedOut(); return }
      setAuthError(e instanceof AuthError ? e.code : friendly(e))
    })
  }, [])

  useEffect(() => cloud?.watch((id, s) => {
    setConn((all) => ({ ...all, [id]: s }))
    if (s.state === 'unauthorized' && !DEV_KEY) signedOut()
  }), [cloud, signedOut])

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
  // Without GitHub a new session is a scratch sandbox, so its ideas are things to build, not repo chores.
  const starterChips = useMemo(() => pickStarters(3, !key || !account?.handle).map((text) => ({ text })), [key, account?.handle])
  const start = useCallback(async (text: string, repo?: string, images: Image[] = [], base?: string, slot?: string, before?: Promise<unknown>) => {
    if (!cloud) return
    // Open the session at once, as a placeholder, and adopt the real one when the gateway
    // answers: starting a conversation should feel instant, not wait on a round trip. The view,
    // the sent message and the composer are the same nodes before and after (ui/Opening.tsx).
    const temp = `${PENDING}${Date.now()}`
    const at = Date.now()
    slots.current[temp] = slot ?? temp
    firsts.current[temp] = firstTitle(text)
    const row: SessionSummary = { id: temp, title: firstTitle(text), repo: repo ?? '', branch: '', state: 'starting', updated: at }
    setOpening((o) => ({ ...o, [temp]: { text, images, repo, base, at, row } }))
    setView({ kind: 'session', id: temp })
    try {
      await before // Try again: the failed sandbox goes first, so it doesn't count against the running limit
      const s = await cloud.gateway.create({ ...(repo ? { repo } : {}), ...(repo && base ? { base } : {}), ...(chosenModel ? { model: spec(chosenModel) } : {}) })
      slots.current[s.id] = slots.current[temp]
      firsts.current[s.id] = firsts.current[temp]
      setSessions((all) => [s, ...all.filter((x) => x.id !== s.id && x.id !== temp)])
      setOpening(({ [temp]: first, ...rest }) => ({ ...rest, [s.id]: { ...(first ?? { text, images, repo, base, at }), row: s } }))
      // A follow-up sent while the POST was out waits for this session's first turn.
      setQueue(({ [temp]: q, ...rest }) => (q?.length ? { ...rest, [s.id]: q } : rest))
      setView((v) => (v.kind === 'session' && v.id === temp ? { kind: 'session', id: s.id } : v))
      if (newMode !== 'default') cloud.send(s.id, { op: 'set_mode', mode: newMode })
      // Not through the outbox: the status row speaks for the first message until its turn starts.
      cloud.send(s.id, { op: 'submit', text, ...(images.length ? { images } : {}) }) // queued until the session's socket is live
    } catch (e) {
      // Said in place, on the status row, with Try again: the message stays where it is.
      const why = `Couldn't start a sandbox: ${friendly(e)}`
      setOpening((o) => (o[temp] ? { ...o, [temp]: { ...o[temp], failed: why, row: { ...o[temp].row, state: 'error', error: why } } } : o))
    }
  }, [cloud, setSessions, chosenModel, newMode])
  /** A session that couldn't start, started again in place: the same message, the same composer. */
  const retry = useCallback((id: string, text?: string, images: Image[] = []) => {
    const o = opening[id]
    if (!o || !cloud) return
    if (stuck(o)) {
      // The sandbox is up but no turn started: the message (or what you typed instead) again, to the same session.
      const next = { text: text ?? o.text, images: text === undefined ? o.images : images }
      setOpening((all) => ({ ...all, [id]: { ...o, ...next, runningAt: Date.now() } }))
      cloud.send(id, { op: 'submit', text: next.text, ...(next.images.length ? { images: next.images } : {}) })
      return
    }
    setOpening(({ [id]: _, ...rest }) => rest)
    let gone: Promise<unknown> | undefined
    if (!id.startsWith(PENDING)) {
      // Its sandbox failed to boot: a fresh one, and this one goes (it holds nothing yet).
      setSessions((all) => all.filter((x) => x.id !== id))
      gone = cloud.gateway.remove(id).catch(() => { /* gone already, or it'll be in the list to delete */ })
    }
    start(text ?? o.text, o.repo, text === undefined ? o.images : images, o.base, slots.current[id] ?? id, gone)
  }, [opening, cloud, setSessions, start])
  useEffect(() => { if (pending && cloud) { setPending(null); start(pending) } }, [pending, cloud, start])

  const decide = useCallback((id: string, allow: boolean, opts?: DecideOpts) => {
    const ask = thread(id).ask
    if (!ask) return
    const note = opts?.note?.trim()
    cloud?.send(id, { op: 'permission', id: ask.id, decision: allow ? (opts?.always ? 'allow_always' : 'allow') : 'deny', ...(note && !allow ? { note } : {}) })
  }, [thread, cloud])

  const rename = (s: SessionSummary, to: string) => {
    const t = to.trim()
    setRenaming(null)
    if (!t || t === title(s)) return
    keepTitle(s.id, t)
    cloud?.send(s.id, { op: 'set_title', title: t }) // the engine's titled event renames it everywhere
    setSessions((all) => all.map((x) => (x.id === s.id ? { ...x, title: t } : x)))
  }
  const remove = async (s: SessionSummary) => {
    if (!confirm(`Delete "${title(s)}"? Its sandbox, changes and conversation are gone for good.`)) return
    try {
      // A placeholder whose POST failed exists only here.
      if (!s.id.startsWith(PENDING)) await cloud?.gateway.remove(s.id)
      setOpening(({ [s.id]: _, ...rest }) => rest)
      setSessions((all) => all.filter((x) => x.id !== s.id))
      setView((v) => (v.kind === 'session' && v.id === s.id ? { kind: 'new' } : v))
    } catch (e) {
      say(`Couldn't delete: ${friendly(e)}`)
    }
  }

  const archive = async (s: SessionSummary, archived: boolean) => {
    try {
      const next = await cloud!.gateway.archive(s.id, archived)
      setSessions((all) => all.map((x) => (x.id === s.id ? { ...x, ...next } : x)))
      // Archiving the session on screen clears the view to a new one (as the Mac does, and as
      // Delete already does below). Archiving another session leaves you where you are, and
      // unarchiving never navigates: you're in the archive, restoring things.
      if (archived) setView((v) => viewAfterArchive(v, s.id, archived))
      say(archived ? 'Archived. Find it under View options → Archived.' : 'Unarchived. Back in your sessions.')
    } catch (e) {
      say(`Couldn't ${archived ? 'archive' : 'restore'} it: ${friendly(e)}`)
    }
  }

  // Sandboxes that never started have nothing to lose: clear them together, without a prompt each.
  const clear = async (ids: string[]) => {
    const gone = (await Promise.allSettled(ids.map((id) => cloud!.gateway.remove(id)))).map((r, i) => (r.status === 'fulfilled' ? ids[i] : null)).filter(Boolean)
    setSessions((all) => all.filter((x) => !gone.includes(x.id)))
    if (gone.length < ids.length) say(`Couldn't clear ${ids.length - gone.length} of them. Try again.`)
  }

  // Commit and push are asks to the agent, so they show up in the conversation like any step.
  // A session without a repo has no remote to push to (and the gateway can't hand files back
  // or make a repo yet), so its one git step is a local commit.
  // The +N −N pill goes once a commit turn finishes, until the changes move again.
  const [committed, setCommitted] = useState<Record<string, { turn: number; sig: string | null }>>({})
  const commitAsk = (s: SessionSummary, text: string) => { setCommitted((c) => ({ ...c, [s.id]: { turn: thread(s.id).turns.length, sig: null } })); send(s.id, text) }
  const commit = (s: SessionSummary) => commitAsk(s, 'Commit the changes with a clear message.')
  const push = (s: SessionSummary) => !s.repo ? commit(s) : commitAsk(s, s.pr ? `Commit the changes and push to ${s.pr}.` : 'Commit the changes, push the branch and open a pull request.')

  // Signed out: what's in the landing composer, so the sidebar's Sign in takes it along too.
  const signedOutDraft = useRef('')
  const noteSignedOutDraft = useCallback((t: string) => { signedOutDraft.current = t }, [])
  const mac = useMacAppChip(machines)
  /** Signed out, New session is the landing's composer. */
  const focusComposer = () => { go({ kind: 'new' }); setDrawer(false); requestAnimationFrame(() => document.querySelector<HTMLTextAreaElement>('.dock textarea')?.focus()) }
  const leave = (after: string | null, provider: Provider = 'github', connect?: string, pick = !!connect) => { setLeavingFor(provider); signIn(after ?? undefined, provider, connect, pick).catch(() => setLeavingFor(null)) }

  // Keyboard: ⌘K palette, ⌘N new, ⌘, settings, ⌘↩ / ⌘. answer the current ask.
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey)) return
      if (e.key === '\\') { e.preventDefault(); setCollapsedState((c) => { try { localStorage.setItem('frog.sidebarCollapsed', c ? '0' : '1') } catch { /* private mode */ } return !c }) }
      // Signed out there's no palette, no settings and no session to answer: nothing to open.
      if (!key) return
      if (e.key === 'k') { e.preventDefault(); setPalette((p) => !p) }
      if (e.key === 'n') { e.preventDefault(); setMode('threads'); setView({ kind: 'new' }) }
      if (e.key === ',') { e.preventDefault(); openSettings() }
      // A permission card hidden under another mode isn't answered from there.
      if (mode !== 'threads') return
      if (current && ct?.ask && e.key === 'Enter') { e.preventDefault(); decide(current.id, true) }
      if (current && ct?.ask && e.key === '.') { e.preventDefault(); decide(current.id, false) }
    }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [key, current, ct, decide, mode])

  const commands: Command[] = [
    { id: 'c-new', label: 'New session', hint: '⌘N', run: () => key && go({ kind: 'new' }) },
    { id: 'c-repo', label: 'Connect a repo', run: () => key && go({ kind: 'new', pick: true }) },
    { id: 'c-settings', label: 'Settings', hint: '⌘,', run: () => openSettings() },
    ...WEB_SECTIONS.map((x) => ({ id: `s-${x.id}`, label: x.label, hint: 'Settings', run: () => openSettings(x.id) })),
    { id: 'c-customize', label: 'Customize', run: () => openCustomize() },
    ...CUSTOMIZE_SECTIONS.map((x) => ({ id: `z-${x.id}`, label: x.label, hint: 'Customize', run: () => openCustomize({ section: x.id }) })),
    { id: 'c-docs', label: 'Documentation', run: () => openDocs() },
    ...DOCS.map((p) => ({ id: `d-${p.slug}`, label: p.title, hint: 'Documentation', run: () => openDocs(p.slug) })),
    ...(current ? [
      { id: 'c-rename', label: 'Rename session', run: () => { setMode('threads'); setRenaming(current.id) } },
      { id: 'c-compact', label: 'Compact the conversation', run: () => { setCompacting((c) => ({ ...c, [current.id]: (thread(current.id).marks ?? []).length + 1 })); cloud?.send(current.id, { op: 'compact' }) } },
      { id: 'c-archive', label: current.archived ? 'Unarchive session' : 'Archive session', run: () => archive(current, !current.archived) },
      { id: 'c-delete', label: 'Delete session', run: () => remove(current) },
    ] : []),
    { id: 'c-insp', label: inspector ? 'Hide inspector' : 'Show inspector', run: () => setInspector(!inspector) },
    { id: 'c-theme', label: 'Toggle dark mode', run: () => setTheme(toggledTheme()) },
  ]

  const Nav = () => (
    <nav aria-label="Main" className="nav">
      <button type="button" className="row big" onClick={() => setView({ kind: 'new' })}><Icon d={icons.new} /><span style={{ flex: 1 }}>New session</span><span className="kb">⌘N</span></button>
      <button type="button" className="row big" onClick={() => setPalette(true)}><Icon d={icons.search} /><span style={{ flex: 1 }}>Search</span><span className="kb">⌘K</span></button>
    </nav>
  )




  useEffect(() => {
    if (!current || !ct || ct.running) return
    const d = committed[current.id]
    if (d && d.sig === null && ct.turns.length > d.turn && ct.ended?.type === 'complete')
      setCommitted((c) => ({ ...c, [current.id]: { ...d, sig: changeSig(ct.changes) } }))
  }, [current, ct, committed])

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
          // Sent but never started (the engine didn't pick it up): after 45s, say so and offer a resend.
          const state: Out['state'] = m.state === 'failed' || dead || (!live && Date.now() - m.at > 20_000) || (live && !thread(id).running && Date.now() - m.at > 45_000) ? 'failed' : live ? 'sent' : 'sending'
          return state === m.state ? m : { ...m, state }
        })
        if (kept.length !== list.length || kept.some((m, i) => m !== list[i])) changed = true
        if (kept.length) next[id] = kept
      }
      return changed ? next : o
    })
  })
  // Re-check now and then while anything's waiting, so the 45s nudge appears without other activity.
  const [, setTick] = useState(0)
  const waiting = Object.values(outbox).some((l) => l.length)
  useEffect(() => { if (!waiting) return; const t = setInterval(() => setTick((n) => n + 1), 5000); return () => clearInterval(t) }, [waiting])
  const resend = (id: string, n: number) => {
    const m = outbox[id]?.find((x) => x.id === n)
    if (!m) return
    setOutbox((o) => ({ ...o, [id]: (o[id] ?? []).filter((x) => x.id !== n) }))
    send(id, m.text, m.images)
  }

  // ---------- signed in ----------
  const sig = changeSig(ct?.changes ?? [])
  const done = current ? committed[current.id] : undefined
  const clean = !!done && done.sig === sig
  const adds = clean ? 0 : ct?.changes.reduce((n, c) => n + c.added, 0) ?? 0
  const dels = clean ? 0 : ct?.changes.reduce((n, c) => n + c.removed, 0) ?? 0
  const paused = ct ? outOfCredits(ct) : false
  const cs = current ? conn[current.id] : undefined

  return (
    <Shell mode={mode} className={`win ${drawer ? 'drawer' : ''}${collapsed ? ' collapsed' : ''}`}
      before={<div className="side-scrim" onClick={() => setDrawer(false)} />}
      brand={<div className="brand"><Mark /><b style={{ flex: 1 }}>Frog</b><span id="side-acts" className="side-acts" style={mode === 'threads' ? undefined : { display: 'none' }} />{sideToggle(true)}</div>}
      side={{ threads: !key ? (
        <SignedOutSide onNew={focusComposer} chip={mac.chip} onDismissChip={mac.dismiss} onDocs={() => openDocs()}
          onSignIn={(provider) => leave(signedOutDraft.current.trim() || null, provider)} />
      ) : <>
        <Nav />
        <SessionList sessions={sessions} thread={thread} title={title} current={current?.id ?? null} error={listError}
          onOpen={(id) => { setView({ kind: 'session', id }); setDrawer(false) }} onClear={clear} onSearch={() => setPalette(true)}
          onRename={(s) => setRenaming(s.id)} onArchive={archive} onDelete={remove} />
        <ChipSlot chip={mac.chip} onDismiss={mac.dismiss} />
        <DocsRow onOpen={() => openDocs()} />
        <SettingsRow onOpen={() => openSettings()} />
        <button type="button" className="row" onClick={() => openSettings('account')} title="Account">
          {account?.handle ? <img className="avatar" src={`https://github.com/${encodeURIComponent(account.handle)}.png?size=56`} alt="" width={28} height={28} />
              : account?.image ? <img className="avatar" src={account.image} alt="" width={28} height={28} referrerPolicy="no-referrer" /> : <Mark size={28} />}
          <div style={{ flex: 1, textAlign: 'left', minWidth: 0 }}>
            <b>{firstName(account) ?? (DEV_KEY ? 'Dev key' : 'Signed in')}</b>
            <div className="det" style={{ color: account && account.credit_cents <= 0 ? 'var(--warn)' : undefined }}>{account ? creditLine(account) : DEV_KEY ? 'local gateway' : ''}</div>
          </div>
        </button>
        <a className="version-chip" href={`https://github.com/muni-works/frog/commit/${__FROG_COMMIT__}`} target="_blank" rel="noreferrer" title="This build on GitHub">Frog {VERSION}, {__FROG_COMMIT__}</a>
      </>, docs: <DocsSidebar pages={DOCS} current={docPage} version={VERSION} onBack={backToApp} onOpen={openDocs} />,
      settings: key && <SettingsSidebar current={section} onBack={backToApp} onOpen={(x) => openSettings(x)} />,
      customize: key && <CustomizeSidebar current={czAt.section} onBack={backToApp} onOpen={(x) => openCustomize({ section: x })} /> }}
      main={{ docs: <DocsPage pages={DOCS} slug={docPage} onOpen={openDocs} bar={<><Burger />{collapsed && sideToggle(false)}</>} />,
      customize: key && <CustomizePage at={czAt} repos={repoList} report={czSample?.report ?? null} automations={czSample?.automations} machines={machines} docSlugs={DOCS.map((d) => d.slug)}
        onOpen={(at) => openCustomize(at)} onDocs={openDocs} bar={<><Burger />{collapsed && sideToggle(false)}</>} />,
      settings: key && <SettingsPage section={section} account={account} apiKey={!DEV_KEY ? key : undefined} models={models} machines={machines} focusCoupon={couponAsk}
        newMode={newMode} onNewMode={setNewMode} pinnedModel={pinned} onPinModel={setPinned}
        bar={<><Burger />{collapsed && sideToggle(false)}</>} onOpen={(x) => openSettings(x)}
        onTopUp={!DEV_KEY ? (d) => topUp(key, d) : undefined} onSubscribe={!DEV_KEY ? (p) => subscribe(key, p) : undefined} onConnect={!DEV_KEY ? (p) => leave(null, p, key, false) : undefined}
        onSignOut={() => { if (!DEV_KEY) signOut(key); signedOut() }}
        onRedeemed={(r) => { setAccount((a) => (a ? { ...a, credit_cents: r.credit_cents } : a)); refreshAccount() }} />,
      threads: !key ? (
      // Signed out: the landing, in the shell. The composer's Sign in keeps what was typed and
      // sends it after the round trip.
      <main className="main home">
        {collapsed && <div className="side-float">{sideToggle(false)}</div>}<div className="phone-bar floating"><Burger /><b>Frog</b></div>
        {authError && <div role="status" className="banner warn">Sign-in didn't finish ({authError}). Try again.</div>}
        <div className="home-hero">
          <Pond />
          <Mark size={56} />
          <span className="beta-pill"><i />Now in beta</span>
          <h1>What should we work on?</h1>
          <div className="home-sub">
            <p>Frog is a coding agent for your repos: open models, on your machines or in Frog Cloud.</p>
            <p><b>25¢ of Frog Cloud credit free, $1 when you connect GitHub.</b></p>
          </div>
          <HowItWorks />
          <Trust />
        </div>
        <div className="dock"><div>
          <Composer onSend={() => {}} onSignIn={(provider, text) => leave(text || null, provider)} autoFocus chips={starterChips} onText={noteSignedOutDraft}
            model={chosenModel} models={models} machines={machines} onModel={setNewModel} mode={newMode} onMode={setNewMode} />
          {leaving && <div className="det" style={{ textAlign: 'center' }}>Opening {leaving === 'google' ? 'Google' : 'GitHub'}… your message is saved.</div>}
        </div></div>
        <footer className="muni-foot">
          <nav className="foot-links" aria-label="About Frog"><a href="/pricing">Pricing</a><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/mac">Get the Mac app</a></nav>
          <a href="https://muni.works" target="_blank" rel="noreferrer" aria-label="Municipal Robotics"><Muni /></a>
        </footer>
      </main>
      ) :
      <main className="main">
        {current ? (<div className="titlebar">
          <Burger />
          {collapsed && sideToggle(false)}
          <div className="title-wrap">
            {current && renaming === current.id ? (
              <input className="f-field title-edit" autoFocus defaultValue={title(current)} aria-label="Session name"
                onBlur={(e) => rename(current, e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter') rename(current, (e.target as HTMLInputElement).value); if (e.key === 'Escape') setRenaming(null) }} />
            ) : (
              <b style={{ fontSize: 14 }} onDoubleClick={() => current && setRenaming(current.id)} title={current ? 'Double-click to rename' : undefined}>{current ? title(current) : 'New session'}</b>
            )}
            {current && (
              <div className="title-menu">
                <button type="button" className="ic-btn title-chev" aria-label="Session menu" title="Session menu" aria-expanded={menuOpen} onClick={() => setMenuOpen(!menuOpen)}>
                  <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"><path d="M6 9l6 6 6-6" /></svg>
                </button>
                {menuOpen && (
                  <div className="f-card cz-menu" role="menu" aria-label="Session" style={{ top: 30, bottom: 'auto', left: 0, right: 'auto', width: 200 }} onMouseLeave={() => setMenuOpen(false)} {...titleNav}>
                    <button type="button" role="menuitem" onClick={() => { setMenuOpen(false); setRenaming(current.id) }}>Rename</button>
                    <button type="button" role="menuitem" onClick={() => { setMenuOpen(false); archive(current, !current.archived) }}>{current.archived ? 'Unarchive' : 'Archive'}</button>
                    <button type="button" role="menuitem" style={{ color: 'var(--warn)' }} onClick={() => { setMenuOpen(false); remove(current) }}>Delete session</button>
                  </div>
                )}
              </div>
            )}
          </div>
          <span style={{ flex: 1 }} />
          {current && !opening[current.id] && <span style={{ fontSize: 12, color: cs?.state === 'live' ? 'var(--frog)' : 'var(--muted)' }}>{cs?.state === 'live' ? '' : cs?.state === 'connecting' ? (cs.attempt ? 'Reconnecting…' : 'Connecting…') : cs?.state === 'refused' ? 'Update Frog to continue' : cs?.state === 'closed' ? (cs.code === 4004 ? 'Session deleted' : 'Disconnected') : ''}</span>}
          {current && !inspector && <button type="button" className="ic-btn" onClick={() => setInspector(!inspector)} aria-pressed={inspector} aria-label={inspector ? 'Hide inspector' : 'Show inspector'} title={inspector ? 'Hide inspector' : 'Inspector'}>
            <svg aria-hidden="true" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="4" width="18" height="16" rx="3" /><path d="M15 4v16" />{inspector && <path d="M15 4h3a3 3 0 0 1 3 3v10a3 3 0 0 1-3 3h-3z" fill="currentColor" stroke="none" opacity=".35" />}</svg>
          </button>}
        </div>) : <>{collapsed && <div className="side-float">{sideToggle(false)}</div>}<div className="phone-bar floating"><Burger /><b>Frog</b></div></>}

        {/* A link to a session this account doesn't have (deleted, or never was) says so. */}
        {sessionMissing(view, sessions, sessionsLoaded) && (
          <div className="main home">
            <div className="home-hero">
              <Mark size={56} />
              <h1>Session not found</h1>
              <div className="det wrap" style={{ textAlign: 'center' }}>It may have been deleted, or it belongs to another account.</div>
              <button type="button" className="f-btn f-btn--prominent" onClick={() => setView({ kind: 'new' })}>New session</button>
            </div>
          </div>
        )}
        {view.kind === 'session' && current && ct && (<>
          <div className="scroll" ref={pinScroll}><div className="col tx">
            {cs?.state === 'refused' && <div role="status" className="banner warn"><span style={{ flex: 1 }}>Update Frog to continue. This sandbox speaks a different protocol than this page.</span>{safeHref(cs.refused.upgrade) ? <a className="f-btn f-btn--bordered f-btn--small" href={safeHref(cs.refused.upgrade)!.href} style={{ textDecoration: 'none' }}>Update</a> : <button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => location.reload()}>Reload</button>}</div>}
            {cs?.state === 'closed' && cs.code === 4004 && <div role="status" className="banner warn">This session was deleted.</div>}
            {ct.turns.length === 0 && !opening[current.id] && cs?.state !== 'refused' && current.state !== 'error' && (
              <div className="ghost" role="status" aria-label={current.state === 'starting' ? 'Starting the sandbox' : 'Loading'}>
                <div className="ghost-me" />
                <div className="ghost-line" style={{ width: '92%' }} />
                <div className="ghost-line" style={{ width: '78%' }} />
                <div className="ghost-line" style={{ width: '54%' }} />
              </div>
            )}
            <Transcript thread={op ? provisional(ct, op) : ct} start={op && { since: op.at, stage: current.id.startsWith(PENDING) ? 'reserving' : current.state === 'running' ? 'engine' : 'booting', repo: op.repo, upSince: op.runningAt, onRetry: () => retry(current.id),
              error: op.failed ?? (current.state === 'error' ? (current.error ? plainError(current.error) : "The sandbox couldn't start.") : null) }} models={models} credit={account ? creditLine(account).replace(/ credit$/, '') : undefined} onDecide={(a, o) => decide(current.id, a, o)}
              onAnswer={(choices, other) => ct.question && cloud?.send(current.id, { op: 'answer', id: ct.question.id, choices, ...(other ? { other } : {}) })}
              onElicit={(action, content) => ct.elicitation && cloud?.send(current.id, { op: 'elicit', id: ct.elicitation.id, action, ...(content ? { content } : {}) })}
              onRetry={() => send(current.id, 'Try that again.')}
              onPrompt={(text) => send(current.id, text)}
              onShowChange={() => { try { localStorage.setItem('frog.inspectorTab', 'changes') } catch { /* private mode */ } setInspectorTab('changes'); setInspectorNonce((n) => n + 1); setInspector(true) }}
              outbox={undelivered(outbox[current.id], ct.turns)} onResend={(n) => resend(current.id, n)}
              waiting={cs?.state === 'connecting' ? (cs.attempt ? 'reconnecting to the sandbox' : 'connecting to the sandbox')
                : current.state === 'sleeping' ? 'waking the sandbox' : current.state === 'starting' ? 'starting the sandbox'
                : ct.running ? 'Frog is finishing the last turn' : undefined}
              onEdit={(text) => setRestore({ text, images: [] })}
              onContinue={() => send(current.id, 'Continue.')} />
            {/* A sandbox that couldn't start says so here, by the composer, not above the conversation
                (a new one says so on its status row, under its first message). */}
            {current.state === 'error' && !op && <div role="status" className="banner warn"><span style={{ flex: 1 }}>{current.error ? plainError(current.error) : "The sandbox couldn't start."}</span><button type="button" className="f-btn f-btn--bordered f-btn--small" onClick={() => remove(current)}>Delete</button></div>}
            {card.show && !paused && key && (
              <ConnectCard onConnect={() => leave(null, 'github', key, true)} onDismiss={() => remember({ done: true })} />
            )}
            {paused && (
              <CreditWall thread={ct} models={models} avg={avgTurn} apiKey={!DEV_KEY ? key : undefined}
                onTopUp={!DEV_KEY ? (d) => { wall.leaving(d, account?.credit_cents ?? 0); return topUp(key, d).catch((e) => { wall.stayed(); throw e }) } : undefined}
                onRedeemed={(r) => { setAccount((a) => (a ? { ...a, credit_cents: r.credit_cents } : a)); refreshAccount(); wall.redeemed(r) }}
                waiting={wall.waiting ? { text: wall.waiting, onResume: wall.resumeByHand(account?.credit_cents ?? 0) } : null}
                credit={account?.credit_cents} creditAt={accountAt} onResume={wall.resumeByHand(account?.credit_cents ?? 0)} />
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
            {!paused && <Composer key={slots.current[current.id] ?? current.id} session autoFocus usage={account ? { sub: account.subscription ?? null, credit: creditLine(account).replace(/ credit$/, ''), onBilling: () => openSettings('billing'), onOpen: refreshAccount } : undefined} context={ct.context} compacting={!!compacting[current.id]}
              onCompact={(focus) => { setCompacting((c) => ({ ...c, [current.id]: (ct.marks ?? []).length + 1 })); cloud?.send(current.id, { op: 'compact', ...(focus ? { focus } : {}) }) }} chips={ct.next && !ct.running ? [{ text: ct.next.text, send: true, act: ct.next.act }] : undefined} state={ct.running || (opening[current.id] && !failedStart) ? 'working' : paused ? 'paused' : 'idle'} startedAt={ct.startedAt} speed={ct.speed} waiting={!!(ct.ask || ct.question || ct.elicitation)}
              repo={current.repo} branch={current.branch} pr={current.pr} adds={adds} dels={dels}
              model={idOf(ct.model)} models={models} machines={machines} onManage={() => openSettings('models')} onModel={(id) => cloud?.send(current.id, { op: 'set_model', spec: spec(id) })}
              mode={ct.mode ?? 'default'} onMode={(mode) => cloud?.send(current.id, { op: 'set_mode', mode })}
              queued={queue[current.id]} restore={restore} vision={ct.vision} insert={preview?.insert} onText={preview ? (t) => preview.noteDraft(t) : undefined}
              onUnqueue={(i) => setQueue((all) => ({ ...all, [current.id]: (all[current.id] ?? []).filter((_, j) => j !== i) }))}
              asking={mode === 'threads' && !!ct.ask}
              onSend={(text, images) => failedStart ? retry(current.id, text, images) : (ct.running || opening[current.id]
                ? setQueue((all) => ({ ...all, [current.id]: [...(all[current.id] ?? []), { text, images }] }))
                : send(current.id, text, images))} onStop={() => cloud?.send(current.id, { op: 'interrupt' })} onGit={() => push(current)} />}
            {!paused && <CreditWarning account={account} addedCents={lastAdded} avg={avgTurn} onAdd={() => openSettings('billing')} />}
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
              <Composer usage={account ? { sub: account.subscription ?? null, credit: creditLine(account).replace(/ credit$/, ''), onBilling: () => openSettings('billing'), onOpen: refreshAccount } : undefined} repo={view.repo} draft={draft} autoFocus pickRepo={view.pick} chips={starterChips}
                recent={[...new Set(sessions.map((s) => s.repo).filter(Boolean))]} repos={repoList.repos.map((r) => r.name)} install={repoList.install} onRepo={(repo) => setView({ kind: 'new', repo })} base={view.base} onBase={(base) => setView((v) => (v.kind === 'new' ? { ...v, base } : v))}
                onConnectGithub={key && account && !account.handle && !DEV_KEY ? (text) => leave(text || null, 'github', key) : undefined}
                model={chosenModel} models={models} machines={machines} onManage={() => openSettings('models')} onModel={setNewModel} mode={newMode} onMode={setNewMode}
                onSend={(text, images) => { setDraft(undefined); start(text, view.repo, images, view.base) }} />
              <CreditWarning account={account} addedCents={lastAdded} avg={avgTurn} onAdd={() => openSettings('billing')} />
            </div>
          </div>
        )}

      </main> }}
      inspector={key && view.kind === 'session' && current && ct && inspector && (
        <Inspector key={inspectorNonce} onClose={() => setInspector(false)} thread={ct} branch={current.branch} hasPr={!!current.pr} onCommit={() => commit(current)} onPr={current.repo ? () => push(current) : undefined} machines={machines} send={(op) => cloud?.send(current.id, op)} preview={preview} pane={inspectorTab} />
      )}
      after={<>
      {key && palette && <Palette commands={commands} sessions={sessions} onOpen={(id) => go({ kind: 'session', id })} onClose={() => setPalette(false)}
        text={(id) => thread(id).turns.flatMap((u) => [u.input, ...u.entries.filter((e) => e.kind === 'message').map((e) => e.text)]).join('\n')} />}
      {toast && <div className="toast" role="status">{toast}</div>}
      </>} />
  )
}
