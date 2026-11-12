/** How often one widget may ask Frog a follow-up (`sendPrompt`): at most one every
 * `gapMs`, and `max` in any `windowMs`. Returns a check that records the asks it allows. */
export function promptGate(gapMs = 4000, max = 3, windowMs = 60_000) {
  const at: number[] = []
  return (now: number): boolean => {
    while (at.length && now - at[0] > windowMs) at.shift()
    if (at.length >= max) return false
    if (at.length && now - at[at.length - 1] < gapMs) return false
    at.push(now)
    return true
  }
}
