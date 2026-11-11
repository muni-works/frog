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
