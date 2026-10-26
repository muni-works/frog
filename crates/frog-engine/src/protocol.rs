//! The only interface between the engine and its clients (TUI, print mode, `--serve`, sub-agents).
//! Everything here is serializable so the same protocol works in-process and over JSONL.
//!
//! Shape, borrowed from codex-rs's app-server and opencode's V2 event audit:
//! - Every event travels in an [`Envelope`] with a per-session monotonic `seq`.
//! - Work is `Turn > Item`. Items go `ItemStarted → ItemDelta* → ItemCompleted`.
//! - Events are either durable facts (worth persisting and replaying) or ephemeral
//!   hints (deltas, spinners, status). See [`Event::is_durable`]. Text deltas are never persisted; bounded image previews are replayable.
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
    /// A local classifier approves the steps that plainly serve the request; the rest ask.
    Auto,
    /// Never ask.
    Yolo,
}

impl Mode {
    pub fn next(self) -> Self {
        match self {
            Self::Default => Self::AcceptEdits,
            Self::AcceptEdits => Self::Auto,
            Self::Auto => Self::Yolo,
            Self::Yolo => Self::Default,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::AcceptEdits => "accept edits",
            Self::Auto => "auto",
            Self::Yolo => "yolo",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    Allow,
    /// Allow this and similar calls for the rest of the session. For shell
    /// commands it means the same as `AllowPrefix`: no blanket allow of a program.
    AllowAlways,
    /// Allow this program on paths under the card's `prefix` for the rest of the
    /// session (falls back to allowing once when the card has no prefix).
    AllowPrefix,
    Deny,
}

/// What a permission prompt shows so the user can decide quickly: why the agent
/// wants it, what triggered the prompt, what it touches, and frog's advice.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct ApprovalCard {
    /// What the agent said it was doing, from its message before the call.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_reason: Option<String>,
    /// The rule or verdict that made it ask.
    pub trigger: String,
    /// Paths the command names, with sizes and whether this session created them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub touches: Vec<Touch>,
    /// One line on what could go wrong.
    pub risk: String,
    /// `allow` or `deny`, and why.
    pub recommendation: String,
    /// The path prefix `AllowPrefix` would cover.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prefix: Option<String>,
    /// Seconds until frog stops waiting and takes the safe path (deny).
    pub timeout_secs: u64,
}

/// One path a command touches.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Touch {
    pub path: String,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub exists: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub dir: bool,
    /// Total bytes (a directory's, counted up to a cap).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bytes: Option<u64>,
    /// This session made it (wrote the file or created the directory).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub created_here: bool,
}

/// What [`Op::Continue`] tells the model when the client gives no note of its own.
pub const CONTINUE_NOTE: &str =
    "<resumed after the app restarted; your previous turn was interrupted; continue>";

/// What [`Op::Continue`] tells the model when an app update's [`Op::Drain`] suspended the turn
/// and the relaunched app picks it back up. Its own note, not [`CONTINUE_NOTE`]: the model
/// knows it wasn't its fault or the user's.
pub const SUSPENDED_NOTE: &str =
    "<resumed after the app updated; your previous turn was suspended; continue>";

