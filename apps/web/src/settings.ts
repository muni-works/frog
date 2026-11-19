// Settings mode (docs/design/app-shell.md): the shell's third mode. Its sections on the web, their
// URLs, the old `?settings=` deep links, and the theme Appearance keeps. No React here, so the
// routing and the theme are testable on their own.

import file from '../../../design/settings.json'

/** A setting, as design/settings.json lists it for both apps. */
export interface SettingRow {
  id: string
  section: Section
  group?: string
  label: string
  description?: string
  control: 'toggle' | 'segmented' | 'menu' | 'field' | 'button' | 'value' | 'list'
  /** both: works here; invite: the Mac's, shown here as an invitation; mac: never here; web: only here. */
  platform: 'both' | 'invite' | 'mac' | 'web'
  options?: { id: string; label: string; description?: string }[]
  when?: string
  /** Drawn on a machine's (or provider's) own page, not the section's. */
  page?: 'machine' | 'provider'
  /** An invitation's words on the web, where they differ from the Mac's. */
  web?: { label: string; description?: string }
  /** Why it can't work on a platform yet: that platform leaves it out. */
  notYet?: { web?: string; mac?: string }
}

/** The thirteen sections, in the spec's order, from design/settings.json, in three runs: the app
 *  (1), what Frog knows and can do (2: skills, connections, rules, memory, automations, each with a
 *  page of its own in ./ui/Customize.tsx), and you (3). Account is where Settings first opens. */
export const SECTION_IDS = ['general', 'appearance', 'models', 'permissions', 'shortcuts', 'skills', 'connections', 'rules', 'memory', 'automations', 'usage', 'account', 'billing'] as const
export type Section = (typeof SECTION_IDS)[number]
export const SECTIONS: readonly { id: Section; label: string; aliases?: string[]; run: 1 | 2 | 3 }[] = file.sections as { id: Section; label: string; aliases?: string[]; run: 1 | 2 | 3 }[]
export const ROWS: readonly SettingRow[] = file.rows as SettingRow[]

export const isSection = (s: unknown): s is Section => SECTIONS.some((x) => x.id === s)

/** The sections Settings shows on the web: all of them. */
export const WEB_SECTIONS = SECTIONS

/** A section by its name or an old one (mcp → connections, instructions → rules, energy → usage, lend → models). */
export const sectionNamed = (s: string | null | undefined): Section | null =>
  SECTIONS.find((x) => x.id === s || (s != null && x.aliases?.includes(s)))?.id ?? null

/** What the web draws of a section (or a machine's page): the rows that work here, and the
 *  Mac's rows it shows as invitations. `mac` rows and anything not yet possible here are left out. */
export function webRows(section: Section, page?: SettingRow['page']): { rows: SettingRow[]; invites: SettingRow[] } {
  const here = ROWS.filter((r) => r.section === section && r.page === page && !r.notYet?.web)
  return {
    rows: here.filter((r) => r.platform === 'both' || r.platform === 'web'),
    invites: here.filter((r) => r.platform === 'invite'),
  }
}

/** A row's label and description as the web shows them. */
export const webWords = (r: SettingRow) => ({ label: r.web?.label ?? r.label, description: r.web ? r.web.description : r.description })

/** Settings › <section>'s own URL. */
export const settingsPath = (s: Section) => `/settings/${s}`

/** The section a path names: '' for bare /settings, null for any other path. */
export function settingsSectionOf(path: string): Section | '' | null {
  const m = path.match(/^\/settings(?:\/([\w-]*))?\/?$/)
  if (!m) return null
  return sectionNamed(m[1]) ?? ''
}

/** api.frog.toys and Stripe land on `?settings=account|billing`: the section that names, if any. */
export function sectionOfQuery(search: string): Section | null {
  const q = new URLSearchParams(search)
  if (!q.has('settings')) return null
  return sectionNamed(q.get('settings')) ?? 'account'
}

// ---------- Appearance ----------

export type Theme = 'system' | 'light' | 'dark'
export const THEMES: { id: Theme; label: string }[] = [
  { id: 'system', label: 'System' },
  { id: 'light', label: 'Light' },
  { id: 'dark', label: 'Dark' },
]
export const THEME_KEY = 'frog.theme'

/** The theme kept in this browser; System when none is. */
export function savedTheme(): Theme {
  try {
    const t = localStorage.getItem(THEME_KEY)
    return t === 'light' || t === 'dark' ? t : 'system'
  } catch {
    return 'system'
  }
}

/** Light or dark on the page; System leaves it to the browser (tokens.css's media query). */
export function applyTheme(t: Theme, root: { dataset: Record<string, string | undefined> } = document.documentElement) {
  if (t === 'system') delete root.dataset.theme
  else root.dataset.theme = t
}

