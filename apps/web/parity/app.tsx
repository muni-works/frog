// The whole App, signed in with a mock key and open on a session, for screenshots against the mock
// gateway (test/shoot-wall.ts). `?key=<bearer>&session=<id>&theme=light|dark&click=<button text>`.
// Dev only (vite dev, /v1 proxied to $GATEWAY).
import { createRoot } from 'react-dom/client'
import '../src/tokens.css'
import '../src/components.css'
import '../src/app.css'
import '../src/transcript.css'
import '../src/wall.css'

const q = new URLSearchParams(location.search)
if (q.get('theme')) document.documentElement.dataset.theme = q.get('theme')!
try { localStorage.setItem('frog.key', q.get('key') ?? 'frog_parity'); localStorage.setItem('frog.sidebarCollapsed', '0') } catch { /* headless profile */ }
history.replaceState(null, '', q.get('session') ? `/s/${q.get('session')}` : '/')
const { default: App } = await import('../src/App')
createRoot(document.getElementById('root')!).render(<App />)
// After the session has streamed in: press a button by its text (the wall's "Have a code?").
const click = q.get('click')
if (click) setTimeout(() => [...document.querySelectorAll('button')].find((b) => b.textContent === click)?.click(), 2500)
