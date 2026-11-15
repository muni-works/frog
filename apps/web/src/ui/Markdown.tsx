import { Fragment, memo, useMemo, useRef, useState, type ReactNode } from 'react'

// Replies as Markdown: fenced code (with Copy), headings, lists, quotes, rules, tables and
// inline code, bold, italics and links. Built as React elements, never HTML strings, so model
// output can't inject markup. Links are http(s) and mailto only.

export type Block =
  | { k: 'code'; lang: string; text: string; open: boolean }
  | { k: 'h'; level: number; text: string }
  | { k: 'list'; ordered: boolean; start: number; items: string[]; depth?: number[]; marks?: string[] }
  | { k: 'quote'; text: string }
  | { k: 'hr' }
  | { k: 'table'; head: string[]; rows: string[][]; align?: ('left' | 'center' | 'right')[] }
  | { k: 'p'; text: string }

export function parse(src: string): Block[] {
  const lines = src.replace(/\r\n?/g, '\n').split('\n')
  const out: Block[] = []
  let i = 0
  const para: string[] = []
  const flush = () => { if (para.length) { out.push({ k: 'p', text: para.join('\n') }); para.length = 0 } }
  while (i < lines.length) {
    const line = lines[i]
    const fence = line.match(/^\s*(`{3,}|~{3,})\s*([\w+#.-]*)/)
    if (fence) {
      flush()
      const body: string[] = []
      i++
      while (i < lines.length && !lines[i].trimStart().startsWith(fence[1])) body.push(lines[i++])
      // An unclosed fence is a reply still streaming: draw it as code anyway.
      out.push({ k: 'code', lang: fence[2], text: body.join('\n'), open: i >= lines.length })
      i++
      continue
    }
    const h = line.match(/^(#{1,6})\s+(.*)$/)
    if (h) { flush(); out.push({ k: 'h', level: h[1].length, text: h[2].replace(/\s+#+\s*$/, '') }); i++; continue }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { flush(); out.push({ k: 'hr' }); i++; continue }
    if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[i + 1])) {
      flush()
      const cells = (l: string) => l.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim())
      const head = cells(line)
      const align = cells(lines[i + 1]).map((c) => (c.startsWith(':') && c.endsWith(':') ? 'center' : c.endsWith(':') ? 'right' : 'left') as 'left' | 'center' | 'right')
      const rows: string[][] = []
      i += 2
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) rows.push(cells(lines[i++]))
      out.push({ k: 'table', head, rows, ...(align.some((a) => a !== 'left') ? { align } : {}) })
      continue
    }
    const li = line.match(/^\s*([-*+]|(\d+)[.)])\s+(.*)$/)
    if (li) {
      flush()
      const ordered = !!li[2]
      const indent = (l: string) => l.match(/^ */)![0].length
      const base = indent(line)
      const items: string[] = [], depth: number[] = [], marks: string[] = []
      while (i < lines.length) {
        const m = lines[i].match(/^\s*([-*+]|(\d+)[.)])\s+(.*)$/)
        // A nested item (two more spaces a level, as on Mac) may be either kind; a top-level
        // one must be the list's own kind.
        const d = m ? Math.floor(Math.max(0, indent(lines[i]) - base) / 2) : 0
        if (m && (d > 0 || !!m[2] === ordered)) { items.push(m[3]); depth.push(d); marks.push(m[2] ? `${m[2]}.` : '•'); i++; continue }
        // A wrapped or indented continuation line belongs to the item above.
        if (items.length && /^\s{2,}\S/.test(lines[i])) { items[items.length - 1] += '\n' + lines[i].trim(); i++; continue }
        break
      }
      out.push({ k: 'list', ordered, start: ordered ? Number(li[2]) : 1, items, ...(depth.some((d) => d > 0) ? { depth, marks } : {}) })
      continue
    }
    if (/^\s*>/.test(line)) {
      flush()
      const q: string[] = []
      while (i < lines.length && /^\s*>/.test(lines[i])) q.push(lines[i++].replace(/^\s*>\s?/, ''))
      out.push({ k: 'quote', text: q.join('\n') })
      continue
    }
    if (line.trim() === '') { flush(); i++; continue }
    para.push(line)
    i++
  }
  flush()
  return out
}

/** Where `src` can be cut so that parse(head) ++ parse(tail) == parse(src): the end of the last
 * blank line outside a code fence (every block ends at a blank line in this grammar), or 0. */
export function stableCut(src: string): number {
  const text = src.replace(/\r\n?/g, '\n')
  let cut = 0, fence: string | null = null, pos = 0, prevBlank = false
  for (const line of text.split('\n')) {
    const f = line.match(/^\s*(`{3,}|~{3,})/)
    if (fence) { if (f && line.trimStart().startsWith(fence)) fence = null }
    else if (f) fence = f[1]
    else if (line.trim() === '' && !prevBlank) cut = pos
    prevBlank = !fence && line.trim() === ''
    pos += line.length + 1
  }
  return text === src ? cut : 0
}

/** A streaming reply's blocks: the part before the last safe cut is parsed once and reused while
 * only the tail grows. `cache` holds the last head and its blocks. */
export function parseStreaming(src: string, cache: { head: string; blocks: Block[] }): Block[] {
  const cut = stableCut(src)
  const head = src.slice(0, cut)
  if (head !== cache.head) {
    // Usually the old head plus a few new blocks: parse just what was added to it.
    cache.blocks = head.startsWith(cache.head) && stableCut(cache.head) === cache.head.length
      ? [...cache.blocks, ...parse(head.slice(cache.head.length))]
      : parse(head)
    cache.head = head
  }
  return [...cache.blocks, ...parse(src.slice(cut))]
}

