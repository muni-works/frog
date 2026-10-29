// A turn's numbers for its footer: cost at list price, speed, sizes and times. Pure, so the
// tests can load it without Vite.
import type { TurnUsage } from './cloud/protocol'

/** The model's per-token list prices (from /v1/models). */
export interface Prices { input: number | null; output: number | null; cached: number | null }

/** A turn's cost in dollars at the model's list price, split like the Mac's PriceCard. Cache
 * writes are priced as fresh input. Null when the model's prices aren't known. */
export function turnCost(u: TurnUsage, m: Prices | undefined) {
  if (!m || m.input == null || m.output == null) return null
  const cached = u.cached_tokens ?? 0
  const fresh = Math.max(0, u.input_tokens - cached) * m.input
  const reused = cached * (m.cached ?? m.input)
  const output = u.output_tokens * m.output
  return { fresh, cached: reused, output, total: fresh + reused + output }
}

/** The Mac's ModelStats.money: "Free", "<1¢", "11¢", "$1.84". */
export function money(d: number) {
  if (d <= 0) return 'Free'
  if (d < 0.01) return '<1¢'
  if (d < 1) return `${Math.round(d * 100)}¢`
  return `$${d.toFixed(2)}`
}

/** "8.4k", "312", "1.2M". */
export function tokens(n: number) {
  return n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1000 ? `${(n / 1000).toFixed(n >= 10_000 ? 0 : 1)}k` : `${n}`
}

/** "0.8s", "12s", "2m 5s". */
export function seconds(ms: number) {
  const s = ms / 1000
  return s < 10 ? `${s.toFixed(1)}s` : s < 60 ? `${Math.round(s)}s` : `${Math.floor(s / 60)}m ${Math.round(s % 60)}s`
}
