// A follow-up message must not rename a session (frog.toys review, 2026-11-14: "pomodoro timer
// cli" became turn 2's text in the sidebar and title bar).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { keepTitle, keptTitle } from '../src/titles.ts'

const mem = () => { const m = new Map<string, string>(); return { getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, v) } }

test('the first engine title sticks when a later titled event renames it', () => {
  const s = mem()
  assert.equal(keptTitle('a', null, 'Build a pomodoro timer', s), 'Build a pomodoro timer')
  assert.equal(keptTitle('a', 'pomodoro timer cli', 'Build a pomodoro timer', s), 'pomodoro timer cli')
  assert.equal(keptTitle('a', 'add a pause button', 'add a pause button', s), 'pomodoro timer cli')
})

test('a rename by the user replaces the kept title', () => {
  const s = mem()
  keptTitle('a', 'pomodoro timer cli', '', s)
  keepTitle('a', 'focus timer', s)
  assert.equal(keptTitle('a', 'pomodoro timer cli', '', s), 'focus timer')
})
