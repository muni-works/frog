// Mirrors crates/frog-engine/src/protocol.rs: only the parts the web client reads or sends.
// Receivers skip unknown variants and ignore unknown fields (wire contract §2).

export type Decision = "allow" | "allow_always" | "deny";

export type Op =
  /** `typed`: the person typed (or dictated) this text in the composer. Only typed text is their
   *  own words to the engine (a Customize ask, a note, "remember …"); the app's own prompts
   *  (git actions, chips, retries, replays) leave it out. */
  | { op: "submit"; text: string; images?: Image[]; more?: Part[]; typed?: boolean }
  | { op: "interrupt" }
  /** Op::Continue: run a turn on the (repaired) history with `note` as its message; the wall
   *  resumes a turn that stopped on credit with it (wall.ts resumeNote). */
  | { op: "continue"; note?: string }
  | { op: "compact"; focus?: string }
  | { op: "permission"; id: string; decision: Decision; note?: string; choice?: string }
  /** Undo a Customize change by its handle (docs/customize-events.md). */
  | { op: "undo"; undo: string }
  /** "Make it a rule" on a note Frog kept: the engine answers with its card. */
  | { op: "note_to_rule"; id: string; scope: string; where?: "home" }
  /** The app's current setting values, so the engine can quote them (docs/customize-events.md). */
  | { op: "settings"; values: Record<string, string | number | boolean> }
  | { op: "answer"; id: string; choices?: string[]; other?: string }
  | { op: "elicit"; id: string; action: "accept" | "decline" | "cancel"; content?: unknown }
  | { op: "set_title"; title: string }
  | { op: "set_client_caps"; panes?: boolean; ask?: boolean; sessions?: boolean; irc?: boolean; customize?: boolean; notes?: boolean }
  | { op: "pane_open"; kind: "terminal" | "preview"; cwd?: string; url?: string; cols?: number; rows?: number }
  | { op: "pane_input"; id: string; data: string }
  | { op: "pane_resize"; id: string; cols: number; rows: number }
  | { op: "pane_close"; id: string }
  /** Something the preview saw: a console line, a failed request, an error, a navigation. */
  | { op: "pane_report"; id: string; kind: ReportKind; level?: ReportLevel; message: string; url?: string; status?: number }
  /** The answer to a `pane_request`. */
  | { op: "pane_reply"; call: string; result: unknown; error?: string }
  /** The user picked an element in inspect mode and mentioned it in the composer. */
  | { op: "pane_mention"; id: string; mention: string; context?: string }
  | { op: "set_model"; spec: string }
  | { op: "set_mode"; mode: Mode };

/** protocol.rs `ReportKind` / `ReportLevel`: what a preview pane reports. */
export type ReportKind = "console" | "network" | "error" | "navigated" | "title";
export type ReportLevel = "info" | "warn" | "error";

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
  | {
      type: "reasoning";
      text: string;
      /** The thought lines the thinking row showed, in order, each with its paragraph's range in
       * `text` (UTF-16 indices). Absent in older logs and when nothing was ever shown. */
      thoughts?: ShownThought[];
      /** How long the reasoning streamed, in ms (first reasoning delta to the first answer text
       * or tool call). Absent in older logs: never derive it from the item's own times. */
      think_ms?: number;
    }
  | {
      type: "tool_call";
      name: string;
      arg: string;
      outcome: ToolOutcome;
      output: string;
      display: string | null;
      diff?: FileDiff;
      widget?: Widget;
      /** A test run the engine recognised in the output's summary line (cargo, pytest, go,
       * vitest, jest). Absent for anything else: the web never parses output for a count. */
      tests?: TestRun;
    };

/** A recognised test run (the engine's shape, commit 420a7ae2): "passed of total", and the failing
 * tests' names in output order. `total` = passed + failed; `failed_names` may be shorter than
 * `failed`, never longer, and is absent when empty. */
export interface TestRun { runner: string; passed: number; failed: number; total: number; failed_names?: string[] }

/** thought.rs `ShownThought`: a line the thinking row showed, its paragraph `[start, end)` in the
 * reasoning text, and when it showed (ms after the item's first reasoning). */
export interface ShownThought { text: string; start: number; end: number; ms: number }

/** pace.rs `Pace`: output tokens streamed in each `bucket_ms` from the turn's start. */
export interface Pace { bucket_ms: number; tokens: number[] }

/** widget.rs `Widget`: a Visualize result. `html` is the sandboxed document to load as is. */
export interface Widget { title: string; code: string; html: string }

export type Delta =
  | { type: "text"; text: string }
  /** `thought`: the thinking row's line, on the delta where it changes (at most every 1.2 s).
   * Absent on every other delta: keep the last one. Shown verbatim. */
  | { type: "reasoning"; text: string; thought?: string }
  | { type: "output"; text: string }
  | { type: "image_preview" };

export type EndReason =
  | { type: "complete" | "max_tokens" | "denied" | "looping" | "step_limit" | "cancelled" }
  | { type: "error"; error: unknown }
  /** protocol.rs `EndReason::BillingLimit`: the wallet is empty (`credit`), or a plan window
   *  (`5h`, `weekly`) refused and nothing admitted going on. */
  | { type: "billing_limit"; window: string; reason?: string; balance_micro?: number };

