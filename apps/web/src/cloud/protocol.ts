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

export type Event =
  | { event: "turn_started"; turn: number; input: string }
  | { event: "turn_ended"; turn: number; reason: EndReason }
  | { event: "item_started"; id: string; kind: ItemKind }
  | { event: "item_completed"; id: string; item: Item }
  | { event: "item_delta"; id: string; delta: Delta }
  | { event: "permission_request"; id: string; item: string; name: string; arg: string; always: string; preview?: FileDiff; reason?: string }
  | { event: "permission_resolved"; id: string; decision: Decision }
  | { event: "titled"; title: string }
  | { event: "status"; model: string; mode: Mode; context_tokens: number | null; context_window: number }
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
  repo: string;
  branch?: string;
  base?: string;
  model?: string;
}
