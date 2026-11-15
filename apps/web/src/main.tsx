import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import './tokens.css'
import './components.css'
import './app.css'

// `?theme=light|dark` pins the theme; otherwise it follows the system.
const theme = new URLSearchParams(location.search).get('theme')
if (theme) document.documentElement.dataset.theme = theme

createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>)
