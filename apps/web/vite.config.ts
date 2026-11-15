import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// /v1 (HTTP and websockets) goes to the gateway in $GATEWAY, default the mock (`npm run mock`),
// so the page and the gateway share an origin in dev.
const gateway = process.env.GATEWAY ?? 'http://127.0.0.1:8788'

export default defineConfig({
  plugins: [react()],
  server: { proxy: { '/v1': { target: gateway, ws: true, changeOrigin: true } } },
})
