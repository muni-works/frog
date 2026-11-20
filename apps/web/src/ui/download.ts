// Where the web app can point at the Mac app: the download chip's two gates, as plain predicates
// so they're testable without a browser and a test can prove each one is load-bearing.

/** A finger, not a mouse. iOS and Android browsers report their primary pointer as coarse. */
export const COARSE_POINTER = '(pointer: coarse)'

/** A `matchMedia` query, injected in tests. */
export type Matches = (query: string) => boolean

const media: Matches = (q) => {
  try {
    return typeof matchMedia === 'function' && matchMedia(q).matches
  } catch {
    return false
  }
}

/** Gate 1: a phone or tablet. The web app can't pair a machine or run a local model there, and
 *  iOS won't run a .dmg at all. Not `drawer` (App.tsx): that's the sidebar, which also opens on a
 *  narrow desktop window and is closed on a phone until the burger is tapped. */
export function isPhone(matches: Matches = media): boolean {
  return matches(COARSE_POINTER)
}

/** Gate 2: they already have the app. A paired local machine — `Machine.thisMac` on any row —
 *  is the Mac app's own node, so the heaviest users aren't the ones shown the prompt most. */
export const hasThisMac = (machines: readonly { thisMac?: boolean }[] = []): boolean =>
  machines.some((m) => m.thisMac === true)

/** Whether the download chip shows at all: off a phone, and only when the Mac app is missing. */
export function showsDownloadChip({ thisMac, phone }: { thisMac: boolean; phone: boolean }): boolean {
  return !phone && !thisMac
}

/** The same decision for a site that also has to hide something else when the chip is there. */
export function downloadChipShown(machines: readonly { thisMac?: boolean }[] = [], phone: boolean = isPhone()): boolean {
  return showsDownloadChip({ thisMac: hasThisMac(machines), phone })
}

/** A Mac with a mouse: what a Mac-only setting's invitation needs before it offers the app. An
 *  iPad says "Macintosh" too, so a coarse pointer rules it out. */
export function isMacVisitor(matches: Matches = media, ua: string = typeof navigator === 'object' ? navigator.userAgent : ''): boolean {
  return !isPhone(matches) && /Macintosh|Mac OS X/.test(ua)
}

/** What an invitation row (a setting that works in the Mac app) offers where its control would
 *  be: the download, the app they already have, or nothing off a Mac. */
export type Invite = 'get' | 'open' | 'elsewhere'
export function inviteFor({ mac, thisMac }: { mac: boolean; thisMac: boolean }): Invite {
  if (!mac) return 'elsewhere'
  return thisMac ? 'open' : 'get'
}

/** The longest message a `frog://new` link carries: the Mac drops a longer one rather than cut
 *  it (NewSessionLink.maxPrompt, counted in characters; code points here never undercount). */
export const MAX_LINK_PROMPT = 8000

/** What a local model's row hands Frog for Mac: the model (the catalog id the row is keyed on),
 *  the composer's draft, and the session's repo. All optional. */
export interface HandoffDraft { model?: string; prompt?: string; repo?: string }

/** `frog://new?model=…&prompt=…&repo=…`: a new session on the Mac with that model chosen and the
 *  message in its composer, unsent. `encodeURIComponent`, not `URLSearchParams`: Foundation reads
 *  a `+` as a plus, not a space. A message over the cap is left off (the web keeps it). */
export function newSessionHref({ model, prompt, repo }: HandoffDraft = {}): string {
  const text = prompt?.trim() ? prompt : undefined
  const parts: [string, string | undefined][] = [
    ['model', model || undefined],
    ['prompt', text && [...text].length <= MAX_LINK_PROMPT ? text : undefined],
    ['repo', repo || undefined],
  ]
  const q = parts.filter(([, v]) => v !== undefined).map(([k, v]) => `${k}=${encodeURIComponent(v!)}`).join('&')
  return q ? `frog://new?${q}` : 'frog://new'
}

/** Where picking a local model in the web's model menu goes, by the same invitation. With the app
 *  (a paired This Mac): a new session in Frog for Mac with the model and the draft. On a Mac the
 *  web can't tell about (no machines reported, which today is every Mac): the same link, and the
 *  download if nothing answers it (`fallback`, see `openWithFallback`). Anywhere else, the Mac
 *  app's page. */
export function macHandoff(invite: Invite, draft: HandoffDraft = {}): { href: string; does: string; title: string; fallback?: string } {
  if (invite === 'open') return { href: newSessionHref(draft), does: 'opens Frog for Mac', title: 'Opens in Frog for Mac' }
  if (invite === 'get') return { href: newSessionHref(draft), fallback: '/download', does: 'opens Frog for Mac, or gets it', title: 'Opens in Frog for Mac. No app yet? Download it free' }
  return { href: '/mac', does: 'learn about Frog for Mac', title: 'Runs on a Mac, in Frog for Mac' }
}

/** Where the draft waits while the tab is away at the download, for the composer to take back. */
export const HANDOFF_DRAFT_KEY = 'frog.handoffDraft'

/** The draft left by a hand-off that went to the download, once. */
export function takeHandoffDraft(storage: Pick<Storage, 'getItem' | 'removeItem'> | undefined = globalThis.sessionStorage): string | undefined {
  try {
    const v = storage?.getItem(HANDOFF_DRAFT_KEY)
    if (v === null || v === undefined) return undefined
    storage!.removeItem(HANDOFF_DRAFT_KEY)
    return v
  } catch { return undefined }
}

/** What `openWithFallback` touches, injected in tests. */
export interface FallbackEnv {
  go: (href: string) => void
  on: (event: 'blur' | 'pagehide' | 'visibilitychange', f: () => void) => () => void
  hidden: () => boolean
  /** The page has the keyboard (`document.hasFocus`). */
  focused: () => boolean
  storage?: Pick<Storage, 'setItem'>
  later: (f: () => void, ms: number) => void
}

const browserEnv = (): FallbackEnv => ({
  go: (href) => { window.location.href = href },
  on: (event, f) => {
    const target: EventTarget = event === 'visibilitychange' ? document : window
    target.addEventListener(event, f)
    return () => target.removeEventListener(event, f)
  },
  hidden: () => document.visibilityState === 'hidden',
  focused: () => document.hasFocus(),
  storage: (() => { try { return sessionStorage } catch { return undefined } })(),
  later: (f, ms) => { setTimeout(f, ms) },
})

/** Try the Mac app's link; go to `fallback` (with the draft kept for the composer to take back)
 *  only if this page stayed visible and focused for the whole `wait`: nothing answered `frog://`,
 *  so no app. The app opening takes the window (`blur`, `pagehide`, `visibilitychange`), which
 *  cancels the redirect, so someone with the app is never sent to the download. */
export function openWithFallback(href: string, fallback: string, draft: string, wait = 2000, env: FallbackEnv = browserEnv()): void {
  let left = false
  const offs = (['blur', 'pagehide', 'visibilitychange'] as const).map((e) => env.on(e, () => { left = true }))
  env.go(href)
  env.later(() => {
    offs.forEach((off) => off())
    if (left || env.hidden() || !env.focused()) return
    try { if (draft.trim()) env.storage?.setItem(HANDOFF_DRAFT_KEY, draft) } catch { /* private mode */ }
    env.go(fallback)
  }, wait)
}
