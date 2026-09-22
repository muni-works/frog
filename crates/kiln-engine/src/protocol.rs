//! The only interface between the engine and its clients (TUI, print mode, `--serve`, sub-agents).
//! Everything here is serializable so the same protocol works in-process and over JSONL.
//!
//! Shape, borrowed from codex-rs's app-server and opencode's V2 event audit:
//! - Every event travels in an [`Envelope`] with a per-session monotonic `seq`.
//! - Work is `Turn > Item`. Items go `ItemStarted → ItemDelta* → ItemCompleted`.
//! - Events are either durable facts (worth persisting and replaying) or ephemeral
//!   hints (deltas, spinners, status). See [`Event::is_durable`]. Deltas are never persisted.
//! - Turns always end with [`Event::TurnEnded`] carrying a typed [`EndReason`].

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
/// `Interrupt` and `Permission` take effect immediately. Everything else is queued
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
    Clear,
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
    ModelChanged {
        model: String,
    },
    ModeChanged {
        mode: Mode,
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
                | Self::ModelChanged { .. }
                | Self::ModeChanged { .. }
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
    },
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
    Text { text: String },
    Reasoning { text: String },
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
    pub output_tokens: u64,
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
