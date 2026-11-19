import type { ReactNode } from 'react'

// The new-session landing's centre (home.css): the mark, one heading, the composer, and signed
// out the "What is Frog?" card. Signed out and signed in share it, at the same fixed offset from
// the top, so nothing moves on sign-in.

/** The suggestions the landing's composer cycles through, signed out or without a repo. */
export const SCRATCH_SUGGESTIONS = [
  'Make a tiny pomodoro timer',
  'Build a Markdown notes app that saves locally',
  'Write a CLI that renames photos by date taken',
  'Start five small tools at once',
] as const

/** With a repo chosen: chores for it. */
export const REPO_SUGGESTIONS = [
  'Fix the failing tests',
  'Review my open pull request',
  'Find and fix a bug from the open issues',
  'Update the dependencies and run the tests',
] as const

/** The mark, the heading and the composer, centred in the page; `below` (the signed-out card)
 * hangs under them and only pushes them up when the window is too short for both. */
export function HomeHero({ children, below }: { children: ReactNode; below?: ReactNode }) {
  return (
    <div className="home-col">
      <div className="home-above" />
      <div className="home-hero-c">
        <span className="mark home-mark" aria-hidden="true" />
        <h1>What should we work on?</h1>
        {children}
      </div>
      <div className="home-below">{below}</div>
    </div>
  )
}

/** Signed out, under the composer: what Frog is, in one card. */
export function WhatIsFrog() {
  const lanes = [30, 58, 86, 114, 142]
  // Where each lane has got to: done ones end in a merged PR, running ones in a live dot.
  const ends = [206, 170, 206, 134, 206]
  return (
    <section className="what" aria-labelledby="what-h">
      <div className="what-tx">
        <span className="what-lb">What is Frog?</span>
        <h2 id="what-h">Hand it the work.<br />Close the laptop.</h2>
        <p>A coding agent on open models. Each task gets its own sandbox, five can run at once, and you come back to pull requests.</p>
        <span className="what-ft">Only the repos you pick. Nothing merges without you.</span>
      </div>
      <svg className="what-art" viewBox="0 0 240 172" role="img" aria-label="A closed laptop asleep while five tasks run side by side, three already done as pull requests">
        <defs>
          <pattern id="wa-dots" width="12" height="12" patternUnits="userSpaceOnUse"><circle cx="1" cy="1" r="0.8" className="wa-dot" /></pattern>
          <mask id="wa-moon"><rect width="240" height="172" fill="#fff" /><circle cx="41" cy="27" r="11" fill="#000" /></mask>
        </defs>
        <rect width="240" height="172" fill="url(#wa-dots)" />
        <circle className="wa-go" cx="34" cy="34" r="13" mask="url(#wa-moon)" />
        <text className="wa-z" x="66" y="132" fontSize="10">z</text>
        <text className="wa-z" x="74" y="123" fontSize="7">z</text>
        <rect className="wa-lid" x="14" y="140" width="62" height="6" rx="2" />
        <rect className="wa-base" x="9" y="146" width="72" height="6" rx="3" />
        <circle className="wa-go" cx="45" cy="143" r="1.5" />
        {lanes.map((y, i) => (
          <g key={y}>
            <path className="wa-track" d={`M100 ${y}H206`} />
            <path className="wa-run" d={`M100 ${y}H${ends[i]}`} />
            {ends[i] === 206 ? (
              <g transform={`translate(220 ${y})`}>
                <circle className="wa-go" r="8" />
                <path className="wa-tick" d="M-3.5 0.2l2.3 2.3 4.7-4.8" />
              </g>
            ) : (
              <g transform={`translate(${ends[i]} ${y})`}>
                <circle className="wa-halo" r="7" />
                <circle className="wa-go" r="3.5" />
              </g>
            )}
          </g>
        ))}
      </svg>
    </section>
  )
}
