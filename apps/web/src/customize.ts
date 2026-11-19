// Customize mode (docs/design/app-shell.md, beside Documentation and Settings): what the agent
// knows and can do. Settings is how the app behaves; Customize is its skills, connections, rules,
// memory and automations. Its sections, URLs, the engine's report (docs/customize-api.md) and
// what a Frog Cloud session really reads. No React here, so routing and the rules are testable.

/** The five sections, in the sidebar's order. */
export const CUSTOMIZE_SECTIONS = [
  { id: 'skills', label: 'Skills' },
  { id: 'connections', label: 'Connections' },
  { id: 'rules', label: 'Rules' },
  { id: 'memory', label: 'Memory' },
  { id: 'automations', label: 'Automations' },
] as const
export type CustomizeSection = (typeof CUSTOMIZE_SECTIONS)[number]['id']

/** Old names that open a section: Instructions is now Rules; Settings' MCP tab is Connections. */
const ALIASES: Record<string, CustomizeSection> = { instructions: 'rules', mcp: 'connections' }

export const customizeLabel = (s: CustomizeSection) => CUSTOMIZE_SECTIONS.find((x) => x.id === s)!.label

export const isCustomizeSection = (s: unknown): s is CustomizeSection => CUSTOMIZE_SECTIONS.some((x) => x.id === s)

/** A page in Customize: a section's list, or one of its detail pages. */
export type CustomizeAt =
  | { section: CustomizeSection; page?: undefined }
  /** Skills › a skill (F2Skill), by name. */
  | { section: 'skills'; page: 'skill'; name: string }
  /** Skills or Connections › Add (F9Find). */
  | { section: 'skills' | 'connections'; page: 'add' }
  /** Connections › Add › one result (F10Review), by its id. */
  | { section: 'connections'; page: 'review'; id: string }

/** Customize opens on Skills. */
export const FIRST_CUSTOMIZE: CustomizeAt = { section: 'skills' }

/** A page's own URL. */
export function customizePath(at: CustomizeAt): string {
  const base = `/customize/${at.section}`
  if (at.page === 'skill') return `${base}/${encodeURIComponent(at.name)}`
  if (at.page === 'add') return `${base}/add`
  if (at.page === 'review') return `${base}/add/${encodeURIComponent(at.id)}`
  return base
}

/** The page a path names: FIRST_CUSTOMIZE for bare /customize, null for any other path. An unknown
 *  section opens Skills; an unknown page under a section opens that section. */
export function customizeAtOf(path: string): CustomizeAt | null {
  const m = path.match(/^\/customize(?:\/([\w-]*))?(?:\/([^/]+))?(?:\/([^/]+))?\/?$/)
  if (!m) return null
  const raw = m[1] ?? ''
  const section = isCustomizeSection(raw) ? raw : ALIASES[raw]
  if (!section) return FIRST_CUSTOMIZE
  const [a, b] = [m[2], m[3]].map((x) => (x == null ? undefined : safeDecode(x)))
  if (a === 'add' && (section === 'skills' || section === 'connections')) {
    if (b && section === 'connections') return { section, page: 'review', id: b }
    return { section, page: 'add' }
  }
  if (a && !b && section === 'skills') return { section, page: 'skill', name: a }
  return { section }
}

const safeDecode = (s: string) => { try { return decodeURIComponent(s) } catch { return s } }

/** The page that can be shown: a skill's page needs that skill in a report, and a result's review
 *  needs a search the web doesn't have, so with no data they open their list or Add page. */
export function shownAt(at: CustomizeAt): CustomizeAt {
  if (at.page === 'skill') return { section: 'skills' }
  if (at.page === 'review') return { section: 'connections', page: 'add' }
  return at
}

/** Bare /customize and old names are replaced in the history, not pushed. */
export const customizePathIsCanonical = (path: string) => {
  const at = customizeAtOf(path)
  return !!at && customizePath(at) === path.replace(/\/+$/, '')
}

