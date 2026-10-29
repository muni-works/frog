// A TypeScript slice of crates/frog-engine/src/protocol.rs: only what the web app reads today.
// Field names and serde tags match the Rust side, so real JSONL from a Frog Cloud
// sandbox deserializes into these types unchanged.

export type Decision = 'allow' | 'allow_always' | 'allow_prefix' | 'deny'

/** Client → engine (`Op`, tagged by `op`). */
export type Op =
  | { op: 'submit'; text: string }
  | { op: 'interrupt' }
  | { op: 'permission'; id: string; decision: Decision; note?: string }
  | { op: 'subscribe'; after: number }

export type LineKind = 'context' | 'add' | 'remove'
export interface DiffLine { kind: LineKind; old: number | null; new: number | null; text: string }
export interface FileDiff { path: string; created: boolean; added: number; removed: number; hunks: { lines: DiffLine[] }[] }

export type ToolOutcome = 'ok' | 'error' | 'denied' | 'skipped'

export type ItemKind =
  | { type: 'message' }
  | { type: 'reasoning' }
  | { type: 'tool_call'; name: string; arg: string }

export type Item =
  | { type: 'message'; text: string }
  | { type: 'reasoning'; text: string }
  | { type: 'tool_call'; name: string; arg: string; input: unknown; outcome: ToolOutcome; output: string; display: string | null; diff?: FileDiff }

export type Delta =
  | { type: 'text'; text: string }
  | { type: 'reasoning'; text: string }
  | { type: 'output'; text: string }

export type EndReason =
  | { type: 'complete' }
  | { type: 'denied' }
  | { type: 'cancelled' }
  | { type: 'error'; error: { type: string; message?: string } }

export interface TurnUsage { context_tokens: number | null; input_tokens: number; output_tokens: number; model_calls: number }

/** Engine → client (`Event`, tagged by `event`). */
export type Event =
  | { event: 'turn_started'; turn: number; input: string }
  | { event: 'turn_ended'; turn: number; reason: EndReason; usage: TurnUsage }
  | { event: 'item_started'; id: string; kind: ItemKind }
  | { event: 'item_delta'; id: string; delta: Delta }
  | { event: 'item_completed'; id: string; item: Item }
  | { event: 'permission_request'; id: string; item: string; name: string; arg: string; always: string; preview?: FileDiff; reason?: string }
  | { event: 'permission_resolved'; id: string; decision: Decision }
  | { event: 'titled'; title: string }
  | { event: 'idle' }

/** `Envelope`: every event, with a per-session monotonic `seq` starting at 1. */
export type Envelope = Event & { seq: number; session: string; created: number }
