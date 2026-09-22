//! The agent loop. Runs as a background task; clients drive it with [`Op`]s and receive
//! [`Envelope`]s. See `protocol.rs` for the event lifecycle.

use crate::config::{Config, Profile, ToolMode};
use crate::message::{Block, Message, Role, Usage};
use crate::prompt;
use crate::protocol::{
    Decision, Delta, EndReason, EngineError, Envelope, Event, Item, ItemKind, Level, Mode, Op,
    Status, ToolOutcome, TurnUsage,
};
use crate::provider::{
    HttpError, Provider, Request, Response, Stop, StreamEvent, ToolSpec, new_id,
};
use crate::session::Session;
use crate::text_filter::TagFilter;
use crate::tools::{self, Ctx, Kind};
use anyhow::Result;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

macro_rules! marker_error {
    ($name:ident, $msg:literal) => {
        #[derive(Debug)]
        struct $name;
        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                write!(f, $msg)
            }
        }
        impl std::error::Error for $name {}
    };
}

marker_error!(Interrupted, "interrupted");
marker_error!(
    IncompleteStream,
    "the response stream ended before the provider finished"
);

#[derive(Debug)]
struct ConfigError(String);

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for ConfigError {}

/// Read-only commands that never need approval (when not chained or redirected).
const SAFE_BASH: &[&str] = &[
    "ls",
    "pwd",
    "cat",
    "head",
    "tail",
    "wc",
    "which",
    "file",
    "stat",
    "tree",
    "du",
    "df",
    "echo",
    "rg",
    "grep",
    "git status",
    "git diff",
    "git log",
    "git show",
    "git branch",
    "git remote",
    "git rev-parse",
    "git blame",
];

const COMPACT_PROMPT: &str = "Your context window is nearly full. Write a detailed summary of this conversation \
so work can continue from it alone. Include: the user's requests and intent, key decisions, files read or changed \
(with paths), important code details, errors hit and how they were fixed, what's done, what's in progress, and the \
next step. Do not call any tools. Output only the summary.";

pub struct Options {
    pub cfg: Config,
    pub profile_name: String,
    pub profile: Profile,
    pub cwd: PathBuf,
    pub mode: Mode,
    /// False for headless clients: anything that would ask is denied instead.
    pub can_ask: bool,
    pub resume: Option<Session>,
    /// Write sessions to disk.
    pub persist: bool,
}

pub struct Handle {
    pub ops: mpsc::UnboundedSender<Op>,
    pub events: mpsc::UnboundedReceiver<Envelope>,
}

/// State the op router touches while a turn is running.
#[derive(Default)]
struct Shared {
    cancel: Mutex<CancellationToken>,
    pending: Mutex<HashMap<String, oneshot::Sender<Decision>>>,
}

/// Start the engine. It emits `Status` then `Idle` once ready, and exits after `Op::Shutdown`
/// (or when every `ops` sender is dropped), closing the event stream.
pub fn spawn(opts: Options) -> Result<Handle> {
    let provider = Provider::new(&opts.profile)?;
    Ok(start(opts, provider))
}

