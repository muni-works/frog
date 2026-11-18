// A turn's timeline (docs/design/transcript/spec.md, "The turn line and the turn panel"): its
// events made into segments of thinking, tools, waiting on a person and writing, in ms from the
// turn's start. A port of the engine's reference (crates/frog-engine/src/timeline.rs); both must
// pass docs/design/transcript/timeline.json.
//
// - A reasoning item is thinking from its start for its `think_ms`. An older log has none: it
//   thinks until the first message or tool call logged after it in the turn starts, or until it
//   completed if that's sooner (#441; its completion alone overstates it, since it completes only
//   once the whole reply is in). A message is writing; a tool call is a tool.
// - `permission_resolved` / `question_resolved` with `asked`: waiting, from `asked` to the event's
//   `created`, cut out of its own tool's segment. Different items' segments can overlap.
// - `items_discarded`: those items are dropped (a retried call's partial reply).
// - An item still open at the end ends at the turn's end (`turn_ended`, or the last event).

export type SegmentKind = 'thinking' | 'tool' | 'waiting' | 'writing'
export interface Segment { kind: SegmentKind; start_ms: number; end_ms: number; item?: string }

/** The few fields of an envelope the timeline reads; the thread keeps these per turn. */
export interface TimedEvent {
  created: number
  event: string
  id?: string
  kind?: { type: string }
  item?: unknown
  asked?: number
  ids?: string[]
}

const ORDER: SegmentKind[] = ['thinking', 'tool', 'waiting', 'writing']

/** The segments of one turn from its events (anything before `turn_started` is ignored), sorted
 * by start, kind, item. `now` ends a live turn's open items instead of its last event. */
export function segments(all: TimedEvent[], now?: number): Segment[] {
  const begin = all.findIndex((e) => e.event === 'turn_started')
  if (begin < 0) return []
  const events = all.slice(begin)
  const t0 = events[0].created
  const ended = events.find((e) => e.event === 'turn_ended')
  const end = ended?.created ?? Math.max(now ?? 0, events[events.length - 1].created)
  const at = (t: number) => Math.min(Math.max(t, t0), Math.max(end, t0)) - t0

  // Where each message or tool call started, in log order: an older reasoning item's end.
  const answers = events.flatMap((e, i) => (e.event === 'item_started' && (e.kind?.type === 'message' || e.kind?.type === 'tool_call') ? [{ i, at: e.created }] : []))
  const open = new Map<string, { kind: SegmentKind; start: number; began: number }>()
  const out: Segment[] = []
  const waits: Segment[] = []
  const discarded: string[] = []
  for (const [i, e] of events.entries()) {
    if (e.event === 'item_started' && e.id) {
      const t = e.kind?.type
      open.set(e.id, { kind: t === 'reasoning' ? 'thinking' : t === 'message' ? 'writing' : 'tool', start: e.created, began: i })
    } else if (e.event === 'item_completed' && e.id) {
      const o = open.get(e.id)
      if (!o) continue
      open.delete(e.id)
      const it = e.item as { type?: string; think_ms?: number } | undefined
      const next = answers.find((a) => a.i > o.began)
      const stop = it?.type !== 'reasoning' ? e.created
        : it.think_ms != null ? Math.min(o.start + it.think_ms, e.created)
        : next ? Math.min(next.at, e.created) : e.created
      out.push({ kind: o.kind, start_ms: at(o.start), end_ms: at(stop), item: e.id })
    } else if ((e.event === 'permission_resolved' || e.event === 'question_resolved') && e.asked != null) {
      waits.push({ kind: 'waiting', start_ms: at(e.asked), end_ms: at(e.created), ...(typeof e.item === 'string' ? { item: e.item } : {}) })
    } else if (e.event === 'items_discarded') {
      discarded.push(...(e.ids ?? []))
    } else if (e.event === 'turn_ended') {
      break
    }
  }
  // Still open at the end.
  ;[...open.entries()].sort(([a, x], [b, y]) => x.start - y.start || (a < b ? -1 : a > b ? 1 : 0))
    .forEach(([id, o]) => out.push({ kind: o.kind, start_ms: at(o.start), end_ms: at(end), item: id }))
  const kept = out.filter((s) => !(s.item && discarded.includes(s.item)))
  // Cut each wait out of its own tool's segment.
  const cut: Segment[] = []
  for (const s of kept) {
    if (s.kind !== 'tool') { cut.push(s); continue }
    let pieces: [number, number][] = [[s.start_ms, s.end_ms]]
    for (const w of waits.filter((w) => w.item === s.item)) {
      pieces = pieces.flatMap(([a, b]) => ([[a, Math.min(w.start_ms, b)], [Math.max(w.end_ms, a), b]] as [number, number][]).filter(([x, y]) => x < y))
    }
    cut.push(...pieces.map(([a, b]) => ({ ...s, start_ms: a, end_ms: b })))
  }
  cut.push(...waits)
  const key = (s: Segment) => s.item ?? ''
  return cut.sort((a, b) => a.start_ms - b.start_ms || ORDER.indexOf(a.kind) - ORDER.indexOf(b.kind)
    || (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0) || a.end_ms - b.end_ms)
}

/** How long each reasoning item thought, in start order: its thinking segment's length. What
 * "Thought for Ns" says (engine timeline.rs `thinking`). */
export function thinking(all: TimedEvent[], now?: number): { item: string; ms: number }[] {
  return segments(all, now).filter((s) => s.kind === 'thinking').map((s) => ({ item: s.item ?? '', ms: s.end_ms - s.start_ms }))
}

/** How long each kind took, as wall time covered (overlapping tools count once). */
export function totals(segs: Segment[]): Record<SegmentKind, number> {
  const out = { thinking: 0, tool: 0, waiting: 0, writing: 0 } as Record<SegmentKind, number>
  for (const k of ORDER) {
    const spans = segs.filter((s) => s.kind === k).map((s) => [s.start_ms, s.end_ms]).sort((a, b) => a[0] - b[0])
    let reach = -1
    for (const [a, b] of spans) {
      if (b <= reach) continue
      out[k] += b - Math.max(a, reach)
      reach = b
    }
  }
  return out
}
