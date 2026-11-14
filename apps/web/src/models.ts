import { useEffect, useState } from 'react'
import { API } from './auth'
import type { Mode } from './cloud/protocol'

// Frog Cloud's models, from the edge's OpenAI-style /v1/models (prices are USD per token).
// The engine names them `cloud/<id>`.

export interface Model { id: string; context: number | null; input: number | null; output: number | null; cached: number | null }

export const spec = (id: string) => `cloud/${id}`

/** Where a model runs: `local` for this Mac, Apple's model and paired nodes; every other
 *  provider (Frog Cloud, Anthropic, OpenAI) is `cloud`. Mirrors FrogKit's `ModelIdentity.Place`. */
export type Place = 'cloud' | 'local'
export const placeOf = (spec: string | null | undefined): Place =>
  /^(local|apple|node|ollama|lmstudio)\//.test(spec ?? '') ? 'local' : 'cloud'

/** The one place color rule (docs/models.md, "Place color"): cloud green, local blue. Every
 *  model name, place tag and "where it runs" chip takes its color from here, never its own. */
export const placeColor = (p: Place): string => (p === 'cloud' ? 'var(--place-cloud)' : 'var(--place-local)')

/** The only name a user sees for who served a turn: Frog Cloud, whichever upstream proxied the
 *  call (Cam, 2026-11-12, superseding the gateway plan's decisions 1 and 8 as far as upstream
 *  naming goes). `served_by.name` stays the real upstream in the log, for cache and cost
 *  debugging; views render this. Mirrors the engine's `ServedBy::display_name` and FrogKit's
 *  `ServedBy.displayName`. */
export const servedByName = (_s: { id: string; name: string }): string => 'Frog Cloud'

/** Frog Cloud's old model ids and their explicit names today. The gateway still answers the
 *  old ones; a remembered pick or an old session's spec reads as today's id. */
const OLD_IDS: Record<string, string> = { bull: 'deepseek-v4.1-flash', tree: 'glm-5.3-flash', dart: 'qwen3-coder-next' }
export const currentId = (id: string) => OLD_IDS[id] ?? id
export const idOf = (spec: string | null) => {
  const id = spec?.startsWith('cloud/') ? spec.slice(6) : spec
  return id == null ? id : currentId(id)
}

/** The plain model name people see. */
const NAMES: Record<string, string> = {
  'deepseek-v4.1-flash': 'DeepSeek V4.1 Flash',
  'glm-5.3-flash': 'GLM-5.3 Flash',
  'qwen3-coder-next': 'Qwen3 Coder Next',
}
/** Word by word for an id the list doesn't name: "qwen3-vl-8b" reads "Qwen3 VL 8B". */
const WORDS: Record<string, string> = { glm: 'GLM', vl: 'VL', deepseek: 'DeepSeek', moe: 'MoE' }
export function humanize(id: string): string {
  const base = id.includes('/') ? id.slice(id.lastIndexOf('/') + 1) : id
  return base.split(/[-_]/).filter(Boolean).map((w) => {
    const k = w.toLowerCase()
    if (WORDS[k]) return WORDS[k]
    if (/^\d+(\.\d+)?[bkm]$/i.test(w) || /^v\d/i.test(w)) return w.toUpperCase()
    return w[0].toUpperCase() + w.slice(1)
  }).join(' ')
}
export const modelName = (id: string) => NAMES[currentId(id)] ?? humanize(id)

/** USD per million tokens, e.g. "$0.20 / $0.80 per M". */
export function price(m: Model) {
  if (m.input == null || m.output == null) return ''
  const f = (x: number) => `$${(x * 1e6).toFixed(x * 1e6 < 1 ? 2 : 1)}`
  return `${f(m.input)} in · ${f(m.output)} out per M tokens`
}

/** "$0.80/M out": a cloud model's price per million output tokens, as the picker shows it. */
export const outputPrice = (m: Model) => (m.output == null ? '' : `$${(m.output * 1e6).toFixed(2)}/M out`)

/** "$0.20 in · $0.80 out /M": both per-million prices, as the picker shows them. */
export const inOutPrice = (m: Model) =>
  m.input == null || m.output == null ? outputPrice(m) : `$${(m.input * 1e6).toFixed(2)} in · $${(m.output * 1e6).toFixed(2)} out /M`

/** The model a new session starts on: GLM-5.3 Flash while Frog Cloud lists it (it always
 *  serves it), else the first it lists. Nothing is built in: no list, no default. */
export const defaultModel = (models: Model[]) => (models.find((m) => currentId(m.id) === 'glm-5.3-flash') ?? models[0])?.id

/** The smallest context window worth offering for agent sessions. */
const MIN_AGENT_CONTEXT = 64_000

export function useModels(key: string | null) {
  const [models, setModels] = useState<Model[]>([])
  useEffect(() => {
    // Signed out, /v1/models answers without a key: the picker shows only what Frog Cloud
    // serves now, and nothing until it answers.
    setModels([])
    let live = true
    fetch(`${API}/v1/models`, key ? { headers: { authorization: `Bearer ${key}` } } : {})
      .then((r) => (r.ok ? r.json() : { data: [] }))
      .then((v: { data?: { id: string; context_length?: number; pricing?: { prompt?: string; completion?: string; input_cache_read?: string } }[] }) => {
        if (!live) return
        // Agent work needs room: the system prompt and tools alone take ~9k tokens, so models
        // with a small window (the 8B helpers the engine uses for side jobs) aren't offered.
        setModels((v.data ?? []).filter((m) => (m.context_length ?? MIN_AGENT_CONTEXT) >= MIN_AGENT_CONTEXT).map((m) => ({
          id: m.id,
          context: m.context_length ?? null,
          input: m.pricing?.prompt != null ? Number(m.pricing.prompt) : null,
          output: m.pricing?.completion != null ? Number(m.pricing.completion) : null,
          cached: m.pricing?.input_cache_read != null ? Number(m.pricing.input_cache_read) : null,
        })))
      })
      .catch(() => live && setModels([]))
    return () => { live = false }
  }, [key])
  return models
}

/** The engine's modes, in the words the composer uses. */
export const modes: { id: Mode; label: string; note: string }[] = [
  { id: 'default', label: 'Ask first', note: 'Asks before edits and commands' },
  { id: 'accept-edits', label: 'Allow edits', note: 'Edits run; commands still ask' },
  { id: 'auto', label: 'Auto', note: 'Runs what plainly serves the task; asks about the rest' },
  { id: 'yolo', label: 'Never ask', note: "Runs everything. It's your sandbox; nothing is pushed unless you ask" },
]

