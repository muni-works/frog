// Chapters for the turn rail (docs/design/chrome/spec.md, "The turn rail"): the Mac's
// apps/macos/Frog/Model/Chapters.swift, line for line. Both run docs/design/chrome/rail-cases.json.

export type ChapterKind = 'prompt' | 'compacted' | 'run'
export interface Chapter { start: number; kind: ChapterKind }
/** What a chapter needs from a turn. */
export interface ChapterTurn { input: string; more?: readonly unknown[]; images?: readonly unknown[]; compacted?: boolean; chapterTitle?: string | null }

/** A run breaks into a chapter after this many turns with no prompt. */
export const RUN_AFTER = 6

const isPrompt = (t: ChapterTurn) => (t.input !== '' || (t.more?.length ?? 0) > 0) && !t.input.startsWith('<')

export function chaptersOf(turns: readonly ChapterTurn[]): Chapter[] {
  const out: Chapter[] = []
  let since = 0
  turns.forEach((t, i) => {
    if (i === 0 || isPrompt(t)) { out.push({ start: i, kind: 'prompt' }); since = 0 }
    else if (t.compacted) { out.push({ start: i, kind: 'compacted' }); since = 0 }
    else if (since >= RUN_AFTER) { out.push({ start: i, kind: 'run' }); since = 0 }
    else since++
  })
  return out
}

/** The chapter a turn is in: the last one starting at or before it. */
export function chapterIndex(i: number, starts: readonly number[]): number | null {
  if (!starts.length || i < starts[0]) return null
  let lo = 0, hi = starts.length - 1
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= i) lo = mid; else hi = mid - 1 }
  return lo
}

const LEAD_INS = new Set(['ok', 'okay', 'so', 'hey', 'please', 'pls', 'plz', 'now', 'alright', "let's", 'lets', 'let', 'us', 'can', 'could', 'would', 'you',
  'i', 'we', 'want', 'to', 'should', 'need', 'actually', 'also'])
const TRAILING = new Set(['a', 'an', 'the', 'and', 'or', 'of', 'on', 'in', 'to', 'for', 'with', 'at', 'by', 'from', 'it', 'is', 'that'])

/** The first clause of `text`, lead-in dropped, at most four words, never ending on a connective. */
export function chapterWords(text: string): string {
  const line = text.toLowerCase().split(/\r?\n/)[0] ?? ''
  // A period ends a sentence only before a space ("frog.app" is one word).
  const sentence = line.split('. ')[0]
  const clause = sentence.split(/[,:;?!()—–]/)[0] ?? ''
  let ws = clause.split(/\s+/).map((w) => w.replace(/^[^\p{L}\p{N}'-]+|[^\p{L}\p{N}'-]+$/gu, '')).filter(Boolean)
  while (ws.length > 1 && LEAD_INS.has(ws[0])) ws.shift()
  ws = ws.slice(0, 4)
  while (ws.length > 1 && TRAILING.has(ws[ws.length - 1])) ws.pop()
  return ws.join(' ')
}

/** A chapter's name: the engine's title once written, else what you asked, else what kind of stretch it is. */
export function chapterTitle(c: Chapter, t: ChapterTurn, turns: number): string {
  if (t.chapterTitle) return t.chapterTitle
  const own = `on its own · ${turns} turn${turns === 1 ? '' : 's'}`
  if (c.kind === 'compacted') return 'summarized'
  if (c.kind === 'run') return own
  if (t.input.startsWith('<') || t.input === '') return own
  const w = chapterWords(t.input)
  if (w) return w
  const raw = t.input.trim()
  if (raw && [...raw].length <= 24) return raw
  return t.images?.length ? 'an image' : 'untitled'
}

/** Chapters, their starts and names for a conversation. */
export function chapters(turns: readonly ChapterTurn[]): { chapters: Chapter[]; starts: number[]; titles: string[] } {
  const cs = chaptersOf(turns)
  const starts = cs.map((c) => c.start)
  const titles = cs.map((c, k) => chapterTitle(c, turns[c.start], (k + 1 < cs.length ? starts[k + 1] : turns.length) - c.start))
  return { chapters: cs, starts, titles }
}
