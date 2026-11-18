import { Fragment, useEffect, useRef, useState, type ReactNode } from 'react'
import type { TurnUsage } from '../cloud/protocol'
import { currentId, idOf, modelName, servedByName, type Model } from '../models'
import { money, seconds, tokens, turnCost } from '../usage'
import { CopyButton, IconButton } from './Transcript'

// The turn's footer (docs/design/transcript/spec.md, "The footer"): one meta line under the last
// row, the model then time, tokens and cost; the cost opens the working (PriceCard on the Mac).
// Speed moves to the stats line in phase 2. Copy and retry show on hover, after the line.

export function TurnFooter({ usage, models, answer, pinned, onRetry, credit }: { usage: TurnUsage; models: Model[]; answer: string; pinned: boolean; onRetry?: () => void; /** The account's credit left, "$4.12". */ credit?: string }) {
  const [open, setOpen] = useState(false)
  const root = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!open) return
    const down = (e: MouseEvent) => { if (!root.current?.contains(e.target as Node)) setOpen(false) }
    document.addEventListener('mousedown', down)
    return () => document.removeEventListener('mousedown', down)
  }, [open])
  if (usage.model_calls <= 0) return null

  const id = idOf(usage.model ?? null)
  const model = models.find((m) => currentId(m.id) === id)
  const cost = turnCost(usage, model)
  const t = usage.timing

  // One meta line (spec, "The footer"): the model in muted, then time, tokens and cost, set off
  // by middle dots. The cost opens the working (the turn card) until the turn panel replaces it.
  const parts: ReactNode[] = []
  if (t) parts.push(<span key="t" title="Wall time for this turn">{seconds(t.wall_ms)}</span>)
  if (usage.output_tokens > 0) parts.push(<span key="n" title={`${usage.output_tokens.toLocaleString('en-US')} tokens written, ${usage.input_tokens.toLocaleString('en-US')} read`}>{usage.output_tokens.toLocaleString('en-US')} tokens</span>)
  if (cost) parts.push(<button key="c" type="button" className="turn-plate" aria-expanded={open} title="Cost of this turn" onClick={() => setOpen(!open)}>{money(cost.total)}</button>)

  return (
    <div ref={root} data-row="footer" className={`turn-foot ${pinned || open ? 'pinned' : ''}`}>
      <span className="turn-line">
        {id && <span className="turn-model">{modelName(id)}</span>}
        {/* Who served a Frog Cloud turn reads as Frog Cloud, whoever's GPUs answered (Cam, 2026-11-12). */}
        {usage.served_by && <><span className="dot" aria-hidden="true"> · </span><span className="turn-model">{servedByName(usage.served_by)}</span></>}
        {parts.map((p, i) => <Fragment key={i}>{(i > 0 || id) && <span className="dot" aria-hidden="true"> · </span>}{p}</Fragment>)}
      </span>
      <span className="hover-acts">
        {answer && <CopyButton text={answer} label="Copy answer" />}
        {onRetry && <IconButton label="Try again" icon="retry" onClick={onRetry} />}
      </span>
      {open && cost && (
        <div className="f-card turn-card" role="dialog" aria-label="Cost of this turn">
          <div className="turn-card-h"><b>Cost</b><b className="num">{money(cost.total)}</b></div>
          {credit && <div className="det">of {credit} credit left</div>}
          <Row label="Input" detail={`${tokens(Math.max(0, usage.input_tokens - (usage.cached_tokens ?? 0)))} tokens`} value={cost.fresh} />
          {(usage.cached_tokens ?? 0) > 0 && <Row label="Cached input" detail={`${tokens(usage.cached_tokens ?? 0)} tokens`} value={cost.cached} />}
          <Row label="Output" detail={`${tokens(usage.output_tokens)} tokens`} value={cost.output} />
          {t && (
            <div className="turn-card-time">
              {seconds(t.wall_ms)} total: {seconds(t.prefill_ms)} reading, {seconds(t.decode_ms)} writing{t.tool_ms ? `, ${seconds(t.tool_ms)} in tools` : ''}
            </div>
          )}
          <div className="det wrap">{usage.model_calls} model call{usage.model_calls === 1 ? '' : 's'} on {id} at list price.</div>
        </div>
      )}
    </div>
  )
}

function Row({ label, detail, value }: { label: string; detail: string; value: number }) {
  return (
    <div className="turn-card-row">
      <span style={{ flex: 1 }}>{label} <span className="det">{detail}</span></span>
      <span className="num">{value > 0 && value < 0.0001 ? '<$0.0001' : `$${value.toFixed(4)}`}</span>
    </div>
  )
}
