//! The only interface between the engine and its clients (TUI, print mode, `--serve`, sub-agents).
//! Everything here is serializable so the same protocol works in-process and over JSONL.
//!
//! Shape, borrowed from codex-rs's app-server and opencode's V2 event audit:
//! - Every event travels in an [`Envelope`] with a per-session monotonic `seq`.
//! - Work is `Turn > Item`. Items go `ItemStarted → ItemDelta* → ItemCompleted`.
//! - Events are either durable facts (worth persisting and replaying) or ephemeral
//!   hints (deltas, spinners, status). See [`Event::is_durable`]. Deltas are never persisted.
//! - Turns always end with [`Event::TurnEnded`] carrying a typed [`EndReason`].

use crate::config::ToolMode;
use crate::harness::Tier;
use crate::tools::todo::Todo;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Mode {
    /// Ask before edits and shell commands.
    Default,
    /// Edits run freely; shell commands still ask.
    AcceptEdits,
    /// Never ask.
    Yolo,
}

impl Mode {
    pub fn next(self) -> Self {
        match self {
            Self::Default => Self::AcceptEdits,
            Self::AcceptEdits => Self::Yolo,
            Self::Yolo => Self::Default,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::AcceptEdits => "accept edits",
            Self::Yolo => "yolo",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    Allow,
    /// Allow this and similar calls for the rest of the session.
    AllowAlways,
    Deny,
}

/// Client → engine.
///
/// `Interrupt`, `Permission`, `Elicit`, `AppCall` and `StopSubagent` take effect immediately. Everything else is queued
/// and handled in order; each queued op ends with [`Event::Idle`].
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    Submit {
        text: String,
    },
    /// Run a shell command directly; its output is attached to the next message.
    Shell {
        command: String,
    },
    Interrupt,
    Permission {
        id: String,
        decision: Decision,
    },
    SetMode {
        mode: Mode,
    },
    /// Profile name or `provider/model`.
    SetModel {
        spec: String,
    },
    Compact {
        focus: Option<String>,
    },
    /// Replay this session's durable events with `seq > after`, then [`Event::Synced`].
    /// Replayed envelopes keep their original `seq`, so gaps (where ephemeral events were) are expected.
    Subscribe {
        after: u64,
    },
    Clear,
    /// Name the session (clients may generate this, e.g. with an on-device model).
    SetTitle {
        title: String,
    },
    /// Answer an [`Event::Elicitation`]. `action` is `accept`, `decline` or `cancel`;
    /// `content` holds the form's values when accepting.
    Elicit {
        id: String,
        action: String,
        #[serde(default)]
        content: Option<serde_json::Value>,
    },
    /// Stop a running subagent (`id` is its `Task` tool call). The parent keeps going with
    /// whatever the subagent found so far.
    StopSubagent {
        id: String,
    },
    /// An MCP App calling a tool on its own server. Answered with [`Event::AppResult`].
    AppCall {
        id: String,
        server: String,
        tool: String,
        #[serde(default)]
        arguments: serde_json::Value,
    },
    Shutdown,
}

/// Wrapper for every event.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Envelope {
    /// Monotonic within a session; starts at 1.
    pub seq: u64,
    pub session: String,
    /// Unix milliseconds.
    pub created: i64,
    #[serde(flatten)]
    pub event: Event,
}

