// Mirrors crates/frog-engine/src/protocol.rs: only the parts the web client reads or sends.
// Receivers skip unknown variants and ignore unknown fields (wire contract §2).

export type Decision = "allow" | "allow_always" | "deny";

export type Op =
  | { op: "submit"; text: string }
  | { op: "interrupt" }
  | { op: "permission"; id: string; decision: Decision }
  | { op: "set_model"; spec: string }
  | { op: "set_mode"; mode: Mode };

/** protocol.rs `Mode` (kebab-case): when the engine asks before acting. */
export type Mode = "default" | "accept-edits" | "auto" | "yolo";

export type LineKind = "context" | "add" | "remove";
export interface DiffLine {
  kind: LineKind;
  old: number | null;
  new: number | null;
  text: string;
}
export interface FileDiff {
  path: string;
  created: boolean;
  added: number;
  removed: number;
  hunks: { lines: DiffLine[] }[];
}

export type ToolOutcome = "ok" | "error" | "denied" | "skipped";

export type ItemKind = { type: "message" } | { type: "reasoning" } | { type: "tool_call"; name: string; arg: string };

export type Item =
  | { type: "message"; text: string }
  | { type: "reasoning"; text: string }
  | {
      type: "tool_call";
      name: string;
      arg: string;
      outcome: ToolOutcome;
      output: string;
      display: string | null;
      diff?: FileDiff;
    };

export type Delta =
  | { type: "text"; text: string }
  | { type: "reasoning"; text: string }
  | { type: "output"; text: string }
  | { type: "image_preview" };

export type EndReason = { type: "complete" | "max_tokens" | "denied" | "looping" | "step_limit" | "cancelled" } | { type: "error"; error: unknown };

/** protocol.rs `TurnUsage`: what a turn's model calls took. */
export interface TurnUsage {
  context_tokens: number | null;
  input_tokens: number;
  output_tokens: number;
  /** The part of input read from the provider's cache, and the part written to it. */
  cached_tokens?: number;
  cache_write_tokens?: number;
  model_calls: number;
  tokens_per_sec?: number | null;
  /** The model spec the turn ran on, e.g. `cloud/qwen3-coder-next`. */
  model?: string | null;
  timing?: { wall_ms: number; prefill_ms: number; decode_ms: number; think_ms?: number; tool_ms: number } | null;
}

export type Event =
  | { event: "turn_started"; turn: number; input: string }
  | { event: "turn_ended"; turn: number; reason: EndReason; usage?: TurnUsage }
  | { event: "item_started"; id: string; kind: ItemKind }
  | { event: "item_completed"; id: string; item: Item }
  | { event: "item_delta"; id: string; delta: Delta }
  | { event: "permission_request"; id: string; item: string; name: string; arg: string; always: string; preview?: FileDiff; reason?: string }
  | { event: "permission_resolved"; id: string; decision: Decision }
  | { event: "titled"; title: string }
  | { event: "status"; model: string; mode: Mode; context_tokens: number | null; context_window: number }
  | { event: "progress"; label: string; completed?: number; total?: number }
  | { event: "notice"; level: "info" | "warn"; message: string }
  | { event: "model_changed"; model: string }
  | { event: "mode_changed"; mode: Mode }
  | { event: "error"; message?: string }
  | { event: "idle" };

export type Envelope = { seq: number; session: string; created: number } & Event;

// Contract §2 handshake frames.
export interface Hello {
  hello: { protocol: number; client: string; resume_after: number };
}
export interface Welcome {
  protocol: number;
  session: string;
  engine: string;
  last_seq: number;
}
export interface Refused {
  reason: string;
  min: number;
  max: number;
  upgrade: string;
}

// Contract §4.
export interface SessionSummary {
  id: string;
  title: string;
  repo: string;
  branch: string;
  state: string;
  updated: number;
  pr?: string;
}
export interface NewSession {
  /** Omit for a session without a repo (an empty git repo in the sandbox). */
  repo?: string;
  branch?: string;
  base?: string;
  model?: string;
}

/** GET /v1/repos: repos the Frog GitHub App can reach for this account, plus the user's public ones. */
export interface RepoList {
  repos: { name: string; private: boolean; pushed_at: string | null }[];
  /** The App's install page, to give Frog access to more repos. */
  install?: string;
}
