// Mirrors crates/frog-engine/src/protocol.rs: only the parts the web client reads or sends.
// Receivers skip unknown variants and ignore unknown fields (wire contract §2).

export type Decision = "allow" | "allow_always" | "deny";

export type Op =
  | { op: "submit"; text: string; images?: Image[]; more?: Part[] }
  | { op: "interrupt" }
  | { op: "compact"; focus?: string }
  | { op: "permission"; id: string; decision: Decision }
  | { op: "answer"; id: string; choices?: string[]; other?: string }
  | { op: "elicit"; id: string; action: "accept" | "decline" | "cancel"; content?: unknown }
  | { op: "set_title"; title: string }
  | { op: "set_client_caps"; panes?: boolean; ask?: boolean; sessions?: boolean; irc?: boolean }
  | { op: "pane_open"; kind: "terminal" | "preview"; cwd?: string; url?: string; cols?: number; rows?: number }
  | { op: "pane_input"; id: string; data: string }
  | { op: "pane_resize"; id: string; cols: number; rows: number }
  | { op: "pane_close"; id: string }
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

/** protocol.rs `Image`: base64 data with its mime type. */
export interface Image { mime: string; data: string }
/** One message of several sent as one turn (Op::Submit's `more`). */
export interface Part { text: string; images?: Image[] }

/** The TodoWrite list (tools/todo.rs); status is pending, in_progress or completed. */
export interface Todo { content: string; status: string }

/** An MCP elicitation's requested shape: a flat JSON Schema object (MCP spec). */
export interface ElicitSchema {
  type?: "object";
  properties?: Record<string, { type?: string; title?: string; description?: string; enum?: string[]; enumNames?: string[]; default?: unknown }>;
  required?: string[];
}

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
  /** Who served a Frog Cloud turn: `frog` (its own GPUs) or a third party. Absent when unknown. */
  served_by?: ServedBy | null;
}

/** protocol.rs `ServedBy`. */
export interface ServedBy {
  id: string;
  name: string;
  third_party?: boolean;
}

/** Blue on Frog Cloud's own GPUs, green for a third party (the `served-*` classes). */
export function servedClass(s: ServedBy | null | undefined): string {
  if (!s) return '';
  return (s.third_party ?? s.id !== 'frog') ? 'served-third' : 'served-frog';
}

export type Event =
  | { event: "turn_started"; turn: number; input: string; images?: Image[]; more?: Part[] }
  | { event: "turn_ended"; turn: number; reason: EndReason; usage?: TurnUsage }
  | { event: "item_started"; id: string; kind: ItemKind }
  | { event: "item_completed"; id: string; item: Item }
  | { event: "item_delta"; id: string; delta: Delta }
  | { event: "permission_request"; id: string; item: string; name: string; arg: string; always: string; preview?: FileDiff; reason?: string }
  | { event: "permission_resolved"; id: string; decision: Decision }
  | { event: "titled"; title: string }
  | { event: "compacted"; tokens_before: number; tokens_after: number }
  | { event: "compaction_failed"; detail?: string }
  | { event: "context_pruned"; results: number; tokens_before: number; tokens_after: number }
  | { event: "next_suggested"; turn: number; text: string; act?: boolean }
  | { event: "status"; model: string; mode: Mode; context_tokens: number | null; context_window: number; todos?: Todo[]; vision?: boolean }
  | { event: "question"; id: string; item: string; question: string; options: { label: string; detail?: string }[]; multi?: boolean; allow_other?: boolean }
  | { event: "question_resolved"; id: string; choices?: string[]; other?: string }
  | { event: "elicitation"; id: string; server: string; message: string; schema?: ElicitSchema; url?: string }
  | { event: "elicitation_done"; id: string }
  | { event: "pane_opened"; id: string; kind: "terminal" | "preview"; title: string; cwd?: string; url?: string }
  | { event: "pane_closed"; id: string; exit?: number }
  | { event: "pane_screen"; id: string; cols: number; rows: number; lines: string[]; cursor: [number, number]; screen_seq: number }
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
  /** When it was made; older gateways leave it out. */
  created?: number;
  updated: number;
  /** When a turn last ended; unlike `updated`, sleep and wake don't move it. */
  last_turn?: number;
  pr?: string;
  /** Put away (PATCH archived); listed under Archived. */
  archived?: boolean;
  /** With state "error": why the sandbox couldn't start, in words a person can act on. */
  error?: string;
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
