// Dev only (`?customize=sample` under `npm run dev`): the canvas frames' sample data, so the
// designs can be seen before a cloud session answers a real report. App.tsx imports this behind
// import.meta.env.DEV, so a production build never contains it. Never shown to anyone as real.

import type { Automation, Report, Use } from './customize'

const use = (s: string): Use => {
  const days: number[] = s.split('').map((c) => (c === '2' ? 3 : c === '1' ? 1 : 0))
  return { count: days.reduce((a, b) => a + b, 0), days, last: null }
}
const sq = (s: string) => s.split('').map((c, i) => ({ name: `tool_${i}`, exposed: `mcp__x__tool_${i}`, description: '', state: c === '1' ? 'on' as const : c === 'x' ? 'withheld' as const : 'off' as const, why: null, read_only: null, tokens: 0, tokens_if_on: 0, use: use('0') }))
const skill = (name: string, description: string, scope: 'project' | 'everywhere', t: number, u: string, on = true) =>
  ({ id: name, name, description, scope, source: 'frog' as const, path: `.frog/skills/${name}/SKILL.md`, on, tokens: on ? t : 0, tokens_if_on: t, full_tokens: 310, shadowed_by: null, use: use(u) })

export const SAMPLE: { report: Report; automations: Automation[] } = {
  report: {
    project: 'pond',
    estimate: { chars_per_token: 3.5, calibrated: false },
    tokens: 4060,
    skills: {
      tokens: 820, budget_tokens: 1500, names_only: false,
      items: [
        skill('release-notes', "Write release notes in pond's house style from merged pull requests.", 'project', 140, '000100010000100110001000120011'),
        skill('db-migrations', "How to write and check a migration for pond's Postgres schema.", 'project', 190, '000000000100000000000010000100'),
        skill('commit', 'Write a commit message from the staged changes.', 'everywhere', 90, '121201221012210122101221012212'),
        skill('code-review', 'Review a diff for bugs before it is committed.', 'everywhere', 190, '010100110001010010011000101101'),
        skill('pdf', 'Read, fill and build PDF files. From Claude Code.', 'everywhere', 210, '000000000000000000000000000000'),
        skill('threejs-shaders', 'Write GLSL shaders for three.js scenes. From Claude Code.', 'everywhere', 200, '000000000000000000000000000000', false),
      ],
    },
    connections: {
      tokens: 2860, deferred: false,
      items: [
        { name: 'github', scope: 'everywhere', source: 'frog', on: true, state: 'connected', error: null, waiting: null, tokens: 700, tokens_if_all_on: 2100, instructions_tokens: 0, tools: sq('111100000000'), use: { ...use('0'), count: 88 } },
        { name: 'figma', scope: 'everywhere', source: 'frog', on: true, state: 'connected', error: null, waiting: null, tokens: 2160, tokens_if_all_on: 3900, instructions_tokens: 0, tools: sq('11111111111100000000xx0'), use: use('0') },
        { name: 'linear', scope: 'everywhere', source: 'frog', on: true, state: 'needs_sign_in', error: null, waiting: 'sign_in', tokens: 0, tokens_if_all_on: 0, instructions_tokens: 0, tools: sq('00000000'), use: use('0') },
      ],
    },
    rules: {
      tokens: 310,
      files: [
        { path: '/workspace/repo/CLAUDE.md', scope: 'project', source: 'claude_code', kind: 'instructions', applies: 'always', paths: [], tokens: 210, full_tokens: 210,
          lines: [
            { n: 1, text: 'Use pnpm in this project, never npm.', follows: 41 },
            { n: 2, text: 'Tests live in spec/, one file per module. Run them with pnpm test.', follows: 28 },
            { n: 3, text: 'Never edit files under generated/. Change the schema and run pnpm codegen.', follows: 6 },
            { n: 4, text: 'Commit messages start with the area, then a colon: "timer: fix drift after sleep".', follows: 19 },
          ] },
        { path: '~/.config/frog/AGENTS.md', scope: 'everywhere', source: 'frog', kind: 'instructions', applies: 'always', paths: [], tokens: 100, full_tokens: 100,
          lines: [
            { n: 1, text: "Be concise. Skip explanations I didn't ask for.", follows: 120 },
            { n: 2, text: 'Never force-push or reset --hard without asking.', follows: 2 },
          ] },
      ],
    },
    memory: {
      tokens: 70, omitted: 0,
      notes: [
        { id: 'a', scope: 'project', created: '2026-11-16T10:00:00Z', session: null, title: 'timer drifts after sleep', text: 'The timer module is being rewritten in #212; avoid large edits there.', path: '', cites: [], missing: [], tokens: 18, omitted: false },
        { id: 'b', scope: 'project', created: '2026-11-12T10:00:00Z', session: null, title: 'why did my seed data vanish', text: "The staging database is reset every Monday; don't rely on data there.", path: '', cites: [], missing: [], tokens: 18, omitted: false },
        { id: 'c', scope: 'everywhere', created: '2026-10-28T10:00:00Z', session: null, title: 'set up a new CLI', text: 'Prefers Rust and TypeScript; uses npm outside pond.', path: '', cites: [], missing: [], tokens: 14, omitted: false },
      ],
    },
  },
  automations: [
    { id: 'ci', name: 'Fix CI when it fails on main', when: 'When CI fails', where: 'ecto/pond, Frog Cloud', on: true, waiting: true, week: [['did'], [], [], [], ['did', 'fail'], ['did'], ['ask']] },
    { id: 'triage', name: 'Morning triage', when: 'Weekdays at 9:00', where: 'ecto/pond, Frog Cloud', on: true, waiting: false, week: [['did'], ['idle'], [], [], ['did'], ['idle'], ['did']] },
    { id: 'review', name: 'Review my open pull requests', when: 'Weekdays at 16:30', where: 'all repos, paused after 3 failures', on: false, waiting: false, week: [['fail'], ['fail'], [], [], ['fail'], [], []] },
  ],
}
