import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { applyTheme, savedTheme } from './settings'
import { listenForHandoffs } from './track'
import './tokens.css'
import './components.css'
import './app.css'
import './transcript.css'

// `?theme=light|dark` pins the theme; otherwise Settings › Appearance's (index.html applies it
// before first paint too), which is System unless you picked one.
const theme = new URLSearchParams(location.search).get('theme')
if (theme) document.documentElement.dataset.theme = theme
else applyTheme(savedTheme())

// Web → Mac hand-off clicks, counted only while the gateway has funnel events on (./track.ts).
listenForHandoffs()

createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>)
