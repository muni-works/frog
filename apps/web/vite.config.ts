import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { execSync } from 'node:child_process'

// /v1 (HTTP and websockets) goes to the gateway in $GATEWAY, default the mock (`npm run mock`),
// so the page and the gateway share an origin in dev.
const gateway = process.env.GATEWAY ?? 'http://127.0.0.1:8788'

// The commit this build came from, shown in the sidebar and linked to on GitHub.
const commit = (() => { try { return execSync('git rev-parse --short HEAD').toString().trim() } catch { return 'dev' } })()

export default defineConfig({
  plugins: [react()],
  define: { __FROG_COMMIT__: JSON.stringify(commit) },
  server: { proxy: { '/v1': { target: gateway, ws: true, changeOrigin: true } } },
})
