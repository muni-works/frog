// A permission request as one short question, read at a glance under the "needs you" dot:
// "Run cargo test?", "Edit fetch.ts?". The Mac's twin is FrogKit's `AskPhrase.line`.
export function askLine(name: string, arg: string): string {
  const first = (arg.split('\n')[0] ?? '').trim()
  const file = first.split('/').pop() ?? first
  switch (name) {
    case 'Bash': case 'Shell': return first ? `Run ${first}?` : 'Run a command?'
    case 'Edit': case 'MultiEdit': return first ? `Edit ${file}?` : 'Edit a file?'
    case 'Write': return first ? `Write ${file}?` : 'Write a file?'
    case 'Read': return first ? `Read ${file}?` : 'Read a file?'
    case 'WebFetch': {
      let host = first
      try { host = new URL(first).host || first } catch { /* not a URL */ }
      return host ? `Open ${host}?` : 'Open a web page?'
    }
    default: return first ? `Allow ${name} ${first}?` : `Allow ${name}?`
  }
}

/** Several picks allowed: the model asked for them (`multi`), or the person flipped the card. */
export function wide(multi: boolean, picking: boolean): boolean {
  return multi || picking
}

/** What a click on one option does. The Mac's twin is `AskClick.click` in AskViews.swift. */
export type AskClick = { kind: 'answer'; choices: string[] } | { kind: 'toggle'; picking: boolean }

/**
 * A click on an option, as a person experiences it: a plain click on a single-choice question
 * answers at once (nothing is ambiguous yet), but anything else puts the card into
 * pick-and-confirm, where the arity is theirs. A half-typed answer counts as something else:
 * answering would throw it away, and an answer that drops what they typed isn't the answer
 * they gave.
 */
export function clickOption(v: { multi: boolean; picking: boolean; drafting: boolean }, label: string): AskClick {
  if (wide(v.multi, v.picking)) return { kind: 'toggle', picking: v.picking }
  if (v.drafting) return { kind: 'toggle', picking: true }
  return { kind: 'answer', choices: [label] }
}

