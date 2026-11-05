import { Fragment, memo, useMemo, useState, type ReactNode } from 'react'

// Replies as Markdown: fenced code (with Copy), headings, lists, quotes, rules, tables and
// inline code, bold, italics and links. Built as React elements, never HTML strings, so model
// output can't inject markup. Links are http(s) and mailto only.

type Block =
  | { k: 'code'; lang: string; text: string; open: boolean }
  | { k: 'h'; level: number; text: string }
  | { k: 'list'; ordered: boolean; start: number; items: string[] }
  | { k: 'quote'; text: string }
  | { k: 'hr' }
  | { k: 'table'; head: string[]; rows: string[][] }
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
      const rows: string[][] = []
      i += 2
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) rows.push(cells(lines[i++]))
      out.push({ k: 'table', head, rows })
      continue
    }
    const li = line.match(/^\s*([-*+]|(\d+)[.)])\s+(.*)$/)
    if (li) {
      flush()
      const ordered = !!li[2]
      const items: string[] = []
      while (i < lines.length) {
        const m = lines[i].match(/^\s*([-*+]|(\d+)[.)])\s+(.*)$/)
        if (m && !!m[2] === ordered) { items.push(m[3]); i++; continue }
        // A wrapped or indented continuation line belongs to the item above.
        if (items.length && /^\s{2,}\S/.test(lines[i])) { items[items.length - 1] += '\n' + lines[i].trim(); i++; continue }
        break
      }
      out.push({ k: 'list', ordered, start: ordered ? Number(li[2]) : 1, items })
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

const SAFE = /^(https?:|mailto:)/i

/** Inline Markdown into React nodes: `code`, **bold**, *em*, [links](url), bare URLs. */
export function inline(text: string, key = 0): ReactNode[] {
  const out: ReactNode[] = []
  const re = /(`+)([\s\S]*?[^`])\1(?!`)|\*\*([\s\S]+?)\*\*|__([\s\S]+?)__|(?<![\w*])\*(?!\s)([\s\S]+?)(?<!\s)\*(?!\w)|(?<![\w_])_(?!\s)([\s\S]+?)(?<!\s)_(?!\w)|\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)|(https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"])/g
  let last = 0
  let m: RegExpExecArray | null
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(...lines(text.slice(last, m.index), `${key}-${last}`))
    const k = `${key}-${m.index}`
    if (m[2] !== undefined) out.push(<code key={k}>{m[2]}</code>)
    else if (m[3] !== undefined || m[4] !== undefined) out.push(<strong key={k}>{inline(m[3] ?? m[4], m.index)}</strong>)
    else if (m[5] !== undefined || m[6] !== undefined) out.push(<em key={k}>{inline(m[5] ?? m[6], m.index)}</em>)
    else if (m[7] !== undefined) out.push(SAFE.test(m[8]) ? <a key={k} href={m[8]} target="_blank" rel="noreferrer">{inline(m[7], m.index)}</a> : <Fragment key={k}>{m[7]}</Fragment>)
    else if (m[9] !== undefined) out.push(<a key={k} href={m[9]} target="_blank" rel="noreferrer">{m[9]}</a>)
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
  const blocks = useMemo(() => parse(text), [text])
  return (
    <div className="md">
      {blocks.map((b, i) => {
        switch (b.k) {
          case 'code': return <Code key={i} lang={b.lang} text={b.text} />
          case 'h': {
            const H = (['h3', 'h3', 'h4', 'h5', 'h6', 'h6'] as const)[b.level - 1]
            return <H key={i}>{inline(b.text, i)}</H>
          }
          case 'list': {
            const items = b.items.map((it, j) => <li key={j}>{inline(it, j)}</li>)
            return b.ordered ? <ol key={i} start={b.start}>{items}</ol> : <ul key={i}>{items}</ul>
          }
          case 'quote': return <blockquote key={i}><Markdown text={b.text} /></blockquote>
          case 'hr': return <hr key={i} />
          case 'table': return (
            <div key={i} className="md-table"><table>
              <thead><tr>{b.head.map((c, j) => <th key={j}>{inline(c, j)}</th>)}</tr></thead>
              <tbody>{b.rows.map((r, j) => <tr key={j}>{r.map((c, n) => <td key={n}>{inline(c, n)}</td>)}</tr>)}</tbody>
            </table></div>
          )
          default: return <p key={i}>{inline(b.text, i)}</p>
        }
      })}
    </div>
  )
})
