//! The agent loop. Runs as a background task; clients drive it with [`Op`]s and receive
//! [`Envelope`]s. See `protocol.rs` for the event lifecycle.

use crate::config::{Config, Profile, ProviderKind, ToolMode};
use crate::context::{self, Estimator};
use crate::harness::{self, Caps, Tier};
use crate::message::{Block, Message, Role, Usage};
use crate::prompt;
use crate::protocol::{
    Decision, Delta, EndReason, EngineError, Envelope, Event, Item, ItemKind, Level, Mode, Op,
    Status, ToolOutcome, TurnUsage,
};
use crate::provider::{
    HttpError, Provider, Request, Response, Stop, StreamEvent, ToolSpec, new_id,
};
use crate::session::{self, Header, Log, Record};
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

/// The Nth identical tool call in one turn is refused, with a nudge to change approach…
const LOOP_REFUSE: u32 = 3;
/// …and at this count the turn stops. opencode saw a sub-agent make 364 identical greps.
const LOOP_STOP: u32 = 5;
/// Model calls per turn before stopping to check in with the user.
const MAX_STEPS: u32 = 60;

/// How a batch of tool calls ended.
#[derive(PartialEq)]
enum Batch {
    Continue,
    Denied,
    Looping,
}

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
    /// Session id to resume from `store`.
    pub resume: Option<String>,
    /// Directory for session logs. `None` keeps everything in memory.
    pub store: Option<PathBuf>,
    /// Confine writes to `cwd` (and temp dirs).
    pub sandbox: bool,
    /// The client can answer MCP elicitations and host MCP Apps (the Mac app).
    pub rich: bool,
    /// Run as a subagent: read-only tools, no MCP, no `Task`, a report at the end.
    pub subagent: bool,
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
    /// Connected MCP servers, for elicitation answers and app tool calls mid-turn.
    mcp: Mutex<Option<crate::mcp::Hub>>,
    /// The current session id, for events emitted outside the agent (MCP callbacks).
    session: Mutex<String>,
    /// Running subagents by `Task` tool call id, so a client can stop one.
    subagents: Mutex<HashMap<String, CancellationToken>>,
}

/// Start the engine. It emits `Status` then `Idle` once ready, and exits after `Op::Shutdown`
/// (or when every `ops` sender is dropped), closing the event stream.
pub fn spawn(opts: Options) -> Result<Handle> {
    let provider = Provider::new(&opts.profile)?;
    start(opts, provider)
}

