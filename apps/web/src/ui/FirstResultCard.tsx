// After the first result, once (frame 6): one quiet card under the stats line, for an account on
// the free credit. What the task cost out of the free credit, what Pro covers in the same terms,
// See plans and Not now. When it shows is plans.ts planCard; its words are plans.ts COPY.
import { COPY } from '../plans'

export function FirstResultCard({ took, pro, onPlans, onLater }: { took: string; pro: string; onPlans: () => void; onLater: () => void }) {
  return (
    <section className="cardx first-card" aria-label="What that cost">
      <b style={{ fontSize: 15 }}>{took}</b>
      <div className="det wrap" style={{ marginTop: -4 }}>{pro}</div>
      <div className="acts">
        <button type="button" className="f-btn f-btn--prominent" onClick={onPlans}>{COPY.cardSee}</button>
        <button type="button" className="f-btn f-btn--bordered" onClick={onLater}>{COPY.cardLater}</button>
      </div>
    </section>
  )
}
