import { useState } from 'react'
import type { FileDiff } from '../cloud/protocol'

// A file's changes as hunks: a line-number gutter (new side, old for removals), tinted rows
// for added and removed lines, and a quiet gap between hunks. Used by the inspector's
// Changes list and by the edit cards in the transcript.

export function Hunks({ diff, max }: { diff: FileDiff; max?: number }) {
  const [all, setAll] = useState(false)
  const lines = diff.hunks.flatMap((h, i) => [...(i ? [{ gap: true as const }] : []), ...h.lines])
  const shown = !max || all ? lines : lines.slice(0, max)
  return (
    <div className="hunks" role="table" aria-label={`Changes to ${diff.path}`}>
      {shown.map((l, i) => 'gap' in l
        ? <div key={i} className="hunk-gap" aria-hidden="true">⋯</div>
        : (
          <div key={i} className={`hl ${l.kind}`} role="row">
            <span className="hl-n">{l.kind === 'remove' ? l.old ?? '' : l.new ?? ''}</span>
            <span className="hl-s" aria-hidden="true">{l.kind === 'add' ? '+' : l.kind === 'remove' ? '−' : ''}</span>
            <span className="hl-t">{l.text || ' '}</span>
          </div>
        ))}
      {max && !all && lines.length > max && <button type="button" className="hunk-more" onClick={() => setAll(true)}>Show {lines.length - max} more lines</button>}
    </div>
  )
}

/** One changed file in a list: name, folder, counts; click to open its hunks. */
export function FileRow({ diff, open, onToggle }: { diff: FileDiff; open: boolean; onToggle: () => void }) {
  const slash = diff.path.lastIndexOf('/')
  const name = diff.path.slice(slash + 1), dir = slash > 0 ? diff.path.slice(0, slash) : ''
  return (
    <div className={`file${open ? ' open' : ''}`}>
      <button type="button" className="file-row" aria-expanded={open} onClick={onToggle} title={diff.path}>
        <span className="file-chev" aria-hidden="true">›</span>
        <span className="file-name">{name}</span>
        {dir && <span className="file-dir">{dir}</span>}
        {diff.created && <span className="file-new">new</span>}
        <span style={{ flex: 1 }} />
        <span className="file-add">+{diff.added}</span>
        <span className="file-del">−{diff.removed}</span>
      </button>
      {open && <Hunks diff={diff} max={300} />}
    </div>
  )
}
