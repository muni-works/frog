/** A link target from outside the page (an MCP server, the sandbox, the edge) as a parsed
 *  http(s) URL, or undefined. Never a `javascript:` or `data:` URL: clicking one would run
 *  on frog.toys with the account key in reach. */
export function safeHref(raw: string | undefined): URL | undefined {
  if (!raw) return undefined
  try {
    const url = new URL(raw)
    return url.protocol === 'https:' || url.protocol === 'http:' ? url : undefined
  } catch {
    return undefined
  }
}
