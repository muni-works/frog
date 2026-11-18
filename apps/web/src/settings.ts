// Settings mode (docs/design/app-shell.md): the shell's third mode. Its sections on the web, their
// URLs, the old `?settings=` deep links, and the theme Appearance keeps. No React here, so the
// routing and the theme are testable on their own.

/** The web's sections, in the spec's order (its sections table). The Mac-only ones (General,
 *  Permissions, MCP, Shortcuts, Energy, Lend) aren't shown on the web at all. Account is where
 *  Settings first opens. */
export const SECTIONS = [
  { id: 'appearance', label: 'Appearance' },
  { id: 'models', label: 'Models' },
  { id: 'account', label: 'Account' },
  { id: 'billing', label: 'Billing' },
] as const

export type Section = (typeof SECTIONS)[number]['id']

export const isSection = (s: unknown): s is Section => SECTIONS.some((x) => x.id === s)

/** Settings › <section>'s own URL. */
export const settingsPath = (s: Section) => `/settings/${s}`

/** The section a path names: '' for bare /settings, null for any other path. */
export function settingsSectionOf(path: string): Section | '' | null {
  const m = path.match(/^\/settings(?:\/([\w-]*))?\/?$/)
  if (!m) return null
  return isSection(m[1]) ? m[1] : ''
}

/** api.frog.toys and Stripe land on `?settings=account|billing`: the section that names, if any. */
export function sectionOfQuery(search: string): Section | null {
  const q = new URLSearchParams(search)
  if (!q.has('settings')) return null
  const v = q.get('settings')
  return isSection(v) ? v : 'account'
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
