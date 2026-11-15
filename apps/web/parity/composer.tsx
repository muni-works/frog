// Parity page for the composer tray: one state from docs/design/parity/composer-states.json (the
// file the Mac's ComposerParityTests draws), merged onto cases.json's base.
// `?state=<name>&theme=light|dark`. Dev only (vite dev). The web is all Frog Cloud: a folder
// state shows as its cloud equivalent.
import { createRoot } from 'react-dom/client'
import { Composer } from '../src/ui/Composer'
import type { State } from '../src/composer'
import type { Model } from '../src/models'
import cases from '../../../docs/design/composer/cases.json'
import shots from '../../../docs/design/parity/composer-states.json'
import '../src/tokens.css'
import '../src/components.css'
import '../src/app.css'

const q = new URLSearchParams(location.search)
if (q.get('theme')) document.documentElement.dataset.theme = q.get('theme')!

type Json = unknown
const isObj = (v: Json): v is Record<string, Json> => typeof v === 'object' && v !== null && !Array.isArray(v)
const merge = (a: Json, b: Json): Json => {
  if (!isObj(a) || !isObj(b)) return b
  const out: Record<string, Json> = { ...a }
  for (const [k, v] of Object.entries(b)) out[k] = k in out ? merge(out[k], v) : v
  return out
}

const shot = shots.states.find((s) => s.name === (q.get('state') ?? 'idle')) ?? shots.states[0]
const s = merge(cases.base, shot.given) as State
const models: Model[] = [{ id: 'glm-5.3-flash', context: 131072, input: 2e-7, output: 8e-7, cached: null }]
const w = s.where
const session = w.kind === 'session'
const repo = w.kind === 'session' ? w.repo ?? undefined : w.kind === 'cloud' ? w.repo : w.kind === 'folder' && w.git ? 'muni-works/frog' : undefined

createRoot(document.getElementById('root')!).render(
  <div style={{ padding: `${shot.name === 'stack' ? 150 : 24}px 16px 16px`, maxWidth: 720 }}>
    <Composer
      session={session}
      repo={repo}
      branch={w.kind === 'session' ? w.branch : undefined}
      adds={w.kind === 'session' ? w.diff.add : 0}
      dels={w.kind === 'session' ? w.diff.del : 0}
      prs={w.kind === 'session' ? w.prs : undefined}
      ahead={w.kind === 'session' ? w.ahead : 0}
      draft={s.draft.text}
      state={s.busy === 'working' ? 'working' : 'idle'}
      queued={Array.from({ length: s.queued }, () => ({ text: 'also run the linter', images: [] }))}
      model="glm-5.3-flash" models={models} onModel={() => {}}
      mode={s.mode === 'accept_edits' ? 'accept-edits' : s.mode} onMode={() => {}}
      onRepo={session ? undefined : () => {}}
      onSend={() => {}}
      tray={{ error: s.error, stackOpen: s.stackOpen, notice: s.notice, ...(w.kind === 'chat' ? { where: w } : {}) }}
    />
  </div>,
)
