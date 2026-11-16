import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

// /v1 (HTTP and websockets) goes to the gateway in $GATEWAY, default the mock (`npm run mock`),
// so the page and the gateway share an origin in dev.
const gateway = process.env.GATEWAY ?? 'http://127.0.0.1:8788'

// The docs sidebar shows the frog version this build was made from: the workspace's in Cargo.toml.
const cargo = readFileSync(fileURLToPath(new URL('../../Cargo.toml', import.meta.url)), 'utf8')
const version = cargo.match(/\[workspace\.package\][^[]*?\nversion\s*=\s*"([^"]+)"/)?.[1] ?? cargo.match(/^version\s*=\s*"([^"]+)"/m)?.[1] ?? 'dev'

export default defineConfig({
  plugins: [react()],
  define: { __FROG_VERSION__: JSON.stringify(version) },
  server: {
    proxy: { '/v1': { target: gateway, ws: true, changeOrigin: true } },
    // Documentation mode bundles the pages in docs/app, outside this folder.
    fs: { allow: ['.', fileURLToPath(new URL('../../docs/app', import.meta.url))] },
  },
})