fn start(opts: Options, provider: Provider) -> Result<Handle> {
    let (op_tx, mut op_rx) = mpsc::unbounded_channel::<Op>();
    let (ev_tx, ev_rx) = mpsc::unbounded_channel();
    let (work_tx, mut work_rx) = mpsc::unbounded_channel::<Op>();
    let shared = Arc::new(Shared::default());
    let mut agent = Agent::new(opts, provider, ev_tx, shared.clone())?;

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
                Op::Elicit {
                    id,
                    action,
                    content,
                } => {
                    if let Some(hub) = router.mcp.lock().unwrap().as_ref() {
                        hub.host()
                            .resolve(&id, crate::mcp::ElicitReply { action, content });
                    }
                }
                Op::StopSubagent { id } => {
                    if let Some(t) = router.subagents.lock().unwrap().get(&id) {
                        t.cancel();
                    }
                }
                Op::AppCall {
                    id,
                    server,
                    tool,
                    arguments,
                } => {
                    let Some(hub) = router.mcp.lock().unwrap().clone() else {
                        continue;
                    };
                    tokio::spawn(async move {
                        let (result, error) = match hub.app_call(&server, &tool, &arguments).await {
                            Ok(v) => (Some(v), None),
                            Err(e) => (None, Some(format!("{e:#}"))),
                        };
                        hub.host().emit(Event::AppResult { id, result, error });
                    });
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
        agent.connect_mcp().await;
        agent.resolve_window().await;
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
        agent.mcp.shutdown();
        agent.sync_log();
    });

    Ok(Handle {
        ops: op_tx,
        events: ev_rx,
    })
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
    /// The reply didn't follow the requested tool-call format.
    format_failed: bool,
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
    rich: bool,
    subagent: bool,
    store: Option<PathBuf>,
    /// Opened lazily on the first durable write, so idle launches leave no files behind.
    log: Mutex<Option<Log>>,
    usage: Usage,
    last_call: Duration,
    session_id: String,
    seq: Arc<AtomicU64>,
    turn: u64,
    active_turn: Option<u64>,
    /// The context window actually in effect (config, bounded by what the server reports).
    window: u64,
    est: Estimator,
    /// Everything the user has typed this session, kept verbatim through compaction.
    inputs: Vec<String>,
    /// The tool-call mode in effect (the profile's, or resolved from `auto`).
    tool_mode: ToolMode,
    tier: Tier,
    caps: Option<Caps>,
    /// Tool-call format failures under `auto`; enough of them switches modes.
    mode_failures: u32,
    /// Running totals for the current turn.
    turn_usage: TurnUsage,
    root: PathBuf,
    system: String,
    specs: Vec<ToolSpec>,
    /// Connected MCP servers, whose tools are appended to `specs`.
    mcp: crate::mcp::Hub,
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
    ) -> Result<Self> {
        // The capability cache lives next to the session store; in-memory engines skip it.
        let caps = (o.store.is_some() && !harness::is_hosted(&o.profile))
            .then(|| harness::cached(&o.profile))
            .flatten();
        let tier = harness::tier(&o.profile, caps.as_ref());
        let tool_mode = harness::choose_mode(&o.profile, caps.as_ref(), tier);
        let system = format!(
            "{}{}",
            prompt::system_prompt(&o.cwd, &o.cfg, &o.profile.model),
            harness::guidance(tier)
        );
        let (session_id, messages, seq, turn, log, inputs) = match (&o.resume, &o.store) {
            (Some(id), Some(dir)) => {
                let l = session::load(dir, id).map_err(|e| ConfigError(format!("{e:#}")))?;
                let log = Log::open(dir, id).map_err(|e| ConfigError(format!("{e:#}")))?;
                let (seq, turn) = (l.last_seq(), l.last_turn());
                let inputs = l
                    .events
                    .iter()
                    .filter_map(|e| match &e.event {
                        Event::TurnStarted { input, .. } => Some(input.clone()),
                        _ => None,
                    })
                    .collect();
                (id.clone(), l.messages, seq, turn, Some(log), inputs)
            }
            (Some(_), None) => {
                anyhow::bail!(ConfigError("can't resume without a session store".into()))
            }
            (None, _) => (session::new_id(), Vec::new(), 0, 0, None, Vec::new()),
        };
        let window = o.profile.context_window();
        let resumed = o.resume.is_some();
        let mut agent = Self {
            cfg: o.cfg,
            profile_name: o.profile_name,
            profile: o.profile,
            provider,
            messages,
            ctx: {
                let mut ctx = Ctx::new(o.cwd.clone());
                if o.sandbox {
                    ctx.sandbox = Some(o.cwd.canonicalize().unwrap_or_else(|_| o.cwd.clone()));
                }
                ctx
            },
            mode: o.mode,
            can_ask: o.can_ask,
            rich: o.rich,
            subagent: o.subagent,
            store: o.store,
            log: Mutex::new(log),
            usage: Usage::default(),
            last_call: Duration::ZERO,
            session_id,
            seq: Arc::new(AtomicU64::new(seq)),
            turn,
            active_turn: None,
            window,
            est: Estimator::default(),
            inputs,
            tool_mode,
            tier,
            caps,
            mode_failures: 0,
            turn_usage: TurnUsage::default(),
            root: o.cwd,
            system,
            specs: tools::specs(),
            mcp: crate::mcp::Hub::empty(),
            session_allow: HashSet::new(),
            pending: Vec::new(),
            events,
            shared,
        };
        if resumed {
            // A session that died mid-turn may have dangling tool calls.
            agent.repair();
        }
        agent.sync_specs();
        agent.apply_harness();
        Ok(agent)
    }

    // ---- persistence ----

    /// Append a record to the session log, creating the log on first use.
    fn record(&self, rec: Record) {
        let Some(dir) = &self.store else { return };
        let mut log = self.log.lock().unwrap();
        if log.is_none() {
            let header = Header {
                version: session::VERSION,
                id: self.session_id.clone(),
                cwd: self.root.clone(),
                model: self.profile_name.clone(),
                created: now_ms(),
                forked_from: None,
            };
            match Log::create(dir, header) {
                Ok(l) => *log = Some(l),
                Err(e) => {
                    drop(log);
                    self.notice(Level::Warn, format!("session won't be saved: {e:#}"));
                    return;
                }
            }
        }
        if let Some(Err(e)) = log.as_mut().map(|l| l.append(&rec)) {
            *log = None;
            drop(log);
            self.notice(
                Level::Warn,
                format!("session log write failed, no longer saving: {e:#}"),
            );
        }
    }

    fn sync_log(&self) {
        if let Some(l) = self.log.lock().unwrap().as_ref() {
            let _ = l.sync();
        }
    }

    fn push_msg(&mut self, message: Message) {
        self.record(Record::Push {
            message: message.clone(),
        });
        self.messages.push(message);
    }

    fn extend_last(&mut self, blocks: Vec<Block>) {
        self.record(Record::Extend {
            blocks: blocks.clone(),
        });
        if let Some(m) = self.messages.last_mut() {
            m.content.extend(blocks);
        }
    }

    fn reset(&mut self, messages: Vec<Message>) {
        self.record(Record::Reset {
            messages: messages.clone(),
        });
        self.messages = messages;
    }

    // ---- events ----

    fn emit(&self, event: Event) {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed) + 1;
        let env = Envelope {
            seq,
            session: self.session_id.clone(),
            created: now_ms(),
            event,
        };
        if env.event.is_durable() {
            self.record(Record::Event { env: env.clone() });
        }
        let _ = self.events.send(env);
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
            context_window: self.window,
            tool_mode: self.tool_mode,
            tier: self.tier,
            tokens_per_sec: self.tokens_per_sec(),
            todos: self.ctx.todos.clone(),
        }));
    }

    fn count_call(&mut self, u: Usage) {
        self.turn_usage.input_tokens += u.input + u.cache_read;
        self.turn_usage.output_tokens += u.output;
        self.turn_usage.model_calls += 1;
    }

    fn end_turn(&self, turn: u64, reason: EndReason) {
        let usage = TurnUsage {
            tokens_per_sec: self.tokens_per_sec(),
            context_tokens: self.context_tokens(),
            ..self.turn_usage
        };
        self.emit(Event::TurnEnded {
            turn,
            reason,
            usage,
        });
        self.sync_log();
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
                self.profile_name = name;
                self.profile = profile;
                self.caps = (self.store.is_some() && !harness::is_hosted(&self.profile))
                    .then(|| harness::cached(&self.profile))
                    .flatten();
                self.mode_failures = 0;
                self.apply_harness();
                self.resolve_window().await;
                self.emit(Event::ModelChanged {
                    model: self.profile_name.clone(),
                });
            }
            Op::Compact { focus } => self.compact(focus.as_deref()).await?,
            Op::Subscribe { after } => {
                let replay = match &self.store {
                    Some(dir) if self.log.lock().unwrap().is_some() => {
                        session::events_after(dir, &self.session_id, after)?
                    }
                    _ => Vec::new(),
                };
                for env in replay {
                    let _ = self.events.send(env);
                }
                self.emit(Event::Synced {
                    upto: self.seq.load(Ordering::Relaxed),
                });
            }
            Op::Clear => {
                self.sync_log();
                *self.log.lock().unwrap() = None;
                self.messages.clear();
                self.inputs.clear();
                let sandbox = self.ctx.sandbox.take();
                self.ctx = Ctx::new(self.root.clone());
                self.ctx.sandbox = sandbox;
                self.usage = Usage::default();
                self.session_id = session::new_id();
                *self.shared.session.lock().unwrap() = self.session_id.clone();
                self.seq.store(0, Ordering::Relaxed);
                self.turn = 0;
                self.apply_harness();
                self.notice(Level::Info, "started a new conversation");
            }
            Op::SetTitle { title } => {
                let title: String = title.trim().chars().take(80).collect();
                if !title.is_empty() {
                    self.emit(Event::Titled { title });
                }
            }
            // Handled by the router, never queued.
            Op::Interrupt
            | Op::Permission { .. }
            | Op::Elicit { .. }
            | Op::AppCall { .. }
            | Op::StopSubagent { .. }
            | Op::Shutdown => {}
        }
        Ok(())
    }

    /// Append user text, merging into a trailing user message so roles always alternate.
    fn push_user(&mut self, text: String) {
        match self.messages.last() {
            Some(m) if m.role == Role::User => self.extend_last(vec![Block::Text { text }]),
            _ => self.push_msg(Message::user(text)),
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
        self.inputs.push(input.to_string());
        self.checkpoint(turn);
        self.turn_usage = TurnUsage::default();

        self.ensure_profiled().await;

        let mut text = std::mem::take(&mut self.pending).join("\n");
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(&self.expand_mentions(input));
        self.push_user(text);

        let mut compacted = false;
        let mut repeats: HashMap<String, u32> = HashMap::new();
        let mut steps = 0;
        let reason = loop {
            steps += 1;
            let limit = if self.subagent {
                crate::subagent::MAX_STEPS
            } else {
                MAX_STEPS
            };
            if steps > limit {
                break EndReason::StepLimit;
            }
            if self.mcp.refresh().await {
                self.apply_harness();
            }
            self.sync_specs();
            self.fit_context(&mut compacted).await?;
            let sent = self.fixed_chars() + context::history_chars(&self.messages);
            let started = Instant::now();
            let (resp, streamed) = self.call("thinking", &self.messages, false).await?;
            self.last_call = started.elapsed();
            self.usage = resp.usage;
            self.count_call(resp.usage);
            self.est
                .calibrate(sent, resp.usage.input + resp.usage.cache_read);
            let (msg, recovered) = normalize(resp.message);
            let bad_args = msg
                .tool_uses()
                .iter()
                .any(|(_, _, i)| i.get("_invalid_json").is_some());
            if recovered || bad_args || streamed.format_failed {
                self.note_format_failure();
            }

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
            self.push_msg(msg);
            if uses.is_empty() {
                break if resp.stop == Stop::Length {
                    EndReason::MaxTokens
                } else {
                    EndReason::Complete
                };
            }

            match self.run_tools(uses, &mut repeats).await? {
                Batch::Continue => {}
                Batch::Denied => break EndReason::Denied,
                Batch::Looping => break EndReason::Looping,
            }
        };
        self.active_turn = None;
        self.end_turn(turn, reason);
        Ok(())
    }

    /// Recompute tier, tool mode and system prompt from the profile and capabilities.
    fn apply_harness(&mut self) {
        self.tier = harness::tier(&self.profile, self.caps.as_ref());
        self.tool_mode = harness::choose_mode(&self.profile, self.caps.as_ref(), self.tier);
        self.system = format!(
            "{}{}",
            prompt::system_prompt(&self.root, &self.cfg, &self.profile.model),
            harness::guidance(self.tier)
        );
        self.system.push_str(&self.mcp.prompt());
        if self.subagent {
            self.system.push_str(crate::subagent::PROMPT);
        }
    }

    /// Probe a local model's capabilities the first time it's used under `auto`.
    async fn ensure_profiled(&mut self) {
        if self.profile.tool_mode != ToolMode::Auto
            || harness::is_hosted(&self.profile)
            || self.caps.is_some()
        {
            return;
        }
        self.emit(Event::Progress {
            label: format!("profiling {} (first use only)", self.profile.model),
        });
        let caps = match harness::probe(&self.provider, &self.specs).await {
            Ok(caps) => caps,
            Err(e) => {
                // Don't cache anything; the turn itself will surface the real error.
                self.notice(
                    Level::Warn,
                    format!("couldn't profile {}: {e:#}", self.profile.model),
                );
                return;
            }
        };
        if self.store.is_some() {
            harness::save(&self.profile, &caps);
        }
        self.caps = Some(caps);
        self.apply_harness();
        self.notice(
            Level::Info,
            format!(
                "{}: using {:?} tool calls, {:?} tier",
                self.profile.model, self.tool_mode, self.tier
            )
            .to_lowercase(),
        );
    }

    /// The model botched the tool-call format (text calls under native, invalid JSON args, or
    /// JSON mode not honored). Under `auto`, two strikes moves to text mode for the session
    /// and records the finding.
    fn note_format_failure(&mut self) {
        if self.profile.tool_mode != ToolMode::Auto || self.tool_mode == ToolMode::Text {
            return;
        }
        self.mode_failures += 1;
        if self.mode_failures < 2 {
            return;
        }
        let from = self.tool_mode;
        self.tool_mode = ToolMode::Text;
        self.mode_failures = 0;
        if let Some(c) = self.caps.as_mut() {
            match from {
                ToolMode::Native => c.native_tools = false,
                ToolMode::Json => c.json_mode = false,
                _ => {}
            }
            if self.store.is_some() {
                harness::save(&self.profile, c);
            }
        }
        self.notice(
            Level::Warn,
            format!(
                "{:?} tool calls keep failing; switching to text tool calls",
                from
            )
            .to_lowercase(),
        );
    }

    /// Settle the context window: configured value, bounded by what the server reports.
    /// Ollama allocates memory per `num_ctx`, so an unconfigured window stays at 32k.
    async fn resolve_window(&mut self) {
        if let Some(model) = self.profile.sidecar.clone() {
            if !crate::sidecar::is_serving(&model).await {
                self.emit(Event::Progress {
                    label: format!("loading {model}"),
                });
            }
            if let Err(e) = crate::sidecar::ensure(&self.profile).await {
                self.notice(Level::Warn, format!("{e:#}"));
            }
        }
        let configured = self.profile.context_window;
        let probed = self.provider.probe_context().await;
        self.window = match (configured, probed) {
            (Some(c), Some(p)) if p < c => {
                self.notice(
                    Level::Warn,
                    format!("context_window is {c} but the server supports {p}; using {p}"),
                );
                p
            }
            (Some(c), _) => c,
            (None, Some(p)) if self.profile.provider == ProviderKind::Ollama => p.min(32_768),
            (None, Some(p)) => p,
            (None, None) => self.profile.context_window(),
        };
        self.provider.set_context_window(self.window);
    }

    fn fixed_chars(&self) -> usize {
        fixed_chars(&self.system, &self.specs)
    }

    fn estimate(&self) -> u64 {
        self.est
            .tokens(self.fixed_chars() + context::history_chars(&self.messages))
    }

    /// Stage 1: prune stale and old tool output (no LLM). Stage 2: summarize, at most once per turn.
    async fn fit_context(&mut self, compacted: &mut bool) -> Result<()> {
        let window = self.window as f64;
        let before = self.estimate();
        if (before as f64) < window * context::PRUNE_AT {
            return Ok(());
        }
        let target = self.est.chars((window * context::PRUNE_TO) as u64);
        let plan = context::plan_prune(&self.messages, target.saturating_sub(self.fixed_chars()));
        if !plan.is_empty() {
            for (id, content) in &plan {
                self.record(Record::Replace {
                    id: id.clone(),
                    content: content.clone(),
                });
                context::apply(&mut self.messages, id, content);
            }
            self.emit(Event::ContextPruned {
                results: plan.len(),
                tokens_before: before,
                tokens_after: self.estimate(),
            });
        }
        if (self.estimate() as f64) > window * context::COMPACT_AT && !*compacted {
            self.notice(
                Level::Warn,
                "context is still nearly full after pruning; summarizing…",
            );
            self.compact(None).await?;
            *compacted = true;
        }
        Ok(())
    }

    /// Pin the working tree before the turn touches anything (git repos, persisted sessions only).
    fn checkpoint(&self, turn: u64) {
        if self.store.is_none() {
            return;
        }
        let Some(root) = crate::checkpoint::repo_root(&self.root) else {
            return;
        };
        match crate::checkpoint::snapshot(&root, &format!("{}/{turn}", self.session_id)) {
            Ok(commit) => self.record(Record::Checkpoint { turn, root, commit }),
            Err(e) => self.notice(
                Level::Warn,
                format!("couldn't checkpoint the working tree: {e:#}"),
            ),
        }
    }

    /// Before an Edit/Write, log the file's current content so the turn can be rewound.
    fn snapshot(&self, name: &str, input: &Value) {
        if !matches!(name, "Edit" | "Write") {
            return;
        }
        let Some(p) = input["file_path"].as_str() else {
            return;
        };
        let path = self.ctx.resolve(p);
        let before = match std::fs::metadata(&path) {
            Ok(m) if m.len() > 4_000_000 => return,
            Ok(_) => match std::fs::read_to_string(&path) {
                Ok(s) => Some(s),
                Err(_) => return,
            },
            Err(_) => None,
        };
        self.record(Record::Snapshot {
            turn: self.turn,
            path,
            before,
        });
    }

    /// Connect the configured MCP servers (config.toml and the project's `.mcp.json`) and add
    /// their tools. Failures and quarantined tools become notices; nothing here is fatal.
    async fn connect_mcp(&mut self) {
        if self.subagent {
            return;
        }
        let servers = crate::mcp::configured(&self.cfg, &self.root);
        if servers.is_empty() {
            return;
        }
        let n = servers.len();
        self.emit(Event::Progress {
            label: format!("connecting {n} MCP server{}", if n == 1 { "" } else { "s" }),
        });
        *self.shared.session.lock().unwrap() = self.session_id.clone();
        let emit = {
            let (events, seq, shared) =
                (self.events.clone(), self.seq.clone(), self.shared.clone());
            move |event: Event| {
                let seq = seq.fetch_add(1, Ordering::Relaxed) + 1;
                let _ = events.send(Envelope {
                    seq,
                    session: shared.session.lock().unwrap().clone(),
                    created: now_ms(),
                    event,
                });
            }
        };
        let host = crate::mcp::Host::new(emit, self.rich && self.can_ask, &self.root);
        let hub = crate::mcp::Hub::connect(servers, host).await;
        for st in hub.status() {
            if let Some(e) = &st.error {
                self.notice(
                    Level::Warn,
                    format!("MCP `{}` didn't connect: {e}", st.name),
                );
            }
            for q in &st.quarantined {
                self.notice(
                    Level::Warn,
                    format!(
                        "MCP `{}`: withheld tool `{}` because its description {}. Set `trust = true` for this server to allow it.",
                        st.name, q.tool, q.reason
                    ),
                );
            }
        }
        *self.shared.mcp.lock().unwrap() = Some(hub.clone());
        self.mcp = hub;
        self.sync_specs();
        self.apply_harness();
    }

    /// Built-in tools plus whatever MCP tools are live (and, with many, loaded).
    fn sync_specs(&mut self) {
        let mut specs = tools::specs();
        if self.subagent {
            specs.retain(|s| tools::kind(&s.name) == Kind::Read);
        } else {
            specs.push(crate::subagent::spec());
            specs.extend(self.mcp.specs());
        }
        self.specs = specs;
    }

    /// `Task`: run a read-only subagent and return its report. Its steps stream as live output.
    async fn run_task(&mut self, id: &str, input: &Value) -> Result<tools::Output> {
        if self.subagent {
            anyhow::bail!("subagents can't start subagents");
        }
        let opts = Options {
            cfg: self.cfg.clone(),
            profile_name: self.profile_name.clone(),
            profile: self.profile.clone(),
            cwd: self.root.clone(),
            mode: Mode::Default,
            can_ask: false,
            resume: None,
            store: None,
            sandbox: true,
            rich: false,
            subagent: true,
        };
        let stop = CancellationToken::new();
        self.shared
            .subagents
            .lock()
            .unwrap()
            .insert(id.to_string(), stop.clone());
        let (events, seq, session, item) = (
            self.events.clone(),
            self.seq.clone(),
            self.session_id.clone(),
            id.to_string(),
        );
        let out = crate::subagent::run(opts, input, stop, move |inner| {
            let seq = seq.fetch_add(1, Ordering::Relaxed) + 1;
            let _ = events.send(Envelope {
                seq,
                session: session.clone(),
                created: now_ms(),
                event: Event::Subagent {
                    item: item.clone(),
                    inner: Box::new(inner),
                },
            });
        })
        .await;
        self.shared.subagents.lock().unwrap().remove(id);
        out
    }

    /// Run a tool, streaming its live output as ephemeral `Output` deltas on item `id`.
    async fn run_tool(&mut self, id: &str, name: &str, input: &Value) -> Result<tools::Output> {
        if name == crate::subagent::TOOL {
            return self.run_task(id, input).await;
        }
        if self.mcp.handles(name) {
            return self.mcp.call(id, name, input).await;
        }
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        self.ctx.progress = Some(tx);
        // The tool holds `ctx` mutably, so deltas go out through a detached emitter.
        let emit = {
            let (events, seq, session, id) = (
                self.events.clone(),
                self.seq.clone(),
                self.session_id.clone(),
                id.to_string(),
            );
            move |text: String| {
                let seq = seq.fetch_add(1, Ordering::Relaxed) + 1;
                let _ = events.send(Envelope {
                    seq,
                    session: session.clone(),
                    created: now_ms(),
                    event: Event::ItemDelta {
                        id: id.clone(),
                        delta: Delta::Output { text },
                    },
                });
            }
        };
        let out = {
            let run = tools::run(name, input, &mut self.ctx);
            tokio::pin!(run);
            loop {
                tokio::select! {
                    out = &mut run => break out,
                    Some(chunk) = rx.recv() => emit(chunk),
                }
            }
        };
        while let Ok(chunk) = rx.try_recv() {
            emit(chunk);
        }
        self.ctx.progress = None;
        out
    }

    /// Run one batch of tool calls. Returns true if the user denied one.
    async fn run_tools(
        &mut self,
        uses: Vec<(String, String, Value)>,
        repeats: &mut HashMap<String, u32>,
    ) -> Result<Batch> {
        // Results accumulate in place so an interrupt keeps what already ran.
        self.push_msg(Message {
            role: Role::User,
            content: Vec::new(),
        });
        let mut denied = false;
        let mut looping = false;
        for (id, name, input) in uses {
            let seen = repeats.entry(format!("{name}\u{0}{input}")).or_insert(0);
            *seen += 1;
            let seen = *seen;
            looping |= seen >= LOOP_STOP;
            let (_, arg) = tools::label(&name, &input, &self.ctx);
            self.emit(Event::ItemStarted {
                id: id.clone(),
                kind: ItemKind::ToolCall {
                    name: name.clone(),
                    arg: arg.clone(),
                },
            });

            let text = |outcome, content: String, display: Option<&str>| {
                (
                    outcome,
                    tools::Output {
                        content,
                        display: display.map(String::from),
                        ..Default::default()
                    },
                )
            };
            let (outcome, out) = if seen >= LOOP_REFUSE {
                let msg = format!(
                    "Not run: this exact call already ran {} times this turn with the same result. \
Don't repeat it. Change the arguments or try a different approach.",
                    seen - 1
                );
                text(
                    ToolOutcome::Error,
                    msg,
                    Some("refused: repeated identical call"),
                )
            } else if denied {
                text(
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
                text(ToolOutcome::Denied, msg.to_string(), None)
            } else {
                self.snapshot(&name, &input);
                match self.run_tool(&id, &name, &input).await {
                    Ok(o) => (ToolOutcome::Ok, o),
                    Err(e) => text(ToolOutcome::Error, format!("Error: {e:#}"), None),
                }
            };
            let output = out.content;

            self.extend_last(vec![Block::ToolResult {
                id: id.clone(),
                name: name.clone(),
                content: output.clone(),
                is_error: outcome != ToolOutcome::Ok,
            }]);
            self.emit(Event::ItemCompleted {
                id,
                item: Item::ToolCall {
                    name,
                    arg,
                    input,
                    outcome,
                    output,
                    display: out.display,
                    diff: out.diff,
                    diagram: out.diagram,
                    images: out.images,
                    app: out.app,
                },
            });
        }
        Ok(if denied {
            Batch::Denied
        } else if looping {
            Batch::Looping
        } else {
            Batch::Continue
        })
    }

    /// One model request. Streams item events (unless `quiet`) and retries transient errors
    /// that happen before anything streamed.
    async fn call(
        &self,
        label: &str,
        messages: &[Message],
        quiet: bool,
    ) -> Result<(Response, Streamed)> {
        let json_mode = self.tool_mode == ToolMode::Json;
        let converted;
        let schema;
        let (system, messages, tools, format) = match self.tool_mode {
            ToolMode::Text => {
                converted = prompt::to_text_mode(messages);
                let system = format!("{}{}", self.system, prompt::text_tools_prompt(&self.specs));
                (system, &converted[..], &[][..], None)
            }
            ToolMode::Json => {
                converted = prompt::to_json_mode(messages);
                schema = prompt::json_schema(&self.specs);
                let system = format!("{}{}", self.system, prompt::json_tools_prompt(&self.specs));
                (system, &converted[..], &[][..], Some(&schema))
            }
            ToolMode::Native | ToolMode::Auto => {
                (self.system.clone(), messages, &self.specs[..], None)
            }
        };
        let req = Request {
            system: &system,
            messages,
            tools,
            max_tokens: self.profile.max_tokens,
            format,
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
                        // JSON-mode output is raw JSON; the parsed answer is shown when complete.
                        StreamEvent::Text(_) if json_mode => {}
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
                // Unparseable JSON-mode output is kept as a plain answer and counted as a failure.
                Ok(resp) if json_mode => {
                    return Ok(match from_json_mode(resp.clone()) {
                        Some(resp) => (resp, streamed),
                        None => (
                            resp,
                            Streamed {
                                format_failed: true,
                                ..streamed
                            },
                        ),
                    });
                }
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
        let mcp = name.starts_with("mcp__");
        let key = match kind {
            Kind::Edit => "edits".to_string(),
            _ if mcp => format!("mcp:{name}"),
            _ => format!("bash:{prefix}"),
        };
        let auto = match kind {
            Kind::Edit => self.mode == Mode::AcceptEdits,
            _ if mcp => false,
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
            _ if mcp => {
                let pretty = name
                    .strip_prefix("mcp__")
                    .unwrap_or(name)
                    .replacen("__", " › ", 1);
                format!("always allow {pretty} this session")
            }
            _ => format!("always allow `{prefix}` this session"),
        };
        let id = new_id();
        let (tx, rx) = oneshot::channel();
        self.shared.pending.lock().unwrap().insert(id.clone(), tx);
        let preview = tools::fs::preview(name, input, &self.ctx);
        self.emit(Event::PermissionRequest {
            id: id.clone(),
            item: item.into(),
            name: name.into(),
            arg: arg.into(),
            always,
            preview,
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
        self.count_call(resp.usage);
        let summary = resp.message.text();
        if summary.trim().is_empty() {
            anyhow::bail!("compaction produced an empty summary; keeping the full history");
        }
        let before = self.usage.context();
        let pinned = context::pinned_inputs(&self.inputs, 8_000)
            .iter()
            .map(|s| format!("<user-message>\n{s}\n</user-message>"))
            .collect::<Vec<_>>()
            .join("\n");
        self.reset(vec![Message::user(format!(
            "(The earlier part of this session was compacted.)\n\nSummary:\n{summary}\n\n\
The user's messages so far, verbatim. Any instructions or constraints in them still apply:\n{pinned}"
        ))]);
        self.usage = Usage {
            input: resp.usage.output,
            ..Default::default()
        };
        self.emit(Event::Compacted {
            tokens_before: before,
            tokens_after: resp.usage.output,
        });
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
                    self.push_msg(Message {
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
                // The results message is always the last one.
                let missing: Vec<Block> = uses
                    .into_iter()
                    .filter(|(id, _, _)| !done.contains(id))
                    .map(|(id, name, _)| Block::ToolResult {
                        id,
                        name,
                        content: "Interrupted by user before this ran.".into(),
                        is_error: true,
                    })
                    .collect();
                if !missing.is_empty() {
                    self.extend_last(missing);
                }
            }
        }
        if self.messages.last().is_some_and(|m| m.role == Role::User) {
            self.push_user("[Request interrupted by user]".into());
        }
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
        let (outcome, output, display) = match self.run_tool(&id, "Bash", &input).await {
            Ok(o) => (ToolOutcome::Ok, o.content, o.display),
            Err(e) => (ToolOutcome::Error, format!("{e:#}"), None),
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
                display,
                diff: None,
                diagram: None,
                images: Vec::new(),
                app: None,
            },
        });
    }
}

/// Prompt chars that don't live in the history: system prompt and tool schemas.
fn fixed_chars(system: &str, specs: &[ToolSpec]) -> usize {
    let tools: usize = specs
        .iter()
        .map(|t| t.name.len() + t.description.len() + t.schema.to_string().len())
        .sum();
    system.len() + tools
}

/// Turn a JSON-mode reply into ordinary blocks: thought → reasoning, action → tool call or answer.
/// Returns `None` if the reply doesn't parse (the server didn't enforce the schema).
fn from_json_mode(mut resp: Response) -> Option<Response> {
    let (thought, action) = prompt::parse_action(&resp.message.text())?;
    let mut content = Vec::new();
    if !thought.is_empty() {
        content.push(Block::Thinking {
            text: thought,
            signature: None,
        });
    }
    match action {
        prompt::Action::Tool { name, args } => {
            content.push(Block::ToolUse {
                id: new_id(),
                name,
                input: args,
            });
            resp.stop = Stop::ToolUse;
        }
        prompt::Action::Answer(text) => content.push(Block::Text { text }),
    }
    resp.message.content = content;
    Some(resp)
}

/// Recover tool calls a model wrote as text instead of via the API.
/// Returns whether anything was recovered (a sign the configured format isn't working).
fn normalize(mut msg: Message) -> (Message, bool) {
    for b in &mut msg.content {
        if let Block::Text { text } = b {
            *text = prompt::strip_answer_tags(text);
        }
    }
    if !msg.tool_uses().is_empty() {
        return (msg, false);
    }
    let Some((clean, calls)) = prompt::extract_tool_calls(&msg.text()) else {
        return (msg, false);
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
    (msg, true)
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
        engine_at(script, can_ask, None, None)
    }

    fn engine_at(
        script: Vec<Response>,
        can_ask: bool,
        store: Option<PathBuf>,
        resume: Option<String>,
    ) -> Handle {
        engine_with(script, can_ask, store, resume, None, std::env::temp_dir())
    }

    fn engine_mode(script: Vec<Response>, mode: ToolMode) -> Handle {
        let mut profile = Profile::new(ProviderKind::Ollama, "test");
        profile.tool_mode = mode;
        let opts = Options {
            cfg: Config::default(),
            profile_name: "test".into(),
            profile,
            cwd: std::env::temp_dir(),
            mode: Mode::Default,
            can_ask: true,
            resume: None,
            store: None,
            sandbox: false,
            rich: false,
            subagent: false,
        };
        start(opts, Provider::Scripted(scripted::Client::new(script))).unwrap()
    }

    fn engine_with(
        script: Vec<Response>,
        can_ask: bool,
        store: Option<PathBuf>,
        resume: Option<String>,
        window: Option<u64>,
        cwd: PathBuf,
    ) -> Handle {
        let mut profile = Profile::new(ProviderKind::Ollama, "test");
        profile.context_window = window;
        profile.tool_mode = ToolMode::Native;
        let opts = Options {
            cfg: Config::default(),
            profile_name: "test".into(),
            profile,
            cwd,
            mode: Mode::Default,
            can_ask,
            resume,
            store,
            sandbox: false,
            rich: false,
            subagent: false,
        };
        start(opts, Provider::Scripted(scripted::Client::new(script))).unwrap()
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

    fn tmp_store() -> PathBuf {
        let d = std::env::temp_dir().join(format!("kiln-engine-test-{}", session::new_id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// Collect events through the next `Idle`.
    async fn until_idle(h: &mut Handle) -> Vec<Envelope> {
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

    async fn shutdown(mut h: Handle) {
        h.ops.send(Op::Shutdown).unwrap();
        while h.events.recv().await.is_some() {}
    }

    #[tokio::test]
    async fn session_resumes_with_history_replay_and_continuing_seq() {
        let dir = tmp_store();
        let mut h = engine_at(
            vec![reply(vec![text("hello")], Stop::End)],
            true,
            Some(dir.clone()),
            None,
        );
        let first = run(&mut h, "hi").await;
        let sid = first[0].session.clone();
        let last_seq = first.last().unwrap().seq;
        shutdown(h).await;

        let mut h = engine_at(
            vec![reply(vec![text("again")], Stop::End)],
            true,
            Some(dir),
            Some(sid.clone()),
        );
        let boot = until_idle(&mut h).await;
        assert!(matches!(&boot[0].event, Event::Status(s) if s.messages == 2));

        h.ops.send(Op::Subscribe { after: 0 }).unwrap();
        let replay = until_idle(&mut h).await;
        let durable = replay
            .iter()
            .take_while(|e| !matches!(e.event, Event::Synced { .. }))
            .count();
        assert_eq!(
            durable, 4,
            "turn_started, item_started, item_completed, turn_ended"
        );
        assert!(matches!(&replay[0].event, Event::TurnStarted { input, .. } if input == "hi"));
        assert!(replay.iter().all(|e| e.session == sid));

        h.ops
            .send(Op::Submit {
                text: "more".into(),
            })
            .unwrap();
        let second = until_idle(&mut h).await;
        assert!(matches!(
            second[0].event,
            Event::TurnStarted { turn: 2, .. }
        ));
        assert!(second[0].seq > last_seq, "seq continues across restarts");
        shutdown(h).await;
    }

    #[tokio::test]
    async fn crashed_mid_turn_session_is_repaired_on_resume() {
        let dir = tmp_store();
        let id = session::new_id();
        let mut log = Log::create(
            &dir,
            Header {
                version: session::VERSION,
                id: id.clone(),
                cwd: "/x".into(),
                model: "m".into(),
                created: 0,
                forked_from: None,
            },
        )
        .unwrap();
        log.append(&Record::Push {
            message: Message::user("go"),
        })
        .unwrap();
        let call = Block::ToolUse {
            id: "t1".into(),
            name: "Bash".into(),
            input: json!({ "command": "ls" }),
        };
        log.append(&Record::Push {
            message: Message {
                role: Role::Assistant,
                content: vec![call],
            },
        })
        .unwrap();
        drop(log);

        let h = engine_at(vec![], true, Some(dir.clone()), Some(id.clone()));
        shutdown(h).await;
        let loaded = session::load(&dir, &id).unwrap();
        let last = loaded.messages.last().unwrap();
        assert_eq!(last.role, Role::User);
        assert!(
            last.content
                .iter()
                .any(|b| matches!(b, Block::ToolResult { id, is_error: true, .. } if id == "t1"))
        );
    }

    #[tokio::test]
    async fn stale_reads_are_pruned_before_the_call_and_logged() {
        let dir = tmp_store();
        let big: String = (0..800).map(|i| format!("fn line_{i}() {{}}\n")).collect();
        std::fs::write(dir.join("big.rs"), &big).unwrap();
        let read = |id: &str| Block::ToolUse {
            id: id.into(),
            name: "Read".into(),
            input: json!({ "file_path": "big.rs" }),
        };
        let script = vec![
            reply(vec![read("r1")], Stop::ToolUse),
            reply(vec![read("r2")], Stop::ToolUse),
            reply(vec![text("done")], Stop::End),
        ];
        // Size the window so the fixed prompt plus one read fits under PRUNE_AT but two don't.
        let fixed = fixed_chars(
            &prompt::system_prompt(&dir, &Config::default(), "test"),
            &tools::specs(),
        );
        let read_chars: usize = big.lines().map(|l| 6 + 1 + l.len() + 1).sum();
        let window = context::Estimator::default()
            .tokens(((fixed as f64 + 1.5 * read_chars as f64) / context::PRUNE_AT) as usize);
        let mut h = engine_with(
            script,
            true,
            Some(dir.clone()),
            None,
            Some(window),
            dir.clone(),
        );
        let evs = run(&mut h, "look at big.rs twice").await;
        let sid = evs[0].session.clone();
        let pruned = evs.iter().find_map(|e| match e.event {
            Event::ContextPruned {
                results,
                tokens_before,
                tokens_after,
            } => Some((results, tokens_before, tokens_after)),
            _ => None,
        });
        let (results, before, after) = pruned.expect("expected a ContextPruned event");
        assert_eq!(results, 1);
        assert!(after < before);
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
        shutdown(h).await;

        // The pruning is in the log, so a resumed session sees the same history.
        let loaded = session::load(&dir, &sid).unwrap();
        let contents: Vec<&str> = loaded
            .messages
            .iter()
            .flat_map(|m| &m.content)
            .filter_map(|b| match b {
                Block::ToolResult { id, content, .. } if id == "r1" || id == "r2" => {
                    Some(content.as_str())
                }
                _ => None,
            })
            .collect();
        assert!(contents[0].starts_with("[stale: big.rs"));
        assert!(contents[1].contains("fn line_799"));
    }

    #[tokio::test]
    async fn compaction_keeps_the_users_words_verbatim() {
        let dir = tmp_store();
        let script = vec![
            reply(vec![text("ok")], Stop::End),
            reply(vec![text("They are refactoring the parser.")], Stop::End),
        ];
        let mut h = engine_at(script, true, Some(dir.clone()), None);
        let evs = run(&mut h, "refactor the parser but NEVER touch main.rs").await;
        let sid = evs[0].session.clone();
        h.ops.send(Op::Compact { focus: None }).unwrap();
        let evs = until_idle(&mut h).await;
        assert!(
            evs.iter()
                .any(|e| matches!(e.event, Event::Compacted { .. }))
        );
        shutdown(h).await;

        let loaded = session::load(&dir, &sid).unwrap();
        assert_eq!(loaded.messages.len(), 1);
        let text = loaded.messages[0].text();
        assert!(text.contains("They are refactoring the parser."));
        assert!(text.contains("NEVER touch main.rs"));
    }

    #[tokio::test]
    async fn json_mode_turn_runs_the_action_and_shows_the_answer() {
        let script = vec![
            reply(
                vec![text(
                    r#"{"thought":"check the file","action":{"tool":"Glob","args":{"pattern":"*.nothing"}}}"#,
                )],
                Stop::End,
            ),
            reply(
                vec![text(
                    r#"{"thought":"","action":{"answer":"No such files."}}"#,
                )],
                Stop::End,
            ),
        ];
        let mut h = engine_mode(script, ToolMode::Json);
        let evs = run(&mut h, "any .nothing files?").await;
        let items: Vec<&Item> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::ItemCompleted { item, .. } => Some(item),
                _ => None,
            })
            .collect();
        assert!(matches!(items[0], Item::Reasoning { text } if text == "check the file"));
        assert!(
            matches!(items[1], Item::ToolCall { name, outcome: ToolOutcome::Ok, .. } if name == "Glob")
        );
        assert!(matches!(items[2], Item::Message { text } if text == "No such files."));
        // Raw JSON never streams to the client.
        assert!(!evs.iter().any(|e| matches!(&e.event, Event::ItemDelta { delta: Delta::Text { text }, .. } if text.contains("thought"))));
    }

    #[tokio::test]
    async fn auto_profiles_on_first_use_then_falls_back_when_native_calls_fail() {
        let read_probe = Block::ToolUse {
            id: "p".into(),
            name: "Read".into(),
            input: json!({ "file_path": "probe.txt" }),
        };
        let text_call =
            r#"<tool_call>{"name":"Glob","arguments":{"pattern":"*.nothing"}}</tool_call>"#;
        let script = vec![
            // Capability probes (text first, as the reachability check): text ok, native ok,
            // abstains ok, JSON not enforced.
            reply(
                vec![text(
                    r#"<tool_call>{"name":"Read","arguments":{"file_path":"probe.txt"}}</tool_call>"#,
                )],
                Stop::End,
            ),
            reply(vec![read_probe], Stop::ToolUse),
            reply(vec![text("42")], Stop::End),
            reply(vec![text("not json")], Stop::End),
            // The turn: native mode, but the model keeps writing calls as text.
            reply(vec![text(text_call)], Stop::End),
            reply(vec![text(text_call)], Stop::End),
            reply(vec![text("none found")], Stop::End),
        ];
        let mut h = engine_mode(script, ToolMode::Auto);
        let evs = run(&mut h, "find .nothing files").await;
        let notices: Vec<&str> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::Notice { message, .. } => Some(message.as_str()),
                _ => None,
            })
            .collect();
        assert!(
            notices
                .iter()
                .any(|n| n.contains("using native tool calls, medium tier")),
            "{notices:?}"
        );
        assert!(
            notices
                .iter()
                .any(|n| n.contains("switching to text tool calls")),
            "{notices:?}"
        );
        let status = evs.iter().rev().find_map(|e| match &e.event {
            Event::Status(s) => Some(s.tool_mode),
            _ => None,
        });
        assert_eq!(status, Some(ToolMode::Text));
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
    }

    #[tokio::test]
    async fn identical_calls_are_refused_then_the_turn_stops() {
        let call = || Block::ToolUse {
            id: new_id(),
            name: "Glob".into(),
            input: json!({ "pattern": "*.nothing" }),
        };
        let script = (0..LOOP_STOP)
            .map(|_| reply(vec![call()], Stop::ToolUse))
            .collect();
        let mut h = engine(script, true);
        let evs = run(&mut h, "loop forever").await;
        let refused = evs
            .iter()
            .filter(|e| matches!(&e.event, Event::ItemCompleted { item: Item::ToolCall { display: Some(d), .. }, .. } if d.starts_with("refused")))
            .count();
        assert_eq!(refused as u32, LOOP_STOP - LOOP_REFUSE + 1);
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Looping,
                ..
            }
        )));
    }

    #[tokio::test]
    async fn permission_requests_preview_the_exact_edit() {
        let dir = tmp_store();
        std::fs::write(dir.join("calc.py"), "def add(a, b):\n    return a - b\n").unwrap();
        let read = Block::ToolUse {
            id: "r".into(),
            name: "Read".into(),
            input: json!({ "file_path": "calc.py" }),
        };
        let edit = Block::ToolUse {
            id: "e".into(),
            name: "Edit".into(),
            input: json!({ "file_path": "calc.py", "old_string": "a - b", "new_string": "a + b" }),
        };
        let script = vec![
            reply(vec![read], Stop::ToolUse),
            reply(vec![edit], Stop::ToolUse),
            reply(vec![text("fixed")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, None, dir.clone());
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "fix add".into(),
            })
            .unwrap();
        let preview = loop {
            if let Event::PermissionRequest { id, preview, .. } =
                h.events.recv().await.unwrap().event
            {
                h.ops
                    .send(Op::Permission {
                        id,
                        decision: Decision::Allow,
                    })
                    .unwrap();
                break preview;
            }
        };
        let preview = preview.expect("edit should carry a preview");
        assert_eq!((preview.added, preview.removed), (1, 1));
        // Nothing was written before the answer.
        let evs = until_idle(&mut h).await;
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
        assert!(
            std::fs::read_to_string(dir.join("calc.py"))
                .unwrap()
                .contains("a + b")
        );
    }

    #[tokio::test]
    async fn rewind_restores_files_and_branches_the_conversation() {
        let dir = tmp_store();
        let ws = tmp_store();
        let write = Block::ToolUse {
            id: "w".into(),
            name: "Write".into(),
            input: json!({ "file_path": "notes.txt", "content": "v1\n" }),
        };
        let edit = Block::ToolUse {
            id: "e".into(),
            name: "Edit".into(),
            input: json!({ "file_path": "notes.txt", "old_string": "v1", "new_string": "v2" }),
        };
        let script = vec![
            reply(vec![write], Stop::ToolUse),
            reply(vec![text("created")], Stop::End),
            reply(vec![edit], Stop::ToolUse),
            reply(vec![text("edited")], Stop::End),
        ];
        let mut h = engine_with(script, false, Some(dir.clone()), None, None, ws.clone());
        // Headless engines deny edits, so run this one in yolo.
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops.send(Op::SetMode { mode: Mode::Yolo }).unwrap();
        let evs = until_idle(&mut h).await;
        let sid = evs[0].session.clone();
        h.ops
            .send(Op::Submit {
                text: "create notes".into(),
            })
            .unwrap();
        until_idle(&mut h).await;
        h.ops
            .send(Op::Submit {
                text: "bump notes".into(),
            })
            .unwrap();
        until_idle(&mut h).await;
        shutdown(h).await;
        let file = ws.join("notes.txt");
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "v2\n");

        let r = session::rewind(&dir, &sid, 2).unwrap();
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "v1\n");
        let branch = session::load(&dir, &r.session).unwrap();
        assert_eq!(branch.last_turn(), 1, "the branch ends after turn 1");

        session::rewind(&dir, &sid, 1).unwrap();
        assert!(!file.exists(), "a file created in turn 1 is removed");
    }

    #[tokio::test]
    async fn rewind_in_a_git_repo_undoes_shell_commands_too() {
        let dir = tmp_store();
        let ws = tmp_store();
        let git = |args: &[&str]| {
            assert!(
                std::process::Command::new("git")
                    .arg("-C")
                    .arg(&ws)
                    .args(args)
                    .status()
                    .unwrap()
                    .success()
            )
        };
        std::fs::write(ws.join("keep.txt"), "original\n").unwrap();
        git(&["init", "-q"]);
        git(&["add", "-A"]);
        git(&[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "-qm",
            "init",
        ]);

        let bash = Block::ToolUse {
            id: "b".into(),
            name: "Bash".into(),
            input: json!({ "command": "echo junk > made.txt && echo changed > keep.txt" }),
        };
        let script = vec![
            reply(vec![bash], Stop::ToolUse),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_with(script, false, Some(dir.clone()), None, None, ws.clone());
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops.send(Op::SetMode { mode: Mode::Yolo }).unwrap();
        let sid = until_idle(&mut h).await[0].session.clone();
        h.ops
            .send(Op::Submit {
                text: "make a mess".into(),
            })
            .unwrap();
        until_idle(&mut h).await;
        shutdown(h).await;
        assert!(ws.join("made.txt").exists());

        session::rewind(&dir, &sid, 1).unwrap();
        assert!(
            !ws.join("made.txt").exists(),
            "files a command created are removed"
        );
        assert_eq!(
            std::fs::read_to_string(ws.join("keep.txt")).unwrap(),
            "original\n"
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
