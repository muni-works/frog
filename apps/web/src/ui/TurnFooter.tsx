import { useEffect, useRef, useState } from 'react'
import type { TurnUsage } from '../cloud/protocol'
import { currentId, idOf, modelName, placeColor, placeOf, servedByName, type Model } from '../models'
import { money, seconds, tokens, turnCost } from '../usage'
import { CopyButton, IconButton } from './Transcript'

// Port of the Mac app's turn footer (FrogKit EndView): the model it ran on, what it cost
// (opens the working, like PriceCard), how fast it wrote in tokens/s, with copy and retry icons first. On the Mac every
// footer is hover-only; here the latest finished turn keeps its footer, like the phone.

export function TurnFooter({ usage, models, answer, pinned, onRetry }: { usage: TurnUsage; models: Model[]; answer: string; pinned: boolean; onRetry?: () => void }) {
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
  const tps = usage.tokens_per_sec ?? 0
  const speed = tps > 0 ? Math.round(tps) : null
  const t = usage.timing

  return (
    <div ref={root} className={`turn-foot ${pinned || open ? 'pinned' : ''}`}>
      <span className="hover-acts">
        {answer && <CopyButton text={answer} label="Copy answer" />}
        {onRetry && <IconButton label="Try again" icon="retry" onClick={onRetry} />}
      </span>
      {id && <span className="turn-model" style={{ color: placeColor(placeOf(usage.model)) }}>{modelName(id)}</span>}
      {/* Who served it is a place tag: a Frog Cloud turn is cloud green whoever's GPUs answered,
          and reads as Frog Cloud whoever proxied it (Cam, 2026-11-12). */}
      {usage.served_by && <span style={{ color: placeColor('cloud') }}>{servedByName(usage.served_by)}</span>}
      {cost && (
        <button type="button" className="turn-plate" aria-expanded={open} title="Cost of this turn" onClick={() => setOpen(!open)}>{money(cost.total)}</button>
      )}
      {speed != null && <span title="Tokens per second">{speed} tok/s</span>}
      {t && <span title="Wall time for this turn">{seconds(t.wall_ms)}</span>}

      {open && cost && (
        <div className="f-card turn-card" role="dialog" aria-label="Cost of this turn">
          <div className="turn-card-h"><b>Cost</b><b className="num">{money(cost.total)}</b></div>
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
