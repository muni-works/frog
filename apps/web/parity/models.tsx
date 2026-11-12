// Parity page for the model picker and Settings › Models: the same fixture the Mac's
// ModelsParityTests draws. `?view=picker|settings|machine&theme=light|dark`. Dev only (vite dev).
import { createRoot } from 'react-dom/client'
import { Composer } from '../src/ui/Composer'
import { Settings } from '../src/ui/Overlays'
import type { Machine } from '../src/machines'
import type { Model } from '../src/models'
import '../src/tokens.css'
import '../src/components.css'
import '../src/app.css'

const q = new URLSearchParams(location.search)
if (q.get('theme')) document.documentElement.dataset.theme = q.get('theme')!

const G = 2 ** 30
const machines: Machine[] = [
  { id: 'this-mac', name: 'studio', thisMac: true, hardware: 'M4 Max · 64 GB unified', online: true, model: null, totalBytes: 64 * G, freeBytes: 40 * G,
    models: [{ id: 'mlx-community/Qwen3-8B-4bit', name: 'Qwen3-8B-4bit', hash: 'aaaaaaaaaaaa11', loaded: false, quant: 'mlx-4bit' }] },
  { id: 'n1', name: 'mew', hardware: 'RTX 3090 · 24 GB VRAM', online: true, model: 'Qwen3-4B', decode: 58.4, totalBytes: 24 * G, freeBytes: 6 * G,
    models: [
      { id: 'Qwen/Qwen3-4B', name: 'Qwen3-4B', hash: 'bbbbbbbbbbbb22', loaded: true, quant: 'bf16' },
      { id: 'mlx-community/Qwen3-8B-4bit', name: 'Qwen3-8B-4bit', hash: 'aaaaaaaaaaaa11', loaded: false, quant: 'mlx-4bit' },
    ] },
]
const models: Model[] = [
  { id: 'deepseek-v4.1-flash', context: 131072, input: 1e-7, output: 4e-7, cached: null },
  { id: 'glm-5.3-flash', context: 131072, input: 2e-7, output: 8e-7, cached: null },
  { id: 'qwen3-coder-next', context: 262144, input: 3e-7, output: 1.2e-6, cached: null },
]
const account = { name: 'Cam', email: 'cam@example.com', credit_cents: 1234 } as never
const view = q.get('view') ?? 'picker'

createRoot(document.getElementById('root')!).render(
  view === 'picker'
    ? <div style={{ padding: '340px 24px 24px', maxWidth: 720 }}><Composer model="glm-5.3-flash" models={models} machines={machines} openModels onModel={() => {}} onManage={() => {}} /></div>
    : <Settings account={account} tab="Models" machines={machines} machine={view === 'machine' ? 'n1' : undefined} onSignOut={() => {}} onClose={() => {}} />,
)
