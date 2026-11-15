// Small pure pieces of the live-session plumbing, kept apart so the tests can load them without Vite.

/** Which subscriptions to open and which to close when the streamed set changes. */
export function diffIds(open: Iterable<string>, want: readonly string[]) {
  const had = new Set(open)
  const keep = new Set(want)
  return { add: [...keep].filter((id) => !had.has(id)), drop: [...had].filter((id) => !keep.has(id)) }
}

/** Hands out each queued batch once. The queue effect can run twice before its own state update
 * lands (e.g. when `opening` clears in the same frame), and a second run must not submit again:
 * a batch is identified by the array it came in, which the update then replaces. */
export function once<T extends object>() {
  const taken = new WeakSet<T>()
  return (batch: T) => {
    if (taken.has(batch)) return false
    taken.add(batch)
    return true
  }
}
