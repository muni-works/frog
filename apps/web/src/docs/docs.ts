// Documentation mode's pages: the manifest in docs/app/manifest.json, the platform blocks in each
// page, and the routes. Pure, so the tests can feed it the real files; the Vite-only loader that
// bundles them is ./bundle.ts. The format is shared with the Mac app (docs/design/app-shell.md).

export type Platform = 'mac' | 'web' | 'terminal'

export interface Manifest {
  version: number
  sections: { title: string; pages: { slug: string; title: string; file: string }[] }[]
}

/** One page, flattened out of the manifest with its section and markdown. */
export interface Page {
  slug: string
  title: string
  section: string
  file: string
  /** The page's markdown for this platform, its leading `# Title` taken off. */
  body: string
}

const OPEN = /^\s*<!--\s*only:\s*([\w\s,]+?)\s*-->\s*$/
const END = /^\s*<!--\s*end\s*-->\s*$/

/** The page's text for one platform: blocks marked for other platforms dropped, the markers
 *  themselves gone, unmarked text kept. An unclosed block runs to the end of the page. */
export function forPlatform(src: string, platform: Platform): string {
  const out: string[] = []
  let keep = true
  let inBlock = false
  for (const line of src.replace(/\r\n?/g, '\n').split('\n')) {
    const open = line.match(OPEN)
    if (open && !inBlock) {
      inBlock = true
      keep = open[1].split(',').map((p) => p.trim()).includes(platform)
      continue
    }
    if (inBlock && END.test(line)) { inBlock = false; keep = true; continue }
    if (keep) out.push(line)
  }
  // Dropping a block can leave runs of blank lines; one is enough between paragraphs.
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trim()
}

/** The leading `# Title` off a page: the shell draws the manifest's title above the page. */
export function withoutTitle(src: string): string {
  return src.replace(/^\s*#\s+[^\n]*\n?/, '').trim()
}

/** Every page in manifest order, with its text for `platform`. `read` gives a file's markdown
 *  by its manifest path; a missing file is an empty page rather than a crash. */
export function pages(manifest: Manifest, read: (file: string) => string | undefined, platform: Platform): Page[] {
  return manifest.sections.flatMap((s) => s.pages.map((p) => ({
    slug: p.slug,
    title: p.title,
    section: s.title,
    file: p.file,
    body: withoutTitle(forPlatform(read(p.file) ?? '', platform)),
  })))
}

/** The pages before and after `slug`, across sections. */
export function neighbors(all: readonly Page[], slug: string): { prev?: Page; next?: Page } {
  const i = all.findIndex((p) => p.slug === slug)
  if (i < 0) return {}
  return { prev: all[i - 1], next: all[i + 1] }
}

/** Pages whose title or a heading contains the query, case-insensitively. */
export function search(all: readonly Page[], query: string): Page[] {
  const q = query.trim().toLowerCase()
  if (!q) return [...all]
  return all.filter((p) => p.title.toLowerCase().includes(q)
    || p.body.split('\n').some((l) => /^#{1,6}\s/.test(l) && l.toLowerCase().includes(q)))
}

/** The docs page a path names (`/docs/<slug>`), `''` for `/docs` itself, or null for any other path. */
export function docsSlugOf(path: string): string | null {
  const m = path.match(/^\/docs(?:\/([\w-]*))?\/?$/)
  return m ? (m[1] ?? '') : null
}

export const docsPath = (slug: string) => `/docs/${slug}`
