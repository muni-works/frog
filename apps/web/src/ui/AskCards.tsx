import { useState } from 'react'
import type { Elicitation, Question } from '../engine/thread'
import { safeHref } from './href'

// Ports of FrogKit's QuestionCard (AskViews.swift) and ElicitationCard (McpViews.swift).

/** The Ask tool: pick one (or several), or type your own. Skip answers with nothing. */
export function QuestionCard({ q, onAnswer }: { q: Question; onAnswer: (choices: string[], other?: string) => void }) {
  const [picked, setPicked] = useState<string[]>([])
  const [other, setOther] = useState('')
  const toggle = (label: string) => setPicked(picked.includes(label) ? picked.filter((x) => x !== label) : [...picked, label])
  const ready = picked.length > 0 || other.trim() !== ''
  return (
    <section className="cardx ask-card" aria-label="Frog has a question">
      <b>{q.question}</b>
      <div className="ask-options">
        {q.options.map((o, i) => (
          <button key={o.label} type="button" className={`ask-option ${picked.includes(o.label) ? 'on' : ''}`}
            onClick={() => (q.multi ? toggle(o.label) : onAnswer([o.label]))} aria-pressed={q.multi ? picked.includes(o.label) : undefined}>
            <span className="ask-n">{i + 1}</span>
            <span style={{ flex: 1, minWidth: 0 }}>{o.label}{o.detail && <span className="det wrap" style={{ display: 'block' }}>{o.detail}</span>}</span>
          </button>
        ))}
      </div>
      {q.allowOther && (
        <input className="f-field" value={other} placeholder="Or type your own answer" aria-label="Your own answer"
          onChange={(e) => setOther(e.target.value)}
          onKeyDown={(e) => { if (e.nativeEvent.isComposing || e.keyCode === 229) return; if (e.key === 'Enter' && other.trim()) onAnswer(picked, other.trim()) }} />
      )}
      <div className="ask-acts">
        <button type="button" className="f-btn f-btn--plain" onClick={() => onAnswer([])}>Skip</button>
        {(q.multi || q.allowOther) && (
          <button type="button" className="f-btn f-btn--prominent" disabled={!ready} onClick={() => onAnswer(picked, other.trim() || undefined)}>Answer</button>
        )}
      </div>
    </section>
  )
}

type Value = string | number | boolean

/** An MCP server asking for input: a small form from its schema, or a link to open. */
export function ElicitationCard({ e, onReply }: { e: Elicitation; onReply: (action: 'accept' | 'decline' | 'cancel', content?: Record<string, Value>) => void }) {
  const props = Object.entries(e.schema?.properties ?? {})
  const required = new Set(e.schema?.required ?? [])
  const [values, setValues] = useState<Record<string, Value>>(() =>
    Object.fromEntries(props.flatMap(([k, p]) => (p.default !== undefined ? [[k, p.default as Value]] : p.type === 'boolean' ? [[k, false]] : []))))
  const set = (k: string, v: Value) => setValues({ ...values, [k]: v })
  const missing = [...required].some((k) => values[k] === undefined || values[k] === '')
  const link = safeHref(e.url)
  return (
    <section className="cardx ask-card" aria-label={`${e.server} needs your input`}>
      <b>{e.server} needs your input</b>
      <div className="wrap" style={{ fontSize: 13 }}>{e.message}</div>
      {link ? <a href={link.href} target="_blank" rel="noreferrer" className="f-btn f-btn--bordered" style={{ alignSelf: 'flex-start', textDecoration: 'none' }}>Open {link.host}</a> : e.url && <div className="det wrap">{e.url}</div>}
      {props.map(([k, p]) => (
        <label key={k} className="ask-field">
          <span>{p.title ?? k}{required.has(k) ? '' : ' (optional)'}</span>
          {p.enum ? (
            <select className="f-field" value={String(values[k] ?? '')} onChange={(ev) => set(k, ev.target.value)}>
              {!required.has(k) && <option value="">None</option>}
              {p.enum.map((v, i) => <option key={v} value={v}>{p.enumNames?.[i] ?? v}</option>)}
            </select>
          ) : p.type === 'boolean' ? (
            <input type="checkbox" checked={!!values[k]} onChange={(ev) => set(k, ev.target.checked)} />
          ) : (
            <input className="f-field" type={p.type === 'number' || p.type === 'integer' ? 'number' : 'text'} value={String(values[k] ?? '')}
              onChange={(ev) => set(k, p.type === 'number' || p.type === 'integer' ? Number(ev.target.value) : ev.target.value)} />
          )}
          {p.description && <span className="det wrap">{p.description}</span>}
        </label>
      ))}
      <div className="ask-acts">
        <button type="button" className="f-btn f-btn--plain" onClick={() => onReply('cancel')}>Cancel</button>
        <button type="button" className="f-btn f-btn--bordered" onClick={() => onReply('decline')}>Decline</button>
        <button type="button" className="f-btn f-btn--prominent" disabled={missing} onClick={() => onReply('accept', props.length ? values : undefined)}>{e.url && !props.length ? 'Done' : 'Submit'}</button>
      </div>
    </section>
  )
}