fn start(opts: Options, provider: Provider) -> Handle {
    let (op_tx, mut op_rx) = mpsc::unbounded_channel::<Op>();
    let (ev_tx, ev_rx) = mpsc::unbounded_channel();
    let (work_tx, mut work_rx) = mpsc::unbounded_channel::<Op>();
    let shared = Arc::new(Shared::default());
    let mut agent = Agent::new(opts, provider, ev_tx, shared.clone());

    let router = shared.clone();
    tokio::spawn(async move {
        while let Some(op) = op_rx.recv().await {
            match op {
                Op::Interrupt => router.cancel.lock().unwrap().cancel(),
                Op::Permission { id, decision } => {
                    if let Some(tx) = router.pending.lock().unwrap().remove(&id) {
                        let _ = tx.send(decision);
                    }
                }
                op => {
                    if work_tx.send(op).is_err() {
                        break;
                    }
                }
            }
        }
    });

    tokio::spawn(async move {
        agent.emit_status();
        agent.emit(Event::Idle);
        while let Some(op) = work_rx.recv().await {
            if let Op::Shutdown = op {
                break;
            }
            let token = CancellationToken::new();
            *shared.cancel.lock().unwrap() = token.clone();
            let r = tokio::select! {
                r = agent.handle(op) => r,
                _ = token.cancelled() => Err(Interrupted.into()),
            };
            shared.pending.lock().unwrap().clear();
            if let Err(e) = r {
                agent.repair();
                let reason = if e.is::<Interrupted>() {
                    EndReason::Cancelled
                } else {
                    EndReason::Error {
                        error: classify(&e),
                    }
                };
                match (agent.active_turn.take(), reason) {
                    (Some(turn), reason) => agent.end_turn(turn, reason),
                    (None, EndReason::Error { error }) => agent.emit(Event::Error { error }),
                    (None, _) => agent.notice(Level::Warn, "interrupted"),
                }
            }
            agent.emit_status();
            agent.emit(Event::Idle);
        }
        agent.save();
    });

    Handle {
        ops: op_tx,
        events: ev_rx,
    }
}

/// Map any failure onto the closed [`EngineError`] set.
fn classify(e: &anyhow::Error) -> EngineError {
    if let Some(h) = e.downcast_ref::<HttpError>() {
        return EngineError::Provider {
            status: h.status,
            message: h.body.clone(),
        };
    }
    if e.is::<IncompleteStream>() {
        return EngineError::IncompleteStream;
    }
    if let Some(c) = e.downcast_ref::<ConfigError>() {
        return EngineError::Config {
            message: c.0.clone(),
        };
    }
    let network = e
        .chain()
        .filter_map(|c| c.downcast_ref::<reqwest::Error>())
        .any(|r| r.is_connect() || r.is_timeout() || r.is_request());
    if network {
        return EngineError::Connection {
            message: format!("{e:#}"),
        };
    }
    EngineError::Internal {
        message: format!("{e:#}"),
    }
}

