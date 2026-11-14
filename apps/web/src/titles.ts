// A session keeps the first name it gets. When a cloud sandbox restarts without its log, the
// engine starts over at "turn 1" and auto-titles from the next message, so a later `titled`
// event (and the gateway's list, which follows it) can rename a session to a follow-up's text.
// Only a rename the user makes here replaces a kept title.

const KEY = 'frog.title.'

type Store = Pick<Storage, 'getItem' | 'setItem'>
const local = (): Store | null => { try { return globalThis.localStorage ?? null } catch { return null } }

/** The title to show: the kept one, else the engine's, else the list's. Keeps the engine's first. */
export function keptTitle(id: string, engine: string | null, listed: string, store: Store | null = local()): string {
  let kept: string | null = null
  try { kept = store?.getItem(KEY + id) ?? null } catch { /* private mode */ }
  if (kept) return kept
  if (engine) { try { store?.setItem(KEY + id, engine) } catch { /* memory only */ } }
  return engine ?? listed
}

/** The user renamed it: that name is kept from now on. */
export function keepTitle(id: string, title: string, store: Store | null = local()) {
  try { store?.setItem(KEY + id, title) } catch { /* memory only */ }
}
