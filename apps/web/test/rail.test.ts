// The turn rail's chapters (docs/design/chrome/spec.md, "The turn rail"): the shared cases the
// Mac's ChapterTests also runs, and where the rail puts a turn.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { chapterIndex, chapters, chapterWords } from '../src/ui/chapters'
import { indexAt, railHeight, yOf } from '../src/ui/TurnRail'

const cases = JSON.parse(readFileSync(new URL('../../../docs/design/chrome/rail-cases.json', import.meta.url), 'utf8')) as {
  words: [string, string][]
  conversations: { name: string; turns: { input: string; compacted?: boolean }[]; chapters: { start: number; kind: string; title: string }[] }[]
}

test('chapter names are the first clause in a few words (shared cases)', () => {
  for (const [text, want] of cases.words) assert.equal(chapterWords(text), want, text)
})

for (const c of cases.conversations) {
  test(`chapters: ${c.name} (shared case)`, () => {
    const got = chapters(c.turns)
    assert.deepEqual(got.chapters.map((x, i) => ({ start: x.start, kind: x.kind, title: got.titles[i] })), c.chapters)
  })
}

test('the current chapter is the last start at or before a turn', () => {
  assert.equal(chapterIndex(0, [0, 2]), 0)
  assert.equal(chapterIndex(1, [0, 2]), 0)
  assert.equal(chapterIndex(3, [0, 2]), 1)
  assert.equal(chapterIndex(0, []), null)
})

test('each chapter gets an equal share of the rail, and the pointer maps back to the turn', () => {
  const starts = [0, 1]
  const n = 11 // one prompt turn, then a ten-turn chapter
  const h = 100
  assert.equal(yOf(0, n, starts, h), 12)
  assert.equal(yOf(1, n, starts, h), 12 + 76 / 2)
  for (let i = 0; i < n; i++) assert.equal(indexAt(yOf(i, n, starts, h) + 0.1, n, starts, h), i)
})

test('the rail grows with chapters, not turns, and stops at 360', () => {
  assert.equal(railHeight(1, 800), 46)
  assert.equal(railHeight(2, 800), 64)
  assert.equal(railHeight(100, 800), 360)
  assert.equal(railHeight(100, 200), 200)
})
