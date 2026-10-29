// Sign-in for the web app: GitHub on api.frog.toys, PKCE code → a `frog_` device key.
//
//   signIn()          → api.frog.toys/auth/web?challenge&state&device&return (GitHub if signed out)
//   back on frog.toys → ?code&state; finishSignIn() POSTs /v1/auth/exchange {code, verifier, device_name}
//   → {key, account}; the key is this browser's bearer for the edge (/v1/me) and the gateway.
//
// The key is per browser ("frog.toys web · <4 chars>"), so it can be revoked on its own
// from api.frog.toys/account. Signing in again on the same browser replaces it.

export const API = (import.meta.env.VITE_API as string | undefined) ?? 'https://api.frog.toys'

/** The account shape every app gets from the edge (accounts-ux §5). */
export interface Account {
  plan: string
  /** The name they go by (GitHub's display name); null until they sign in again, or by email. */
  name?: string | null
  handle: string | null
  email: string | null
  /** Live credit in cents (may be fractional): Frog Cloud bills per token, at each model's
   * prices, against this. The edge still sends tasks_left (credit / $0.25), which no app shows. */
  credit_cents: number
  tasks_left: number
  tasks_limit: number | null
  resets_at: string | null
}

const KEY = 'frog.key'
const DEVICE = 'frog.device'
const PENDING = 'frog.signin'

const store = {
  get: (s: Storage, k: string) => { try { return s.getItem(k) } catch { return null } },
  set: (s: Storage, k: string, v: string) => { try { s.setItem(k, v) } catch { /* private mode: sign-in lasts this tab */ } },
  del: (s: Storage, k: string) => { try { s.removeItem(k) } catch { /* same */ } },
}

const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
const random = (n: number) => b64url(crypto.getRandomValues(new Uint8Array(n)))

function device(): string {
  let d = store.get(localStorage, DEVICE)
  if (!d) { d = `frog.toys web · ${random(3).slice(0, 4)}`; store.set(localStorage, DEVICE, d) }
  return d
}

export const savedKey = () => store.get(localStorage, KEY)

export class AuthError extends Error {
  constructor(readonly status: number, readonly code: string) { super(code) }
}

async function call<T>(path: string, init: RequestInit = {}, key?: string): Promise<T> {
  const res = await fetch(API + path, {
    ...init,
    headers: { ...(init.body ? { 'content-type': 'application/json' } : {}), ...(key ? { authorization: `Bearer ${key}` } : {}) },
  })
  const json = await res.json().catch(() => null)
  if (!res.ok) throw new AuthError(res.status, json?.error?.code ?? 'unavailable')
  return json as T
}

/** Leaves for GitHub. `after` (e.g. the message the user tried to send) survives the trip. */
export async function signIn(after?: string) {
  const verifier = random(32)
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)))
  const state = random(16)
  store.set(sessionStorage, PENDING, JSON.stringify({ verifier, state, after }))
  const q = new URLSearchParams({ challenge: b64url(digest), state, device: device(), return: location.origin + '/' })
  location.assign(`${API}/auth/web?${q}`)
}

/** On load: finishes a sign-in if the URL carries ?code&state. Returns what was pending. */
export async function finishSignIn(): Promise<{ key: string; account: Account; after?: string } | null> {
  const q = new URLSearchParams(location.search)
  const code = q.get('code'), state = q.get('state')
  if (!code || !state) return null
  history.replaceState(null, '', location.pathname) // the code is single-use; keep it out of history
  const pending = JSON.parse(store.get(sessionStorage, PENDING) ?? 'null') as { verifier: string; state: string; after?: string } | null
  store.del(sessionStorage, PENDING)
  if (!pending || pending.state !== state) throw new AuthError(400, 'state_mismatch')
  const r = await call<{ key: string; account: Account }>('/v1/auth/exchange', {
    method: 'POST', body: JSON.stringify({ code, verifier: pending.verifier, device_name: device() }),
  })
  store.set(localStorage, KEY, r.key)
  return { ...r, after: pending.after }
}

/** Credit top-ups, in dollars (the edge's CREDIT_TOP_UPS). */
export const TOP_UPS = [5, 10, 25, 50, 100]

/** Leaves for Stripe Checkout to add credit; it comes back here with ?session_id. */
export async function topUp(key: string, dollars: number) {
  const r = await call<{ url: string }>('/v1/billing/topup', { method: 'POST', body: JSON.stringify({ amount: dollars * 1e6, return: location.origin }) }, key)
  location.assign(r.url)
}

export async function me(key: string): Promise<Account> {
  return (await call<{ account: Account }>('/v1/me', {}, key)).account
}

export function signOut() {
  store.del(localStorage, KEY)
}

/** What to call someone: their first name, else their GitHub login, else their email. */
export function firstName(a: Account | null): string | null {
  return a?.name?.trim().split(/\s+/)[0] || a?.handle || a?.email || null
}