/// Client → engine.
///
/// `Interrupt`, `ClearInbox`, `Permission`, `Answer`, `Elicit`, `AppCall`, `Drain`,
/// `DrainAbort` and `StopSubagent` take effect immediately. Everything else is queued
/// and handled in order; each queued op ends with [`Event::Idle`].
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Op {
    Submit {
        text: String,
        /// Images attached to the message.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<Image>,
        /// More messages sent with this one, in order (follow-ups queued while a turn ran).
        /// They run as the same turn, each its own block of the user's message.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        more: Vec<Part>,
    },
    /// The user pressed a button in a `Present` actions block. Runs a turn like [`Op::Submit`]
    /// with `send` (or `label` when `send` is empty) as the message.
    Act {
        label: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        send: String,
    },
    /// Pick the conversation back up after the app restarted mid-turn: runs a turn on the
    /// (repaired) history with `note`, or [`CONTINUE_NOTE`] when absent, as the message.
    Continue {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        note: Option<String>,
    },
    /// Run a shell command directly; its output is attached to the next message.
    Shell {
        command: String,
    },
    Interrupt,
    Permission {
        id: String,
        decision: Decision,
        /// With a deny: the user's words, sent back to the agent so it can adjust.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        note: Option<String>,
    },
    /// Answer an [`Event::Question`]. No choices and no `other` dismisses it.
    Answer {
        id: String,
        #[serde(flatten)]
        answer: Answer,
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
    /// The rescue for a session whose context overflowed and compaction failed (see
    /// [`Event::CompactionFailed`]): start a carried-forward session. The engine refuses when
    /// the client can't host sessions (it answers the request with an error instead, so the
    /// model is never told a rescue happened when none did). The client that knows how to
    /// carry forward owns the rest: the old session's structured summary as the new session's
    /// opening context, and `continued from <old id>` lineage.
    ContinueSession {
        /// The overflowed session's id, the one being carried forward from.
        #[serde(default, skip_serializing_if = "String::is_empty")]
        from: String,
        /// One line on the context of the rescue, folded into the new session's prompt.
        #[serde(default, skip_serializing_if = "String::is_empty")]
        why: String,
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
    /// Graceful stop for an app update: finish the current step, then stop at the next safe
    /// point (a finished model call, a finished tool call) and end the turn [`EndReason::Suspended`].
    /// Not a cancel — the turn is resumable via [`Op::Continue`]. `Drain` while idle is a no-op
    /// ack. Immediate, like [`Op::Interrupt`], but cooperative.
    Drain {
        /// Unix ms; after this the engine force-stops (cancels the running tool or call) and
        /// records itself suspended anyway.
        deadline: i64,
    },
    /// The drain was called off (the user cancelled the update). Engines already suspended stay
    /// that way (the next user message resumes them); a still-running turn keeps going.
    DrainAbort,
    /// Internal: background work finished and left a notice for the model. Starts a turn
    /// when the engine is idle; never sent by clients.
    #[serde(skip)]
    Wake,
    /// An MCP App calling a tool on its own server. Answered with [`Event::AppResult`].
    AppCall {
        id: String,
        server: String,
        tool: String,
        #[serde(default)]
        arguments: serde_json::Value,
    },
    /// Have the model server prefill this conversation now, so the next turn starts warm:
    /// when a client shows the conversation, and as the user types (`draft`, the composer's
    /// text so far, as the next message). Dropped mid-turn and on servers that can't prefill;
    /// emits nothing.
    Warm {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        draft: Option<String>,
    },
    /// What this client can do beyond the basics. Sent once after connecting; defaults to nothing.
    SetClientCaps {
        /// The client shows terminal panes and hosts preview panes (webviews it observes and
        /// drives for the engine).
        #[serde(default)]
        panes: bool,
        /// The client shows [`Event::Question`]s to a person who can answer them, so the model
        /// gets the `Ask` tool.
        #[serde(default)]
        ask: bool,
        /// The client hosts other sessions and answers [`Event::SessionRequest`]s, so the
        /// model gets `ListSessions`, `SendMessage` and `StartSession`.
        #[serde(default)]
        sessions: bool,
        /// The IRC agent bus is on (config `[irc] enabled`, a frog cloud Bus DO): the model
        /// gets the `Irc` tool, and the client relays the bus. Off by default until the DO
        /// deploys.
        #[serde(default)]
        irc: bool,
    },
    /// Open a pane. The engine mints the id and answers with [`Event::PaneOpened`]. Terminal
    /// panes are engine-owned shells; preview panes are the client's webviews.
    PaneOpen {
        kind: PaneKind,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        url: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cols: Option<u16>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        rows: Option<u16>,
    },
    /// Keystrokes for a terminal pane (UTF-8; control characters as-is).
    PaneInput {
        id: String,
        data: String,
    },
    PaneResize {
        id: String,
        cols: u16,
        rows: u16,
    },
    PaneClose {
        id: String,
    },
    /// Something a preview pane observed: a console message, a failed request, a navigation.
    /// Errors during a turn reach the model; everything is kept for `Preview.console`.
    PaneReport {
        id: String,
        kind: ReportKind,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        level: Option<ReportLevel>,
        message: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        url: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        status: Option<u16>,
    },
    /// The answer to an [`Event::PaneRequest`] with the same `call`.
    PaneReply {
        call: String,
        #[serde(default)]
        result: Option<serde_json::Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// The answer to an [`Event::SessionRequest`] with the same `id`: `result` (JSON or text
    /// for the model) or `error`.
    SessionReply {
        id: String,
        #[serde(default)]
        result: Option<serde_json::Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// A message from another session (`from` is its id, or `system`). Queued like `Submit`:
    /// it runs as a turn wrapped in `<session-message>` once the current op is done. It never
    /// interrupts a running turn; only `Interrupt` stops one. Several queued together run as
    /// one turn: the first as its input, the rest as [`Event::TurnStarted`]'s `more`.
    Deliver {
        from: String,
        #[serde(default)]
        from_name: String,
        message: String,
    },
    /// A message from another session that's pure status ("received", "going idle"): marked
    /// read without a reply turn. Queued like [`Op::Deliver`], but no turn starts and nothing
    /// wakes: it's logged ([`Event::MessageRead`]) and goes along with the next turn as context.
    Inform {
        from: String,
        #[serde(default)]
        from_name: String,
        message: String,
    },
    /// Drop every [`Op::Deliver`] sent so far that no turn has taken yet: the messages
    /// queued behind the running turn never run. Immediate, like `Interrupt`; a stop that
    /// should leave the session quiet sends both (`StopSession` with `clear_queue`,
    /// `ArchiveSession`), or the queued message starts the next turn. Messages sent after it
    /// queue as usual.
    ClearInbox,
    /// The pending strip's "Dismiss all": drop every background wake parked for the next turn
    /// and stop every pending timer and monitor (stale watches). Jobs and Tasks are real
    /// work and keep running. Immediate, like `Interrupt`; the running turn is untouched.
    DismissWakes,
    /// Re-file session `session` under `parent` in the client's sidebar — the nesting its
    /// rows derive from. `None` unparents (a top-level row again). Parentage is the client's
    /// (the engine never reads it), so the move travels as a `MoveSession` tool call: the
    /// engine emits [`Event::SessionRequest`] and the client that owns the sessions answers
    /// with [`Op::SessionReply`]. This op exists as the protocol shape of that move (the
    /// app-side enum mirrors it); sent by a client it's a no-op — the engine has no parentage
    /// to change. A mis-filed session stops being stuck.
    MoveSession {
        session: String,
        /// The new parent's id or name; `None` unparents.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        parent: Option<String>,
    },
    /// The user picked an element in a preview pane. `context` (tag, text, selector, source
    /// location) is inlined the next time `mention` (e.g. `@button.submit`) appears in a message.
    PaneMention {
        id: String,
        mention: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        context: Option<String>,
    },
    Shutdown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PaneKind {
    Terminal,
    Preview,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReportKind {
    Console,
    Network,
    Error,
    Navigated,
    Title,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReportLevel {
    Info,
    Warn,
    Error,
}

/// What the engine can ask a preview pane to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PaneAction {
    Read,
    Click,
    Type,
    Screenshot,
    Navigate,
    Eval,
    Console,
}

impl PaneAction {
    pub fn parse(s: &str) -> Option<Self> {
        serde_json::from_value(serde_json::Value::String(s.to_string())).ok()
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Click => "click",
            Self::Type => "type",
            Self::Screenshot => "screenshot",
            Self::Navigate => "navigate",
            Self::Eval => "eval",
            Self::Console => "console",
        }
    }
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
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<Image>,
        /// The messages sent along with `input` ([`Op::Submit`]'s `more`), in order.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        more: Vec<Part>,
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
    /// A one-line gist of a finished `Bash` tool call's command, written by a small
    /// side-model in one batched call per turn flush (see `gist`). Live only: a
    /// replaying client regenerates nothing, and shows the raw (elided) command.
    CommandGisted {
        /// The tool call's item id.
        item: String,
        /// The command it ran, for hashing on the client (cache).
        command: String,
        /// The gist, one line; empty never arrives (the event is only sent when there is one).
        gist: String,
    },
    /// A chapter's title, written by a small side-model when the next chapter opened (see
    /// `chapter`). The app derives chapters and a heuristic title itself; this one, when it
    /// arrives, wins. Durable, so a replaying client shows it too.
    ChapterTitled {
        /// The turn the chapter starts at.
        turn: u64,
        /// A few lowercase words; empty never arrives.
        title: String,
    },
    /// A retryable model call failed after its reply had started streaming; the client should
    /// drop these partial items (and their deltas) — the step is re-run from scratch. Durable,
    /// so a replaying client also sees the partials come and go.
    ItemsDiscarded {
        ids: Vec<String>,
    },
    PermissionResolved {
        id: String,
        decision: Decision,
    },
    /// The user answered (or dismissed) a [`Event::Question`].
    QuestionResolved {
        id: String,
        #[serde(flatten)]
        answer: Answer,
    },
    /// Auto mode's classifier let tool call `item` run without asking.
    AutoApproved {
        item: String,
        reason: String,
    },
    /// A sandboxed command tried to reach a host off the session's egress allow-list (see
    /// `egress`): blocked at connect time (`enforced`), or only recorded (`flag` mode). The
    /// exfil tripwire: shown as a notice row, logged to `egress.jsonl`, counted in the brief.
    EgressBlocked {
        host: String,
        /// 0 when the sandbox stopped the lookup itself (a client that ignored the proxy).
        #[serde(default)]
        port: u16,
        /// The tool call whose command tried it, when it was still running (a background
        /// job's later attempts have none).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        item: Option<String>,
        /// `Bash` or `Monitor`.
        tool: String,
        /// The start of the command.
        command: String,
        #[serde(default)]
        enforced: bool,
    },
    /// How one permission check was decided, for measuring the ask rate:
    /// which layer answered (rule, classifier, fallback, user) and how long it took.
    PermissionDecision {
        /// The tool call's item id.
        item: String,
        /// `rule` (built-in read-only or hard rule), `classifier` (the model's
        /// verdict), `sandbox`, `session` (an earlier allow-always), `fallback`
        /// (the classifier was down; a read-only fast path answered), or `ask`.
        layer: String,
        /// `allow` or `ask`.
        outcome: String,
        /// How the decision was reached, one line.
        reason: String,
        /// Milliseconds the deciding layer took.
        #[serde(default, skip_serializing_if = "is_zero")]
        ms: u64,
    },
    Compacted {
        tokens_before: u64,
        tokens_after: u64,
        /// What the compaction kept, as a receipt (the structured summary's fields: files
        /// with +/−, turns with their requests and outcomes, tests run and whether each
        /// passed). Absent in older logs and in engines with no session store, so the token
        /// counts stand alone.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        summary: Option<KeptSummary>,
    },
    /// Compaction failed and the history can't be shrunk to fit the window: the session is
    /// stuck until something changes. The rescue is [`Op::ContinueSession`] (a new session
    /// carried forward from this one); the raw provider payload stays in the engine log, not
    /// the transcript. Durable, so a replaying client also knows the session stalled.
    CompactionFailed {
        /// The provider's rejection, for the engine log.
        #[serde(default, skip_serializing_if = "String::is_empty")]
        detail: String,
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
    /// The conversation moved to another folder (`UseFolder`); tools now work there.
    FolderChanged {
        cwd: PathBuf,
    },
    /// A `Bash` call `cd`'d the shell somewhere else: where commands run now (a worktree,
    /// say). Logged so a reader of a dead session's log knows where it was working.
    ShellCwd {
        cwd: PathBuf,
    },
    ModeChanged {
        mode: Mode,
    },
    Titled {
        title: String,
    },
    PaneOpened {
        id: String,
        kind: PaneKind,
        title: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        url: Option<String>,
    },
    PaneClosed {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        exit: Option<i32>,
    },
    /// A preview pane's screenshot taken with turn `turn`'s checkpoint, so a client can show
    /// before/after. `path` is relative to the session's data dir (`panes/turn-3.png`).
    PaneCheckpoint {
        id: String,
        turn: u64,
        path: String,
    },

    // ---- ephemeral ----
    /// The engine stopped where [`Op::Drain`] asked: the turn ended [`EndReason::Suspended`] and
    /// its log is fsynced. The ack the update flow waits for. `jobs` lists the background jobs
    /// stopped for the update; `inbox` the messages delivered but never run, so the app re-sends
    /// them (as fresh deliveries) after the restart.
    Drained {
        steps_done: u32,
        /// Background job ids stopped by the drain (their `BackgroundDone` says
        /// `interrupted_by_update`).
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        jobs: Vec<String>,
        /// The ids and one-line labels of those jobs, so the resumed notice can name them.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        job_labels: Vec<(String, String)>,
        /// Delivered messages that never ran as a turn, as `(from, from_name, message)`:
        /// the app re-delivers them after the restart.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        inbox: Vec<(String, String, String)>,
    },
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
        /// Why this one asks when similar calls don't (e.g. a command leaving the sandbox).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
        /// Set when a subagent asks: its id (the `Task` call, or the background task id).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        subagent: Option<String>,
        /// For shell commands: the agent's reason, the trigger, what it touches and
        /// frog's advice. A client that can forward it may escalate to a parent session.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        card: Option<ApprovalCard>,
    },
    /// The model asks the user to choose (`Ask`). Reply with [`Op::Answer`] using the same id.
    /// `item` is the tool call waiting on it.
    Question {
        id: String,
        item: String,
        question: String,
        options: Vec<AskOption>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        multi: bool,
        /// The user may type their own answer instead.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        allow_other: bool,
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
    /// Background work started: a `Task` with `background`, a Bash `run_in_background` job,
    /// or a `Monitor`. `kind` is `task`, `job`, `monitor` or `timer`.
    BackgroundStarted {
        id: String,
        kind: String,
        label: String,
        /// A shell job's output file, for clients to link the job's row to its log.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        log: Option<String>,
    },
    /// Live output from background work (a subagent's step, a job's output, a monitor poll).
    BackgroundProgress {
        id: String,
        text: String,
    },
    /// Background work ended. `status` is `done`, `failed`, `stopped`, `matched` or
    /// `timeout`; `summary` is what the model was told.
    BackgroundDone {
        id: String,
        kind: String,
        status: String,
        summary: String,
    },
    /// How many background pieces (tasks, jobs, monitors, timers) are running now. Sent
    /// whenever one starts or ends, so a client knows an engine with no turn open still has
    /// work in flight and mustn't be let go. Live only: a new engine starts with none.
    Background {
        running: usize,
    },
    /// The background wakes waiting for the next turn boundary, in the order they came in
    /// (each as the model will get it: `<job-done …>`, `<monitor-done …>`, …). Sent whenever
    /// one is parked and when a turn takes them (then empty), so a client can show what will
    /// flush next. Live only.
    QueuedEvents {
        items: Vec<String>,
    },
    /// The wakes turn `turn` opened with, in order: delivered as one batch with its input
    /// (a message, a session message), ahead of it. A turn started on wakes alone carries
    /// them as its input instead.
    WakesDelivered {
        turn: u64,
        wakes: Vec<String>,
    },
    /// An informational message ([`Op::Inform`]) was read: recorded, no turn started. It goes
    /// along with the next turn as context.
    MessageRead {
        from: String,
        from_name: String,
        message: String,
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
    /// The blocks of a `Present` call that have finished streaming so far, validated. Each
    /// preview replaces the last; the tool call's own item supersedes them all.
    PresentPreview {
        present: Box<crate::present::Present>,
    },
    /// Something is in flight with nothing to show yet (a model request, a tool call's
    /// arguments streaming). Clients typically show a spinner.
    Progress {
        label: String,
        /// Completed setup steps, when this operation has a known length.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        completed: Option<u16>,
        /// Total setup steps, when this operation has a known length.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        total: Option<u16>,
    },
    Notice {
        level: Level,
        message: String,
    },
    /// A terminal pane's grid after processing output. Coalesced to at most ~30/s per pane.
    /// Plain text for now (no attributes).
    PaneScreen {
        id: String,
        cols: u16,
        rows: u16,
        lines: Vec<String>,
        /// `[row, col]`.
        cursor: [u16; 2],
        /// Per-pane update counter (the envelope's `seq` is the session's).
        screen_seq: u64,
    },
    /// The engine asks the client's preview pane to do something. Answer with [`Op::PaneReply`]
    /// using the same `call`; the engine gives up after 20s.
    PaneRequest {
        call: String,
        id: String,
        action: PaneAction,
        #[serde(default)]
        args: serde_json::Value,
    },
    /// A session tool call (`ListSessions`, `SendMessage`, `StartSession`) for the client to
    /// carry out. Reply with [`Op::SessionReply`] using the same `id`. `item` is the tool call.
    SessionRequest {
        id: String,
        item: String,
        tool: String,
        #[serde(default)]
        input: serde_json::Value,
    },
    /// Something a pane reported that the client should show inline (a console error
    /// surfaced during a turn).
    PaneNotice {
        id: String,
        level: ReportLevel,
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
            Self::ItemDelta {
                delta: Delta::ImagePreview { .. },
                ..
            } | Self::TurnStarted { .. }
                | Self::TurnEnded { .. }
                | Self::ItemStarted { .. }
                | Self::ItemCompleted { .. }
                | Self::ItemsDiscarded { .. }
                | Self::PermissionResolved { .. }
                | Self::QuestionResolved { .. }
                | Self::AutoApproved { .. }
                | Self::EgressBlocked { .. }
            | Self::PermissionDecision { .. }
                | Self::Compacted { .. }
            | Self::CompactionFailed { .. }
                | Self::ContextPruned { .. }
                | Self::ModelChanged { .. }
                | Self::FolderChanged { .. }
                | Self::ShellCwd { .. }
                | Self::ModeChanged { .. }
                | Self::Titled { .. }
                | Self::ChapterTitled { .. }
                | Self::PaneOpened { .. }
                | Self::PaneClosed { .. }
                | Self::PaneCheckpoint { .. }
                | Self::BackgroundStarted { .. }
                | Self::BackgroundDone { .. }
                | Self::WakesDelivered { .. }
                | Self::MessageRead { .. }
        ) || matches!(
            // A subagent's steps are worth keeping: without them a reopened session shows
            // only the Task's report. Text deltas stay live-only, as in the main transcript.
            self,
            Self::Subagent {
                inner,
                ..
            } if matches!(**inner, Event::ItemStarted { .. } | Event::ItemCompleted { .. })
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
        /// Set for Present: validated blocks, ready to draw.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        present: Option<Box<crate::present::Present>>,
        /// Images the tool returned (MCP servers), shown to the user.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<Image>,
        /// An MCP App: the server's own UI for this result, for clients that can host it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app: Option<Box<AppView>>,
    },
}

/// One choice offered by `Ask`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct AskOption {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// What the user picked for a question: the chosen labels, their own words, or (both empty)
/// nothing, because they dismissed it.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Answer {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub choices: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub other: Option<String>,
}

impl Answer {
    pub fn dismissed(&self) -> bool {
        self.choices.is_empty() && self.other.as_deref().is_none_or(|o| o.trim().is_empty())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Image {
    pub mime: String,
    /// Base64.
    pub data: String,
}

/// One message the user typed, when several go as one turn (see [`Op::Submit`]'s `more`).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Part {
    pub text: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<Image>,
}

/// An MCP App (`ui://` resource) to render for a tool result. The HTML and the raw
/// `CallToolResult` can be large, so they live in files under the frog data dir.
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
    /// Approximate image for display while generation runs; never model input.
    ImagePreview {
        image: Image,
        step: u64,
        of: u64,
        image_index: usize,
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
    /// The agent retried a call that was already denied this turn (or one denied twice this
    /// session). frog didn't ask again: the turn ends here with the denial, so whoever wakes
    /// the agent next sees why, and the agent routes around it instead of burning another
    /// approval window.
    BlockedOnApproval {
        denial: String,
    },
    /// The turn hit the per-turn step limit.
    StepLimit,
    /// An app update's [`Op::Drain`] stopped the turn at a safe point (or force-stopped it at
    /// the deadline). Never a cancel: the turn is resumable via [`Op::Continue`] and the
    /// relaunched app picks it up automatically.
    Suspended,
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

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct TurnUsage {
    /// Tokens in the context window after the last model call. `None` if the provider didn't say.
    pub context_tokens: Option<u64>,
    /// Totals across every model call in the turn (including compaction).
    pub input_tokens: u64,
    pub output_tokens: u64,
    /// The part of `input_tokens` read from the provider's cache, and the part written to it:
    /// priced at their own rates. Absent in older logs.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub cached_tokens: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub cache_write_tokens: u64,
    pub model_calls: u32,
    /// Generation speed of the last call.
    pub tokens_per_sec: Option<f64>,
    /// Where the turn's wall time went. Absent in logs from before it was recorded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timing: Option<TurnTiming>,
    /// The model (spec) that ran the turn, for pricing it. Absent in older logs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// What the turn cost in energy, when it was measured (`--energy`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub energy: Option<TurnEnergy>,
}

/// What a compaction kept, as a receipt ([`Event::Compacted`]'s `summary`): the structured
/// summary's fields, trimmed to what a banner's expander shows. Built from the session log
/// without a model call (see `summary::build`).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct KeptSummary {
    /// The session it summarizes (the one compacted).
    pub id: String,
    /// Files edited, with lines added and removed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub files: Vec<KeptFile>,
    /// Turns as one line each: what was asked, and how it ended.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub turns: Vec<KeptTurn>,
    /// How the last turn ended (`complete`, `cancelled`, …), for the banner's tail.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub outcome: String,
}

/// One file the compaction kept: its path and the lines added and removed.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct KeptFile {
    pub path: String,
    pub added: u32,
    pub removed: u32,
}

/// One turn the compaction kept: what was asked, which tools ran, the tests run and whether
/// each passed, and how the turn ended.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct KeptTurn {
    pub request: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tools: Vec<String>,
    /// Test commands run, and whether each passed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tests: Vec<KeptTest>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub outcome: String,
}

/// One test the compaction kept: the command and whether it passed.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct KeptTest {
    pub command: String,
    pub passed: bool,
}

/// A turn's energy in watt-hours: the whole Mac above its idle power just before, and for a
/// hosted model an estimate of its data center's share (see `energy::cloud`).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct TurnEnergy {
    pub local_wh: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_wh: Option<f64>,
    /// The Mac's power at rest that was subtracted, in watts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idle_w: Option<f64>,
    /// How `remote_wh` was estimated for this model, and where its numbers come from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_basis: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_source: Option<String>,
}

/// A turn's wall time split by what it was waiting on, in milliseconds. `other` is whatever
/// the rest don't cover (context fitting, MCP refresh, profiling, retries, the engine itself).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct TurnTiming {
    pub wall_ms: u64,
    /// Request sent → first streamed token, summed over the turn's model calls.
    pub prefill_ms: u64,
    /// First streamed token → response done.
    pub decode_ms: u64,
    /// The part of `decode_ms` spent streaming reasoning before any answer or tool call.
    #[serde(default)]
    pub think_ms: u64,
    /// Tools running (not counting permission prompts or the auto-mode classifier). A tool
    /// started early, while its call was still streaming, counts only the time the turn
    /// waited for it after the reply ended.
    pub tool_ms: u64,
    /// Tool time that overlapped other work (mostly decoding the reply that asked for it), so
    /// it isn't in `tool_ms` and the turn didn't wait for it.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub early_ms: u64,
    /// Waiting for the user to answer permission prompts.
    pub user_ms: u64,
    /// Auto mode's classifier deciding whether a tool call may run.
    pub classifier_ms: u64,
    /// Summarizing the conversation when the context filled up (its model call).
    pub compact_ms: u64,
    pub other_ms: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub calls: Vec<CallTiming>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tools: Vec<ToolTiming>,
}

/// One model request.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct CallTiming {
    /// Prompt tokens as the provider reported them (including cache reads).
    pub prompt_tokens: u64,
    /// The part of `prompt_tokens` the server had cached; the rest it prefilled.
    #[serde(default)]
    pub cached_tokens: u64,
    /// Whether this request only appended to the one before it in the conversation (a model
    /// call or a warm-up), so a server could answer all of that one from its cache. Absent for
    /// the first request an engine sends.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extends: Option<bool>,
    /// How much of this request (0–1, by its text) repeats the start of the one before: about
    /// the share of `prompt_tokens` a server's cache could cover.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reusable: Option<f64>,
    pub output_tokens: u64,
    pub ttft_ms: u64,
    pub decode_ms: u64,
    /// Reasoning streamed before the first answer text or tool call.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub think_ms: u64,
    /// Thinking was switched off for this call (see `thinking.rs`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub no_think: bool,
    /// The cap on reasoning tokens sent with this call, if any (see `thinking::budget`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub think_budget: Option<u32>,
    /// A compaction summary rather than a step of the turn.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub compact: bool,
}

/// One tool call that got as far as the permission check.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct ToolTiming {
    /// The tool call's item id.
    pub id: String,
    pub name: String,
    /// Running the tool; zero if it was denied. For a tool started early, only the part the
    /// turn waited for.
    pub ms: u64,
    /// Started while the reply that asked for it was still streaming.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub early: bool,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub user_ms: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub classifier_ms: u64,
}