fn retryable(e: &anyhow::Error) -> bool {
    if let Some(h) = e.downcast_ref::<HttpError>() {
        return matches!(h.status, 429 | 502 | 503 | 504 | 529) || h.body.contains("overloaded");
    }
    e.chain()
        .filter_map(|c| c.downcast_ref::<reqwest::Error>())
        .any(|r| r.is_timeout() || (r.is_request() && !r.is_connect()))
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// Items opened while streaming one model response.
#[derive(Default)]
struct Streamed {
    message: Option<String>,
    reasoning: Option<String>,
}

struct Agent {
    cfg: Config,
    profile_name: String,
    profile: Profile,
    provider: Provider,
    messages: Vec<Message>,
    ctx: Ctx,
    mode: Mode,
    can_ask: bool,
    persist: bool,
    usage: Usage,
    last_call: Duration,
    session_id: String,
    seq: AtomicU64,
    turn: u64,
    active_turn: Option<u64>,
    root: PathBuf,
    system: String,
    specs: Vec<ToolSpec>,
    session_allow: HashSet<String>,
    /// Context from `Op::Shell`, attached to the next message.
    pending: Vec<String>,
    events: mpsc::UnboundedSender<Envelope>,
    shared: Arc<Shared>,
}

impl Agent {
    fn new(
        o: Options,
        provider: Provider,
        events: mpsc::UnboundedSender<Envelope>,
        shared: Arc<Shared>,
    ) -> Self {
        let system = prompt::system_prompt(&o.cwd, &o.cfg, &o.profile.model);
        let (session_id, messages) = match o.resume {
            Some(s) => (s.id, s.messages),
            None => (Session::new_id(), Vec::new()),
        };
        Self {
            cfg: o.cfg,
            profile_name: o.profile_name,
            profile: o.profile,
            provider,
            messages,
            ctx: Ctx::new(o.cwd.clone()),
            mode: o.mode,
            can_ask: o.can_ask,
            persist: o.persist,
            usage: Usage::default(),
            last_call: Duration::ZERO,
            session_id,
            seq: AtomicU64::new(0),
            turn: 0,
            active_turn: None,
            root: o.cwd,
            system,
            specs: tools::specs(),
            session_allow: HashSet::new(),
            pending: Vec::new(),
            events,
            shared,
        }
    }

    // ---- events ----

    fn emit(&self, event: Event) {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed) + 1;
        let _ = self.events.send(Envelope {
            seq,
            session: self.session_id.clone(),
            created: now_ms(),
            event,
        });
    }

    fn notice(&self, level: Level, message: impl Into<String>) {
        self.emit(Event::Notice {
            level,
            message: message.into(),
        });
    }

    /// Unknown (`None`) when the provider didn't report usage, rather than a misleading zero.
    fn context_tokens(&self) -> Option<u64> {
        let c = self.usage.context();
        (c > 0).then_some(c)
    }

    fn tokens_per_sec(&self) -> Option<f64> {
        let secs = self.last_call.as_secs_f64();
        (secs > 0.0 && self.usage.output > 0).then(|| self.usage.output as f64 / secs)
    }

    fn emit_status(&self) {
        self.emit(Event::Status(Status {
            model: self.profile_name.clone(),
            mode: self.mode,
            cwd: self.ctx.cwd.clone(),
            messages: self.messages.len(),
            context_tokens: self.context_tokens(),
            context_window: self.profile.context_window(),
            tokens_per_sec: self.tokens_per_sec(),
            todos: self.ctx.todos.clone(),
        }));
    }

    fn end_turn(&self, turn: u64, reason: EndReason) {
        let usage = TurnUsage {
            context_tokens: self.context_tokens(),
            output_tokens: self.usage.output,
            tokens_per_sec: self.tokens_per_sec(),
        };
        self.emit(Event::TurnEnded {
            turn,
            reason,
            usage,
        });
    }

    fn complete_item(&self, streamed: Option<String>, kind: ItemKind, item: Item) {
        let id = streamed.unwrap_or_else(|| {
            let id = new_id();
            self.emit(Event::ItemStarted {
                id: id.clone(),
                kind,
            });
            id
        });
        self.emit(Event::ItemCompleted { id, item });
    }

    // ---- ops ----

    async fn handle(&mut self, op: Op) -> Result<()> {
        match op {
            Op::Submit { text } => self.turn(&text).await?,
            Op::Shell { command } => self.shell(&command).await,
            Op::SetMode { mode } => {
                self.mode = mode;
                self.emit(Event::ModeChanged { mode });
            }
            Op::SetModel { spec } => {
                let (name, profile) = self
                    .cfg
                    .resolve(Some(&spec))
                    .map_err(|e| ConfigError(format!("{e:#}")))?;
                self.provider =
                    Provider::new(&profile).map_err(|e| ConfigError(format!("{e:#}")))?;
                self.system = prompt::system_prompt(&self.root, &self.cfg, &profile.model);
                self.profile_name = name;
                self.profile = profile;
                self.emit(Event::ModelChanged {
                    model: self.profile_name.clone(),
                });
            }
            Op::Compact { focus } => self.compact(focus.as_deref()).await?,
            Op::Clear => {
                self.save();
                self.messages.clear();
                self.ctx = Ctx::new(self.root.clone());
                self.usage = Usage::default();
                self.session_id = Session::new_id();
                self.seq.store(0, Ordering::Relaxed);
                self.turn = 0;
                self.system = prompt::system_prompt(&self.root, &self.cfg, &self.profile.model);
                self.notice(Level::Info, "started a new conversation");
            }
            // Handled by the router, never queued.
            Op::Interrupt | Op::Permission { .. } | Op::Shutdown => {}
        }
        Ok(())
    }

    fn save(&self) {
        if !self.persist {
            return;
        }
        let s = Session {
            id: self.session_id.clone(),
            cwd: self.root.clone(),
            model: self.profile_name.clone(),
            messages: self.messages.clone(),
        };
        if let Err(e) = s.save() {
            self.notice(Level::Warn, format!("couldn't save session: {e}"));
        }
    }

    /// Append user text, merging into a trailing user message so roles always alternate.
    fn push_user(&mut self, text: String) {
        match self.messages.last_mut() {
            Some(m) if m.role == Role::User => m.content.push(Block::Text { text }),
            _ => self.messages.push(Message::user(text)),
        }
    }

    /// `@path` mentions inline the file so the model doesn't need a Read round-trip.
    fn expand_mentions(&mut self, input: &str) -> String {
        let mut extra = String::new();
        for tok in input.split_whitespace().filter_map(|t| t.strip_prefix('@')) {
            let tok = tok.trim_end_matches([',', ')', ':', ';', '?', '!']);
            let path = self.ctx.resolve(tok.trim_end_matches('.'));
            let Ok(meta) = std::fs::metadata(&path) else {
                continue;
            };
            if !meta.is_file() || meta.len() > 256_000 {
                continue;
            }
            if let Ok(text) = std::fs::read_to_string(&path) {
                extra.push_str(&format!(
                    "\n<file path=\"{}\">\n{text}\n</file>",
                    self.ctx.display(&path)
                ));
                self.ctx.mark_read(&path);
            }
        }
        if extra.is_empty() {
            input.to_string()
        } else {
            format!("{input}\n{extra}")
        }
    }

    async fn turn(&mut self, input: &str) -> Result<()> {
        self.turn += 1;
        let turn = self.turn;
        self.emit(Event::TurnStarted {
            turn,
            input: input.to_string(),
        });
        self.active_turn = Some(turn);

        let mut text = std::mem::take(&mut self.pending).join("\n");
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(&self.expand_mentions(input));
        self.push_user(text);
        self.save();

        let mut compacted = false;
        let reason = loop {
            let started = Instant::now();
            let (resp, streamed) = self.call("thinking", &self.messages, false).await?;
            self.last_call = started.elapsed();
            self.usage = resp.usage;
            let msg = normalize(resp.message);

            let reasoning: String = msg
                .content
                .iter()
                .filter_map(|b| match b {
                    Block::Thinking { text, .. } => Some(text.as_str()),
                    _ => None,
                })
                .collect();
            if !reasoning.is_empty() {
                self.complete_item(
                    streamed.reasoning,
                    ItemKind::Reasoning,
                    Item::Reasoning { text: reasoning },
                );
            }
            let answer = msg.text();
            if !answer.is_empty() {
                self.complete_item(
                    streamed.message,
                    ItemKind::Message,
                    Item::Message { text: answer },
                );
            }

            let uses = msg.tool_uses();
            self.messages.push(msg);
            if uses.is_empty() {
                break if resp.stop == Stop::Length {
                    EndReason::MaxTokens
                } else {
                    EndReason::Complete
                };
            }

            if self.run_tools(uses).await? {
                break EndReason::Denied;
            }
            let over = self
                .context_tokens()
                .is_some_and(|c| c > self.profile.context_window() * 8 / 10);
            if over && !compacted {
                self.notice(Level::Warn, "context is nearly full, compacting…");
                self.compact(None).await?;
                compacted = true;
            }
        };
        self.save();
        self.active_turn = None;
        self.end_turn(turn, reason);
        Ok(())
    }

    /// Run one batch of tool calls. Returns true if the user denied one.
    async fn run_tools(&mut self, uses: Vec<(String, String, Value)>) -> Result<bool> {
        // Results accumulate in place so an interrupt keeps what already ran.
        self.messages.push(Message {
            role: Role::User,
            content: Vec::new(),
        });
        let mut denied = false;
        for (id, name, input) in uses {
            let (_, arg) = tools::label(&name, &input, &self.ctx);
            self.emit(Event::ItemStarted {
                id: id.clone(),
                kind: ItemKind::ToolCall {
                    name: name.clone(),
                    arg: arg.clone(),
                },
            });

            let (outcome, output, display) = if denied {
                (
                    ToolOutcome::Skipped,
                    "Skipped: an earlier tool call was rejected.".to_string(),
                    None,
                )
            } else if self.permit(&id, &name, &arg, &input).await == Decision::Deny {
                let msg = if self.can_ask {
                    "The user rejected this tool call. Stop and wait for their instructions."
                } else {
                    "Not permitted in non-interactive mode (run with --yolo to allow)."
                };
                denied = self.can_ask;
                (ToolOutcome::Denied, msg.to_string(), None)
            } else {
                match tools::run(&name, &input, &mut self.ctx).await {
                    Ok(o) => (ToolOutcome::Ok, o.content, o.display),
                    Err(e) => (ToolOutcome::Error, format!("Error: {e:#}"), None),
                }
            };

            if let Some(m) = self.messages.last_mut() {
                m.content.push(Block::ToolResult {
                    id: id.clone(),
                    name: name.clone(),
                    content: output.clone(),
                    is_error: outcome != ToolOutcome::Ok,
                });
            }
            self.emit(Event::ItemCompleted {
                id,
                item: Item::ToolCall {
                    name,
                    arg,
                    input,
                    outcome,
                    output,
                    display,
                },
            });
        }
        self.save();
        Ok(denied)
    }

    /// One model request. Streams item events (unless `quiet`) and retries transient errors
    /// that happen before anything streamed.
    async fn call(
        &self,
        label: &str,
        messages: &[Message],
        quiet: bool,
    ) -> Result<(Response, Streamed)> {
        let text_mode = self.profile.tool_mode == ToolMode::Text;
        let converted;
        let (system, messages, tools) = if text_mode {
            converted = prompt::to_text_mode(messages);
            (
                format!("{}{}", self.system, prompt::text_tools_prompt(&self.specs)),
                &converted[..],
                &[][..],
            )
        } else {
            (self.system.clone(), messages, &self.specs[..])
        };
        let req = Request {
            system: &system,
            messages,
            tools,
            max_tokens: self.profile.max_tokens,
        };
        let mut attempt = 0;
        loop {
            self.emit(Event::Progress {
                label: label.into(),
            });
            let mut started = false;
            let mut streamed = Streamed::default();
            let mut filter = TagFilter::default();
            let text = |streamed: &mut Streamed, text: String| {
                let id = streamed.message.get_or_insert_with(|| {
                    let id = new_id();
                    self.emit(Event::ItemStarted {
                        id: id.clone(),
                        kind: ItemKind::Message,
                    });
                    id
                });
                self.emit(Event::ItemDelta {
                    id: id.clone(),
                    delta: Delta::Text { text },
                });
            };
            let r = self
                .provider
                .complete(&req, &mut |e| {
                    started = true;
                    if quiet {
                        return;
                    }
                    match e {
                        StreamEvent::Thinking(text) => {
                            let id = streamed.reasoning.get_or_insert_with(|| {
                                let id = new_id();
                                self.emit(Event::ItemStarted {
                                    id: id.clone(),
                                    kind: ItemKind::Reasoning,
                                });
                                id
                            });
                            self.emit(Event::ItemDelta {
                                id: id.clone(),
                                delta: Delta::Reasoning { text },
                            });
                        }
                        StreamEvent::ToolCall(name) => self.emit(Event::Progress {
                            label: format!("{name}…"),
                        }),
                        StreamEvent::Text(s) => {
                            let was_inside = filter.inside;
                            let visible = filter.push(&s);
                            if !visible.is_empty() {
                                text(&mut streamed, visible);
                            }
                            if filter.inside && !was_inside {
                                self.emit(Event::Progress {
                                    label: "tool call…".into(),
                                });
                            }
                        }
                    }
                })
                .await;
            let rest = filter.finish();
            if !quiet && !rest.is_empty() {
                text(&mut streamed, rest);
            }
            match r {
                Ok(resp) if resp.stop == Stop::Incomplete => return Err(IncompleteStream.into()),
                Ok(resp) => return Ok((resp, streamed)),
                Err(e) if !started && attempt < 3 && retryable(&e) => {
                    attempt += 1;
                    self.notice(Level::Warn, format!("{e:#} — retrying ({attempt}/3)"));
                    tokio::time::sleep(Duration::from_secs(1 << attempt)).await;
                }
                Err(e) => return Err(e),
            }
        }
    }

    async fn permit(&mut self, item: &str, name: &str, arg: &str, input: &Value) -> Decision {
        let kind = tools::kind(name);
        if kind == Kind::Read || self.mode == Mode::Yolo {
            return Decision::Allow;
        }
        let cmd = input["command"].as_str().unwrap_or("").trim();
        let prefix = cmd.split_whitespace().next().unwrap_or("").to_string();
        let key = match kind {
            Kind::Edit => "edits".to_string(),
            _ => format!("bash:{prefix}"),
        };
        let auto = match kind {
            Kind::Edit => self.mode == Mode::AcceptEdits,
            _ => bash_allowed(cmd, &self.cfg.allow_bash),
        };
        if auto || self.session_allow.contains(&key) {
            return Decision::Allow;
        }
        if !self.can_ask {
            return Decision::Deny;
        }
        let always = match kind {
            Kind::Edit => "allow all edits this session".to_string(),
            _ => format!("always allow `{prefix}` this session"),
        };
        let id = new_id();
        let (tx, rx) = oneshot::channel();
        self.shared.pending.lock().unwrap().insert(id.clone(), tx);
        self.emit(Event::PermissionRequest {
            id: id.clone(),
            item: item.into(),
            name: name.into(),
            arg: arg.into(),
            always,
        });
        let decision = rx.await.unwrap_or(Decision::Deny);
        self.emit(Event::PermissionResolved { id, decision });
        if decision == Decision::AllowAlways {
            self.session_allow.insert(key);
        }
        decision
    }

    /// Summarize the conversation and continue from the summary.
    async fn compact(&mut self, focus: Option<&str>) -> Result<()> {
        if self.messages.is_empty() {
            return Ok(());
        }
        let mut msgs = self.messages.clone();
        let mut instr = COMPACT_PROMPT.to_string();
        if let Some(f) = focus {
            instr.push_str(&format!("\nFocus especially on: {f}"));
        }
        match msgs.last_mut() {
            Some(m) if m.role == Role::User => m.content.push(Block::Text { text: instr }),
            _ => msgs.push(Message::user(instr)),
        }
        let (resp, _) = self.call("compacting", &msgs, true).await?;
        let summary = resp.message.text();
        if summary.trim().is_empty() {
            anyhow::bail!("compaction produced an empty summary; keeping the full history");
        }
        let before = self.usage.context();
        self.messages = vec![Message::user(format!(
            "(The earlier part of this session was compacted. Summary:)\n\n{summary}"
        ))];
        self.usage = Usage {
            input: resp.usage.output,
            ..Default::default()
        };
        self.emit(Event::Compacted {
            tokens_before: before,
            tokens_after: resp.usage.output,
        });
        self.save();
        Ok(())
    }

    /// After an interrupt or error: give every dangling tool call a result so the history stays valid.
    fn repair(&mut self) {
        if let Some(ai) = self
            .messages
            .iter()
            .rposition(|m| m.role == Role::Assistant)
        {
            let uses = self.messages[ai].tool_uses();
            if !uses.is_empty() {
                if ai + 1 == self.messages.len() {
                    self.messages.push(Message {
                        role: Role::User,
                        content: Vec::new(),
                    });
                }
                let done: HashSet<String> = self.messages[ai + 1]
                    .content
                    .iter()
                    .filter_map(|b| match b {
                        Block::ToolResult { id, .. } => Some(id.clone()),
                        _ => None,
                    })
                    .collect();
                for (id, name, _) in uses {
                    if !done.contains(&id) {
                        self.messages[ai + 1].content.push(Block::ToolResult {
                            id,
                            name,
                            content: "Interrupted by user before this ran.".into(),
                            is_error: true,
                        });
                    }
                }
            }
        }
        if self.messages.last().is_some_and(|m| m.role == Role::User) {
            self.push_user("[Request interrupted by user]".into());
        }
        self.save();
    }

    async fn shell(&mut self, cmd: &str) {
        let id = new_id();
        let (name, arg) = ("!".to_string(), cmd.to_string());
        self.emit(Event::ItemStarted {
            id: id.clone(),
            kind: ItemKind::ToolCall {
                name: name.clone(),
                arg: arg.clone(),
            },
        });
        let input = serde_json::json!({ "command": cmd });
        let (outcome, output) = match tools::run("Bash", &input, &mut self.ctx).await {
            Ok(o) => (ToolOutcome::Ok, o.content),
            Err(e) => (ToolOutcome::Error, format!("{e:#}")),
        };
        self.pending.push(format!(
            "<bash-input>{cmd}</bash-input>\n<bash-output>{output}</bash-output>"
        ));
        self.emit(Event::ItemCompleted {
            id,
            item: Item::ToolCall {
                name,
                arg,
                input,
                outcome,
                output,
                display: None,
            },
        });
    }
}

