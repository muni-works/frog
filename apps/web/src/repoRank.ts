// Which of the account's repos the where menu shows (docs/design/composer/spec.md, Where it
// runs). One rule on both apps, pinned by docs/design/composer/repo-rank.json; the Mac's copy is
// apps/FrogKit/Core/RepoRank.swift.

/** How many repos the menu lists before the rest go behind the search. */
export const REPO_LIMIT = 6

export type RankedRepo = { name: string; pushed_at: string | null }

/** Every repo, best first: the current one, then the ones used in Frog (most recent first), then
 *  the rest by their last push on GitHub (newest first, never-pushed last, then by name).
 *  `pushed_at` is GitHub's ISO 8601 UTC stamp, so comparing the strings orders the times.
 *  GitHub names ignore case: a pasted "Ecto/Pond" is the account's "ecto/pond", one row, in the
 *  account's spelling. */
export function rankRepos(current: string | undefined, used: readonly string[], repos: readonly RankedRepo[]): string[] {
  const spelling = new Map(repos.map((r) => [r.name.toLowerCase(), r.name]))
  const out: string[] = []
  const seen = new Set<string>()
  const add = (r: string | undefined) => {
    if (!r || seen.has(r.toLowerCase())) return
    seen.add(r.toLowerCase())
    out.push(spelling.get(r.toLowerCase()) ?? r)
  }
  add(current)
  used.forEach(add)
  const rest = [...repos].sort((a, b) => {
    if (a.pushed_at !== b.pushed_at) {
      if (a.pushed_at === null) return 1
      if (b.pushed_at === null) return -1
      return a.pushed_at < b.pushed_at ? 1 : -1
    }
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0
  })
  rest.forEach((r) => add(r.name))
  return out
}

/** The rows to show for a search (empty: the best few) and how many matches didn't fit. */
export function pickRepos(ranked: readonly string[], query: string, limit = REPO_LIMIT): { shown: string[]; more: number } {
  const q = query.trim().toLowerCase()
  const matches = q ? ranked.filter((r) => r.toLowerCase().includes(q)) : [...ranked]
  return { shown: matches.slice(0, limit), more: Math.max(0, matches.length - limit) }
}

/** The one quiet line under a trimmed list; null when nothing is hidden. */
export function moreLine(more: number, searching: boolean): string | null {
  if (more <= 0) return null
  if (searching) return `${more} more ${more === 1 ? 'match' : 'matches'}, keep typing`
  return `${more} more ${more === 1 ? 'repo' : 'repos'}, type to search`
}

/** The repos used in Frog, most recent first: by each session's last turn (else its last update). */
export function usedRepos(sessions: readonly { repo?: string | null; updated: number; last_turn?: number }[]): string[] {
  const at = (s: { updated: number; last_turn?: number }) => s.last_turn ?? s.updated
  return [...new Set([...sessions].sort((a, b) => at(b) - at(a)).map((s) => s.repo).filter((r): r is string => !!r))]
}
