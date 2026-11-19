import { useEffect, useState } from 'react'

// The composer's one suggestion: muted text in the empty field with a "tab" hint, Tab takes it.
// One string stays put (a follow-up); a list cycles slowly on the landing: each holds 6 s, fades
// out over 180 ms, and the next fades in over 240 ms. It stops once you type, and under reduced
// motion it never cycles: the first one stays.

export const SUGGEST = { holdMs: 6000, outMs: 180, inMs: 240 } as const

export const reducedMotion = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches

export type Suggestion = string | readonly string[]

const listOf = (s: Suggestion | undefined): readonly string[] => (typeof s === 'string' ? [s] : s ?? []).filter(Boolean)

/** The suggestion showing now, and whether it is fading out. `live` false holds the current one. */
export function useSuggestion(s: Suggestion | undefined, live: boolean): { text: string | null; out: boolean } {
  const list = listOf(s)
  // By content, not identity: the app re-renders on every poll with a new array.
  const key = list.join('\n')
  const [st, set] = useState({ key, i: 0, out: false })
  const cur = st.key === key ? st : { key, i: 0, out: false }
  const cycles = live && list.length > 1
  useEffect(() => {
    if (!cycles || reducedMotion()) { set((p) => (p.key === key && !p.out ? p : { key, i: p.key === key ? p.i : 0, out: false })); return }
    let t: ReturnType<typeof setTimeout>
    const hold = () => {
      t = setTimeout(() => {
        set((p) => ({ key, i: p.key === key ? p.i : 0, out: true }))
        t = setTimeout(() => { set((p) => ({ key, i: (p.key === key ? p.i : 0) + 1, out: false })); hold() }, SUGGEST.outMs)
      }, SUGGEST.holdMs)
    }
    hold()
    return () => clearTimeout(t)
  }, [key, cycles])
  if (!list.length) return { text: null, out: false }
  return { text: list[cur.i % list.length], out: cur.out }
}