/// Recover tool calls a model wrote as text instead of via the API.
fn normalize(mut msg: Message) -> Message {
    if !msg.tool_uses().is_empty() {
        return msg;
    }
    let Some((clean, calls)) = prompt::extract_tool_calls(&msg.text()) else {
        return msg;
    };
    msg.content.retain(|b| !matches!(b, Block::Text { .. }));
    if !clean.is_empty() {
        msg.content.push(Block::Text { text: clean });
    }
    for (name, input) in calls {
        msg.content.push(Block::ToolUse {
            id: new_id(),
            name,
            input,
        });
    }
    msg
}

fn bash_allowed(cmd: &str, extra: &[String]) -> bool {
    if cmd.contains([';', '&', '|', '>', '<', '`', '$', '\n']) {
        return false;
    }
    SAFE_BASH
        .iter()
        .copied()
        .chain(extra.iter().map(String::as_str))
        .any(|p| cmd == p || cmd.starts_with(&format!("{p} ")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Profile, ProviderKind};
    use crate::provider::scripted;
    use serde_json::json;

    fn reply(content: Vec<Block>, stop: Stop) -> Response {
        Response {
            message: Message {
                role: Role::Assistant,
                content,
            },
            usage: Usage {
                input: 100,
                output: 10,
                cache_read: 0,
            },
            stop,
        }
    }

    fn text(t: &str) -> Block {
        Block::Text { text: t.into() }
    }

    fn engine(script: Vec<Response>, can_ask: bool) -> Handle {
        let opts = Options {
            cfg: Config::default(),
            profile_name: "test".into(),
            profile: Profile::new(ProviderKind::Ollama, "test"),
            cwd: std::env::temp_dir(),
            mode: Mode::Default,
            can_ask,
            resume: None,
            persist: false,
        };
        start(opts, Provider::Scripted(scripted::Client::new(script)))
    }

    /// Submit one prompt and collect every event through the following `Idle`.
    async fn run(h: &mut Handle, prompt: &str) -> Vec<Envelope> {
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: prompt.into(),
            })
            .unwrap();
        let mut out = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            let idle = matches!(env.event, Event::Idle);
            out.push(env);
            if idle {
                return out;
            }
        }
    }

    fn names(evs: &[Envelope]) -> Vec<String> {
        evs.iter()
            .map(|e| {
                serde_json::to_value(&e.event).unwrap()["event"]
                    .as_str()
                    .unwrap()
                    .to_string()
            })
            .collect()
    }

    #[tokio::test]
    async fn text_turn_lifecycle() {
        let mut h = engine(vec![reply(vec![text("hello")], Stop::End)], true);
        let evs = run(&mut h, "hi").await;
        assert_eq!(
            names(&evs),
            [
                "turn_started",
                "progress",
                "item_started",
                "item_delta",
                "item_completed",
                "turn_ended",
                "status",
                "idle"
            ]
        );
        let seqs: Vec<u64> = evs.iter().map(|e| e.seq).collect();
        assert!(
            seqs.windows(2).all(|w| w[1] == w[0] + 1),
            "seq must be contiguous: {seqs:?}"
        );
        assert!(
            matches!(&evs[4].event, Event::ItemCompleted { item: Item::Message { text }, .. } if text == "hello")
        );
        assert!(matches!(
            &evs[5].event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        ));
        // The delta and the completion refer to the same item.
        let ids: Vec<&str> = evs[2..5]
            .iter()
            .map(|e| match &e.event {
                Event::ItemStarted { id, .. }
                | Event::ItemDelta { id, .. }
                | Event::ItemCompleted { id, .. } => id.as_str(),
                _ => unreachable!(),
            })
            .collect();
        assert!(ids.iter().all(|i| *i == ids[0]));
    }

    #[tokio::test]
    async fn headless_denial_is_reported_and_turn_continues() {
        let call = Block::ToolUse {
            id: "t1".into(),
            name: "Bash".into(),
            input: json!({ "command": "touch nope" }),
        };
        let mut h = engine(
            vec![
                reply(vec![call], Stop::ToolUse),
                reply(vec![text("ok, I won't")], Stop::End),
            ],
            false,
        );
        let evs = run(&mut h, "make a file").await;
        let outcome = evs.iter().find_map(|e| match &e.event {
            Event::ItemCompleted {
                id,
                item: Item::ToolCall { outcome, .. },
            } if id == "t1" => Some(*outcome),
            _ => None,
        });
        assert_eq!(outcome, Some(ToolOutcome::Denied));
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
    }

    #[tokio::test]
    async fn incomplete_stream_ends_turn_with_typed_error() {
        let mut h = engine(vec![reply(vec![text("partial")], Stop::Incomplete)], true);
        let evs = run(&mut h, "hi").await;
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::TurnEnded {
                reason: EndReason::Error {
                    error: EngineError::IncompleteStream
                },
                ..
            }
        )));
    }

    #[tokio::test]
    async fn max_tokens_is_distinguished() {
        let mut h = engine(vec![reply(vec![text("cut off")], Stop::Length)], true);
        let evs = run(&mut h, "hi").await;
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::MaxTokens,
                ..
            }
        )));
    }

    #[tokio::test]
    async fn only_lifecycle_facts_are_durable() {
        let mut h = engine(vec![reply(vec![text("hello")], Stop::End)], true);
        let evs = run(&mut h, "hi").await;
        let durable: Vec<String> = names(&evs)
            .into_iter()
            .zip(&evs)
            .filter(|(_, e)| e.event.is_durable())
            .map(|(n, _)| n)
            .collect();
        assert_eq!(
            durable,
            [
                "turn_started",
                "item_started",
                "item_completed",
                "turn_ended"
            ]
        );
    }

    #[test]
    fn bash_allowlist() {
        assert!(bash_allowed("git status", &[]));
        assert!(bash_allowed("ls -la src", &[]));
        assert!(!bash_allowed("lsof", &[]));
        assert!(!bash_allowed("ls && rm -rf /", &[]));
        assert!(!bash_allowed("cat x > y", &[]));
        assert!(bash_allowed("cargo check --all", &["cargo check".into()]));
    }
}
