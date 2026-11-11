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