/** Keeps and applies a theme. */
export function setTheme(t: Theme) {
  try {
    if (t === 'system') localStorage.removeItem(THEME_KEY)
    else localStorage.setItem(THEME_KEY, t)
  } catch { /* private mode: this page only */ }
  applyTheme(t)
}

/** The palette's "Toggle dark mode": the opposite of what's on screen, kept like Appearance's. */
export function toggledTheme(): Theme {
  const on = document.documentElement.dataset.theme
  const dark = on ? on === 'dark' : typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches
  return dark ? 'light' : 'dark'
}

// ---------- Density ----------

export type Density = 'comfortable' | 'compact'
export const DENSITY_KEY = 'frog.density'

/** The density kept in this browser; comfortable when none is. */
export function savedDensity(): Density {
  try { return localStorage.getItem(DENSITY_KEY) === 'compact' ? 'compact' : 'comfortable' } catch { return 'comfortable' }
}

/** Compact swaps the transcript's gaps (tokens.css, [data-density="compact"]). */
export function applyDensity(d: Density, root: { dataset: Record<string, string | undefined> } = document.documentElement) {
  if (d === 'compact') root.dataset.density = 'compact'
  else delete root.dataset.density
}

export function setDensity(d: Density) {
  try {
    if (d === 'compact') localStorage.setItem(DENSITY_KEY, d)
    else localStorage.removeItem(DENSITY_KEY)
  } catch { /* private mode: this page only */ }
  applyDensity(d)
}

// ---------- New conversations use ----------

/** "New conversations use": one model every time, kept here. Absent, the last one picked. */
export const DEFAULT_MODEL_KEY = 'frog.defaultModel'
/** The model last picked in a new conversation's composer. */
export const LAST_MODEL_KEY = 'frog.newModel'

type Store = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>
const store = (): Store | null => { try { return globalThis.localStorage ?? null } catch { return null } }

/** The model a new conversation starts on: the pinned one, else the last picked. */
export function startingModel(s: Store | null = store()): string | null {
  try { return s?.getItem(DEFAULT_MODEL_KEY) ?? s?.getItem(LAST_MODEL_KEY) ?? null } catch { return null }
}

/** A pick in the new conversation's composer: remembered as the last model unless one is pinned,
 *  which the next conversation goes back to. */
export function rememberPick(m: string | null, s: Store | null = store()) {
  try {
    if (s?.getItem(DEFAULT_MODEL_KEY)) return
    if (m) s?.setItem(LAST_MODEL_KEY, m)
    else s?.removeItem(LAST_MODEL_KEY)
  } catch { /* private mode */ }
}

/** Pin a model, or null for "the last model I used". */
export function pinModel(m: string | null, s: Store | null = store()) {
  try {
    if (m) s?.setItem(DEFAULT_MODEL_KEY, m)
    else s?.removeItem(DEFAULT_MODEL_KEY)
  } catch { /* private mode */ }
}

export const pinnedModel = (s: Store | null = store()): string | null => { try { return s?.getItem(DEFAULT_MODEL_KEY) ?? null } catch { return null } }

export const AUTO_NOTE_KEY = 'frog.autoNote'

/** Noting on its own (`auto-note`, Settings › Memory): on unless turned off in this browser. */
export const savedAutoNote = (s: Store | null = store()): boolean => { try { return s?.getItem(AUTO_NOTE_KEY) !== 'off' } catch { return true } }

const listeners = new Set<() => void>()
/** Called when a setting the engine reads changes here, so open sessions hear it. */
export function onSettings(fn: () => void): () => void { listeners.add(fn); return () => { listeners.delete(fn) } }

export function setAutoNote(on: boolean, s: Store | null = store()) {
  try { s?.setItem(AUTO_NOTE_KEY, on ? 'on' : 'off') } catch { /* private mode */ }
  listeners.forEach((f) => f())
}

/** The settings this app applies, as the engine names them, with their current values
 *  (`Op::Settings`, sent on every connection): the engine plans a Customize change only for
 *  these ids, and reads auto-note from here (not told, it doesn't note). Exactly the ids
 *  `applySetting` applies. */
export function customizableSettings(): Record<string, string | boolean> {
  return { theme: savedTheme(), density: savedDensity(), 'auto-note': savedAutoNote() }
}

/** A `setting_change` from Customize, or its undo: applied to this app's own setting. False for
 *  a setting this app doesn't have (it lives on the Mac, or nowhere here yet). */
export function applySetting(id: string, value: unknown): boolean {
  if (id === 'theme' && (value === 'system' || value === 'light' || value === 'dark')) { setTheme(value); return true }
  if (id === 'density' && (value === 'comfortable' || value === 'compact')) { setDensity(value); applyDensity(value); return true }
  if (id === 'auto-note' && typeof value === 'boolean') { setAutoNote(value); return true }
  return false
}