/** protocol.rs `Image`: base64 data with its mime type. */
export interface Image { mime: string; data: string }
/** One message of several sent as one turn (Op::Submit's `more`); `typed` is this part's own. */
export interface Part { text: string; images?: Image[]; typed?: boolean }

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
  /** The model spec the turn ran on, e.g. `cloud/glm-5.3-flash`. */
  model?: string | null;
  timing?: { wall_ms: number; prefill_ms: number; decode_ms: number; think_ms?: number; tool_ms: number } | null;
  /** Who served a Frog Cloud turn: `frog` (its own GPUs) or a third party. Absent when unknown. */
  served_by?: ServedBy | null;
  /** Output tokens over the turn in buckets, for the turn line's curve. Absent: no pace data. */
  pace?: Pace | null;
}

/** protocol.rs `ServedBy`. */
export interface ServedBy {
  id: string;
  name: string;
  third_party?: boolean;
}


export type Event =
  | { event: "turn_started"; turn: number; input: string; images?: Image[]; more?: Part[] }
  | { event: "turn_ended"; turn: number; reason: EndReason; usage?: TurnUsage }
  | { event: "item_started"; id: string; kind: ItemKind }
  | { event: "item_completed"; id: string; item: Item }
  | { event: "item_delta"; id: string; delta: Delta }
  /** A finished tool call's one-line gist, from the engine's side-model. Durable. */
  | { event: "item_gisted"; item: string; gist: string }
  | { event: "permission_request"; id: string; item: string; name: string; arg: string; always: string; preview?: FileDiff; reason?: string; proposal?: Proposal }
  /** A Customize change made (at once, or after its card). Durable. */
  | { event: "customize_applied"; item: string; undo: string; card: Proposal }
  | { event: "customize_undone"; undo: string; ok: boolean; message?: string }
  /** A setting the app owns, changed by Customize (or its undo). Live only. */
  | { event: "setting_change"; id: string; value: string | number | boolean }
  /** Frog kept a note on its own (docs/customize-events.md, "Noted"). Durable. */
  | { event: "noted"; item: string; turn: number; id: string; text: string; scope: "project" | "everywhere"; place: string; source: "said" | "correction" | "read"; from?: string; undo: string }
  /** Notes that came back for a turn ("Used notes"). Durable. */
  | { event: "used_notes"; turn: number; tokens: number; notes: { id: string; scope: string; text: string }[] }
  /** `item` and `asked` (unix ms) place the wait on the turn's timeline; absent in older logs. */
  | { event: "permission_resolved"; id: string; decision: Decision; item?: string; asked?: number }
  | { event: "titled"; title: string }
  | { event: "compacted"; tokens_before: number; tokens_after: number }
  | { event: "compaction_failed"; detail?: string }
  | { event: "context_pruned"; results: number; tokens_before: number; tokens_after: number }
  | { event: "next_suggested"; turn: number; text: string; act?: boolean }
  | { event: "status"; model: string; mode: Mode; context_tokens: number | null; context_window: number; todos?: Todo[]; vision?: boolean; tokens_per_sec?: number | null }
  | { event: "question"; id: string; item: string; question: string; options: { label: string; detail?: string }[]; multi?: boolean; allow_other?: boolean }
  | { event: "question_resolved"; id: string; choices?: string[]; other?: string; item?: string; asked?: number }
  | { event: "elicitation"; id: string; server: string; message: string; schema?: ElicitSchema; url?: string }
  | { event: "elicitation_done"; id: string }
  | { event: "pane_opened"; id: string; kind: "terminal" | "preview"; title: string; cwd?: string; url?: string }
  | { event: "pane_closed"; id: string; exit?: number }
  /** The engine asking a preview pane to do something; answered with `pane_reply` within 20s. Live. */
  | { event: "pane_request"; call: string; id: string; action: string; args?: Record<string, unknown> }
  /** A preview error the engine queued for the model. Live. */
  | { event: "pane_notice"; id: string; level: ReportLevel; message: string }
  | { event: "pane_screen"; id: string; cols: number; rows: number; lines: string[]; cursor: [number, number]; screen_seq: number }
  | { event: "progress"; label: string; completed?: number; total?: number }
  | { event: "notice"; level: "info" | "warn"; message: string }
  | { event: "model_changed"; model: string }
  | { event: "mode_changed"; mode: Mode }
  | { event: "error"; message?: string }
  | { event: "idle" }
  /** A retried call's partial items, dropped (the timeline leaves them out). */
  | { event: "items_discarded"; ids: string[] }
  /** The turn's output tokens so far, for the stats line (live only, at most 4 a second).
   * `so_far`: part of it is counted from streamed pieces, so never show it as exact. `slow` (#426,
   * only on so_far counts): the call is slow; say so, never compute it. `cached` (#426, only when a
   * call ends): input tokens read from cache this turn so far. */
  | { event: "output_tokens"; turn: number; output: number; so_far?: boolean; slow?: boolean; cached?: number };

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
  /** The session that started this one (StartSession in a cloud sandbox): the list nests it
   *  under its parent. Older gateways leave it out, and the list stays flat. */
  parent?: string;
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

/** A Customize change, as its card asks it or its receipt reports it (docs/customize-events.md). */
export interface Proposal {
  kind: "line" | "skill" | "tool" | "setting"
  title: string
  change: { old?: string; new?: string }
  where: string
  path?: string
  tokens_per_turn?: number
  /** The primary action's id, always "primary": an allow sends it back as `choice`. */
  choice?: string
  primary: string
  dismiss: string
  alternative?: { id: string; label: string; where: string; tokens_per_turn?: number }
  asked_by?: { who: "user" | "frog"; words: string }
}
