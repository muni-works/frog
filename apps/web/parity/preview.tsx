// Parity page for the inspector's Preview tab: one state per load, measured and drawn by
// test/preview-layout.test.ts in headless Chrome and screenshotted into docs/design/inspector.
// `?state=<name>&theme=light|dark&w=<inspector width>&h=<height>`. Dev only (vite dev).
//
// States: empty, loaded, loading, failed, unavailable, phone, tablet, desktop, devices (the
// device menu open), more (the overflow menu open), mention (a picked element in the draft).
// The page in the frame is parity/sample, served by vite at this origin and standing in for a
// dev server in the sandbox.
import { createRoot } from 'react-dom/client'
import { GatewayError } from '../src/cloud/client'
import type { Thread } from '../src/engine/thread'
import { PreviewHub } from '../src/preview'
import { Inspector } from '../src/ui/Inspector'
import '../src/tokens.css'
import '../src/components.css'
import '../src/app.css'

const q = new URLSearchParams(location.search)
const state = q.get('state') ?? 'empty'
const w = Number(q.get('w') ?? 420)
const h = Number(q.get('h') ?? 560)
if (q.get('theme')) document.documentElement.dataset.theme = q.get('theme')!
// The inspector reads its width from here (clamped to 360–560), as it does in the app.
try { localStorage.setItem('frog.inspectorWidth', String(w)) } catch { /* private mode */ }

const sample = `${location.origin}/parity/sample`
const never = new Promise<never>(() => {})
const mint = async (): Promise<{ url: string; expires: number }> => {
  if (state === 'loading') return never
  if (state === 'failed') throw new GatewayError(502, 'nothing is listening on port 5173 in the sandbox')
  if (state === 'unavailable') throw new GatewayError(503, 'previews are not configured')
  return { url: sample, expires: Date.now() + 3_600_000 }
}
const hub = new PreviewHub(() => {}, mint)
if (state === 'mention') { hub.mention = '@button.book'; hub.mentionInDraft = true }

const paneless = state === 'empty' || state === 'unavailable'
const thread = {
  changes: [],
  panes: paneless ? {} : { p1: { id: 'p1', kind: 'preview', title: 'Lily pad', url: 'http://localhost:5173/', closed: false } },
} as unknown as Thread

document.body.style.margin = '0'
// 1 px in from the corner: test/chrome.ts crops screenshots from (1, 1), since sips reads an offset of 0 as "centre".
document.body.style.padding = '1px'
document.body.style.background = 'var(--canvas)'
createRoot(document.getElementById('root')!).render(
  <div style={{ display: 'flex', justifyContent: 'flex-end', height: h, width: w }}>
    <Inspector thread={thread} hasPr={false} onClose={() => {}} onCommit={() => {}} send={() => {}} preview={hub} pane="preview" />
  </div>,
)

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const rect = (el: Element | null | undefined) => {
  if (!el) return null
  const r = el.getBoundingClientRect()
  return { x: r.x, y: r.y, w: r.width, h: r.height }
}
const shown = (el: Element) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden' }
const click = (sel: string) => (document.querySelector(sel) as HTMLElement | null)?.click()

/** Drive the state (open a menu, pick a device), then write what the test measures. */
async function measure() {
  await sleep(300)
  if (state === 'phone' || state === 'tablet' || state === 'desktop' || state === 'devices') {
    click('[aria-label="Device size"]')
    await sleep(50)
    if (state !== 'devices') { click(`[data-device="${state}"]`); await sleep(400) }
  }
  if (state === 'more') { click('[aria-label="More"]'); await sleep(50) }
  const bar = document.querySelector('.pv-bar')
  const controls = bar ? [...bar.querySelectorAll('button, label, input, .pv-mention')].filter(shown).map((el) => ({
    label: el.getAttribute('aria-label') ?? el.getAttribute('placeholder') ?? el.className ?? el.tagName,
    tag: el.tagName.toLowerCase(),
    inField: !!el.closest('.pv-addr') && el.tagName !== 'LABEL',
    rect: rect(el),
    bg: getComputedStyle(el).backgroundColor,
  })) : []
  const empty = document.querySelector('.pv-stage .insp-empty, .insp-body > .insp-empty, .term-empty')
  const menu = document.querySelector('.pv-menu')
  const geom = {
    state, w,
    inspector: rect(document.querySelector('.insp')),
    strip: rect(document.querySelector('.insp-top')),
    bar: rect(bar),
    controls,
    stage: rect(document.querySelector('.pv-stage')),
    frame: rect(document.querySelector('.pv-frame')),
    iframe: rect(document.querySelector('.pv-frame iframe')),
    progress: rect(document.querySelector('.pv-progress')),
    empty: empty && { box: rect(empty), icon: rect(empty.querySelector('svg')), text: [...empty.querySelectorAll('b, span')].filter(shown).map((e) => ({ text: e.textContent, rect: rect(e) })), buttons: [...empty.querySelectorAll('button, a')].map((b) => b.textContent) },
    menu: menu && { rect: rect(menu), items: [...menu.querySelectorAll('[role^="menuitem"]')].map((i) => ({ text: i.textContent, checked: i.getAttribute('aria-checked'), disabled: (i as HTMLButtonElement).disabled, rect: rect(i) })), bg: getComputedStyle(menu).backgroundColor },
    address: (document.querySelector('.pv-addr input') as HTMLInputElement | null)?.value ?? null,
    text: document.querySelector('.insp')?.textContent ?? '',
  }
  const out = document.getElementById('geom')!
  out.textContent = JSON.stringify(geom)
  out.dataset.done = '1'
}
void measure()