fn is_zero(n: &u64) -> bool {
    *n == 0
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
    /// The model can see images.
    #[serde(default)]
    pub vision: bool,
    /// What's running degraded right now, each with its one-line why (empty when nothing is):
    /// the session header shows them, and SessionStatus reports them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub degraded: Vec<Degraded>,
}

/// One way a session runs degraded, for the header badge and SessionStatus.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Degraded {
    pub kind: DegradedKind,
    /// What's degraded, short and lowercase ("text tool calls").
    pub what: String,
    /// Why, in one line.
    pub why: String,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DegradedKind {
    /// Tool calls written as text (native tool calls off) though the profile didn't ask for it.
    TextTools,
    /// Running on another model than the one the session was started or set to.
    Model,
    /// Auto mode's classifier is down; a fallback model or the built-in rules decide.
    Classifier,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn submit_more_is_optional_both_ways() {
        // An older client's submit still parses, and one message serializes as it always did.
        let old = r#"{"op":"submit","text":"hi"}"#;
        let op: Op = serde_json::from_str(old).unwrap();
        assert!(matches!(&op, Op::Submit { more, .. } if more.is_empty()));
        assert_eq!(serde_json::to_string(&op).unwrap(), old);
        let op: Op = serde_json::from_str(
            r#"{"op":"submit","text":"a","more":[{"text":"b"},{"text":"c","images":[{"mime":"image/png","data":"AA"}]}]}"#,
        )
        .unwrap();
        let Op::Submit { more, .. } = op else {
            panic!("not a submit")
        };
        assert_eq!(
            more.iter().map(|p| p.text.as_str()).collect::<Vec<_>>(),
            ["b", "c"]
        );
        assert_eq!(more[1].images.len(), 1);
        // Logged turns from before parse too.
        let started: Event =
            serde_json::from_str(r#"{"event":"turn_started","turn":1,"input":"x"}"#).unwrap();
        assert!(matches!(started, Event::TurnStarted { more, .. } if more.is_empty()));
    }

    #[test]
    fn turn_usage_without_timing_still_parses() {
        let old = r#"{"context_tokens":5,"input_tokens":1,"output_tokens":2,"model_calls":1,"tokens_per_sec":null}"#;
        let u: TurnUsage = serde_json::from_str(old).unwrap();
        assert_eq!((u.model_calls, &u.timing), (1, &None));
        // And it serializes back without the new field.
        assert_eq!(serde_json::to_string(&u).unwrap(), old);
    }

    #[test]
    fn warm_takes_an_optional_draft() {
        let bare: Op = serde_json::from_str(r#"{"op":"warm"}"#).unwrap();
        assert!(matches!(bare, Op::Warm { draft: None }));
        let typing: Op = serde_json::from_str(r#"{"op":"warm","draft":"fix the"}"#).unwrap();
        assert!(matches!(typing, Op::Warm { draft: Some(d) } if d == "fix the"));
    }

    #[test]
    fn answer_is_flat_on_the_wire() {
        let op: Op =
            serde_json::from_str(r#"{"op":"answer","id":"q1","choices":["Truncate"]}"#).unwrap();
        let Op::Answer { id, answer } = op else {
            panic!("not an answer")
        };
        assert_eq!(
            (id.as_str(), answer.choices.as_slice()),
            ("q1", &["Truncate".to_string()][..])
        );
        assert!(!answer.dismissed());
        let bare: Op = serde_json::from_str(r#"{"op":"answer","id":"q1"}"#).unwrap();
        assert!(matches!(bare, Op::Answer { answer, .. } if answer.dismissed()));
        let blank = Answer {
            choices: vec![],
            other: Some("  ".into()),
        };
        assert!(blank.dismissed());
    }

    #[test]
    fn question_resolved_is_durable_and_question_is_not() {
        let resolved = Event::QuestionResolved {
            id: "q1".into(),
            answer: Answer {
                choices: vec![],
                other: Some("neither".into()),
            },
        };
        assert_eq!(
            serde_json::to_string(&resolved).unwrap(),
            r#"{"event":"question_resolved","id":"q1","other":"neither"}"#
        );
        assert!(resolved.is_durable());
        let asked = Event::Question {
            id: "q1".into(),
            item: "t1".into(),
            question: "Which?".into(),
            options: vec![AskOption {
                label: "A".into(),
                detail: None,
            }],
            multi: false,
            allow_other: true,
        };
        assert_eq!(
            serde_json::to_string(&asked).unwrap(),
            r#"{"event":"question","id":"q1","item":"t1","question":"Which?","options":[{"label":"A"}],"allow_other":true}"#
        );
        assert!(!asked.is_durable());
    }

    /// A subagent's steps survive a reopen: started/completed items inside a `subagent`
    /// wrapper are durable (the log keeps them), while its deltas stay live-only.
    #[test]
    fn subagent_steps_are_durable_and_deltas_are_not() {
        let started = Event::Subagent {
            item: "t1".into(),
            inner: Box::new(Event::ItemStarted {
                id: "s1".into(),
                kind: ItemKind::ToolCall {
                    name: "Read".into(),
                    arg: "main.rs".into(),
                },
            }),
        };
        assert!(started.is_durable());
        let completed = Event::Subagent {
            item: "t1".into(),
            inner: Box::new(Event::ItemCompleted {
                id: "s1".into(),
                item: Item::Message { text: "done".into() },
            }),
        };
        assert!(completed.is_durable());
        let delta = Event::Subagent {
            item: "t1".into(),
            inner: Box::new(Event::ItemDelta {
                id: "s1".into(),
                delta: Delta::Text { text: "hi".into() },
            }),
        };
        assert!(!delta.is_durable());
        // Round-trip: the serde shape is unchanged.
        let json = serde_json::to_string(&started).unwrap();
        let back: Event = serde_json::from_str(&json).unwrap();
        assert!(matches!(back, Event::Subagent { .. }));
    }

    #[test]
    fn client_caps_default_off() {
        let old: Op = serde_json::from_str(r#"{"op":"set_client_caps","panes":true}"#).unwrap();
        let Op::SetClientCaps {
            panes,
            ask,
            sessions,
            irc,
        } = old
        else {
            panic!("not SetClientCaps");
        };
        assert!(panes && !ask && !sessions && !irc);
        // Old clients never send `irc`, so the bus stays off until the client says otherwise.
        let wire: Op =
            serde_json::from_str(r#"{"op":"set_client_caps","panes":false,"irc":true}"#).unwrap();
        assert!(matches!(
            wire,
            Op::SetClientCaps {
                panes: false,
                ask: false,
                sessions: false,
                irc: true
            }
        ));
    }

    #[test]
    fn session_ops_round_trip() {
        let d: Op = serde_json::from_str(
            r#"{"op":"deliver","from":"s1","from_name":"Chief","message":"hi"}"#,
        )
        .unwrap();
        assert!(matches!(d, Op::Deliver { ref from, .. } if from == "s1"));
        let r: Op = serde_json::from_str(r#"{"op":"session_reply","id":"x","result":{"id":"s2"}}"#)
            .unwrap();
        assert!(matches!(r, Op::SessionReply { error: None, .. }));
        let e = Event::SessionRequest {
            id: "x".into(),
            item: "t".into(),
            tool: "SendMessage".into(),
            input: serde_json::json!({"to": "s2", "message": "hi"}),
        };
        let v = serde_json::to_value(&e).unwrap();
        assert_eq!(v["event"], "session_request");
        assert!(!e.is_durable());
        // The move's op shape: session + parent, parent omitted when unparenting.
        let m: Op = serde_json::from_str(
            r#"{"op":"move_session","session":"eng-0002","parent":"chief-0001"}"#,
        )
        .unwrap();
        assert!(matches!(
            m,
            Op::MoveSession {
                ref session,
                ref parent
            } if session == "eng-0002" && parent.as_deref() == Some("chief-0001")
        ));
        let unparented: Op =
            serde_json::from_str(r#"{"op":"move_session","session":"eng-0002"}"#).unwrap();
        assert!(matches!(
            unparented,
            Op::MoveSession { ref session, parent: None } if session == "eng-0002"
        ));
    }

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