const SAFE = /^(https?:|mailto:)/i

/** Inline Markdown into React nodes: `code`, ***both***, ~~struck~~, **bold**, *em*, [links](url), bare URLs. */
export function inline(text: string, key = 0): ReactNode[] {
  const out: ReactNode[] = []
  const re = /(`+)([\s\S]*?[^`])\1(?!`)|\*\*\*(?!\s)([\s\S]+?)\*\*\*|~~(?!\s)([\s\S]+?)~~|\*\*([\s\S]+?)\*\*|__([\s\S]+?)__|(?<![\w*])\*(?!\s)([\s\S]+?)(?<!\s)\*(?!\w)|(?<![\w_])_(?!\s)([\s\S]+?)(?<!\s)_(?!\w)|\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)|(https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"])/g
  let last = 0
  let m: RegExpExecArray | null
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(...lines(text.slice(last, m.index), `${key}-${last}`))
    const k = `${key}-${m.index}`
    if (m[2] !== undefined) out.push(<code key={k}>{m[2]}</code>)
    else if (m[3] !== undefined) out.push(<strong key={k}><em>{inline(m[3], m.index)}</em></strong>)
    else if (m[4] !== undefined) out.push(<del key={k}>{inline(m[4], m.index)}</del>)
    else if (m[5] !== undefined || m[6] !== undefined) out.push(<strong key={k}>{inline(m[5] ?? m[6], m.index)}</strong>)
    else if (m[7] !== undefined || m[8] !== undefined) out.push(<em key={k}>{inline(m[7] ?? m[8], m.index)}</em>)
    else if (m[9] !== undefined) out.push(SAFE.test(m[10]) ? <a key={k} href={m[10]} target="_blank" rel="noreferrer">{inline(m[9], m.index)}</a> : <Fragment key={k}>{m[9]}</Fragment>)
    else if (m[11] !== undefined) out.push(<a key={k} href={m[11]} target="_blank" rel="noreferrer">{m[11]}</a>)
    last = m.index + m[0].length
  }
  if (last < text.length) out.push(...lines(text.slice(last), `${key}-${last}`))
  return out
}

/** Soft line breaks inside a paragraph stay line breaks: models write them on purpose. */
function lines(t: string, key: string): ReactNode[] {
  return t.split('\n').flatMap((part, i) => (i ? [<br key={`${key}-br${i}`} />, part] : [part]))
}

function Code({ lang, text }: { lang: string; text: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <div className="md-code">
      <div className="md-code-top">
        <span>{lang}</span>
        <button type="button" className="turn-plate" onClick={() => { navigator.clipboard?.writeText(text); setCopied(true); setTimeout(() => setCopied(false), 1200) }}>
          {copied ? 'Copied' : 'Copy'}
        </button>
      </div>
      <pre><code>{text}</code></pre>
    </div>
  )
}

/** Memoized on the text: a finished message isn't parsed again while another one streams. */
export const Markdown = memo(function Markdown({ text }: { text: string }) {
  // While it streams, only the last block is parsed again on each new token.
  const cache = useRef<{ head: string; blocks: Block[] }>({ head: '', blocks: [] })
  const blocks = useMemo(() => parseStreaming(text, cache.current), [text])
  return (
    <div className="md">
      {blocks.map((b, i) => {
        switch (b.k) {
          case 'code': return <Code key={i} lang={b.lang} text={b.text} />
          case 'h': {
            // Sized as on Mac (TurnType.heading): body + 4, body + 2, then body.
            const H = (['h2', 'h3', 'h4', 'h5', 'h6', 'h6'] as const)[b.level - 1]
            return <H key={i} dir="auto">{inline(b.text, i)}</H>
          }
          case 'list': {
            // A nested list (Mac's model): one flat list, each item stepped in by its depth,
            // with its own marker (• ◦ ▪ by depth, or its number).
            if (b.depth) return (
              <ul key={i} className="md-nest">{b.items.map((it, j) => {
                const d = b.depth![j], mk = b.marks![j]
                return <li key={j} style={{ ['--d' as string]: d }}><span className={mk === '•' ? 'md-dot' : 'md-num'}>{mk === '•' ? ['•', '◦', '▪'][d % 3] : mk}</span>{inline(it, j)}</li>
              })}</ul>
            )
            const items = b.items.map((it, j) => <li key={j} dir="auto">{inline(it, j)}</li>)
            return b.ordered ? <ol key={i} start={b.start}>{items}</ol> : <ul key={i}>{items}</ul>
          }
          case 'quote': return <blockquote key={i}><Markdown text={b.text} /></blockquote>
          case 'hr': return <hr key={i} />
          case 'table': return (
            <div key={i} className="md-table"><table>
              <thead><tr>{b.head.map((c, j) => <th key={j} style={b.align?.[j] ? { textAlign: b.align[j] } : undefined}>{inline(c, j)}</th>)}</tr></thead>
              <tbody>{b.rows.map((r, j) => <tr key={j}>{r.map((c, n) => <td key={n} style={b.align?.[n] ? { textAlign: b.align[n] } : undefined}>{inline(c, n)}</td>)}</tr>)}</tbody>
            </table></div>
          )
          default: return <p key={i} dir="auto">{inline(b.text, i)}</p>
        }
      })}
    </div>
  )
})
