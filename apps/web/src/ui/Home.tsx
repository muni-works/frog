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

export function HomeHero({ children }: { children: ReactNode }) {
  return (
    <div className="home-col">
      <span className="mark home-mark" aria-hidden="true" />
      <h1>What should we work on?</h1>
      {children}
    </div>
  )
}

/** Signed out, under the composer: what Frog is, in one card. */
export function WhatIsFrog() {
  return (
    <section className="what" aria-labelledby="what-h">
      <div className="what-tx">
        <span className="what-lb">What is Frog?</span>
        <h2 id="what-h">Hand it the work.<br />Close the laptop.</h2>
        <p>A coding agent on open models. Each task gets its own sandbox, five can run at once, and you come back to pull requests.</p>
        <span className="what-ft">Only the repos you pick. Nothing merges without you.</span>
      </div>
      <svg className="what-art" viewBox="0 0 312 200" role="img" aria-label="Five tasks running side by side while a laptop sits closed, three already finished as pull requests">
        <path className="wa-grid" d="M0 40h312M0 80h312M0 120h312M0 160h312M78 0v200M156 0v200M234 0v200" />
        <circle className="wa-go" cx="52" cy="62" r="22" />
        <circle className="wa-bg" cx="62" cy="54" r="18" />
        <rect className="wa-fg" x="20" y="150" width="64" height="7" rx="3.5" />
        <rect className="wa-lid" x="28" y="144" width="48" height="6" rx="1.5" />
        <g strokeLinecap="round" fill="none">
          <path className="wa-track" d="M112 40h172M112 70h172M112 100h172M112 130h172M112 160h172" />
          <path className="wa-run" d="M112 40h172M112 70h118M112 100h172M112 130h72M112 160h172" />
        </g>
        <rect className="wa-fg" x="290" y="34" width="12" height="12" />
        <rect className="wa-fg" x="290" y="94" width="12" height="12" />
        <rect className="wa-fg" x="290" y="154" width="12" height="12" />
        <circle className="wa-go" cx="230" cy="70" r="5" />
        <circle className="wa-go" cx="184" cy="130" r="5" />
      </svg>
    </section>
  )
}
