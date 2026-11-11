// The started-by tree for the web's session list, after the Mac's `SessionNesting.indented`:
// a session followed by the ones it started (those in the same list), one level deeper.
// Order is otherwise kept; a child whose parent isn't listed stays a root; a cycle loses nothing.

export const MAX_DEPTH = 4

export function indented<T extends { id: string; parent?: string | null }>(rows: T[]): { row: T; depth: number }[] {
  const present = new Set(rows.map((r) => r.id))
  const parentIn = (r: T) => (r.parent && r.parent !== r.id && present.has(r.parent) ? r.parent : null)
  const out: { row: T; depth: number }[] = []
  const placed = new Set<string>()
  const walk = (r: T, depth: number) => {
    if (placed.has(r.id)) return
    placed.add(r.id)
    out.push({ row: r, depth })
    for (const c of rows) if (parentIn(c) === r.id) walk(c, Math.min(depth + 1, MAX_DEPTH))
  }
  for (const r of rows) if (!parentIn(r)) walk(r, 0)
  for (const r of rows) if (!placed.has(r.id)) walk(r, 0)
  return out
}
