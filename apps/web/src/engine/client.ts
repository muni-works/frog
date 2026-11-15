import type { Envelope, Op } from '../cloud/protocol'

/**
 * The one seam between the UI and an engine: today a Frog Cloud sandbox through the
 * gateway (`CloudEngine`). Anything that streams protocol envelopes can stand in.
 */
export interface EngineClient {
  /** Deliver every envelope for `session` with `seq > after`, then live ones. Returns unsubscribe. */
  /** `onReset`: the stream restarted from the beginning, so drop what was folded from it. */
  subscribe(session: string, after: number, onEnvelope: (e: Envelope) => void, onReset?: () => void): () => void
  send(session: string, op: Op): void
}
