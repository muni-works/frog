import { useMemo, useState } from 'react'
import type { Account } from '../auth'
import type { SessionSummary } from '../cloud/protocol'
import { useLayer } from './layers'

// What opens over the page: the command palette. (Settings was an overlay here too; it's a mode
// of the shell now, in ./Settings.tsx.)

export interface Command { id: string; label: string; hint?: string; run: () => void }

export function Palette({ commands, sessions, onOpen, onClose, text }: { commands: Command[]; sessions: SessionSummary[]; onOpen: (id: string) => void; onClose: () => void; text?: (id: string) => string }) {
  const [q, setQ] = useState('')
  const [hi, setHi] = useState(0)
  const items = useMemo(() => {
    const needle = q.trim().toLowerCase()
    const named = [...commands, ...sessions.map((s) => ({ id: s.id, label: s.title, hint: s.repo.split('/')[1] ?? 'No repo', run: () => onOpen(s.id) }))]
      .filter((c) => c.label.toLowerCase().includes(needle))
    // Sessions whose loaded conversation mentions it, with the line it's on.
    const said: Command[] = needle.length < 3 || !text ? [] : sessions.flatMap((s) => {
      if (named.some((c) => c.id === s.id)) return []
      const body = text(s.id)
      const at = body.toLowerCase().indexOf(needle)
      if (at < 0) return []
      const line = body.slice(Math.max(0, body.lastIndexOf('\n', at) + 1), body.indexOf('\n', at) < 0 ? undefined : body.indexOf('\n', at)).trim()
      return [{ id: `t-${s.id}`, label: s.title, hint: line.length > 60 ? line.slice(0, 57) + '…' : line, run: () => onOpen(s.id) }]
    })
    return [...named, ...said]
  }, [q, commands, sessions, onOpen, text])
  useLayer(true, onClose)
  const run = (c?: Command) => { if (!c) return; onClose(); c.run() }
  return (
    <div className="scrim" onMouseDown={onClose}>
      <div className="cardx palette" role="dialog" aria-label="Command palette" onMouseDown={(e) => e.stopPropagation()}>
        <input className="pal-in" autoFocus value={q} placeholder="Search sessions and commands" aria-label="Search"
          onChange={(e) => { setQ(e.target.value); setHi(0) }}
          onKeyDown={(e) => {
            if (e.key === 'ArrowDown') { e.preventDefault(); setHi(Math.min(hi + 1, items.length - 1)) }
            if (e.key === 'ArrowUp') { e.preventDefault(); setHi(Math.max(hi - 1, 0)) }
            if (e.key === 'Enter') run(items[hi])
          }} />
        <div className="pal-list">
          {items.length === 0 && <div className="det" style={{ padding: 14 }}>Nothing matches.</div>}
          {items.map((c, i) => (
            <button key={c.id} type="button" className={`row pick ${i === hi ? 'on' : ''}`} onMouseEnter={() => setHi(i)} onClick={() => run(c)}>
              <span style={{ flex: 1 }}>{c.label}</span><span className="det">{c.hint}</span>
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}

/** "$22.04 credit": what's left to spend on tokens. */
export function creditLine(a: Account | null) {
  if (!a) return ''
  return `${dollars(a.credit_cents / 100)} credit`
}

export function dollars(d: number) {
  return d > 0 && d < 0.01 ? '<$0.01' : `$${d.toFixed(2)}`
}