/** The docs link on each section's explainer card: `/docs/<section>` once that page exists, else
 *  the page that covers it today, else none. */
const DOCS_TODAY: Record<CustomizeSection, string | null> = {
  skills: 'skills-and-mcp',
  connections: 'skills-and-mcp',
  rules: 'memory-and-frog-md',
  memory: 'memory-and-frog-md',
  automations: null,
}
export function docsSlugFor(s: CustomizeSection, slugs: readonly string[]): string | null {
  if (slugs.includes(s)) return s
  const today = DOCS_TODAY[s]
  return today && slugs.includes(today) ? today : null
}

/** Each list page's explainer: the bold sentence, the one after it, the link's words. The web's
 *  copy says what's true of a cloud session where the Mac's says "this Mac". */
export const EXPLAINERS: Record<CustomizeSection, { lead: string; rest: string; link: string }> = {
  skills: {
    lead: 'A skill teaches Frog how to do one task your way.',
    rest: 'It is a short file of steps, read in full only when that task comes up. Its one-line summary rides along on every turn.',
    link: 'How skills work',
  },
  connections: {
    lead: 'A connection lets Frog reach something outside your code,',
    rest: 'like GitHub or a database, through its tools. Each tool you switch on adds a little to every turn.',
    link: 'How connections work',
  },
  rules: {
    lead: 'Rules are standing instructions Frog reads on every turn.',
    rest: 'They live in a file in your repo or your home folder, so your team shares them.',
    link: 'How rules work',
  },
  memory: {
    lead: 'Memory is what Frog noted when you said "remember this".',
    rest: 'Notes are kept on your Mac and read on every turn. Say "forget that" to remove one.',
    link: 'How memory works',
  },
  automations: {
    lead: 'An automation is a task Frog repeats without you,',
    rest: 'at a set time or when CI fails.',
    link: 'How automations work',
  },
}

/** What a Frog Cloud session reads, from the engine's code (skills.rs, prompt.rs, mcp.rs) and the
 *  sandbox's start (`frog --serve --serve-ws` in /workspace/repo, a fresh home each time). */
export const CLOUD_READS = {
  skills: ['.frog/skills', '.agents/skills', '.claude/skills'],
  rules: ['AGENTS.md', 'FROG.md', 'CLAUDE.md'],
  connections: '.mcp.json',
} as const

/** The Mac's half of each section, shown on the web as invitations (docs/design/app-shell.md,
 *  Invitations): same words on every page, the pill where the control would be. */
export const CUSTOMIZE_INVITES: Record<CustomizeSection, { id: string; label: string; description: string }[]> = {
  skills: [
    { id: 'home-skills', label: 'Skills for every project', description: 'Kept in your home folder and used wherever you work.' },
    { id: 'skill-weight', label: 'Weight and use', description: 'What each skill adds to a turn, and when it was last used.' },
  ],
  connections: [
    { id: 'local-servers', label: 'Connections on your own machine', description: 'Servers that run beside your code, with keys that never leave it.' },
    { id: 'mcp-sign-in', label: 'Sign in to a server', description: 'Servers like Linear and GitHub, with your own account.' },
  ],
  rules: [
    { id: 'home-rules', label: 'Rules for every project', description: 'A file in your home folder, read wherever you work.' },
  ],
  memory: [
    { id: 'memory-notes', label: 'Notes Frog keeps', description: 'Say "remember this" in a conversation on your Mac. Notes stay there and are read on every turn.' },
  ],
  automations: [],
}

/** The last seven days' names for the week grid, oldest first; today is "Today". */
export function weekDays(now = new Date()): string[] {
  return Array.from({ length: 7 }, (_, i) => {
    if (i === 6) return 'Today'
    const d = new Date(now)
    d.setDate(now.getDate() - (6 - i))
    return d.toLocaleDateString('en-US', { weekday: 'short' })
  })
}
