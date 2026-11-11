/** An engine failure as a plain line: what happened, then what to do. Known failures get their
 * own words, and an OS error string ("No such file or directory (os error 2)") is never shown.
 * Anything else comes back as it was. The Mac's twin is `EngineError.plain`. */
export function plainError(raw: string): string {
  const s = raw.trim()
  if (/\bno session \S+/i.test(s)) return "This session's history isn't in the sandbox anymore, so it couldn't reopen. Start a new session."
  const m = s.match(/\(os error (\d+)\)/i)
  if (!m) return s
  switch (Number(m[1])) {
    case 2: return 'A file Frog needed is missing, so it stopped. Try again, or start a new session.'
    case 1: case 13: return "Frog wasn't allowed to open a file it needs. Try again, or start a new session."
    case 28: return 'The sandbox disk is full. Start a new session.'
    default: return 'Frog hit a system error and stopped. Try again.'
  }
}
