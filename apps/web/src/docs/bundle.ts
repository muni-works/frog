// The documentation pages, bundled into the build: docs/app/manifest.json and every markdown
// file under docs/app, read at build time, so the docs in this build describe this build.
// Vite-only (import.meta.glob); the logic lives in ./docs.ts.
import manifest from '../../../../docs/app/manifest.json'
import { pages, type Manifest } from './docs'

const files = import.meta.glob('../../../../docs/app/**/*.md', { query: '?raw', import: 'default', eager: true }) as Record<string, string>
const PREFIX = '../../../../docs/app/'

/** The web's pages, in manifest order. */
export const DOCS = pages(manifest as Manifest, (file) => files[PREFIX + file], 'web')

/** The frog version this build was made from (the workspace version in Cargo.toml). */
export const VERSION: string = __FROG_VERSION__