/// Engine → client.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    // ---- durable ----
    TurnStarted {
        turn: u64,
        input: String,
    },
    TurnEnded {
        turn: u64,
        reason: EndReason,
        usage: TurnUsage,
    },
    ItemStarted {
        id: String,
        kind: ItemKind,
    },
    ItemCompleted {
        id: String,
        item: Item,
    },
    PermissionResolved {
        id: String,
        decision: Decision,
    },
    Compacted {
        tokens_before: u64,
        tokens_after: u64,
    },
    /// Old tool output was trimmed (no LLM call) to stay inside the window.
    ContextPruned {
        results: usize,
        tokens_before: u64,
        tokens_after: u64,
    },
    ModelChanged {
        model: String,
    },
    ModeChanged {
        mode: Mode,
    },
    Titled {
        title: String,
    },

    // ---- ephemeral ----
    ItemDelta {
        id: String,
        delta: Delta,
    },
    /// Reply with [`Op::Permission`] using the same id. `item` is the tool call it gates.
    PermissionRequest {
        id: String,
        item: String,
        name: String,
        arg: String,
        always: String,
        /// For Edit/Write: exactly what would change, computed without touching the file.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        preview: Option<FileDiff>,
    },
    /// An MCP server asks the user for input mid-call: a form (`schema`, a flat JSON Schema
    /// object) or a URL to open. Reply with [`Op::Elicit`].
    Elicitation {
        id: String,
        server: String,
        message: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        schema: Option<serde_json::Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        url: Option<String>,
    },
    /// The elicitation was answered (by any client) or abandoned.
    ElicitationDone {
        id: String,
    },
    /// An event from the subagent running as tool call `item`: its own items, deltas and
    /// status, for a live view. Only its report is kept (as the tool call's output).
    Subagent {
        item: String,
        inner: Box<Event>,
    },
    /// Progress reported by a running MCP tool.
    ToolProgress {
        id: String,
        progress: f64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        total: Option<f64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    /// Reply to [`Op::AppCall`]: the `CallToolResult` JSON, or an error.
    AppResult {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        result: Option<serde_json::Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// Something is in flight with nothing to show yet (a model request, a tool call's
    /// arguments streaming). Clients typically show a spinner.
    Progress {
        label: String,
    },
    Notice {
        level: Level,
        message: String,
    },
    /// A queued op other than `Submit` failed. Turn failures arrive as `TurnEnded` instead.
    Error {
        error: EngineError,
    },
    Status(Status),
    /// Replay after [`Op::Subscribe`] is done; live events follow. `seq` is the latest so far.
    Synced {
        upto: u64,
    },
    /// The engine finished the queued op and is waiting.
    Idle,
}

impl Event {
    /// Durable events are facts worth persisting and replaying. Everything else is a
    /// live-only hint that a late subscriber can do without.
    pub fn is_durable(&self) -> bool {
        matches!(
            self,
            Self::TurnStarted { .. }
                | Self::TurnEnded { .. }
                | Self::ItemStarted { .. }
                | Self::ItemCompleted { .. }
                | Self::PermissionResolved { .. }
                | Self::Compacted { .. }
                | Self::ContextPruned { .. }
                | Self::ModelChanged { .. }
                | Self::ModeChanged { .. }
                | Self::Titled { .. }
        )
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ItemKind {
    Message,
    Reasoning,
    ToolCall { name: String, arg: String },
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
// Serialized data, built once per item; boxing the big variant buys nothing.
#[allow(clippy::large_enum_variant)]
pub enum Item {
    Message {
        text: String,
    },
    Reasoning {
        text: String,
    },
    ToolCall {
        name: String,
        arg: String,
        input: serde_json::Value,
        outcome: ToolOutcome,
        /// What the model sees.
        output: String,
        /// What a human should see, if different (diffs, summaries).
        display: Option<String>,
        /// Set for Write/Edit.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        diff: Option<FileDiff>,
        /// Set for Diagram: validated and laid out, ready to draw.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        diagram: Option<Box<crate::diagram::Diagram>>,
        /// Images the tool returned (MCP servers), shown to the user.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<Image>,
        /// An MCP App: the server's own UI for this result, for clients that can host it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app: Option<Box<AppView>>,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Image {
    pub mime: String,
    /// Base64.
    pub data: String,
}

/// An MCP App (`ui://` resource) to render for a tool result. The HTML and the raw
/// `CallToolResult` can be large, so they live in files under the kiln data dir.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AppView {
    pub server: String,
    /// The tool's name on the server.
    pub tool: String,
    pub uri: String,
    /// Path to the app's HTML.
    pub html: String,
    /// Path to the tool's `CallToolResult` as JSON.
    pub result: String,
}

/// A file change as data, so clients can draw it however they like.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FileDiff {
    pub path: String,
    /// The file didn't exist before.
    pub created: bool,
    pub added: u32,
    pub removed: u32,
    pub hunks: Vec<Hunk>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Hunk {
    pub lines: Vec<DiffLine>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct DiffLine {
    pub kind: LineKind,
    /// 1-based line numbers in the old and new file.
    pub old: Option<u32>,
    pub new: Option<u32>,
    pub text: String,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LineKind {
    Context,
    Add,
    Remove,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ToolOutcome {
    Ok,
    Error,
    Denied,
    /// Not run because an earlier call in the same batch was denied.
    Skipped,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Delta {
    Text {
        text: String,
    },
    Reasoning {
        text: String,
    },
    /// Live output from a running tool (e.g. a shell command). May contain ANSI colors.
    Output {
        text: String,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EndReason {
    /// The model finished its answer.
    Complete,
    /// The model hit its output token limit.
    MaxTokens,
    /// The user denied a tool call; the engine stopped to wait for instructions.
    Denied,
    /// The model kept repeating an identical tool call.
    Looping,
    /// The turn hit the per-turn step limit.
    StepLimit,
    Cancelled,
    Error {
        error: EngineError,
    },
}

/// Closed set of failures a client can react to.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EngineError {
    /// The provider answered with an error status.
    Provider {
        status: u16,
        message: String,
    },
    /// Couldn't reach the provider.
    Connection {
        message: String,
    },
    /// The response stream ended before the provider said it was done.
    IncompleteStream,
    /// Bad model spec, missing API key, unreadable session.
    Config {
        message: String,
    },
    Internal {
        message: String,
    },
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Self::Provider { status, message } => write!(f, "provider error ({status}): {message}"),
            Self::Connection { message } => write!(f, "connection failed: {message}"),
            Self::IncompleteStream => write!(f, "the response stream ended early"),
            Self::Config { message } | Self::Internal { message } => write!(f, "{message}"),
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Level {
    Info,
    Warn,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct TurnUsage {
    /// Tokens in the context window after the last model call. `None` if the provider didn't say.
    pub context_tokens: Option<u64>,
    /// Totals across every model call in the turn (including compaction).
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub model_calls: u32,
    /// Generation speed of the last call.
    pub tokens_per_sec: Option<f64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Status {
    pub model: String,
    pub mode: Mode,
    pub cwd: PathBuf,
    pub messages: usize,
    pub context_tokens: Option<u64>,
    pub context_window: u64,
    pub tool_mode: ToolMode,
    pub tier: Tier,
    pub tokens_per_sec: Option<f64>,
    pub todos: Vec<Todo>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_round_trips_flat() {
        let env = Envelope {
            seq: 3,
            session: "s".into(),
            created: 1,
            event: Event::ItemDelta {
                id: "i".into(),
                delta: Delta::Text { text: "hi".into() },
            },
        };
        let json = serde_json::to_string(&env).unwrap();
        assert_eq!(
            json,
            r#"{"seq":3,"session":"s","created":1,"event":"item_delta","id":"i","delta":{"type":"text","text":"hi"}}"#
        );
        let back: Envelope = serde_json::from_str(&json).unwrap();
        assert_eq!(back.seq, 3);
        assert!(matches!(back.event, Event::ItemDelta { .. }));
        assert!(!back.event.is_durable());
    }
}
