import { Fragment, useMemo, useState, type ReactNode } from 'react'
import type { TurnUsage } from '../cloud/protocol'
import type { Thread } from '../engine/thread'
import { segments } from '../engine/timeline'
import { currentId, idOf, modelName, servedByName, type Model } from '../models'
import { money, seconds, spent, turnCost, used } from '../usage'
import { CopyButton, IconButton } from './Transcript'
import { TurnLine, TurnPanel } from './TurnGraph'

// The turn's footer (docs/design/transcript/spec.md, "The footer" and "The turn line"): one meta
// line under the last row, the model then time, tokens and cost, and at its right end the turn
// line, which opens the turn panel (phase 3; it replaces the old cost popover). Copy and retry
// show on hover, after the line.

type Turn = Thread['turns'][number]

export function TurnFooter({ usage, turn, models, answer, pinned, onRetry, credit, stopped }: { usage: TurnUsage; turn?: Turn; models: Model[]; answer: string; pinned: boolean; onRetry?: () => void; /** The account's credit left, "$4.12". */ credit?: string; /** The person stopped the turn: the footer says so first. */ stopped?: boolean }) {
  const [open, setOpen] = useState(false)
  const segs = useMemo(() => segments(turn?.tl ?? []), [turn?.tl])
  if (!used(usage)) return null

  const id = idOf(usage.model ?? null)
  const model = models.find((m) => currentId(m.id) === id)
  // A call stopped mid-stream is in the figures as estimated, so they read "about".
  const about = usage.cut ? 'about ' : ''
  const all = spent(usage)
  const cost = turnCost(all, model)
  const t = usage.timing
  // The segments' own span (turn_started to turn_ended); wall time when the turn has no ends.
  const total = turn?.endAt != null && turn.at != null ? turn.endAt - turn.at : t?.wall_ms ?? 0

  // One meta line (spec, "The footer"): "Stopped" for a stopped turn and the model in muted,
  // then time, tokens and cost, 10 apart. The panel holds the working.
  const parts: ReactNode[] = []
  if (t) parts.push(<span key="t" title="Wall time for this turn">{seconds(t.wall_ms)}</span>)
  if (all.output_tokens > 0) parts.push(<span key="n" title={`${about ? 'About ' : ''}${all.output_tokens.toLocaleString('en-US')} tokens written, ${all.input_tokens.toLocaleString('en-US')} read${about ? ": the stopped call's are counted from what had streamed" : ''}`}>{about}{all.output_tokens.toLocaleString('en-US')} tokens</span>)
  // "<$0.01" already says it's a rough figure: no "about" in front of it.
  if (cost) parts.push(<span key="c" title={about ? "Estimated: the stopped call's share is from what had streamed" : 'Cost of this turn'}>{about && cost.total >= 0.01 ? about : ''}{money(cost.total)}</span>)

  return (
    <div data-row="footer" className={`turn-foot ${pinned || open ? 'pinned' : ''}`}>
      <span className="turn-line">
        {stopped && <><span className="turn-model">Stopped</span>{id && <span className="gap"> </span>}</>}
        {id && <span className="turn-model">{modelName(id)}</span>}
        {/* Who served a Frog Cloud turn reads as Frog Cloud, whoever's GPUs answered (Cam, 2026-11-12). */}
        {usage.served_by && <><span className="gap"> </span><span className="turn-model">{servedByName(usage.served_by)}</span></>}
        {parts.map((p, i) => <Fragment key={i}>{(i > 0 || id || stopped) && <span className="gap"> </span>}{p}</Fragment>)}
      </span>
      <span className="hover-acts">
        {answer && <CopyButton text={answer} label="Copy answer" />}
        {onRetry && <IconButton label="Try again" icon="retry" onClick={onRetry} />}
      </span>
      {segs.length > 0 && total > 0 && (
        <TurnLine segs={segs} total={total} pace={usage.pace} entries={turn?.entries ?? []} onOpen={() => setOpen(true)} />
      )}
      {open && <TurnPanel segs={segs} total={total} entries={turn?.entries ?? []} usage={usage} models={models} credit={credit} live={false} onClose={() => setOpen(false)} />}
    </div>
  )
}
