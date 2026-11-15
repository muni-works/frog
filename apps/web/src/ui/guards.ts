// Small checks the UI makes, pulled out so tests can pin them without a DOM.

/** True while an IME is composing: Enter then confirms a candidate and must not send.
 * Safari reports keyCode 229 with isComposing false on the confirming keydown. */
export function composing(e: { nativeEvent: { isComposing?: boolean }; keyCode?: number }): boolean {
  return !!e.nativeEvent.isComposing || e.keyCode === 229
}

/** A `/s/<id>` link to a session the loaded list doesn't have: deleted, or never this account's. */
export function sessionMissing(view: { kind: string; id?: string }, sessions: { id: string }[], loaded: boolean): boolean {
  return view.kind === 'session' && loaded && !sessions.some((s) => s.id === view.id)
}

/** Whether a view follows the archive: only when the archived session is the one it shows.
 * Archiving another session, and unarchiving anything, leave the user where they are. */
export function archiveForwards(archived: string, open: string | null): boolean {
  return open !== null && archived === open
}

/** The view after an archive: a new session when the archived one was on screen, else the same
 * view. `on` false (unarchiving) never navigates. */
export function viewAfterArchive<V extends { kind: string; id?: string }>(view: V, archived: string, on: boolean): V | { kind: 'new' } {
  if (!on) return view
  const open = view.kind === 'session' ? view.id ?? null : null
  return archiveForwards(archived, open) ? { kind: 'new' } : view
}
