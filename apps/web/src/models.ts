import { useEffect, useState } from 'react'
import { API } from './auth'
import type { Mode } from './cloud/protocol'

// Frog Cloud's models, from the edge's OpenAI-style /v1/models (prices are USD per token).
// The engine names them `cloud/<id>`.

export interface Model { id: string; context: number | null; input: number | null; output: number | null }

export const spec = (id: string) => `cloud/${id}`
export const idOf = (spec: string | null) => (spec?.startsWith('cloud/') ? spec.slice(6) : spec)

/** USD per million tokens, e.g. "$0.20 / $0.80 per M". */
export function price(m: Model) {
  if (m.input == null || m.output == null) return ''
  const f = (x: number) => `$${(x * 1e6).toFixed(x * 1e6 < 1 ? 2 : 1)}`
  return `${f(m.input)} in · ${f(m.output)} out per M tokens`
}

export function useModels(key: string | null) {
  const [models, setModels] = useState<Model[]>([])
  useEffect(() => {
    if (!key) return
    let live = true
    fetch(`${API}/v1/models`, { headers: { authorization: `Bearer ${key}` } })
      .then((r) => (r.ok ? r.json() : { data: [] }))
      .then((v: { data?: { id: string; context_length?: number; pricing?: { prompt?: string; completion?: string } }[] }) => {
        if (!live) return
        setModels((v.data ?? []).map((m) => ({
          id: m.id,
          context: m.context_length ?? null,
          input: m.pricing?.prompt != null ? Number(m.pricing.prompt) : null,
          output: m.pricing?.completion != null ? Number(m.pricing.completion) : null,
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
