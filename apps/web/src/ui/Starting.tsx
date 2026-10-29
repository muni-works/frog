import { useEffect, useState } from 'react'

// From Send until Frog's first turn: what the sandbox is doing, as a short list of steps with
// the one in hand spinning, and how long it's taken so far (it takes a few seconds, sometimes
// more with a big repo, and a ticking clock reads as progress rather than a hang).

export function Starting({ repo, since, step }: { repo?: string; since: number; step: 0 | 1 | 2 }) {
  const [now, setNow] = useState(Date.now())
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 250); return () => clearInterval(t) }, [])
  const steps = [
    'Reserving a sandbox',
    repo ? `Booting it and cloning ${repo}` : 'Booting it',
    'Frog is starting on it',
  ]
  const secs = Math.max(0, Math.floor((now - since) / 1000))
  return (
    <div className="starting" role="status" aria-live="polite">
      <ol>
        {steps.map((label, i) => (
          <li key={label} className={i < step ? 'done' : i === step ? 'now' : 'next'}>
            <span className="starting-g" aria-hidden="true">
              {i < step && <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>}
            </span>
            {label}
            {i === step && <span className="starting-t">{secs}s</span>}
          </li>
        ))}
      </ol>
    </div>
  )
}
