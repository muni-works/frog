import { useEffect, useRef } from 'react'
import type { Pane } from '../engine/thread'

// A live terminal in the sandbox: an engine-owned shell (Op::PaneOpen kind terminal). The
// engine sends the visible screen as text lines plus the cursor (pane_screen); keys go back
// as pane_input, and the pane is resized to fit (pane_resize).

const KEYS: Record<string, string> = {
  Enter: '\r', Backspace: '\x7f', Tab: '\t', Escape: '\x1b', Delete: '\x1b[3~',
  ArrowUp: '\x1b[A', ArrowDown: '\x1b[B', ArrowRight: '\x1b[C', ArrowLeft: '\x1b[D',
  Home: '\x1b[H', End: '\x1b[F', PageUp: '\x1b[5~', PageDown: '\x1b[6~',
}

/** A key press as the bytes a terminal expects, or null to let the browser have it. */
export function keyData(e: { key: string; ctrlKey: boolean; metaKey: boolean; altKey: boolean }): string | null {
  if (e.metaKey) return null // ⌘C / ⌘V stay the browser's
  if (e.ctrlKey && e.key.length === 1) {
    const c = e.key.toLowerCase().charCodeAt(0)
    if (c >= 97 && c <= 122) return String.fromCharCode(c - 96) // ⌃A … ⌃Z
    if (e.key === '[') return '\x1b'
    return null
  }
  if (KEYS[e.key]) return KEYS[e.key]
  if (e.key.length === 1) return (e.altKey ? '\x1b' : '') + e.key
  return null
}

export function TerminalPane({ pane, onInput, onResize }: { pane: Pane; onInput: (data: string) => void; onResize: (cols: number, rows: number) => void }) {
  const box = useRef<HTMLDivElement>(null)
  const field = useRef<HTMLTextAreaElement>(null)
  const sent = useRef('')
  // Fit the pane to the box: one character cell is measured once from a hidden probe.
  useEffect(() => {
    const el = box.current
    if (!el) return
    const probe = el.querySelector('.term-probe') as HTMLElement | null
    const fit = () => {
      if (!probe) return
      const cw = probe.getBoundingClientRect().width / 10, ch = probe.getBoundingClientRect().height
      if (!cw || !ch) return
      const cols = Math.max(20, Math.floor((el.clientWidth - 24) / cw)), rows = Math.max(5, Math.floor((el.clientHeight - 20) / ch))
      const key = `${cols}x${rows}`
      if (key !== sent.current) { sent.current = key; onResize(cols, rows) }
    }
    fit()
    const ro = new ResizeObserver(fit)
    ro.observe(el)
    return () => ro.disconnect()
  }, [pane.id, onResize])

  const s = pane.screen
  return (
    <div ref={box} className="term live" onMouseUp={() => { if (!getSelection()?.toString()) field.current?.focus() }}>
      {/* Keys land in a hidden field: special keys (Enter, arrows, ⌃C) go as key presses, and
          typed text as input events, so dictation, IME and paste work too. */}
      <textarea ref={field} className="term-field" aria-label="Terminal input" autoCapitalize="off" autoCorrect="off" spellCheck={false}
        onKeyDown={(e) => {
          if (pane.closed || e.nativeEvent.isComposing) return
          const d = keyData(e)
          // Plain printable keys are left to the input event below.
          if (d != null && !(e.key.length === 1 && !e.ctrlKey && !e.altKey)) { e.preventDefault(); onInput(d) }
        }}
        onInput={(e) => { const t = e.currentTarget.value; e.currentTarget.value = ''; if (t && !pane.closed) onInput(t.replace(/\r?\n/g, '\r')) }} />
      <span className="term-probe" aria-hidden="true">0123456789</span>
      {s ? s.lines.map((line, r) => (
        <div key={r} className="term-line">
          {styled(r === s.cursor[0] && !pane.closed ? line.padEnd(s.cursor[1] + 1) : line, r === s.cursor[0] && !pane.closed ? s.cursor[1] : -1)}
        </div>
      )) : <div className="term-line term-wait">Starting a shell<span className="cursor"> </span></div>}
      {pane.closed && <div className="det" style={{ marginTop: 6 }}>Shell exited{pane.exit != null ? ` (${pane.exit})` : ''}.</div>}
    </div>
  )
}

// The screen is plain text (no colours from the engine), so the one thing worth styling is
// picked out by shape: a prompt at the start of a line, "repo # " or "~/x $ ". Its folder is
// green and its sigil faint; the rest is as printed. `cursor` is a column, or -1.
const PROMPT = /^(\S{1,60}) ([#$]) /
function styled(line: string, cursor: number) {
  const m = line.match(PROMPT)
  const parts: { text: string; cls?: string }[] = m
    ? [{ text: m[1], cls: 't-path' }, { text: ' ' }, { text: m[2], cls: 't-sigil' }, { text: ' ' }, { text: line.slice(m[0].length) }]
    : [{ text: line || ' ' }]
  let col = 0
  return parts.flatMap((p, i) => {
    const start = col
    col += p.text.length
    if (cursor < start || cursor >= col) return [<span key={i} className={p.cls}>{p.text}</span>]
    const at = cursor - start
    return [
      <span key={`${i}a`} className={p.cls}>{p.text.slice(0, at)}</span>,
      <span key={`${i}c`} className="cursor">{p.text[at] ?? ' '}</span>,
      <span key={`${i}b`} className={p.cls}>{p.text.slice(at + 1)}</span>,
    ]
  })
}
