// The home screen's backdrop: slow ripples spreading from under the frog, and reeds that sway
// at the edges. Pure SVG + CSS, drawn in the frog green at low opacity, so it reads as mood,
// not content. Stills itself for prefers-reduced-motion.

const REEDS = [{ x: 20, h: 150, d: 0 }, { x: 44, h: 210, d: 1.2 }, { x: 66, h: 120, d: 2.1 }, { x: 88, h: 170, d: 0.6 }]

function Reeds({ side }: { side: 'l' | 'r' }) {
  return (
    <svg className={`pond-reeds pond-reeds--${side}`} viewBox="0 0 120 240">
      {REEDS.map((r) => (
        <path key={r.x} d={`M${r.x} 240 Q ${r.x + 3} ${240 - r.h / 2} ${r.x + 8} ${240 - r.h}`} style={{ animationDelay: `-${side === 'r' ? r.d + 0.8 : r.d}s` }} />
      ))}
    </svg>
  )
}

export function Pond() {
  return (
    <div className="pond" aria-hidden="true">
      <svg className="pond-ripples" viewBox="-300 -120 600 240" preserveAspectRatio="xMidYMid meet">
        {[0, 1, 2, 3].map((i) => (
          <ellipse key={i} cx="0" cy="0" rx="300" ry="96" style={{ animationDelay: `${i * 3}s` }} />
        ))}
      </svg>
      <Reeds side="l" />
      <Reeds side="r" />
    </div>
  )
}

const STEPS = [
  { n: '1', title: 'Ask', text: 'Describe a change, a bug or a question. Pick a GitHub repo, or none to just talk.' },
  { n: '2', title: 'Frog works in a sandbox', text: 'It clones the repo into its own cloud machine, reads, edits and runs tests. Watch every step, or leave.' },
  { n: '3', title: 'Review and ship', text: 'See the diff, open a terminal, then commit or open a PR. You pay only for the tokens used.' },
]

export function HowItWorks() {
  return (
    <ol className="how">
      {STEPS.map((s) => (
        <li key={s.n}>
          <span className="how-n">{s.n}</span>
          <b>{s.title}</b>
          <span>{s.text}</span>
        </li>
      ))}
    </ol>
  )
}
