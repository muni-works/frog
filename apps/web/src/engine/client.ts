import type { Envelope, Op } from './protocol'

/**
 * The one seam between the UI and an engine. Today it's `MockEngine`; later it's a
 * websocket to the session's Frog Cloud sandbox speaking the same JSONL protocol.
 */
export interface EngineClient {
  /** Deliver every envelope for `session` with `seq > after`, then live ones. Returns unsubscribe. */
  subscribe(session: string, after: number, onEnvelope: (e: Envelope) => void): () => void
  send(session: string, op: Op): void
}
