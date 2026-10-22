//! The agent loop. Runs as a background task; clients drive it with [`Op`]s and receive
//! [`Envelope`]s. See `protocol.rs` for the event lifecycle.

use crate::config::{Config, Profile, ProviderKind, Thinking, ToolMode};
use crate::context::{self, Estimator};
use crate::harness::{self, Caps, Tier};
use crate::message::{Block, Message, Role, Usage};
use crate::prompt;
use crate::protocol::{
    CallTiming, Decision, Delta, EndReason, EngineError, Envelope, Event, Item, ItemKind, Level,
    Mode, Op, Status, ToolOutcome, ToolTiming, TurnTiming, TurnUsage,
};
use crate::provider::{
    HttpError, Provider, Request, Response, Stop, StreamError, StreamEvent, ToolSpec, new_id,
};
use crate::session::{self, Header, Log, Record};
use crate::text_filter::TagFilter;
use crate::thinking;
use crate::tools::{self, Ctx, Kind};
use anyhow::Result;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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

/// The 2nd identical tool call in one turn gets its earlier result back with a nudge…
const LOOP_NUDGE: u32 = 2;
/// …the 3rd and 5th also get a re-plan message listing what's been tried…
const LOOP_REPLAN: u32 = 3;
/// …and at this count the turn stops. opencode saw a sub-agent make 364 identical greps.
const LOOP_STOP: u32 = 6;
/// Re-plans in a row, with no new distinct call in between, before the turn stops.
const LOOP_STALE_REPLANS: u32 = 3;
/// Distinct calls a re-plan message lists.
const LOOP_RECENT: usize = 8;

/// Tools whose result for the same arguments only changes when something else changes the
/// world, so an earlier result can stand in for a repeat.
fn replayable(name: &str) -> bool {
    matches!(name, "Read" | "Grep" | "Glob")
}

/// Per-turn record of repeated tool calls. Pure bookkeeping: no model calls.
#[derive(Default)]
struct LoopGuard {
    /// Times each exact call (name + input) was made this turn.
    counts: HashMap<String, u32>,
    /// The last good result of each replayable call.
    last: HashMap<String, String>,
    /// Distinct calls this turn, oldest first, as "Name arg".
    recent: Vec<String>,
    /// Re-plans since the last call that was new to this turn.
    stale_replans: u32,
}

impl LoopGuard {
    fn note_recent(&mut self, label: String) {
        self.recent.retain(|l| *l != label);
        self.recent.push(label);
    }

    /// The system-side message asking the model to change course.
    fn replan(&self, repeated: &str, times: u32) -> String {
        let tried: Vec<String> = self
            .recent
            .iter()
            .rev()
            .take(LOOP_RECENT)
            .rev()
            .map(|l| format!("- {l}"))
            .collect();
        format!(
            "[frog] You have made the same call ({repeated}) {times} times this turn and got the \
same result each time. Calls tried this turn (duplicates removed):\n{}\n\
Before your next call, state in one sentence what you still need to learn and your next step. Then \
use a different tool or different arguments; repeating this call will not give a different answer.",
            tried.join("\n")
        )
    }
}

/// What to tell the model when it repeats a call whose earlier `result` it already has.
fn repeat_nudge(name: &str, input: &Value, result: &str, times: u32) -> String {
    let lead = format!(
        "(Repeat #{times} of this exact call; this is the earlier result, not a fresh run.)"
    );
    match name {
        "Read" => {
            let numbered: Vec<usize> = result
                .lines()
                .filter_map(|l| l.split_once('\t')?.0.trim().parse().ok())
                .collect();
            let more = result
                .lines()
                .rev()
                .find(|l| l.starts_with('…') && l.contains("more lines"));
            match (numbered.first(), numbered.last(), more) {
                (Some(a), Some(b), Some(_)) => format!(
                    "{lead} That Read showed lines {a}-{b} only, and the file continues. Re-reading \
returns the same slice. Use offset={} (with a limit) to read the next part, or Grep for the part you need.",
                    b + 1
                ),
                (Some(a), Some(b), None) => format!(
                    "{lead} That Read showed lines {a}-{b}, which is all of what it asked for. Act on it, or Grep for something specific."
                ),
                _ => format!("{lead} Change offset/limit or the path, or Grep for what you need."),
            }
        }
        "Grep" | "Glob" => format!(
            "{lead} The same pattern gives the same matches. Change the pattern or path, or Read one of these files."
        ),
        _ => {
            let _ = input;
            format!("{lead} Change the arguments or try a different approach.")
        }
    }
}
/// Model calls per top-level turn: uncapped unless `FROG_MAX_STEPS` sets one. Runaway loops are
/// caught by the repeat guard above, so long agentic work can run to completion.
fn max_steps() -> u32 {
    std::env::var("FROG_MAX_STEPS").ok().and_then(|v| v.parse().ok()).unwrap_or(u32::MAX)
}
/// How many times a turn carries on after a reply runs out of output room.
const MAX_CONTINUES: u32 = 3;
/// Output budget requested from hosted APIs that don't set their own: well within what current
/// frontier and open models accept, and far above the defaults that cut thinking short.
const CLOUD_MAX_OUTPUT: u32 = 16_384;

/// How a batch of tool calls ended.
#[derive(PartialEq)]
enum Batch {
    Continue,
    Denied,
    Looping,
}

const COMPACT_PROMPT: &str = "Your context window is nearly full. Write a detailed summary of this conversation \
so work can continue from it alone. A terse summary loses the thread of a long working session, so be thorough — \
cover the whole session, not just the last few turns. Structure it under these headings, in order: \
1. Task: the user's goal and constraints. \
2. Done: work completed, with file paths. \
3. Decisions: choices made and why, including rejected alternatives. \
4. Code details: types, functions, constants, signatures and test names likely to matter for the next step. \
5. Errors: failures hit and how they were fixed. \
6. In progress: the current step, half-done edits, uncommitted work. \
7. Next steps: the immediate next actions, in order. \
Keep names, paths and error text verbatim. Do not call any tools. Output only the summary.";

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
    /// A plain chat, not tied to a project: no file or shell tools, a chat system prompt.
    pub chat: bool,
}

pub struct Handle {
    pub ops: mpsc::UnboundedSender<Op>,
    pub events: mpsc::UnboundedReceiver<Envelope>,
}

/// State the op router touches while a turn is running.
struct Shared {
    cancel: Mutex<CancellationToken>,
    pending: Mutex<HashMap<String, oneshot::Sender<Decision>>>,
    /// Open `Ask` questions, answered by `Op::Answer`.
    questions: Mutex<HashMap<String, oneshot::Sender<crate::protocol::Answer>>>,
    /// A client shows questions to someone who can answer (`SetClientCaps { ask }`).
    client_ask: AtomicBool,
    /// Session tools the client answers (`SetClientCaps { sessions }`).
    sessions: crate::tools::sessions::Hub,
    /// Connected MCP servers, for elicitation answers and app tool calls mid-turn.
    mcp: Mutex<Option<crate::mcp::Hub>>,
    /// Running subagents by `Task` tool call id, so a client can stop one.
    subagents: Mutex<HashMap<String, CancellationToken>>,
    /// Set (under the lock) just before the first `Idle`; until then the router answers
    /// `Subscribe` itself.
    ready: Mutex<bool>,
    journal: Arc<Journal>,
    /// Terminal and preview panes, driven by the router so they work mid-turn.
    panes: Arc<crate::panes::Panes>,
    /// The agent is handling an op (a turn, mostly); the router drops `Warm` meanwhile.
    working: AtomicBool,
    /// Background tasks, jobs and monitors (see `background`).
    bg: Arc<crate::background::Registry>,
}

/// Event numbering and the session log. Shared, so events raised outside the agent loop (MCP
/// callbacks, panes) get the same seq and, when durable, land in the log too.
struct Journal {
    /// Taken when the agent stops, so the event stream closes even though the router (and
    /// the panes) still hold the journal.
    events: Mutex<Option<mpsc::UnboundedSender<Envelope>>>,
    seq: AtomicU64,
    session: Mutex<String>,
    store: Option<PathBuf>,
    /// Opened lazily on the first durable write, so idle launches leave no files behind.
    log: Mutex<Option<Log>>,
    /// For the header: cwd and model name.
    header: Mutex<(PathBuf, String)>,
    /// The current turn's streaming events (text as it arrives, progress), beside the log as
    /// `<id>.live`, so another process following this session sees it live. Reset each turn.
    live: Mutex<Option<(String, std::fs::File)>>,
}

impl Journal {
    fn new(events: mpsc::UnboundedSender<Envelope>, store: Option<PathBuf>) -> Self {
        Self {
            events: Mutex::new(Some(events)),
            seq: AtomicU64::new(0),
            session: Mutex::new(String::new()),
            store,
            log: Mutex::new(None),
            header: Mutex::new((PathBuf::new(), String::new())),
            live: Mutex::new(None),
        }
    }

    fn session(&self) -> String {
        self.session.lock().unwrap().clone()
    }

    /// Switch to a session (new or resumed), with its log if already open.
    fn start_session(&self, id: String, seq: u64, log: Option<Log>) {
        *self.session.lock().unwrap() = id;
        self.seq.store(seq, Ordering::Relaxed);
        *self.log.lock().unwrap() = log;
    }

    fn has_log(&self) -> bool {
        self.log.lock().unwrap().is_some()
    }

    /// Append a record to the session log, creating the log on first use. An error means the
    /// session is no longer being saved.
    fn record(&self, rec: Record) -> std::result::Result<(), String> {
        let Some(dir) = &self.store else {
            return Ok(());
        };
        let mut log = self.log.lock().unwrap();
        if log.is_none() {
            let (cwd, model) = self.header.lock().unwrap().clone();
            let header = Header {
                version: session::VERSION,
                id: self.session(),
                cwd,
                model,
                created: now_ms(),
                forked_from: None,
            };
            match Log::create(dir, header) {
                Ok(l) => *log = Some(l),
                Err(e) => return Err(format!("session won't be saved: {e:#}")),
            }
        }
        if let Some(Err(e)) = log.as_mut().map(|l| l.append(&rec)) {
            *log = None;
            return Err(format!("session log write failed, no longer saving: {e:#}"));
        }
        Ok(())
    }

    fn sync(&self) {
        if let Some(l) = self.log.lock().unwrap().as_ref() {
            let _ = l.sync();
        }
    }

    fn emit(&self, event: Event) {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed) + 1;
        let env = Envelope {
            seq,
            session: self.session(),
            created: now_ms(),
            event,
        };
        if env.event.is_durable()
            && let Err(message) = self.record(Record::Event { env: env.clone() })
        {
            self.emit(Event::Notice {
                level: Level::Warn,
                message,
            });
        }
        self.live(&env);
        self.send(env);
    }

    /// Mirror an event into the session's live file (see `live`). Best effort: following a
    /// session is a view, never a reason to fail the turn.
    fn live(&self, env: &Envelope) {
        let Some(dir) = &self.store else { return };
        if self.log.lock().unwrap().is_none() {
            return;
        }
        let mut live = self.live.lock().unwrap();
        let fresh = matches!(env.event, Event::TurnStarted { .. });
        if fresh || live.as_ref().is_none_or(|(id, _)| *id != env.session) {
            *live = std::fs::File::create(session::live_path(dir, &env.session))
                .ok()
                .map(|f| (env.session.clone(), f));
        }
        if let Some((_, f)) = live.as_mut()
            && let Ok(mut line) = serde_json::to_vec(env)
        {
            use std::io::Write;
            line.push(b'\n');
            let _ = f.write_all(&line);
        }
    }

    fn send(&self, env: Envelope) {
        if let Some(tx) = self.events.lock().unwrap().as_ref() {
            let _ = tx.send(env);
        }
    }

    /// Close the event stream and release the session log (its lock), for good.
    fn close(&self) {
        self.sync();
        self.log.lock().unwrap().take();
        self.events.lock().unwrap().take();
    }
}

/// Start the engine. It emits `Status` then `Idle` once ready, and exits after `Op::Shutdown`
/// (or when every `ops` sender is dropped), closing the event stream.
pub fn spawn(opts: Options) -> Result<Handle> {
    crate::policy::check(&opts.cwd, &opts.profile_name, &opts.profile)?;
    let provider = Provider::new(&opts.profile)?.with_cwd(&opts.cwd);
    start(opts, provider)
}

/// Start a subagent's engine. Tests script it via `tests::child_script`.
pub(crate) fn spawn_child(opts: Options) -> Result<Handle> {
    #[cfg(test)]
    if let Some(script) = tests::child_script(&opts.cwd) {
        return start(
            opts,
            Provider::Scripted(crate::provider::scripted::Client::new(script)),
        );
    }
    spawn(opts)
}

fn start(opts: Options, provider: Provider) -> Result<Handle> {
    let (op_tx, mut op_rx) = mpsc::unbounded_channel::<Op>();
    let (ev_tx, ev_rx) = mpsc::unbounded_channel();
    let (work_tx, mut work_rx) = mpsc::unbounded_channel::<Op>();
    let journal = Arc::new(Journal::new(ev_tx, opts.store.clone()));
    let panes = {
        let j = journal.clone();
        crate::panes::Panes::new(move |e| j.emit(e))
    };
    let shared = Arc::new(Shared {
        cancel: Default::default(),
        pending: Default::default(),
        questions: Default::default(),
        client_ask: Default::default(),
        sessions: Default::default(),
        mcp: Default::default(),
        subagents: Default::default(),
        ready: Default::default(),
        working: Default::default(),
        bg: {
            let j = journal.clone();
            crate::background::Registry::new(move |e| j.emit(e))
        },
        journal,
        panes,
    });
    shared.bg.set_wake(&work_tx);
    let mut agent = Agent::new(opts, provider, shared.clone())?;
    // What's running, before anything slow (MCP servers, a local model loading, probing the
    // provider), so a client can name the model as soon as a conversation opens.
    agent.emit_status();
    // A resumed session's log, for answering `Subscribe` while the engine starts up.
    let resumed = match (&agent.store, shared.journal.has_log()) {
        (Some(dir), true) => Some((dir.clone(), agent.session_id.clone())),
        _ => None,
    };

    let router = shared.clone();
    tokio::spawn(async move {
        while let Some(op) = op_rx.recv().await {
            if router.panes.handle(&op) {
                continue;
            }
            match op {
                // Replaying the log needs nothing that starting up does, so a reopened
                // conversation's transcript doesn't wait on it. Holding `ready` keeps the whole
                // replay ahead of the first `Idle`, and so of any turn; once started up, the
                // agent answers, in order with its turns.
                Op::Subscribe { after } if resumed.is_some() => {
                    let ready = router.ready.lock().unwrap();
                    let Some((dir, id)) = resumed.as_ref().filter(|_| !*ready) else {
                        drop(ready);
                        if work_tx.send(op).is_err() {
                            break;
                        }
                        continue;
                    };
                    let journal = &router.journal;
                    for env in session::events_after(dir, id, after).unwrap_or_default() {
                        journal.send(env);
                    }
                    let upto = journal.seq.load(Ordering::Relaxed);
                    journal.emit(Event::Synced { upto });
                }
                Op::Interrupt => {
                    router.cancel.lock().unwrap().cancel();
                    router.bg.stop_all();
                }
                // Mid-turn the server is busy with the turn itself, which leaves it warm.
                Op::Warm { .. } if router.working.load(Ordering::Relaxed) => {}
                // Stopping mid-turn ends the turn first (cancelled, and logged as such), rather
                // than waiting behind it: a client that stops an engine gives it about a second
                // before killing it, and a turn cut off there would stay open in the log.
                Op::Shutdown => {
                    router.cancel.lock().unwrap().cancel();
                    router.bg.stop_all();
                    if work_tx.send(Op::Shutdown).is_err() {
                        break;
                    }
                }
                Op::Permission { id, decision } => {
                    if let Some(tx) = router.pending.lock().unwrap().remove(&id) {
                        let _ = tx.send(decision);
                    } else {
                        router.bg.answer(&id, decision);
                    }
                }
                Op::Answer { id, answer } => {
                    if let Some(tx) = router.questions.lock().unwrap().remove(&id) {
                        let _ = tx.send(answer);
                    }
                }
                Op::SessionReply { id, result, error } => {
                    router.sessions.resolve(&id, result, error)
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
        if agent.profile.provider == ProviderKind::Codex
            && let Err(e) = crate::provider::codex::check_available().await
        {
            agent.notice(Level::Warn, format!("{e:#}"));
            agent.emit_status();
        }
        agent.connect_mcp();
        agent.resolve_window().await;
        agent.emit_status();
        {
            let mut ready = shared.ready.lock().unwrap();
            *ready = true;
            agent.emit(Event::Idle);
        }
        // Only seconds spent waiting for the user count toward the idle baseline: not startup
        // (MCP servers, a model loading), and not any op's work.
        agent.meter_busy(false);
        loop {
            let op = tokio::select! {
                op = work_rx.recv() => op,
                result = agent.mcp_ready() => {
                    if let Some((_name, delta)) = result {
                        agent.mcp_ready_queue.push((_name, delta));
                    } else {
                        agent.mcp_pending = None;
                    }
                    agent.emit_status();
                    continue;
                }
            };
            let Some(op) = op else { break };
            agent.poll_mcp();
            if let Op::Shutdown = op {
                break;
            }
            // In the background, and not an op the client waits on: no `Idle` after it.
            if let Op::Warm { draft } = op {
                agent.warm(draft.as_deref());
                continue;
            }
            // A wake whose notices an earlier turn already took.
            if matches!(op, Op::Wake) && !shared.bg.has_notices() {
                continue;
            }
            shared.working.store(true, Ordering::Relaxed);
            agent.meter_busy(true);
            let token = CancellationToken::new();
            *shared.cancel.lock().unwrap() = token.clone();
            let r = tokio::select! {
                r = agent.handle(op) => r,
                _ = token.cancelled() => Err(Interrupted.into()),
            };
            shared.pending.lock().unwrap().clear();
            // A question still open when the turn ends (interrupted) was dismissed; say so,
            // so clients put the card away.
            let open: Vec<String> = shared
                .questions
                .lock()
                .unwrap()
                .drain()
                .map(|(id, _)| id)
                .collect();
            for id in open {
                agent.emit(Event::QuestionResolved {
                    id,
                    answer: Default::default(),
                });
            }
            shared.panes.set_in_turn(false);
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
            shared.working.store(false, Ordering::Relaxed);
            agent.emit_status();
            agent.emit(Event::Idle);
            agent.meter_busy(false);
        }
        shared.bg.stop_all();
        agent.mcp.shutdown();
        shared.mcp.lock().unwrap().take();
        shared.panes.shutdown();
        agent.sync_log();
        agent.write_summary();
        shared.journal.close();
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
    if let Some(s) = e.downcast_ref::<StreamError>() {
        return EngineError::Provider {
            status: 502,
            message: s.message.clone(),
        };
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
    // An in-stream error event (the stream ended before the terminal chunk, the upstream was
    // overloaded or timed out) is the same class of trouble as a 5xx: worth another try.
    if e.downcast_ref::<StreamError>().is_some() {
        return true;
    }
    // Same for a stream that just ended without saying it was done.
    if e.is::<IncompleteStream>() {
        return true;
    }
    e.chain()
        .filter_map(|c| c.downcast_ref::<reqwest::Error>())
        .any(|r| r.is_timeout() || (r.is_request() && !r.is_connect()))
}

/// frog's local model server answers (it listens on 127.0.0.1:8911 when running).
fn local_server_up() -> bool {
    std::net::TcpStream::connect_timeout(
        &std::net::SocketAddr::from(([127, 0, 0, 1], 8911)),
        Duration::from_millis(200),
    )
    .is_ok()
}

pub(crate) fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// Items opened while streaming one model response.
/// A warm-up request on its way to the server (see `Agent::warm`).
type Warming = std::pin::Pin<Box<dyn std::future::Future<Output = Result<()>> + Send>>;

/// A model call's request in the current tool mode (see `Engine::wire`).
struct Wire {
    system: String,
    /// The messages, when the tool mode or images changed them.
    messages: Option<Vec<Message>>,
    /// Tools go as native specs (else they're described in the system prompt).
    native_tools: bool,
    /// JSON schema the reply must match.
    format: Option<Value>,
}

impl Wire {
    fn messages<'a>(&'a self, original: &'a [Message]) -> &'a [Message] {
        self.messages.as_deref().unwrap_or(original)
    }
}

#[derive(Default)]
struct Streamed {
    message: Option<String>,
    reasoning: Option<String>,
    /// The reply didn't follow the requested tool-call format.
    format_failed: bool,
    /// Request sent → first streamed event, and first event → done (the attempt that succeeded).
    ttft: Duration,
    decode: Duration,
    /// Reasoning streamed before the first answer text or tool call.
    think: Duration,
    /// Thinking was switched off for this call.
    no_think: bool,
    /// The reasoning-token cap sent with this call.
    think_budget: Option<u32>,
    /// How this request compares with the one sent before it (see [`CallTiming::extends`]).
    extends: Option<bool>,
    reusable: Option<f64>,
    /// Read-only tool calls started while the reply streamed (see `early`).
    early: crate::early::Early,
}

/// A request as a server's prompt cache sees it, flattened: the system prompt, the tools, then
/// the messages as JSON. A request that only appends to an earlier one starts with that one's
/// text, less the closing `]`.
fn flatten(system: &str, tools: &[ToolSpec], messages: &[Message]) -> String {
    let mut s = system.to_string();
    for t in tools {
        s.push_str(&t.name);
        s.push_str(&t.description);
        s.push_str(&t.schema.to_string());
    }
    s.push_str(&serde_json::to_string(messages).unwrap_or_default());
    s
}

/// Whether `cur` only appends to `prev` (both [`flatten`]ed), and the share of `cur` that
/// repeats the start of `prev`. Nothing to compare with when `prev` is empty.
fn reuse(prev: &str, cur: &str) -> (Option<bool>, Option<f64>) {
    if prev.is_empty() || cur.is_empty() {
        return (None, None);
    }
    let shared = prev
        .bytes()
        .zip(cur.bytes())
        .take_while(|(a, b)| a == b)
        .count();
    let extends = cur.starts_with(prev.strip_suffix(']').unwrap_or(prev));
    (Some(extends), Some(shared as f64 / cur.len() as f64))
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
    chat: bool,
    store: Option<PathBuf>,
    usage: Usage,
    last_call: Duration,
    session_id: String,
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
    /// A Tang sidecar loads its weights on its first completion request. Keep that visible until
    /// the first response arrives, then regular request activity takes over.
    model_ready: bool,
    /// Model calls in a row this turn with thinking switched off.
    quiet: u32,
    /// Running totals for the current turn.
    turn_usage: TurnUsage,
    /// Where the current turn's time went, and when it started.
    timing: TurnTiming,
    turn_clock: Option<Instant>,
    /// The last request sent to this conversation's server cache (a model call or a warm-up),
    /// [`flatten`]ed, to tell whether the next one only appends to it.
    sent: Mutex<String>,
    /// The power meter, with `--energy`, and where this turn started on it (with the idle
    /// power to subtract).
    meter: Option<crate::energy::Meter>,
    energy_mark: Option<(crate::energy::Mark, Option<f64>)>,
    root: PathBuf,
    system: String,
    specs: Vec<ToolSpec>,
    /// Connected MCP servers, whose tools are appended to `specs`.
    mcp: crate::mcp::Hub,
    /// Per-server completion events from concurrent MCP connection attempts.
    mcp_pending: Option<tokio::sync::mpsc::UnboundedReceiver<(String, crate::mcp::Hub)>>,
    /// Completed MCP deltas queued until the next turn boundary.
    mcp_ready_queue: Vec<(String, crate::mcp::Hub)>,
    /// Agent Skills found for this project, and the ones already loaded this session.
    skills: std::collections::BTreeMap<String, crate::skills::Skill>,
    skills_loaded: HashSet<String>,
    /// The user's memory notes (none for subagents or in-memory engines), loaded when the
    /// session starts and after `/remember` or `/forget`, so the system prompt stays put.
    memory: Option<crate::memory::Store>,
    notes: Vec<crate::memory::Note>,
    /// Notes that didn't fit the current model's index.
    notes_omitted: usize,
    /// Rule files for this project, and the scoped ones already shown this session.
    rules: Vec<crate::rules::Rule>,
    rules_seen: HashSet<PathBuf>,
    /// The ranked repo map in the system prompt (small and mid-size models only), rebuilt
    /// between turns when files change.
    repo_map: crate::repomap::Map,
    map_build_tx: std::sync::mpsc::Sender<(crate::repomap::Map, bool)>,
    map_build_rx: Mutex<std::sync::mpsc::Receiver<(crate::repomap::Map, bool)>>,
    map_building: bool,
    /// Whether the session log holds the current `repo_map`.
    map_logged: bool,
    /// Files edited this session, relative to the root, for ranking the map.
    edited: Vec<String>,
    /// The model can see images (probed, or `vision` in the profile).
    vision: bool,
    /// The server takes a per-call reasoning budget (probed).
    budget_ok: bool,
    /// The server keeps a prompt cache per conversation, keyed by the session id (probed).
    cache_key_ok: bool,
    /// The server can prefill a conversation without answering (probed).
    prefill_ok: bool,
    /// A warm-up is running, and the one to send after it (see `warm`).
    warming: Arc<Mutex<(bool, Option<Warming>)>>,
    /// Auto mode's classifier, started on first use.
    classifier: Option<crate::auto::Classifier>,
    session_allow: HashSet<String>,
    /// Context from `Op::Shell`, attached to the next message.
    pending: Vec<String>,
    shared: Arc<Shared>,
}

impl Agent {
    fn new(o: Options, provider: Provider, shared: Arc<Shared>) -> Result<Self> {
        // Cached or shipped capability profiles are useful in both persisted and in-memory engines.
        let caps = (!harness::is_hosted(&o.profile))
            .then(|| harness::cached(&o.profile))
            .flatten();
        let tier = harness::tier(&o.profile, caps.as_ref());
        let tool_mode = harness::choose_mode(&o.profile, caps.as_ref(), tier);
        let system = format!(
            "{}{}",
            prompt::system_prompt(&o.cwd, &o.cfg, &o.profile.model),
            harness::guidance(tier)
        );
        // Panes open when the session was last saved, to close in the log (their shells died
        // with that process) so a resumed client doesn't expect them.
        let mut stale_panes: Vec<String> = Vec::new();
        let mut resumed_map = None;
        let (session_id, messages, seq, turn, log, inputs, unfinished) = match (&o.resume, &o.store)
        {
            (Some(id), Some(dir)) => {
                let l = session::load(dir, id).map_err(|e| ConfigError(format!("{e:#}")))?;
                let log = Log::open(dir, id).map_err(|e| ConfigError(format!("{e:#}")))?;
                let (seq, turn) = (l.last_seq(), l.last_turn());
                resumed_map = l.repo_map.clone();
                let inputs = l
                    .events
                    .iter()
                    .filter_map(|e| match &e.event {
                        Event::TurnStarted { input, .. } => Some(input.clone()),
                        _ => None,
                    })
                    .collect();
                let mut used = Vec::new();
                for e in &l.events {
                    match &e.event {
                        Event::PaneOpened { id, .. } => {
                            used.push(id.clone());
                            stale_panes.push(id.clone());
                        }
                        Event::PaneClosed { id, .. } => stale_panes.retain(|p| p != id),
                        _ => {}
                    }
                }
                shared.panes.seed_ids(used);
                // A turn that started and never ended: the engine died or was killed mid-turn.
                let unfinished = l.events.iter().rev().find_map(|e| match &e.event {
                    Event::TurnEnded { .. } => Some(None),
                    Event::TurnStarted { turn, .. } => Some(Some(*turn)),
                    _ => None,
                });
                (
                    id.clone(),
                    l.messages,
                    seq,
                    turn,
                    Some(log),
                    inputs,
                    unfinished.flatten(),
                )
            }
            (Some(_), None) => {
                anyhow::bail!(ConfigError("can't resume without a session store".into()))
            }
            (None, _) => (session::new_id(), Vec::new(), 0, 0, None, Vec::new(), None),
        };
        *shared.journal.header.lock().unwrap() = (o.cwd.clone(), o.profile_name.clone());
        shared.journal.start_session(session_id.clone(), seq, log);
        for id in stale_panes {
            shared.journal.emit(Event::PaneClosed { id, exit: None });
        }
        let skills = if o.subagent {
            Default::default()
        } else {
            crate::skills::discover_in(&o.cwd, !o.cfg.hermetic)
        };
        let memory = match (&o.store, o.subagent) {
            (Some(store), false) => Some(crate::memory::Store::new(
                &memory_root(store),
                (!o.chat).then_some(o.cwd.as_path()),
            )),
            // A subagent has no session store, but reads the same notes and summaries
            // for `Recall`.
            (None, true) => Some(crate::memory::Store::new(
                &crate::memory::default_root(),
                Some(o.cwd.as_path()),
            )),
            _ => None,
        };
        let notes = memory.as_ref().map(|m| m.load()).unwrap_or_default();
        let rules = if o.chat {
            Vec::new()
        } else {
            crate::rules::discover(&o.cwd)
        };
        let shell_sandbox = o.cfg.sandbox_shell && tools::bash::available() && !o.chat;
        let window = o.profile.context_window();
        let web = Arc::new(tools::web::Web::from_config(&o.cfg));
        let image = o.cfg.image.clone();
        let screenshot_endpoint = o.cfg.screenshot_endpoint.clone();
        let judge = Some(match &o.cfg.compare_model {
            Some(model) => o.cfg.resolve(Some(model))?.1,
            None => o.profile.clone(),
        });
        let resumed = o.resume.is_some();
        let sandbox_extra = o.cfg.sandbox.clone();
        let shell_root = o.cwd.canonicalize().unwrap_or_else(|_| o.cwd.clone());
        shared.panes.configure(o.cwd.clone());
        let (map_build_tx, map_build_rx) = std::sync::mpsc::channel();
        let mut agent = Self {
            cfg: o.cfg,
            profile_name: o.profile_name,
            profile: o.profile,
            provider,
            messages,
            ctx: {
                let mut ctx = Ctx::new(o.cwd.clone());
                ctx.web = web;
                ctx.image = image;
                ctx.screenshot_endpoint = screenshot_endpoint;
                ctx.judge = judge;
                ctx.sandbox_extra = sandbox_extra;
                if o.sandbox {
                    ctx.sandbox = Some(o.cwd.canonicalize().unwrap_or_else(|_| o.cwd.clone()));
                }
                if shell_sandbox {
                    ctx.shell_sandbox = Some(shell_root);
                }
                ctx
            },
            mode: o.mode,
            can_ask: o.can_ask,
            rich: o.rich,
            subagent: o.subagent,
            chat: o.chat,
            store: o.store,
            usage: Usage::default(),
            last_call: Duration::ZERO,
            session_id,
            turn,
            active_turn: None,
            window,
            est: Estimator::default(),
            inputs,
            tool_mode,
            tier,
            caps,
            mode_failures: 0,
            model_ready: false,
            quiet: 0,
            turn_usage: TurnUsage::default(),
            timing: TurnTiming::default(),
            turn_clock: None,
            sent: Mutex::default(),
            meter: None,
            energy_mark: None,
            root: o.cwd,
            system,
            specs: tools::specs(),
            mcp: crate::mcp::Hub::empty(),
            mcp_pending: None,
            mcp_ready_queue: Vec::new(),
            skills,
            skills_loaded: HashSet::new(),
            memory,
            notes,
            notes_omitted: 0,
            rules,
            rules_seen: HashSet::new(),
            repo_map: Default::default(),
            map_build_tx,
            map_build_rx: Mutex::new(map_build_rx),
            map_building: false,
            map_logged: false,
            edited: Vec::new(),
            classifier: None,
            vision: false,
            budget_ok: false,
            cache_key_ok: false,
            prefill_ok: false,
            warming: Default::default(),
            session_allow: HashSet::new(),
            pending: Vec::new(),
            shared,
        };
        if resumed {
            // A session that died mid-turn may have dangling tool calls, and a turn that never
            // ended: end it, cancelled, so clients don't show it running forever.
            agent.repair();
            if let Some(turn) = unfinished {
                agent.end_turn(turn, EndReason::Cancelled);
            }
        }
        agent.sync_specs();
        // A resumed session keeps the map it last sent: one rebuilt from the files as they are
        // now would rewrite the prompt the server has cached, after any edit.
        match resumed_map {
            Some(map) => {
                agent.repo_map = map;
                agent.map_logged = true;
            }
            None => agent.refresh_repo_map(&[]),
        }
        agent.apply_harness();
        if agent.cfg.energy && !agent.subagent {
            agent.meter = crate::energy::Meter::new();
            agent.meter_busy(true);
        }
        Ok(agent)
    }

    // ---- persistence ----

    /// Append a record to the session log, creating the log on first use.
    fn record(&self, rec: Record) {
        if let Err(message) = self.shared.journal.record(rec) {
            self.notice(Level::Warn, message);
        }
    }

    fn sync_log(&self) {
        self.shared.journal.sync();
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
        self.shared.journal.emit(event);
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
            vision: self.vision,
        }));
    }

    fn count_call(&mut self, u: Usage, streamed: &Streamed, compact: bool) {
        self.turn_usage.input_tokens += u.input + u.cache_read;
        self.turn_usage.output_tokens += u.output;
        self.turn_usage.model_calls += 1;
        if let Some(model) = &u.model {
            self.turn_usage.model = Some(model.clone());
        }
        let (ttft, decode, think) = (ms(streamed.ttft), ms(streamed.decode), ms(streamed.think));
        let t = &mut self.timing;
        if compact {
            t.compact_ms += ttft + decode;
        } else {
            t.prefill_ms += ttft;
            t.decode_ms += decode;
            t.think_ms += think;
        }
        t.calls.push(CallTiming {
            prompt_tokens: u.input + u.cache_read,
            cached_tokens: u.cache_read,
            extends: streamed.extends,
            reusable: streamed.reusable,
            output_tokens: u.output,
            ttft_ms: ttft,
            decode_ms: decode,
            think_ms: think,
            no_think: streamed.no_think,
            think_budget: streamed.think_budget,
            compact,
        });
    }

    fn end_turn(&self, turn: u64, reason: EndReason) {
        let timing = self.turn_clock.map(|start| {
            let mut t = self.timing.clone();
            t.wall_ms = ms(start.elapsed());
            t.other_ms = t.wall_ms.saturating_sub(
                t.prefill_ms + t.decode_ms + t.tool_ms + t.user_ms + t.classifier_ms + t.compact_ms,
            );
            t
        });
        let usage = TurnUsage {
            tokens_per_sec: self.tokens_per_sec(),
            context_tokens: self.context_tokens(),
            timing,
            model: Some(self.profile_name.clone()),
            energy: self.turn_energy(),
            ..self.turn_usage.clone()
        };
        self.emit(Event::TurnEnded {
            turn,
            reason,
            usage,
        });
        self.sync_log();
        self.write_summary();
    }

    fn meter_busy(&self, busy: bool) {
        if let Some(m) = &self.meter {
            m.set_busy(busy);
        }
    }

    /// This turn's energy, when it's being measured and there was idle to measure against.
    fn turn_energy(&self) -> Option<crate::protocol::TurnEnergy> {
        let m = self.meter.as_ref()?;
        let (mark, idle) = self.energy_mark.as_ref()?;
        let reading = m.since(mark);
        let estimate = crate::harness::is_cloud(&self.profile)
            .then(|| crate::energy::cloud::for_model(&self.profile_name));
        Some(crate::protocol::TurnEnergy {
            local_wh: reading.above_idle_wh((*idle)?),
            idle_w: *idle,
            remote_wh: estimate
                .as_ref()
                .map(|e| e.wh(self.turn_usage.input_tokens, self.turn_usage.output_tokens)),
            remote_basis: estimate.as_ref().map(|e| e.basis.clone()),
            remote_source: estimate.as_ref().map(|e| e.source.to_string()),
        })
    }

    /// "Remember that …" in an ordinary message saves a note (and the turn still runs).
    fn remember_from(&mut self, text: &str) {
        if self.subagent {
            return;
        }
        let Some(note) = crate::memory::detect_remember(text) else {
            return;
        };
        let Some(store) = &self.memory else { return };
        let scope = if self.chat {
            crate::memory::Scope::Global
        } else {
            crate::memory::Scope::Project
        };
        match store.add(scope, &note) {
            Ok((saved, redacted)) => {
                let mut msg = format!("remembered as `{}`: {}", saved.id, saved.first_line());
                if !redacted.is_empty() {
                    msg.push_str(&format!(" (redacted: {})", redacted.join(", ")));
                }
                msg.push_str(" — /forget removes it");
                self.notes = store.load();
                self.apply_harness();
                self.notice(Level::Info, msg);
            }
            Err(e) => self.notice(Level::Warn, format!("couldn't save the note: {e:#}")),
        }
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
            Op::Submit { text, images } => {
                if !self.memory_command(&text) {
                    self.remember_from(&text);
                    self.turn(&text, images).await?
                }
            }
            Op::Act { label, send } => {
                let text = if send.trim().is_empty() { label } else { send };
                self.turn(&text, Vec::new()).await?
            }
            Op::Continue { note } => {
                let note = note.unwrap_or_else(|| crate::protocol::CONTINUE_NOTE.to_string());
                self.turn(&note, Vec::new()).await?
            }
            Op::Shell { command } => self.shell(&command).await,
            Op::Wake => {
                let notices = self.shared.bg.take_notices();
                if !notices.is_empty() {
                    self.turn(&notices.join("\n\n"), Vec::new()).await?
                }
            }
            Op::SetMode { mode } => {
                self.mode = mode;
                self.emit(Event::ModeChanged { mode });
            }
            Op::SetModel { spec } => self.set_model(&spec).await?,
            Op::Compact { focus } => self.compact(focus.as_deref()).await?,
            Op::Subscribe { after } => {
                let replay = match &self.store {
                    Some(dir) if self.shared.journal.has_log() => {
                        session::events_after(dir, &self.session_id, after)?
                    }
                    _ => Vec::new(),
                };
                for env in replay {
                    self.shared.journal.send(env);
                }
                self.emit(Event::Synced {
                    upto: self.shared.journal.seq.load(Ordering::Relaxed),
                });
            }
            Op::Clear => {
                self.shared.bg.stop_all();
                self.shared.bg.take_notices();
                self.sync_log();
                self.write_summary();
                self.messages.clear();
                self.inputs.clear();
                self.skills_loaded.clear();
                self.rules_seen.clear();
                self.edited.clear();
                let sandbox = self.ctx.sandbox.take();
                let shell_sandbox = self.ctx.shell_sandbox.take();
                let web = self.ctx.web.clone();
                self.ctx = Ctx::new(self.root.clone());
                self.ctx.sandbox = sandbox;
                self.ctx.shell_sandbox = shell_sandbox;
                self.ctx.web = web;
                self.ctx.image = self.cfg.image.clone();
                self.ctx.screenshot_endpoint = self.cfg.screenshot_endpoint.clone();
                self.ctx.judge = Some(match &self.cfg.compare_model {
                    Some(model) => self.cfg.resolve(Some(model))?.1,
                    None => self.profile.clone(),
                });
                self.usage = Usage::default();
                self.session_id = session::new_id();
                self.shared
                    .journal
                    .start_session(self.session_id.clone(), 0, None);
                self.turn = 0;
                self.notes = self.memory.as_ref().map(|m| m.load()).unwrap_or_default();
                self.refresh_repo_map(&[]);
                self.apply_harness();
                self.notice(Level::Info, "started a new conversation");
            }
            Op::SetTitle { title } => {
                let title: String = title.trim().chars().take(80).collect();
                if !title.is_empty() {
                    self.emit(Event::Titled { title });
                }
            }
            Op::Deliver {
                from,
                from_name,
                message,
            } => {
                let text = crate::tools::sessions::wrap(&from, &from_name, &message);
                self.turn(&text, Vec::new()).await?
            }
            Op::SetClientCaps {
                panes,
                ask,
                sessions,
            } => {
                self.shared.panes.set_client(panes);
                self.shared.client_ask.store(ask, Ordering::Relaxed);
                self.shared.sessions.set_enabled(sessions);
                self.sync_specs();
                self.apply_harness();
            }
            // Handled by the router, never queued.
            Op::Interrupt
            | Op::Permission { .. }
            | Op::Answer { .. }
            | Op::SessionReply { .. }
            | Op::Elicit { .. }
            | Op::AppCall { .. }
            | Op::StopSubagent { .. }
            | Op::PaneOpen { .. }
            | Op::PaneInput { .. }
            | Op::PaneResize { .. }
            | Op::PaneClose { .. }
            | Op::PaneReport { .. }
            | Op::PaneReply { .. }
            | Op::PaneMention { .. }
            | Op::Warm { .. }
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

    /// `@path` mentions inline the file so the model doesn't need a Read round-trip; `@element`
    /// mentions the user picked in a preview pane inline what the pane said about them.
    fn expand_mentions(&mut self, input: &str) -> String {
        let mut extra = String::new();
        for tok in input.split_whitespace().filter_map(|t| t.strip_prefix('@')) {
            let tok = tok.trim_end_matches([',', ')', ':', ';', '?', '!']);
            if let Some(context) = self.shared.panes.mention(&format!("@{tok}")) {
                extra.push_str(&format!(
                    "\n<element mention=\"@{tok}\">\n{context}\n</element>"
                ));
                continue;
            }
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

    /// Project files the user named without `@` ("calc.py has a bug"), which small models often
    /// ask the user to paste instead of reading. Below the strong tier, small text files are
    /// inlined like `@` mentions (within a slice of the window); otherwise a short note says
    /// they exist and can be Read. Returns the text to append and the files named.
    fn attach_named(&mut self, input: &str) -> (String, Vec<PathBuf>) {
        if self.chat || self.subagent {
            return (String::new(), Vec::new());
        }
        let files = crate::named_files::named(input, &self.root);
        let mut budget = if self.tier == Tier::Strong {
            0
        } else {
            (self.est.chars(self.window) / 10).min(24_000)
        };
        let (mut inlined, mut noted) = (String::new(), Vec::new());
        for path in &files {
            let mtime = std::fs::metadata(path).and_then(|m| m.modified()).ok();
            // Already inlined or read, and unchanged since.
            if self.ctx.read_files.get(path).is_some_and(|t| *t == mtime) {
                continue;
            }
            let shown = self.ctx.display(path);
            let text = std::fs::metadata(path)
                .is_ok_and(|m| budget > 0 && (m.len() as usize) <= budget)
                .then(|| std::fs::read_to_string(path).ok())
                .flatten()
                .filter(|t| !t.contains('\0'));
            match text {
                Some(text) => {
                    budget -= text.len();
                    inlined.push_str(&format!("\n<file path=\"{shown}\">\n{text}\n</file>"));
                    self.ctx.mark_read(path);
                }
                None => noted.push(shown),
            }
        }
        let mut extra = inlined;
        if !noted.is_empty() {
            extra.push_str(&format!(
                "\n(In this project: {}. Use Read to open them.)",
                noted.join(", ")
            ));
        }
        (extra, files)
    }

    /// A nudge for a reply that asked the user for code it could Read, or said it can't see
    /// files. `None` when the reply is fine, or asks for a named file that isn't here.
    fn file_nudge(&self, reply: &str, named: &[PathBuf]) -> Option<String> {
        if self.chat || !self.specs.iter().any(|s| s.name == "Read") {
            return None;
        }
        if !crate::named_files::asks_for_files(reply) {
            return None;
        }
        let mut files = crate::named_files::named(reply, &self.root);
        for p in named {
            if !files.contains(p) {
                files.push(p.clone());
            }
        }
        if files.is_empty()
            && !crate::named_files::claims_no_access(reply)
            && !crate::named_files::candidates(reply).is_empty()
        {
            return None;
        }
        let how = match files.as_slice() {
            [] => "use Glob or Grep to find the relevant files and Read to open them".to_string(),
            fs => format!(
                "use Read to open {}",
                fs.iter()
                    .map(|p| self.ctx.display(p))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        };
        Some(format!(
            "You have tools and can open this project's files yourself, so don't ask me for them: {how}, then continue with the task."
        ))
    }

    async fn turn(&mut self, input: &str, mut images: Vec<crate::protocol::Image>) -> Result<()> {
        // A completed background map can be adopted at a turn boundary. Never wait for it;
        // if it is still running, this turn proceeds with the current prompt.
        self.poll_repo_map();
        let (input, named) = crate::image_paths::attach(input);
        let input = input.as_str();
        images.extend(named);
        self.turn += 1;
        let turn = self.turn;
        self.emit(Event::TurnStarted {
            turn,
            input: input.to_string(),
            images: images.clone(),
        });
        self.active_turn = Some(turn);
        // A draft still waiting to warm is stale now; the turn itself leaves the cache warm.
        self.warming.lock().unwrap().1 = None;
        self.shared.panes.set_in_turn(true);
        self.inputs.push(input.to_string());
        self.turn_clock = Some(Instant::now());
        if let Some(m) = &self.meter {
            // Idle from the seconds spent waiting before this turn (the op loop marked it busy).
            self.energy_mark = Some((m.mark(), m.idle_estimate()));
        }
        self.timing = TurnTiming::default();
        self.quiet = 0;
        self.checkpoint(turn);
        self.turn_usage = TurnUsage::default();

        let mut text = std::mem::take(&mut self.pending).join("\n");
        // Background work that finished while this turn was queued.
        for notice in self.shared.bg.take_notices() {
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(&notice);
        }
        if !text.is_empty() {
            text.push('\n');
        }
        let typed = input.to_string();
        // `/skill-name ...` loads that skill ahead of the request.
        let input = match crate::skills::expand_command(&self.skills, input) {
            Some((expanded, name)) => {
                self.skills_loaded.insert(name);
                expanded
            }
            None => input.to_string(),
        };
        text.push_str(&self.expand_mentions(&input));
        // Only the user's own words: not skill text or shell output.
        let (extra, named) = self.attach_named(&typed);
        text.push_str(&extra);
        // Files the user pointed at (`@path` or by name): their scoped rules, and on a session's
        // first turn a fresh repo map if they aren't on it. Both happen before the first model
        // call of the turn.
        let pointed: Vec<PathBuf> = typed
            .split_whitespace()
            .filter_map(|t| t.strip_prefix('@'))
            .map(|t| {
                self.ctx
                    .resolve(t.trim_end_matches([',', ')', ':', ';', '?', '!', '.']))
            })
            .chain(named.iter().cloned())
            .collect();
        for p in &pointed {
            text.push_str(&self.rules_for(p));
        }
        let mentioned: Vec<String> = pointed.iter().filter_map(|p| self.rel(p)).collect();
        // The map is part of the system prompt, so after the first turn it's rebuilt only where
        // the history is rewritten anyway (`rebased`): rebuilding it whenever a file changed
        // would re-prefill the whole conversation on the turn after every edit.
        if self.messages.is_empty() {
            self.refresh_repo_map(&mentioned);
        }
        self.log_map();
        self.apply_harness();
        self.push_user(text);
        if !images.is_empty() {
            self.extend_last(
                images
                    .into_iter()
                    .map(|i| Block::Image {
                        mime: i.mime,
                        data: i.data,
                    })
                    .collect(),
            );
        }
        // The user's message is on disk before any model call: a crash or quit mid-turn
        // loses the reply, never the request. One fsync per accepted message.
        self.sync_log();

        let mut compacted = None;
        let mut guard = LoopGuard::default();
        let mut steps = 0;
        // Cut-off replies continued in a row (reset whenever a reply runs tools).
        let mut continued = 0;
        // A reply asking for files it could Read is nudged once, before any tool has run.
        let (mut nudged, mut used_tools) = (false, false);
        let reason = loop {
            steps += 1;
            let limit = if self.subagent {
                self.cfg.subagent_max_steps.max(1)
            } else {
                max_steps()
            };
            if steps > limit {
                break EndReason::StepLimit;
            }
            // MCP tools (and their servers' instructions) change the prompt's prefix, so they're
            // only taken on between turns, never mid-turn where the next call would re-prefill
            // everything the server has cached.
            if steps == 1 {
                self.poll_mcp();
                let mcp = self.mcp.clone();
                if mcp.refresh().await {
                    self.apply_harness();
                }
            }
            self.sync_specs();
            // What the preview pane saw go wrong since the last call.
            let reports = self.shared.panes.take_queued();
            if !reports.is_empty() {
                self.push_user(reports.join("\n"));
            }
            // Between turns, pruning starts at PRUNE_AT; inside one, only once the window is
            // nearly full, since a prune rewrites the prefix the server has cached.
            let start = if steps == 1 {
                context::PRUNE_AT
            } else {
                context::COMPACT_AT
            };
            self.fit_context(&mut compacted, start).await?;
            let sent = self.fixed_chars() + context::history_chars(&self.messages);
            let think = self.think_switch(thinking::wanted(&self.messages, self.quiet));
            self.quiet = if think == Some(false) {
                self.quiet + 1
            } else {
                0
            };
            let budget = self.think_budget(think);
            let started = Instant::now();
            let activity = if !self.model_ready && self.profile.sidecar.is_some() {
                format!("loading {}", self.profile.model)
            } else {
                "thinking".into()
            };
            let (resp, streamed) = match self
                .call(&activity, &self.messages, false, true, think, budget)
                .await
            {
                Ok(r) => r,
                Err(e) => {
                    let Some(local) = self.cloud_fallback(&e) else {
                        return Err(e);
                    };
                    self.notice(
                        Level::Warn,
                        format!("frog api unavailable ({e:#}) — continuing on {local}"),
                    );
                    self.set_model(&local).await?;
                    continue;
                }
            };
            self.model_ready = true;
            self.last_call = started.elapsed();
            self.usage = resp.usage.clone();
            self.count_call(resp.usage.clone(), &streamed, false);
            for (id, name, input) in self.provider.take_codex_items() {
                let arg = input.to_string();
                self.emit(Event::ItemStarted {
                    id: id.clone(),
                    kind: ItemKind::ToolCall {
                        name: name.clone(),
                        arg: arg.clone(),
                    },
                });
                let output = input["output"].as_str().unwrap_or("").to_owned();
                self.emit(Event::ItemCompleted {
                    id,
                    item: Item::ToolCall {
                        name,
                        arg,
                        input,
                        outcome: ToolOutcome::Ok,
                        output,
                        display: None,
                        diff: None,
                        diagram: None,
                        present: None,
                        images: Vec::new(),
                        app: None,
                    },
                });
            }
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
            let nudge = (!nudged && !used_tools && resp.stop != Stop::Length)
                .then(|| self.file_nudge(&answer, &named))
                .flatten();
            if !answer.is_empty() {
                self.complete_item(
                    streamed.message,
                    ItemKind::Message,
                    Item::Message { text: answer },
                );
            }

            let uses = msg.tool_uses();
            self.push_msg(msg);
            if let (true, Some(nudge)) = (uses.is_empty(), nudge) {
                nudged = true;
                self.notice(
                    Level::Info,
                    "the model asked for files it can read; reminded it to use its tools",
                );
                self.push_user(nudge);
                continue;
            }
            if uses.is_empty() {
                // Ran out of output room mid-reply (long thinking, usually): carry on rather
                // than end the turn, a few times, so long work doesn't stop on a token cap.
                if resp.stop == Stop::Length && continued < MAX_CONTINUES {
                    continued += 1;
                    self.notice(Level::Info, "reply hit the output limit; continuing");
                    self.push_user("Continue exactly where you left off.".into());
                    continue;
                }
                break if resp.stop == Stop::Length {
                    EndReason::MaxTokens
                } else {
                    EndReason::Complete
                };
            }

            used_tools = true;
            // A reply that acted is progress: the next cut-off gets a fresh set of continues.
            continued = 0;
            match self.run_tools(uses, &mut guard, streamed.early).await? {
                Batch::Continue => {}
                Batch::Denied => break EndReason::Denied,
                Batch::Looping => break EndReason::Looping,
            }
        };
        // Prune now, while the user reads the reply, and warm the result: the next turn then
        // starts from a prefix that's already cached instead of prefilling all of it.
        if self.prune(context::PRUNE_AT) {
            self.rebased();
            self.warm(None);
        }
        self.active_turn = None;
        self.shared.panes.set_in_turn(false);
        self.end_turn(turn, reason);
        Ok(())
    }

    /// Recompute tier, tool mode and system prompt from the profile and capabilities.
    fn apply_harness(&mut self) {
        self.tier = harness::tier(&self.profile, self.caps.as_ref());
        self.tool_mode = harness::choose_mode(&self.profile, self.caps.as_ref(), self.tier);
        let base = if self.chat {
            prompt::chat_prompt(&self.cfg, &self.profile.model)
        } else {
            prompt::system_prompt(&self.root, &self.cfg, &self.profile.model)
        };
        let rules =
            crate::rules::prompt_section(&self.rules, crate::rules::prompt_budget(self.tier));
        self.system = format!("{base}{rules}{}", harness::guidance(self.tier));
        if !self.subagent && self.shared.sessions.enabled() {
            self.system.push_str(crate::tools::sessions::PROMPT);
        }
        if !self.chat && !self.subagent {
            self.system
                .push_str(prompt::panes_prompt(self.shared.panes.client()));
        }
        if !self.plain_chat() {
            self.system.push_str(&self.mcp.prompt());
        }
        if self.subagent {
            self.system.push_str(if self.cfg.subagent_write {
                crate::subagent::WRITE_PROMPT
            } else {
                crate::subagent::PROMPT
            });
        }
        // No Skill tool in a small window (see `sync_specs`), so no catalog either.
        if !self.small_window() {
            self.system.push_str(&crate::skills::catalog(&self.skills));
        }
        let (index, omitted) = crate::memory::index(&self.notes, self.tier, self.window);
        self.system.push_str(&index);
        self.notes_omitted = omitted;
        if self.has_recall() {
            self.system
                .push_str("\nRecall searches your notes and past sessions in this project.\n");
        }
        // Last, since it's the one part that changes between turns.
        self.system.push_str(&self.repo_map.text);
    }

    /// Whether `Recall` is offered: there's a project with notes and summaries to search.
    fn has_recall(&self) -> bool {
        !self.chat
            && self
                .memory
                .as_ref()
                .is_some_and(|m| m.sessions_dir().is_some())
    }

    /// Notes and this project's session summaries, for `Recall`.
    fn recall_sources(&self) -> Vec<crate::summary::Stored> {
        self.memory
            .as_ref()
            .and_then(|m| m.sessions_dir())
            .map(|d| crate::summary::load(&d))
            .unwrap_or_default()
    }

    /// Rebuild the repo map for small and mid-size models if files changed (or `mentioned`
    /// names a source file it doesn't show). Only called between turns, so the prompt prefix
    /// holds while a turn runs.
    fn refresh_repo_map(&mut self, mentioned: &[String]) {
        self.poll_repo_map();
        if self.chat || self.subagent || self.memory.is_none() {
            return;
        }
        let budget = match crate::repomap::budget(self.tier) {
            // A small window gets the top of the map only.
            b if self.small_window() => b.min(Self::SMALL_REPO_MAP),
            b => b,
        };
        if budget == 0 {
            if !self.repo_map.text.is_empty() {
                self.repo_map = Default::default();
                self.map_logged = false;
                self.log_map();
            }
            return;
        }
        // The initial build was scheduled from `Agent::new`; if it has completed, keep it.
        // Rebuilds after edits are scheduled by `rebased`, where the system prompt is rebuilt.
        if !self.repo_map.text.is_empty() {
            return;
        }
        if self.map_building {
            return;
        }
        let cache = self
            .memory
            .as_ref()
            .and_then(|m| m.project_file(crate::repomap::CACHE_FILE));
        let root = self.root.clone();
        let cache = cache.clone();
        let mentioned = mentioned.to_vec();
        let edited = self.edited.clone();
        let tx = self.map_build_tx.clone();
        self.map_building = true;
        std::thread::spawn(move || {
            let Some(root) = crate::checkpoint::repo_root(&root) else {
                let _ = tx.send((crate::repomap::Map::default(), false));
                return;
            };
            let home = dirs::home_dir().and_then(|p| p.canonicalize().ok());
            let canonical = root.canonicalize().unwrap_or_else(|_| root.clone());
            if canonical == Path::new("/") || home.as_deref() == Some(canonical.as_path()) {
                let _ = tx.send((crate::repomap::Map::default(), false));
                return;
            }
            let seeds = crate::repomap::Seeds {
                mentioned: &mentioned,
                edited: &edited,
            };
            let result = crate::repomap::build_bounded(
                &root,
                cache.as_deref(),
                &seeds,
                budget,
                20_000,
                Some(Duration::from_secs(2)),
            );
            let _ = tx.send(result);
        });
    }

    fn poll_repo_map(&mut self) {
        let Ok((map, capped)) = self.map_build_rx.lock().unwrap().try_recv() else {
            return;
        };
        self.map_building = false;
        if capped {
            self.notice(Level::Info, "repo map limited to 20,000 files or 2 seconds");
        }
        if map.text != self.repo_map.text {
            self.map_logged = false;
        }
        self.repo_map = map;
        self.log_map();
    }

    /// Log the repo map if the session log doesn't hold it yet. Only into a log that exists: a
    /// conversation opened and never used shouldn't get one just for its map.
    fn log_map(&mut self) {
        if self.map_logged || self.store.is_none() || !self.shared.journal.has_log() {
            return;
        }
        self.record(Record::RepoMap {
            map: self.repo_map.clone(),
        });
        self.map_logged = true;
    }

    /// `path` relative to the project root, for rules and the repo map.
    fn rel(&self, path: &Path) -> Option<String> {
        let p = if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.root.join(path)
        };
        p.strip_prefix(&self.root)
            .ok()
            .map(|r| r.to_string_lossy().into_owned())
    }

    /// The scoped rules `path` matches that haven't been shown this session, as a block.
    fn rules_for(&mut self, path: &Path) -> String {
        let Some(rel) = self.rel(path) else {
            return String::new();
        };
        let due = crate::rules::due(&self.rules, &rel, &mut self.rules_seen);
        crate::rules::block(&due, &rel, crate::rules::inject_budget(self.tier))
    }

    /// Write or update this session's summary from its log. No model call.
    fn write_summary(&self) {
        let (Some(dir), Some(out)) = (
            &self.store,
            self.memory.as_ref().and_then(|m| m.sessions_dir()),
        ) else {
            return;
        };
        if !self.shared.journal.has_log() {
            return;
        }
        let Ok(loaded) = session::load(dir, &self.session_id) else {
            return;
        };
        if loaded.events.is_empty() {
            return;
        }
        let summary = crate::summary::build(&loaded.header, &loaded.events, None);
        if let Err(e) = crate::summary::write(&out, &summary) {
            self.notice(
                Level::Warn,
                format!("couldn't write the session summary: {e:#}"),
            );
        }
    }

    /// `/remember`, `/forget`, `/memory` and `/recall`: answered with a notice, no model call.
    /// Returns false if `text` isn't one of them.
    fn memory_command(&mut self, text: &str) -> bool {
        if self.subagent || !crate::memory::is_command(text) {
            return false;
        }
        let Some(store) = &self.memory else {
            self.notice(
                Level::Warn,
                "memory isn't available without a session store",
            );
            return true;
        };
        if let Some(query) = crate::memory::recall_query(text) {
            let sessions = self.recall_sources();
            let sources = crate::recall::Sources {
                notes: &self.notes,
                sessions: &sessions,
            };
            let reply = crate::recall::command(&sources, query, self.tier);
            self.notice(Level::Info, reply);
            return true;
        }
        let Some(reply) = crate::memory::command(store, &self.notes, text, self.notes_omitted)
        else {
            return false;
        };
        if reply.changed {
            self.notes = store.load();
            self.apply_harness();
        }
        self.notice(reply.level, reply.message);
        true
    }

    /// The `thinking` setting in effect: the profile's, else the global one.
    fn thinking_mode(&self) -> Thinking {
        self.profile.thinking.unwrap_or(self.cfg.thinking)
    }

    /// The thinking switch for the next call, given whether [`thinking::wanted`] it.
    fn think_switch(&self, want: bool) -> Option<bool> {
        let can_switch = match &self.caps {
            // Nothing to switch off.
            Some(c) if !c.thinks => return None,
            Some(c) => c.think_off,
            None => None,
        };
        thinking::switch(self.thinking_mode(), can_switch, want)
    }

    /// The reasoning-token cap for the next call, given its thinking switch: only for servers
    /// that take one, and only where the model thinks.
    fn think_budget(&self, think: Option<bool>) -> Option<u32> {
        if !self.budget_ok || self.thinking_mode() == Thinking::Never {
            return None;
        }
        let base = self
            .profile
            .thinking_budget
            .unwrap_or(self.cfg.thinking_budget);
        thinking::budget(base, think, &self.messages)
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
                    completed: None,
                    total: None,
                });
            }
            if let Err(e) = crate::sidecar::ensure(&self.profile).await {
                self.notice(Level::Warn, format!("{e:#}"));
            }
        }
        self.vision = match self.profile.vision {
            Some(v) => v,
            None => self.provider.supports_vision().await.unwrap_or(false),
        };
        let ext = self.provider.extensions().await;
        self.budget_ok = ext.thinking_budget;
        self.cache_key_ok = ext.cache_key;
        self.prefill_ok = ext.prefill;
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
        // The tools, repo map and prompt were built before the window was known; a small one
        // trims them.
        if self.small_window() && self.repo_map.text.len() > Self::SMALL_REPO_MAP {
            self.repo_map = Default::default();
            self.refresh_repo_map(&[]);
        }
        self.sync_specs();
        self.apply_harness();
        self.warm(None);
    }

    /// Have the server prefill this conversation as it stands (it was just opened or shown,
    /// or the model changed), plus `draft` as the next message when the user is typing one,
    /// so the next turn starts warm instead of re-reading everything. In the background, one
    /// at a time: newer drafts replace a queued one. A failure only costs the head start.
    fn warm(&self, draft: Option<&str>) {
        if !self.prefill_ok || !self.cache_key_ok || (self.messages.is_empty() && draft.is_none()) {
            return;
        }
        let mut messages = self.messages.clone();
        if let Some(draft) = draft {
            // As `turn` will send it: shell output waiting to go along, then the words.
            let mut text = self.pending.join("\n");
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(draft);
            match messages.last_mut() {
                Some(m) if m.role == Role::User => m.content.push(Block::Text { text }),
                _ => messages.push(Message::user(text)),
            }
        }
        let wire = self.wire(&messages, &self.specs);
        let req = Request {
            system: &wire.system,
            messages: wire.messages(&messages),
            tools: if wire.native_tools { &self.specs } else { &[] },
            max_tokens: None,
            format: wire.format.as_ref(),
            think: None,
            think_budget: None,
            cache_key: Some(&self.session_id),
        };
        let Some(prefill) = self.provider.prefill(&req) else {
            return;
        };
        *self.sent.lock().unwrap() = flatten(req.system, req.tools, req.messages);
        let prefill: Warming = Box::pin(prefill);
        let mut w = self.warming.lock().unwrap();
        if w.0 {
            w.1 = Some(prefill);
            return;
        }
        w.0 = true;
        drop(w);
        let warming = self.warming.clone();
        let log = self.cfg.log_calls;
        tokio::spawn(async move {
            let mut next = Some(prefill);
            while let Some(prefill) = next {
                let started = Instant::now();
                match prefill.await {
                    Ok(()) if log => {
                        eprintln!("warmed in {:.1}s", started.elapsed().as_secs_f64())
                    }
                    Err(e) if log => eprintln!("warming failed: {e:#}"),
                    _ => {}
                }
                let mut w = warming.lock().unwrap();
                next = w.1.take();
                w.0 = next.is_some();
            }
        });
    }

    fn fixed_chars(&self) -> usize {
        fixed_chars(&self.system, &self.specs)
    }

    fn estimate(&self) -> u64 {
        self.est
            .tokens(self.fixed_chars() + context::history_chars(&self.messages))
    }

    /// Stage 1: prune stale and old tool output (no LLM), once the prompt passes `start` of the
    /// window. Stage 2: summarize again when new messages fill the window.
    async fn fit_context(&mut self, compacted: &mut Option<usize>, start: f64) -> Result<()> {
        let pruned = self.prune(start);
        if (self.estimate() as f64) > self.window as f64 * context::COMPACT_AT
            && compacted.is_none_or(|len| self.messages.len() > len)
        {
            self.notice(
                Level::Warn,
                "context is still nearly full after pruning; summarizing…",
            );
            self.compact(None).await?;
            *compacted = Some(self.messages.len());
        } else if pruned {
            self.rebased();
        }
        Ok(())
    }

    /// Prune down to PRUNE_TO once the prompt passes `start` of the window, logging each
    /// replacement. Whether anything was pruned.
    fn prune(&mut self, start: f64) -> bool {
        let window = self.window as f64;
        let before = self.estimate();
        if (before as f64) < window * start {
            return false;
        }
        let target = self.est.chars((window * context::PRUNE_TO) as u64);
        let plan = context::plan_prune(&self.messages, target.saturating_sub(self.fixed_chars()));
        if plan.is_empty() {
            return false;
        }
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
        true
    }

    /// The history was just rewritten, so the cached prefix is gone anyway: the one time to
    /// bring the repo map (and with it the system prompt) up to date for free.
    fn rebased(&mut self) {
        self.repo_map = Default::default();
        self.map_logged = false;
        self.refresh_repo_map(&[]);
        self.apply_harness();
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
        // A picture of the preview to go with it, if there is one (doesn't hold the turn up).
        if let Some(dir) = &self.store {
            self.shared.panes.checkpoint(&self.session_id, turn, dir);
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
    /// Start connecting the project's MCP servers in the background, so the prompt (and the
    /// first turn) doesn't wait on them; [`Self::poll_mcp`] installs them once they're up.
    fn connect_mcp(&mut self) {
        self.mcp_pending = None;
        if self.subagent {
            return;
        }
        let servers = crate::mcp::configured(&self.cfg, &self.root);
        if servers.is_empty() {
            return;
        }
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let emit = {
            let journal = self.shared.journal.clone();
            move |event: Event| journal.emit(event)
        };
        let host = crate::mcp::Host::new(emit, self.rich && self.can_ask, &self.root);
        for (name, cfg) in servers {
            let tx = tx.clone();
            let host = host.clone();
            tokio::spawn(async move {
                let delta = crate::mcp::Hub::connect_delta(host, name.clone(), cfg).await;
                let _ = tx.send(delta);
            });
        }
        drop(tx);
        self.mcp_pending = Some(rx);
    }

    /// Install the background MCP connection if it has finished.
    fn poll_mcp(&mut self) {
        for (_name, delta) in std::mem::take(&mut self.mcp_ready_queue) {
            self.merge_mcp(delta);
        }
        loop {
            let result = self.mcp_pending.as_mut().and_then(|rx| rx.try_recv().ok());
            let Some((_name, delta)) = result else { break };
            self.mcp_ready_queue.push((_name, delta));
        }
    }

    /// Get the next configured server to connect; the loop returns immediately for a closed queue.
    async fn mcp_ready(&mut self) -> Option<(String, crate::mcp::Hub)> {
        match &mut self.mcp_pending {
            Some(rx) => rx.recv().await,
            None => std::future::pending().await,
        }
    }

    fn merge_mcp(&mut self, delta: crate::mcp::Hub) {
        let failed = delta
            .status()
            .into_iter()
            .filter_map(|st| st.error.map(|e| (st.name, e)))
            .collect::<Vec<_>>();
        self.mcp.merge(delta);
        if let Some(line) = crate::mcp::unavailable_summary(&failed) {
            self.notice(Level::Info, line);
        }
        *self.shared.mcp.lock().unwrap() = Some(self.mcp.clone());
        self.sync_specs();
        self.apply_harness();
    }

    /// Below this window (tokens), the prompt keeps to what a small model can hold: no
    /// subagents, no MCP instructions or schemas until loaded, skills by name only.
    const COMPACT_WINDOW: u64 = 16_384;
    /// Characters of repo map a small window gets.
    const SMALL_REPO_MAP: usize = 1_200;

    fn small_window(&self) -> bool {
        self.window < Self::COMPACT_WINDOW
    }

    /// A chat (no project) with a small model: no tools, so nothing to describe for them.
    fn plain_chat(&self) -> bool {
        self.chat && self.small_window() && !self.subagent
    }

    /// Built-in tools plus whatever MCP tools are live (and, with many, loaded).
    fn sync_specs(&mut self) {
        self.mcp.set_compact(self.small_window());
        let mut specs = tools::specs();
        if self.profile.provider == ProviderKind::Codex {
            specs.clear();
            self.specs = specs;
            return;
        }
        if self.ctx.web.search.is_some() {
            specs.push(tools::websearch::spec());
        }
        if self.chat {
            // No project to work in: only the tools that don't touch files or run commands.
            specs.retain(|s| matches!(&*s.name, "Diagram" | "Image" | "WebFetch" | "WebSearch"));
            specs.push(crate::folder::spec());
        }
        // Terminal panes are engine-owned, so every client gets them; previews need a client
        // that hosts them. Subagents only get to look.
        if !self.chat {
            specs.push(crate::panes::terminal_spec(self.subagent));
            if self.shared.panes.client() {
                specs.push(crate::panes::preview_spec(self.subagent));
            }
        }
        if self.subagent {
            // A write-mode subagent also edits and runs commands (asking as the parent would).
            let write = self.cfg.subagent_write;
            specs.retain(|s| {
                tools::kind(&s.name) == Kind::Read
                    || matches!(&*s.name, crate::panes::TERMINAL | crate::panes::PREVIEW)
                    || (write && matches!(&*s.name, "Bash" | "Write" | "Edit"))
            });
        } else {
            if !self.small_window() {
                specs.push(crate::subagent::spec());
            }
            if !self.chat {
                specs.extend(crate::background::specs());
            }
            if !self.skills.is_empty() {
                specs.push(crate::skills::spec());
            }
            if !self.chat {
                specs.push(crate::folder::spec());
            }
            specs.push(crate::present::spec(self.tier == Tier::Weak));
            if self.can_ask && self.shared.client_ask.load(Ordering::Relaxed) {
                specs.push(crate::ask::spec());
            }
            if self.shared.sessions.enabled() {
                specs.extend(crate::tools::sessions::specs());
            }
        }
        if self.has_recall() {
            specs.push(crate::recall::spec());
        }
        // MCP tools last: servers that connect late (or tools loaded on demand) then only
        // append to the list, and the prefix before them stays cached.
        if !self.subagent {
            specs.extend(self.mcp.specs());
        }
        // A small model chatting just talks: offered any tool, it calls one on every turn
        // (Apple's on-device model drew diagrams of "hello"). With none, it can only answer.
        if self.plain_chat() {
            specs.clear();
        } else if self.small_window() && !self.subagent {
            // In a project, a small window holds the core tools and little else: the rest
            // (diagrams, the code map, docs, recall, skills, the plan) cost more room than
            // they're worth at 8k. Visual tools and panes stay: the user can ask for
            // generation or a capture/compare loop even with a compact local model.
            specs.retain(|s| {
                matches!(
                    &*s.name,
                    "Bash"
                        | "Read"
                        | "Write"
                        | "Edit"
                        | "Glob"
                        | "Grep"
                        | "Image"
                        | "Screenshot"
                        | "Compare"
                ) || matches!(&*s.name, crate::panes::TERMINAL | crate::panes::PREVIEW)
                    || &*s.name == crate::mcp::SEARCH_TOOL
                    || &*s.name == crate::folder::TOOL
                    || &*s.name == crate::ask::TOOL
            });
        }
        self.specs = specs;
    }

    /// `UseFolder` (already approved): move the conversation into `path` and re-derive what
    /// depends on the folder, as `Agent::new` does. The tools and prompt switch on the next
    /// model call, so the turn carries on there.
    async fn use_folder(&mut self, input: &Value) -> Result<tools::Output> {
        let base = if self.chat {
            dirs::home_dir().unwrap_or_else(|| self.root.clone())
        } else {
            self.root.clone()
        };
        let root = crate::folder::resolve(input["path"].as_str().unwrap_or(""), &base)?;
        if !self.chat
            && root
                == self
                    .root
                    .canonicalize()
                    .unwrap_or_else(|_| self.root.clone())
        {
            return Ok(tools::Output::text(format!(
                "Already working in {}.",
                root.display()
            )));
        }
        // A folder that keeps its code on this Mac can't take a cloud model.
        crate::policy::check(&root, &self.profile_name, &self.profile)?;
        // The session file moves with it: its header says which folder it belongs to.
        if let Some(dir) = self.store.clone() {
            let header = Header {
                version: session::VERSION,
                id: self.session_id.clone(),
                cwd: root.clone(),
                model: self.profile_name.clone(),
                created: now_ms(),
                forked_from: None,
            };
            self.shared.journal.header.lock().unwrap().0 = root.clone();
            let mut log = self.shared.journal.log.lock().unwrap();
            if let Some(l) = log.as_mut() {
                let created = session::load(&dir, &self.session_id).map(|l| l.header).ok();
                let header = Header {
                    created: created.as_ref().map_or(header.created, |h| h.created),
                    forked_from: created.and_then(|h| h.forked_from),
                    ..header
                };
                l.rewrite_header(&dir, &header)?;
            }
        }
        self.chat = false;
        self.root = root.clone();
        let web = self.ctx.web.clone();
        let todos = std::mem::take(&mut self.ctx.todos);
        let sandbox = self.ctx.sandbox.is_some();
        self.ctx = Ctx::new(root.clone());
        self.ctx.web = web;
        self.ctx.image = self.cfg.image.clone();
        self.ctx.screenshot_endpoint = self.cfg.screenshot_endpoint.clone();
        self.ctx.judge = Some(match &self.cfg.compare_model {
            Some(model) => self.cfg.resolve(Some(model))?.1,
            None => self.profile.clone(),
        });
        self.ctx.todos = todos;
        if sandbox {
            self.ctx.sandbox = Some(root.clone());
        }
        if self.cfg.sandbox_shell && tools::bash::available() {
            self.ctx.shell_sandbox = Some(root.clone());
        }
        self.rules = crate::rules::discover(&root);
        self.rules_seen.clear();
        self.skills = crate::skills::discover(&root);
        self.skills_loaded.clear();
        if let Some(store) = &self.store {
            let memory = crate::memory::Store::new(&memory_root(store), Some(root.as_path()));
            self.notes = memory.load();
            self.memory = Some(memory);
        }
        // Approvals and the auto-mode judge were for the old folder.
        self.session_allow.clear();
        self.classifier = None;
        self.repo_map = Default::default();
        self.edited.clear();
        self.refresh_repo_map(&[]);
        // MCP servers are configured per project.
        self.mcp.shutdown();
        self.mcp = crate::mcp::Hub::empty();
        *self.shared.mcp.lock().unwrap() = None;
        self.connect_mcp();
        self.sync_specs();
        self.apply_harness();
        self.emit(Event::FolderChanged { cwd: root.clone() });
        self.emit_status();
        Ok(tools::Output::text(format!(
            "This conversation now works in {}. You can read and edit files there and run shell commands.",
            root.display()
        )))
    }

    /// `Task`: run a subagent and return its report (its steps stream as live output), or,
    /// with `background`, start it and return its id. A write-mode subagent works in this
    /// session's mode and sandbox, and its permission prompts come to the user through ours.
    async fn run_task(&mut self, id: &str, input: &Value) -> Result<tools::Output> {
        if self.subagent {
            anyhow::bail!("subagents can't start subagents");
        }
        let write = match input["mode"].as_str().unwrap_or("read") {
            "read" | "" => false,
            "write" => true,
            m => anyhow::bail!("unknown mode `{m}`: use read or write"),
        };
        let (profile_name, profile, fallback) = crate::subagent::profile(
            &self.cfg,
            &self.root,
            input["model"].as_str(),
            (&self.profile_name, &self.profile),
        );
        if let Some(why) = fallback {
            self.notice(Level::Warn, why);
        }
        let mut cfg = self.cfg.clone();
        cfg.subagent_write = write;
        let opts = Options {
            cfg,
            profile_name,
            profile,
            cwd: self.root.clone(),
            // Never more than the parent may do: its mode, and only it can ask the user.
            mode: if write { self.mode } else { Mode::Default },
            can_ask: write && self.can_ask,
            resume: None,
            store: None,
            sandbox: !write || self.ctx.sandbox.is_some(),
            rich: false,
            subagent: true,
            chat: false,
        };
        if tools::bool_arg(input, "background") {
            let max = self.cfg.background_tasks.max(1);
            return crate::background::start_task(&self.shared.bg, opts, input, max);
        }
        let stop = CancellationToken::new();
        self.shared
            .subagents
            .lock()
            .unwrap()
            .insert(id.to_string(), stop.clone());
        let forward = crate::background::forward(self.shared.bg.clone(), id.to_string(), false);
        let out = crate::subagent::run(opts, input, stop, forward).await;
        self.shared.subagents.lock().unwrap().remove(id);
        out
    }

    /// Where background jobs write their output: next to the session log.
    fn jobs_dir(&self) -> PathBuf {
        match &self.store {
            Some(dir) => dir.join(format!("{}.jobs", self.session_id)),
            None => std::env::temp_dir().join(format!("frog-jobs-{}", self.session_id)),
        }
    }

    /// Run a tool, streaming its live output as ephemeral `Output` deltas on item `id`.
    async fn run_tool(&mut self, id: &str, name: &str, input: &Value) -> Result<tools::Output> {
        if name == crate::skills::TOOL {
            return crate::skills::run(&self.skills, &mut self.skills_loaded, input);
        }
        if name == crate::recall::TOOL && self.has_recall() {
            let sessions = self.recall_sources();
            let sources = crate::recall::Sources {
                notes: &self.notes,
                sessions: &sessions,
            };
            return crate::recall::run(&sources, input, self.tier);
        }
        if name == crate::subagent::TOOL {
            return self.run_task(id, input).await;
        }
        if crate::background::handles(name)
            || (name == "Bash" && tools::bool_arg(input, "run_in_background"))
        {
            if self.subagent {
                anyhow::bail!(
                    "background work isn't available to subagents; run it in the foreground"
                );
            }
            if name == "Bash" {
                return crate::background::start_job(
                    &self.shared.bg,
                    input,
                    &self.ctx,
                    &self.jobs_dir(),
                );
            }
            return crate::background::run(&self.shared.bg, name, input, &self.ctx);
        }
        if name == crate::ask::TOOL {
            return self.ask_user(id, input).await;
        }
        if crate::tools::sessions::is_tool(name) && !self.subagent {
            return self.session_tool(id, name, input).await;
        }
        if name == crate::present::TOOL {
            return crate::present::run(input, &self.ctx.cwd, self.tier == Tier::Weak);
        }
        if name == crate::folder::TOOL && !self.subagent {
            return self.use_folder(input).await;
        }
        if name == crate::panes::TERMINAL {
            return self.shared.panes.terminal(input, self.subagent).await;
        }
        if name == crate::panes::PREVIEW {
            return self.shared.panes.preview(input, self.subagent).await;
        }
        if self.mcp.handles(name) {
            let hub = self.mcp.clone();
            return hub.call(id, name, input).await;
        }
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        self.ctx.progress = Some(tx);
        let (preview_tx, mut preview_rx) = mpsc::unbounded_channel();
        self.ctx.preview = Some(preview_tx);
        // The tool holds `ctx` mutably, so deltas go out through a detached emitter.
        let emit = {
            let (journal, id) = (self.shared.journal.clone(), id.to_string());
            move |text: String| {
                journal.emit(Event::ItemDelta {
                    id: id.clone(),
                    delta: Delta::Output { text },
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
                    Some(delta) = preview_rx.recv() => { self.shared.journal.emit(Event::ItemDelta { id: id.to_string(), delta }); },
                }
            }
        };
        while let Ok(chunk) = rx.try_recv() {
            emit(chunk);
        }
        while let Ok(delta) = preview_rx.try_recv() {
            self.shared.journal.emit(Event::ItemDelta {
                id: id.to_string(),
                delta,
            });
        }
        self.ctx.progress = None;
        self.ctx.preview = None;
        out
    }

    /// Run one batch of tool calls. Returns true if the user denied one.
    /// Whether the model may call `name` now: it's in the tool list this step was offered, or
    /// it's a connected MCP server's tool (with many, only some are listed up front and the
    /// rest load on demand; that saves context, it isn't a permission).
    fn offers(&self, name: &str) -> bool {
        self.specs.iter().any(|s| s.name == name)
            || (name.starts_with("mcp__") && self.mcp.handles(name))
    }

    /// A context to run `name` in while its reply is still streaming, if it may: one of the
    /// read-only tools (`early::TOOLS`) that this step offers and that never asks. Its own
    /// context, so nothing it records reaches `self.ctx` unless its result is used.
    fn early_ctx(&self, name: &str, input: &Value) -> Option<Ctx> {
        let ok = crate::early::TOOLS.contains(&name)
            && tools::kind(name) == Kind::Read
            && self.offers(name)
            && !self.mcp.handles(name)
            && input.get("_invalid_json").is_none();
        ok.then(|| Ctx {
            cwd: self.ctx.cwd.clone(),
            read_files: HashMap::new(),
            todos: Vec::new(),
            sandbox: self.ctx.sandbox.clone(),
            shell_sandbox: self.ctx.shell_sandbox.clone(),
            sandbox_extra: self.ctx.sandbox_extra.clone(),
            progress: None,
            preview: None,
            web: self.ctx.web.clone(),
            image: self.ctx.image.clone(),
            screenshot_endpoint: self.ctx.screenshot_endpoint.clone(),
            judge: self.ctx.judge.clone(),
        })
    }

    /// The result of a call that started early, as running it now would give, and how long
    /// it ran before `now` (time the turn didn't wait for it).
    async fn finish_early(
        &mut self,
        call: crate::early::Call,
        now: Instant,
    ) -> Option<(Result<tools::Output>, Duration)> {
        let ran = call.finish().await?;
        // What it read counts as read, as if it had run now.
        self.ctx.read_files.extend(ran.read_files);
        let overlap = ran.done.min(now).saturating_duration_since(ran.started);
        Some((ran.out, overlap))
    }

    async fn run_tools(
        &mut self,
        uses: Vec<(String, String, Value)>,
        guard: &mut LoopGuard,
        mut early: crate::early::Early,
    ) -> Result<Batch> {
        // Results accumulate in place so an interrupt keeps what already ran.
        self.push_msg(Message {
            role: Role::User,
            content: Vec::new(),
        });
        let mut denied = false;
        let mut looping = false;
        let mut replan: Option<String> = None;
        for (index, (id, name, input)) in uses.into_iter().enumerate() {
            // Taken for every call, so a mismatch drops all the early runs after it.
            let started_early = early.take(index, &name, &input);
            let key = format!("{name}\u{0}{input}");
            let count = guard.counts.entry(key.clone()).or_insert(0);
            // Reading a pane again is polling, not looping: what's there changes.
            if !crate::panes::is_read(&name, &input) {
                *count += 1;
            }
            let seen = *count;
            let (_, arg) = tools::label(&name, &input, &self.ctx);
            if seen <= 1 {
                guard.stale_replans = 0;
            }
            guard.note_recent(format!("{name} {arg}"));
            // The 3rd and 5th identical call ask the model to re-plan; the last stops the turn.
            if seen == LOOP_REPLAN || seen == LOOP_STOP - 1 {
                guard.stale_replans += 1;
                replan = Some(guard.replan(&format!("{name} {arg}"), seen));
            }
            if seen >= LOOP_STOP || guard.stale_replans >= LOOP_STALE_REPLANS {
                looping = true;
            }
            let replay = if seen >= LOOP_NUDGE && !looping {
                guard
                    .last
                    .get(&key)
                    .map(|r| format!("{r}\n{}", repeat_nudge(&name, &input, r, seen)))
            } else {
                None
            };
            let mut executed = false;
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
            let (outcome, out) = if looping {
                let msg = format!(
                    "Not run: repeated calls (this one made {seen} times). Stopping the turn; the work so far is kept."
                );
                text(
                    ToolOutcome::Error,
                    msg,
                    Some("refused: repeated identical call"),
                )
            } else if let Some(content) = replay {
                text(
                    ToolOutcome::Ok,
                    content,
                    Some("repeated call: earlier result reused"),
                )
            } else if seen >= LOOP_REPLAN {
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
            } else if !self.offers(&name) {
                // Only what this step offered runs: a chat has no Bash however it's asked for.
                text(
                    ToolOutcome::Error,
                    format!(
                        "There's no `{name}` tool in this conversation. Use only the tools you were given."
                    ),
                    Some("refused: not an available tool"),
                )
            } else if self.timed_permit(&id, &name, &arg, &input).await == Decision::Deny {
                let msg = if self.can_ask {
                    "The user rejected this tool call. Stop and wait for their instructions."
                } else {
                    "Not permitted in non-interactive mode (run with --yolo to allow)."
                };
                denied = self.can_ask;
                text(ToolOutcome::Denied, msg.to_string(), None)
            } else {
                let started = Instant::now();
                self.snapshot(&name, &input);
                let ran = match started_early {
                    Some(call) => self.finish_early(call, started).await,
                    None => None,
                };
                let early = ran.as_ref().map(|(_, overlap)| ms(*overlap));
                let r = match ran {
                    Some((r, _)) => r,
                    None => self.run_tool(&id, &name, &input).await,
                };
                let took = ms(started.elapsed());
                self.timing.tool_ms += took;
                self.timing.early_ms += early.unwrap_or(0);
                if let Some(t) = self.timing.tools.last_mut() {
                    t.ms = took;
                    t.early = early.is_some();
                }
                executed = true;
                match r {
                    Ok(o) => (ToolOutcome::Ok, o),
                    Err(e) => text(ToolOutcome::Error, format!("Error: {e:#}"), None),
                }
            };
            let mut out = out;
            if outcome == ToolOutcome::Ok {
                if executed && replayable(&name) {
                    guard.last.insert(key.clone(), out.content.clone());
                }
                // The world changed, so earlier results and repeat counts no longer apply.
                if matches!(&*name, "Edit" | "Write") {
                    guard.last.clear();
                    guard.counts.clear();
                    guard.stale_replans = 0;
                } else if name == "Bash" {
                    guard.last.clear();
                }
            }
            // A repeat that had to run fresh still gets the nudge.
            if executed && seen == LOOP_NUDGE && outcome == ToolOutcome::Ok {
                let n = repeat_nudge(&name, &input, &out.content, seen);
                out.content = format!("{}\n{n}", out.content);
            }
            let output = out.content;
            // Rules scoped to the file just read or edited go in front of its result, the
            // first time this session.
            let rules = match (&*name, outcome == ToolOutcome::Ok) {
                ("Read" | "Edit" | "Write", true) => input["file_path"]
                    .as_str()
                    .map(|p| self.ctx.resolve(p))
                    .map(|p| self.rules_for(&p))
                    .unwrap_or_default(),
                _ => String::new(),
            };
            if let Some(d) = &out.diff
                && let Some(rel) = self.rel(Path::new(&d.path))
                && !self.edited.contains(&rel)
            {
                self.edited.push(rel);
            }

            self.extend_last(vec![Block::ToolResult {
                id: id.clone(),
                name: name.clone(),
                content: format!("{rules}{output}"),
                is_error: outcome != ToolOutcome::Ok,
            }]);
            // Images a tool returned (a render, a screenshot) go to the model too, after the
            // results; `prepare_images` decides per request whether it gets to see them.
            let seen: Vec<Block> = out
                .images
                .iter()
                .take(2)
                .map(|i| Block::Image {
                    mime: i.mime.clone(),
                    data: i.data.clone(),
                })
                .collect();
            if !seen.is_empty() {
                self.extend_last(seen);
            }
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
                    present: out.present,
                    images: out.images,
                    app: out.app,
                },
            });
        }
        if looping {
            let why = format!(
                "[frog] Turn stopped: the same tool call repeated {LOOP_STOP} times, or {LOOP_STALE_REPLANS} \
re-plans passed with no new call. Everything done so far is kept; give a different instruction to continue."
            );
            self.notice(Level::Warn, why.clone());
            self.extend_last(vec![Block::Text { text: why }]);
        } else if let Some(r) = replan {
            self.extend_last(vec![Block::Text { text: r }]);
        }
        Ok(if denied {
            Batch::Denied
        } else if looping {
            Batch::Looping
        } else {
            Batch::Continue
        })
    }

    /// What a model call sends for `messages` in the current tool mode.
    fn wire(&self, messages: &[Message], specs: &[ToolSpec]) -> Wire {
        let with_images = self.prepare_images(messages);
        let prepared = with_images.as_deref().unwrap_or(messages);
        match self.tool_mode {
            ToolMode::Text => Wire {
                system: format!("{}{}", self.system, prompt::text_tools_prompt(specs)),
                messages: Some(prompt::to_text_mode(prepared)),
                native_tools: false,
                format: None,
            },
            ToolMode::Json => Wire {
                system: format!("{}{}", self.system, prompt::json_tools_prompt(specs)),
                messages: Some(prompt::to_json_mode(prepared)),
                native_tools: false,
                format: Some(prompt::json_schema(specs)),
            },
            ToolMode::Native | ToolMode::Auto => Wire {
                system: self.system.clone(),
                messages: with_images,
                native_tools: true,
                format: None,
            },
        }
    }

    /// Images as the model should get them: the last few as images for a model that can see,
    /// the rest (and all of them, for one that can't) as a short note. `None` when there are
    /// no images to change.
    fn prepare_images(&self, messages: &[Message]) -> Option<Vec<Message>> {
        const KEEP: usize = 3;
        let total = messages
            .iter()
            .flat_map(|m| &m.content)
            .filter(|b| matches!(b, Block::Image { .. }))
            .count();
        let keep = if self.vision { KEEP } else { 0 };
        if total <= keep {
            return None;
        }
        let mut seen = 0;
        let out = messages
            .iter()
            .map(|m| Message {
                role: m.role,
                content: m
                    .content
                    .iter()
                    .map(|b| match b {
                        Block::Image { mime, .. } => {
                            seen += 1;
                            if seen > total - keep {
                                b.clone()
                            } else if self.vision {
                                Block::Text {
                                    text: format!("[earlier {mime} image omitted to save context]"),
                                }
                            } else {
                                Block::Text {
                                    text: format!(
                                        "[{mime} image attached; this model can't see images]"
                                    ),
                                }
                            }
                        }
                        other => other.clone(),
                    })
                    .collect(),
            })
            .collect();
        Some(out)
    }

    /// One model request. Streams item events (unless `quiet`) and retries transient errors
    /// that happen before anything streamed. Without `offer_tools` the model can only answer:
    /// in `json` mode a summary request that offers tools gets a tool call back, not a summary.
    async fn set_model(&mut self, spec: &str) -> Result<()> {
        let (name, profile) = self
            .cfg
            .resolve(Some(spec))
            .map_err(|e| ConfigError(format!("{e:#}")))?;
        if profile.provider == ProviderKind::Codex {
            crate::provider::codex::check_available()
                .await
                .map_err(|e| ConfigError(format!("{e:#}")))?;
        }
        crate::policy::check(&self.root, &name, &profile)
            .map_err(|e| ConfigError(format!("{e:#}")))?;
        self.provider = Provider::new(&profile)
            .map_err(|e| ConfigError(format!("{e:#}")))?
            .with_cwd(&self.root);
        self.profile_name = name;
        self.profile = profile;
        if self.cfg.compare_model.is_none() {
            self.ctx.judge = Some(self.profile.clone());
        }
        self.shared.journal.header.lock().unwrap().1 = self.profile_name.clone();
        self.caps = (!harness::is_hosted(&self.profile))
            .then(|| harness::cached(&self.profile))
            .flatten();
        self.mode_failures = 0;
        self.model_ready = false;
        self.apply_harness();
        self.resolve_window().await;
        self.emit(Event::ModelChanged {
            model: self.profile_name.clone(),
        });
        Ok(())
    }

    /// frog cloud is unreachable (offline) or out of capacity, credit or hours (503, 402, 502):
    /// carry on with a local model instead of failing the turn. `FROG_FALLBACK_MODEL` picks
    /// which.
    /// How many times to retry a failed call: frog cloud gets longer (busy, or a tunnel blip).
    fn retry_budget(&self, _e: &anyhow::Error) -> u32 {
        let cloud = self
            .profile_name
            .split_once('/')
            .is_some_and(|(p, _)| crate::providers::canonical(p) == crate::providers::CLOUD);
        if cloud { 6 } else { 3 }
    }

    fn cloud_fallback(&self, e: &anyhow::Error) -> Option<String> {
        let prov = self.profile_name.split_once('/')?.0;
        if crate::providers::canonical(prov) != crate::providers::CLOUD {
            return None;
        }
        let offline = e
            .chain()
            .filter_map(|c| c.downcast_ref::<reqwest::Error>())
            .any(|r| r.is_connect());
        let unavailable = e
            .downcast_ref::<HttpError>()
            .is_some_and(|h| matches!(h.status, 402 | 502 | 503));
        if !offline && !unavailable {
            return None;
        }
        Some(
            std::env::var("FROG_FALLBACK_MODEL")
                .ok()
                .filter(|m| !m.is_empty())
                .map(|m| crate::providers::normalize(&m))
                .unwrap_or_else(|| crate::config::LOCAL_DEFAULT.into()),
        )
        // Only to a local model that's actually there: a fallback to nothing just fails later.
        .filter(|m| !m.starts_with("local/") || local_server_up())
    }

    async fn call(
        &self,
        label: &str,
        messages: &[Message],
        quiet: bool,
        offer_tools: bool,
        think: Option<bool>,
        think_budget: Option<u32>,
    ) -> Result<(Response, Streamed)> {
        let json_mode = self.tool_mode == ToolMode::Json;
        // A JSON-mode reply is one object whose action comes last, so it's done by the time
        // its call is: nothing to gain.
        let early_tools = self.cfg.early_tools && offer_tools && !quiet && !json_mode;
        let specs = if offer_tools && self.profile.provider != ProviderKind::Codex {
            &self.specs[..]
        } else {
            &[][..]
        };
        let wire = self.wire(messages, specs);
        let (system, messages, format) =
            (&wire.system, wire.messages(messages), wire.format.as_ref());
        let tools = if wire.native_tools { specs } else { &[][..] };
        let prompt = self
            .est
            .tokens(fixed_chars(&system, tools) + context::history_chars(messages));
        // A local server fills whatever's left of the window unless told otherwise, and
        // overflows it; hosted APIs have their own output limits.
        let max_tokens = if crate::harness::is_cloud(&self.profile) {
            // Ask for room explicitly: left unset, some gateways apply a small default that long
            // thinking (GLM at high effort) exhausts before any answer or tool call.
            self.profile.max_tokens.or(Some(CLOUD_MAX_OUTPUT))
        } else {
            Some(context::reply_budget(
                self.window,
                prompt,
                self.profile.max_tokens,
            ))
        };
        let call = NEXT_CALL.fetch_add(1, Ordering::Relaxed) + 1;
        let req = Request {
            system: &system,
            messages,
            tools,
            max_tokens,
            format,
            think,
            think_budget,
            cache_key: self.cache_key_ok.then_some(self.session_id.as_str()),
        };
        let (extends, reusable) = {
            let flat = flatten(&system, tools, messages);
            // `FROG_DUMP_PREFIX=dir`: every request as the cache sees it, to diff when one
            // stops extending the last.
            if let Some(dir) = std::env::var_os("FROG_DUMP_PREFIX") {
                let dir = PathBuf::from(dir);
                let _ = std::fs::create_dir_all(&dir)
                    .and_then(|_| std::fs::write(dir.join(format!("{call:04}.txt")), &flat));
            }
            let mut sent = self.sent.lock().unwrap();
            let r = reuse(&sent, &flat);
            *sent = flat;
            r
        };
        let mut attempt = 0;
        loop {
            self.emit(Event::Progress {
                label: label.into(),
                completed: None,
                total: None,
            });
            let mut started = false;
            let mut streamed = Streamed {
                no_think: think == Some(false),
                think_budget,
                extends,
                reusable,
                ..Default::default()
            };
            let sent = Instant::now();
            // The engine log: what was sent, and a note while nothing has come back, so a
            // slow provider or a hang shows up while it's happening, not just after.
            let heard = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let watchdog = self.cfg.log_calls.then(|| {
                eprintln!(
                    "call {call} {label} → {} · ~{prompt} tokens in · {} tools{}{}",
                    self.profile_name,
                    specs.len(),
                    max_tokens
                        .map(|n| format!(" · reply up to {n}"))
                        .unwrap_or_default(),
                    if attempt > 0 {
                        format!(" · attempt {}", attempt + 1)
                    } else {
                        String::new()
                    },
                );
                let heard = heard.clone();
                tokio::spawn(async move {
                    let mut waited = 0;
                    for step in [30, 30, 60, 120, 240] {
                        tokio::time::sleep(Duration::from_secs(step)).await;
                        waited += step;
                        if heard.load(Ordering::Relaxed) {
                            return;
                        }
                        eprintln!(
                            "call {call}: nothing back after {}",
                            secs(Duration::from_secs(waited))
                        );
                    }
                })
            });
            // When the first event arrived, and the first that wasn't reasoning.
            let (mut first, mut answer) = (None::<Instant>, None::<Instant>);
            let mut filter = TagFilter::default();
            let mut presenting = None::<crate::present::Stream>;
            let (cwd, weak) = (self.ctx.cwd.clone(), self.tier == Tier::Weak);
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
                    heard.store(true, Ordering::Relaxed);
                    let now = Instant::now();
                    first.get_or_insert(now);
                    if !matches!(e, StreamEvent::Thinking(_)) {
                        answer.get_or_insert(now);
                    }
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
                        StreamEvent::ToolCall(name) => {
                            presenting = (name == crate::present::TOOL).then(Default::default);
                            self.emit(Event::Progress {
                                label: format!("{name}…"),
                                completed: None,
                                total: None,
                            })
                        }
                        StreamEvent::ToolArgs { name, chunk } => {
                            if name == crate::present::TOOL
                                && let Some(p) =
                                    presenting.as_mut().and_then(|s| s.push(&chunk, &cwd, weak))
                            {
                                self.emit(Event::PresentPreview {
                                    present: Box::new(p),
                                });
                            }
                        }
                        StreamEvent::ToolReady { index, name, input } => {
                            if early_tools {
                                let ctx = self.early_ctx(&name, &input);
                                streamed.early.ready(index, name, input, ctx);
                            }
                        }
                        // JSON-mode output is raw JSON; the parsed answer is shown when complete.
                        StreamEvent::Text(_) if json_mode => {}
                        StreamEvent::Text(s) => {
                            if early_tools {
                                streamed.early.text(&s, |n, i| self.early_ctx(n, i));
                            }
                            let was_inside = filter.inside;
                            let visible = filter.push(&s);
                            if !visible.is_empty() {
                                text(&mut streamed, visible);
                            }
                            if filter.inside && !was_inside {
                                self.emit(Event::Progress {
                                    label: "tool call…".into(),
                                    completed: None,
                                    total: None,
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
            let done = Instant::now();
            if let Some(w) = watchdog {
                w.abort();
                match &r {
                    Ok(resp) => eprintln!(
                        "call {call} done in {} · first token {} · {} in, {} out · {:?}",
                        secs(done - sent),
                        first
                            .map(|f| secs(f - sent))
                            .unwrap_or_else(|| "none".into()),
                        resp.usage.input + resp.usage.cache_read,
                        resp.usage.output,
                        resp.stop,
                    ),
                    Err(e) => eprintln!("call {call} failed after {}: {e:#}", secs(done - sent)),
                }
            }
            let first = first.unwrap_or(done);
            streamed.ttft = first - sent;
            streamed.decode = done - first;
            streamed.think = answer.unwrap_or(done) - first;
            // A stream that ended without the server saying it was done is the same mid-stream
            // failure as a gateway error event; retried the same way, partials and all.
            let r = match r {
                Ok(resp) if resp.stop == Stop::Incomplete => Err(IncompleteStream.into()),
                other => other,
            };
            match r {
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
                // A busy or briefly unreachable provider is retried before anything falls
                // back: one 503, dropped connection or mid-stream gateway error shouldn't end
                // a long task. When the broken attempt had already streamed a partial reply,
                // its items are discarded and the step runs again from scratch.
                Err(e)
                    if attempt < self.retry_budget(&e)
                        && (retryable(&e) || self.cloud_fallback(&e).is_some()) =>
                {
                    attempt += 1;
                    let ids: Vec<String> = streamed
                        .message
                        .iter()
                        .chain(streamed.reasoning.iter())
                        .cloned()
                        .collect();
                    if !ids.is_empty() {
                        self.emit(Event::ItemsDiscarded { ids });
                    }
                    let wait = Duration::from_secs((1u64 << attempt.min(5)).min(20));
                    let budget = self.retry_budget(&e);
                    self.notice(
                        Level::Warn,
                        format!("{e:#} — retrying in {}s ({attempt}/{budget})", wait.as_secs()),
                    );
                    tokio::time::sleep(wait).await;
                }
                Err(e) => {
                    // The last attempt (or one that isn't retryable) may leave a streamed
                    // partial dangling: drop it, as the retry arm does.
                    let ids: Vec<String> = streamed
                        .message
                        .iter()
                        .chain(streamed.reasoning.iter())
                        .cloned()
                        .collect();
                    if !ids.is_empty() {
                        self.emit(Event::ItemsDiscarded { ids });
                    }
                    return Err(e);
                }
            }
        }
    }

    /// [`Self::permit`], recording a [`ToolTiming`] with how long the user and the
    /// classifier took (the tool's own time is filled in once it runs).
    async fn timed_permit(&mut self, item: &str, name: &str, arg: &str, input: &Value) -> Decision {
        let (user, classifier) = (self.timing.user_ms, self.timing.classifier_ms);
        let decision = self.permit(item, name, arg, input).await;
        let t = &self.timing;
        let timing = ToolTiming {
            id: item.to_string(),
            name: name.to_string(),
            ms: 0,
            early: false,
            user_ms: t.user_ms - user,
            classifier_ms: t.classifier_ms - classifier,
        };
        self.timing.tools.push(timing);
        decision
    }

    async fn permit(&mut self, item: &str, name: &str, arg: &str, input: &Value) -> Decision {
        // A monitor's command is a shell command like any other; a bare timer runs nothing.
        let name = match name {
            crate::background::MONITOR
                if input["command"]
                    .as_str()
                    .is_some_and(|c| !c.trim().is_empty()) =>
            {
                "Bash"
            }
            crate::background::MONITOR => return Decision::Allow,
            n => n,
        };
        let kind = if crate::panes::is_read(name, input) {
            Kind::Read
        } else {
            tools::kind(name)
        };
        if kind == Kind::Read || self.mode == Mode::Yolo {
            return Decision::Allow;
        }
        let pane_action = input["action"].as_str().unwrap_or("");
        // `Terminal.run` is a shell command like any other, except that pane shells can't be
        // sandboxed (see `panes::shell_command`), so it asks the way an unsandboxed command
        // does. The other pane actions (typing into a shell, driving a page) ask on their own
        // terms.
        let terminal_run = name == crate::panes::TERMINAL && pane_action == "run";
        let pane = !terminal_run && matches!(name, crate::panes::TERMINAL | crate::panes::PREVIEW);
        // Web reads change nothing and show on their tool card, like reads. Auto mode runs
        // unwatched, so there the classifier sees the URL first (a query string can carry data).
        if kind == Kind::Net && self.mode != Mode::Auto {
            return Decision::Allow;
        }
        if name == crate::folder::TOOL {
            return self.ask_folder(item, name, arg).await;
        }
        let cmd = input["command"].as_str().unwrap_or("").trim();
        let prefix = cmd.split_whitespace().next().unwrap_or("").to_string();
        let mcp = name.starts_with("mcp__");
        // A sandboxed command can only write inside the project and can't read credentials,
        // so it runs without asking; leaving the sandbox always asks.
        let leaves_sandbox = name == "Bash" && input["unsandboxed"].as_bool() == Some(true);
        if name == "Bash" && self.ctx.shell_sandbox.is_some() && !leaves_sandbox {
            return Decision::Allow;
        }
        let key = match kind {
            Kind::Edit => "edits".to_string(),
            Kind::Net => format!("web:{}", web_host(name, input)),
            _ if name == "Screenshot" => format!("visual:Screenshot:{}", capture_host(input)),
            _ if matches!(name, "Image" | "Compare") => format!("visual:{name}"),
            _ if mcp => format!("mcp:{name}"),
            _ if pane => format!("{}:{pane_action}", name.to_lowercase()),
            _ if leaves_sandbox => format!("bash-unsandboxed:{prefix}"),
            _ => format!("bash:{prefix}"),
        };
        let auto = match kind {
            Kind::Edit => {
                self.mode == Mode::AcceptEdits
                    // Auto mode: edits inside the project are checkpointed and can be undone.
                    || (self.mode == Mode::Auto
                        && crate::auto::hard_rule(name, input, &self.root).is_none())
            }
            Kind::Net => false,
            _ if matches!(name, "Image" | "Screenshot" | "Compare")
                || mcp
                || leaves_sandbox
                || pane =>
            {
                false
            }
            _ => bash_allowed(cmd, &self.cfg.allow_bash),
        };
        if auto || self.session_allow.contains(&key) {
            return Decision::Allow;
        }
        let mut reason = leaves_sandbox.then(|| {
            "Runs outside the sandbox: it can change files anywhere and read your credentials."
                .to_string()
        });
        if terminal_run && self.ctx.shell_sandbox.is_some() {
            reason = Some(
                "Runs in a terminal pane, which isn't sandboxed: it can change files anywhere and read your credentials."
                    .to_string(),
            );
        }
        if self.mode == Mode::Auto {
            let sandbox = match (self.ctx.shell_sandbox.is_some(), leaves_sandbox) {
                (_, true) => crate::auto::Sandbox::Leaving,
                (true, false) => crate::auto::Sandbox::In,
                (false, false) => crate::auto::Sandbox::Off,
            };
            let started = Instant::now();
            let verdict = self.auto_judge(item, name, input, sandbox).await;
            self.timing.classifier_ms += ms(started.elapsed());
            match verdict {
                Ok(()) => return Decision::Allow,
                Err(why) => {
                    reason = Some(format!(
                        "Auto mode asked because {}.",
                        why.trim_end_matches('.')
                    ))
                }
            }
        }
        if !self.can_ask {
            return Decision::Deny;
        }
        let always = match kind {
            Kind::Edit => "allow all edits this session".to_string(),
            Kind::Net if name == "WebSearch" => {
                "always allow web searches this session".to_string()
            }
            Kind::Net => format!(
                "always allow fetching from {} this session",
                web_host(name, input)
            ),
            _ if name == "Image" => "always allow image generation this session".to_string(),
            _ if name == "Screenshot" => format!(
                "always allow screenshots of {} this session",
                capture_host(input)
            ),
            _ if name == "Compare" => "always allow visual comparisons this session".to_string(),
            _ if mcp => {
                let pretty = name
                    .strip_prefix("mcp__")
                    .unwrap_or(name)
                    .replacen("__", " › ", 1);
                format!("always allow {pretty} this session")
            }
            _ if name == crate::panes::TERMINAL && pane => {
                "always allow typing into terminal panes this session".to_string()
            }
            _ if pane => format!("always allow preview {pane_action} this session"),
            _ if leaves_sandbox => {
                format!("always allow `{prefix}` outside the sandbox this session")
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
            reason,
            subagent: None,
        });
        let asked = Instant::now();
        let decision = rx.await.unwrap_or(Decision::Deny);
        self.timing.user_ms += ms(asked.elapsed());
        self.emit(Event::PermissionResolved { id, decision });
        if decision == Decision::AllowAlways {
            self.session_allow.insert(key);
        }
        decision
    }

    /// `ListSessions`, `SendMessage`, `StartSession`: the client carries them out.
    async fn session_tool(
        &mut self,
        item: &str,
        name: &str,
        input: &Value,
    ) -> Result<tools::Output> {
        use crate::tools::sessions;
        sessions::validate(name, input)?;
        let (id, rx) = self.shared.sessions.open();
        self.emit(Event::SessionRequest {
            id,
            item: item.into(),
            tool: name.into(),
            input: input.clone(),
        });
        let reply = rx
            .await
            .unwrap_or_else(|_| Err("the app didn't answer".into()));
        Ok(tools::Output {
            content: sessions::result(reply)?,
            ..Default::default()
        })
    }

    /// `Ask`: show the question and wait for the answer.
    async fn ask_user(&mut self, item: &str, input: &Value) -> Result<tools::Output> {
        let q = crate::ask::parse(input)?;
        let id = new_id();
        let (tx, rx) = oneshot::channel();
        self.shared.questions.lock().unwrap().insert(id.clone(), tx);
        self.emit(Event::Question {
            id: id.clone(),
            item: item.into(),
            question: q.question.clone(),
            options: q.options.clone(),
            multi: q.multi,
            allow_other: q.allow_other,
        });
        // An interrupt drops this whole turn; the loop around it resolves what's still open.
        let asked = Instant::now();
        let answer = rx.await.unwrap_or_default();
        self.timing.user_ms += ms(asked.elapsed());
        self.emit(Event::QuestionResolved {
            id,
            answer: answer.clone(),
        });
        let text = crate::ask::result(&q, &answer);
        Ok(tools::Output {
            display: Some(text.trim_start_matches("The user ").to_string()),
            content: text,
            ..Default::default()
        })
    }

    /// `UseFolder` hands the conversation a folder's files and shell, so the user decides,
    /// every time: no auto mode, no "always".
    async fn ask_folder(&mut self, item: &str, name: &str, arg: &str) -> Decision {
        if !self.can_ask {
            return Decision::Deny;
        }
        let id = new_id();
        let (tx, rx) = oneshot::channel();
        self.shared.pending.lock().unwrap().insert(id.clone(), tx);
        self.emit(Event::PermissionRequest {
            id: id.clone(),
            item: item.into(),
            name: name.into(),
            arg: arg.into(),
            always: String::new(),
            preview: None,
            reason: Some(
                "Frog will be able to read and edit files in this folder and run commands there."
                    .into(),
            ),
            subagent: None,
        });
        let asked = Instant::now();
        let decision = match rx.await.unwrap_or(Decision::Deny) {
            Decision::AllowAlways => Decision::Allow,
            d => d,
        };
        self.timing.user_ms += ms(asked.elapsed());
        self.emit(Event::PermissionResolved { id, decision });
        decision
    }

    /// Auto mode: hard rules, then the classifier. `Ok` runs the call (and records why);
    /// `Err` says why the user should decide.
    async fn auto_judge(
        &mut self,
        item: &str,
        name: &str,
        input: &Value,
        sandbox: crate::auto::Sandbox,
    ) -> std::result::Result<(), String> {
        if let Some(why) = crate::auto::hard_rule(name, input, &self.root) {
            return Err(format!("it {why}"));
        }
        if self.classifier.is_none() {
            match crate::auto::Classifier::new(
                &self.cfg,
                (&self.profile_name, &self.profile),
                &self.root,
            ) {
                Ok(c) => self.classifier = Some(c),
                Err(e) => return Err(format!("the classifier couldn't start ({e:#})")),
            }
        }
        let model = self
            .classifier
            .as_ref()
            .map(|c| c.profile_name.clone())
            .unwrap_or_default();
        self.emit(Event::Progress {
            label: format!("checking with auto mode ({model})"),
            completed: None,
            total: None,
        });
        let preview = tools::fs::preview(name, input, &self.ctx);
        let action = crate::auto::describe(name, input, preview.as_ref(), sandbox);
        let inputs = self.inputs.clone();
        let classifier = self.classifier.as_mut().expect("set above");
        match classifier.judge(&inputs, &action).await {
            crate::auto::Verdict::Allow(reason) => {
                self.emit(Event::AutoApproved {
                    item: item.to_string(),
                    reason,
                });
                Ok(())
            }
            crate::auto::Verdict::Ask(reason) => Err(format!("the classifier said: {reason}")),
        }
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
        // A summary needs no reasoning.
        let think = self.think_switch(false);
        // Native tools ride outside the text, so offering the same ones keeps the request an
        // extension of the last call and the server's cache of it holds: without them it
        // diverges right after the system prompt and the whole history is prefilled again.
        let keep_prefix = matches!(self.tool_mode, ToolMode::Native | ToolMode::Auto);
        let (mut resp, streamed) = self
            .call("compacting", &msgs, true, keep_prefix, think, None)
            .await?;
        self.count_call(resp.usage.clone(), &streamed, true);
        // It called a tool instead of summarizing: ask again with none to call.
        if keep_prefix && resp.message.text().trim().is_empty() {
            let (r, streamed) = self
                .call("compacting", &msgs, true, false, think, None)
                .await?;
            self.count_call(r.usage.clone(), &streamed, true);
            resp = r;
        }
        let summary = resp.message.text();
        if summary.trim().is_empty() {
            anyhow::bail!("compaction produced an empty summary; keeping the full history");
        }
        let before = self.usage.context();
        // Loaded skills' instructions are summarized away; let them load again.
        self.skills_loaded.clear();
        // The structured record, recovered verbatim across repeated compactions: user
        // inputs, files, the latest todos, commands and significant tool calls.
        let record = context::pinned_record(&self.inputs, &self.ctx.todos, &self.messages);
        // A record that filled the window would leave nothing for the summary it follows,
        // so it scales to the window, capped: small models get the essentials.
        let budget = (self.est.chars(self.window) / 8).clamp(1_000, 16_000);
        let record = context::render_record(&record, budget);
        let visual = context::pinned_visual_context(
            &self.messages,
            if self.vision {
                if self.small_window() { 1 } else { 2 }
            } else {
                0
            },
        );
        let compacted_label = format!("{}. Work continues from this alone.)", context::COMPACTION_LABEL);
        let mut compacted = Message::user(format!(
            "{compacted_label}\n\nSummary:\n{summary}\n\n{record}"
        ));
        compacted.content.extend(visual);
        self.reset(vec![compacted]);
        self.usage = Usage {
            input: resp.usage.output,
            ..Default::default()
        };
        self.emit(Event::Compacted {
            tokens_before: before,
            tokens_after: resp.usage.output,
        });
        self.rebased();
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
        // A chat has no folder, and nothing runs there: not even a command typed with `!`.
        if self.chat {
            self.notice(
                Level::Warn,
                "Commands need a folder, and this conversation doesn't have one. Ask frog to move it into one, or start a conversation in a project.",
            );
            return;
        }
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
                present: None,
                images: Vec::new(),
                app: None,
            },
        });
    }
}

fn ms(d: Duration) -> u64 {
    d.as_millis() as u64
}

/// Memory notes sit next to the session store: `~/.local/share/frog/memory`.
fn memory_root(store: &std::path::Path) -> PathBuf {
    store
        .parent()
        .map(|p| p.join("memory"))
        .unwrap_or_else(crate::memory::default_root)
}

/// Prompt chars that don't live in the history: system prompt and tool schemas.
/// Model calls this engine has made, numbering them in the log.
static NEXT_CALL: AtomicU64 = AtomicU64::new(0);

/// "0.4s", "12.3s", "3m 05s".
fn secs(d: Duration) -> String {
    let s = d.as_secs_f64();
    if s < 60.0 {
        format!("{s:.1}s")
    } else {
        format!("{}m {:02}s", (s / 60.0) as u64, (s % 60.0) as u64)
    }
}

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

/// The host a web call reaches, for "always allow" (searches share one key).
fn web_host(name: &str, input: &Value) -> String {
    if name == "WebSearch" {
        return "search".into();
    }
    input["url"]
        .as_str()
        .and_then(|u| tools::web::parse_url(u).ok())
        .and_then(|u| u.host_str().map(String::from))
        .unwrap_or_default()
}

/// What a Screenshot approval covers: one http(s) host, or workspace files.
fn capture_host(input: &Value) -> String {
    let raw = input["url"].as_str().unwrap_or("");
    if !(raw.starts_with("http://") || raw.starts_with("https://")) {
        return "workspace files".into();
    }
    reqwest::Url::parse(raw)
        .ok()
        .and_then(|u| u.host_str().map(String::from))
        .unwrap_or_default()
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
    use crate::protocol::Answer;
    use crate::provider::scripted;
    use serde_json::json;

    /// Scripts for subagents started in a given cwd (each test uses its own directory).
    static CHILD_SCRIPTS: std::sync::LazyLock<Mutex<HashMap<PathBuf, Vec<Vec<Response>>>>> =
        std::sync::LazyLock::new(Default::default);

    pub(super) fn child_script(cwd: &Path) -> Option<Vec<Response>> {
        let mut all = CHILD_SCRIPTS.lock().unwrap();
        let list = all.get_mut(cwd)?;
        (!list.is_empty()).then(|| list.remove(0))
    }

    fn script_child(cwd: &Path, script: Vec<Response>) {
        CHILD_SCRIPTS
            .lock()
            .unwrap()
            .entry(cwd.to_path_buf())
            .or_default()
            .push(script);
    }

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
                model: None,
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

    /// An engine whose scripted provider fails the next calls mid-stream (see
    /// [`scripted::Fail`]) before replaying `script`.
    fn engine_fail(fails: Vec<scripted::Fail>, script: Vec<Response>) -> Handle {
        let mut profile = Profile::new(ProviderKind::Ollama, "test");
        profile.tool_mode = ToolMode::Native;
        let opts = Options {
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
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
            chat: false,
        };
        let client = scripted::Client::new(script);
        *client.fails.lock().unwrap() = fails.into();
        start(opts, Provider::Scripted(client)).unwrap()
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
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
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
            chat: false,
        };
        start(opts, Provider::Scripted(scripted::Client::new(script))).unwrap()
    }

    fn engine_qwen3_mode(script: Vec<Response>, mode: ToolMode) -> Handle {
        let model = "mlx-community/Qwen3-8B-4bit".to_string();
        let mut profile = Profile::new(ProviderKind::Openai, &model.clone());
        profile.sidecar = Some(model);
        profile.tool_mode = mode;
        let opts = Options {
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
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
            chat: false,
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
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
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
            chat: false,
        };
        start(opts, Provider::Scripted(scripted::Client::new(script))).unwrap()
    }

    /// Like `engine_with` (edits allowed), also handing back every request the provider was sent.
    fn engine_sent(
        script: Vec<Response>,
        store: Option<PathBuf>,
        resume: Option<String>,
        window: Option<u64>,
        cwd: PathBuf,
    ) -> (Handle, Arc<Mutex<Vec<String>>>) {
        let mut profile = Profile::new(ProviderKind::Ollama, "test");
        profile.context_window = window;
        profile.tool_mode = ToolMode::Native;
        let opts = Options {
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
            profile_name: "test".into(),
            profile,
            cwd,
            mode: Mode::AcceptEdits,
            can_ask: true,
            resume,
            store,
            sandbox: false,
            rich: false,
            subagent: false,
            chat: false,
        };
        let client = scripted::Client::new(script);
        let sent = client.sent.clone();
        (start(opts, Provider::Scripted(client)).unwrap(), sent)
    }

    /// Whether request `b` only appends to request `a`, so a server's cache of `a` still holds.
    fn extends(a: &str, b: &str) -> bool {
        b.starts_with(a.strip_suffix(']').unwrap())
    }

    /// The model calls a turn's `TurnEnded` recorded.
    fn calls(evs: &[Envelope]) -> Vec<CallTiming> {
        evs.iter()
            .find_map(|e| match &e.event {
                Event::TurnEnded { usage, .. } => usage.timing.as_ref().map(|t| t.calls.clone()),
                _ => None,
            })
            .expect("a timed TurnEnded")
    }

    /// Submit one prompt and collect every event through the following `Idle`.
    async fn run(h: &mut Handle, prompt: &str) -> Vec<Envelope> {
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: prompt.into(),
                images: Vec::new(),
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
        // Leaving the sandbox always asks, so headless it's denied (sandboxed commands run).
        let call = Block::ToolUse {
            id: "t1".into(),
            name: "Bash".into(),
            input: json!({ "command": "touch nope", "unsandboxed": true }),
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

    #[tokio::test(start_paused = true)]
    async fn incomplete_stream_is_retried_before_failing() {
        // A stream that ended before the terminal chunk is retried with backoff; when every
        // attempt dies the same way, the typed error ends the turn.
        let script = (0..4)
            .map(|_| reply(vec![text("partial")], Stop::Incomplete))
            .collect();
        let mut h = engine(script, true);
        let evs = run(&mut h, "hi").await;
        assert_eq!(
            evs.iter()
                .filter(|e| matches!(
                    e.event,
                    Event::Notice { message: ref m, .. } if m.contains("retrying")
                ))
                .count(),
            3
        );
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

    #[tokio::test(start_paused = true)]
    async fn a_gateway_error_before_any_output_is_retried() {
        // The Vercel/zai failure shape: an in-stream error event with nothing streamed yet.
        let mut h = engine_fail(
            vec![scripted::Fail::before(
                "{\"message\":\"Upstream stream ended before terminal chunk\",\"origin\":\"gateway\"}",
            )],
            vec![reply(vec![text("all good")], Stop::End)],
        );
        let evs = run(&mut h, "hi").await;
        // A retry happened: a warn notice, and the turn completed with the good reply.
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::Notice { level: Level::Warn, message: ref m } if m.contains("retrying")
        )));
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
        let messages: Vec<&Event> = evs
            .iter()
            .map(|e| &e.event)
            .filter(|e| matches!(e, Event::ItemCompleted { item: Item::Message { .. }, .. }))
            .collect();
        assert_eq!(messages.len(), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn a_gateway_error_mid_stream_discards_the_partial_and_retries() {
        // The reply had started streaming when the gateway gave up: the partial is dropped
        // (ItemsDiscarded) and the step re-runs from scratch.
        let mut h = engine_fail(
            vec![scripted::Fail::partial(
                "partial ans",
                "{\"message\":\"Upstream stream ended before terminal chunk\",\"origin\":\"gateway\",\"upstream_finish_received\":false}",
            )],
            vec![reply(vec![text("full answer")], Stop::End)],
        );
        let evs = run(&mut h, "hi").await;
        // The streamed partial opened an item, and the retry discarded exactly it.
        let discarded = evs
            .iter()
            .find_map(|e| match &e.event {
                Event::ItemsDiscarded { ids } => Some(ids.clone()),
                _ => None,
            })
            .expect("items_discarded");
        assert_eq!(discarded.len(), 1);
        // Its delta streamed before the discard; no completion ever arrived for it.
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::ItemDelta { id, .. } if discarded.contains(id)
        )));
        assert!(!evs.iter().any(|e| matches!(
            &e.event,
            Event::ItemCompleted { id, .. } if discarded.contains(id)
        )));
        // The turn completed with the re-run's full answer, not the partial.
        let answer = evs
            .iter()
            .find_map(|e| match &e.event {
                Event::ItemCompleted {
                    item: Item::Message { text },
                    ..
                } => Some(text.clone()),
                _ => None,
            })
            .expect("a completed message");
        assert_eq!(answer, "full answer");
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
    }

    #[tokio::test(start_paused = true)]
    async fn an_auth_error_is_never_retried() {
        // 401 from the provider: fail the turn at once — no retry notice, no discard, and
        // the unused scripted reply stays unconsumed.
        let mut h = engine_fail(
            vec![scripted::Fail::http(401, "{\"error\":\"invalid api key\"}")],
            vec![reply(vec![text("never reached")], Stop::End)],
        );
        let evs = run(&mut h, "hi").await;
        assert!(!evs.iter().any(|e| matches!(
            e.event,
            Event::Notice { message: ref m, .. } if m.contains("retrying")
        )));
        assert!(!evs.iter().any(|e| matches!(e.event, Event::ItemsDiscarded { .. })));
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::TurnEnded {
                reason: EndReason::Error {
                    error: EngineError::Provider { status: 401, .. }
                },
                ..
            }
        )));
    }

    #[tokio::test(start_paused = true)]
    async fn a_mid_stream_error_retries_only_up_to_budget() {
        // The gateway keeps failing: 3 retries with backoff, then the turn ends with the
        // typed error.
        let fails = (0..=3)
            .map(|_| {
                scripted::Fail::partial(
                    "partial",
                    "{\"message\":\"Upstream stream ended before terminal chunk\",\"origin\":\"gateway\"}",
                )
            })
            .collect();
        let mut h = engine_fail(fails, vec![]);
        let evs = run(&mut h, "hi").await;
        let retries = evs
            .iter()
            .filter(|e| matches!(
                e.event,
                Event::Notice { message: ref m, .. } if m.contains("retrying")
            ))
            .count();
        assert_eq!(retries, 3);
        // Each failed attempt discarded its partial.
        assert_eq!(
            evs.iter()
                .filter(|e| matches!(e.event, Event::ItemsDiscarded { .. }))
                .count(),
            4
        );
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::TurnEnded {
                reason: EndReason::Error {
                    error: EngineError::Provider { status: 502, .. }
                },
                ..
            }
        )));
    }

    #[tokio::test]
    async fn a_reply_cut_off_by_the_output_limit_is_continued() {
        let mut h = engine(
            vec![
                reply(vec![text("part one")], Stop::Length),
                reply(vec![text("part two")], Stop::End),
            ],
            true,
        );
        let evs = run(&mut h, "hi").await;
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
    }

    #[tokio::test]
    async fn max_tokens_is_distinguished() {
        // Continued MAX_CONTINUES times, then still cut off: the turn ends as MaxTokens.
        let mut h = engine(
            (0..=MAX_CONTINUES)
                .map(|_| reply(vec![text("cut off")], Stop::Length))
                .collect(),
            true,
        );
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
        let d = std::env::temp_dir().join(format!("frog-engine-test-{}", session::new_id()));
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

    /// A chat moves into a folder (once the user approves): the rest of the turn runs there,
    /// and the session file now belongs to that folder.
    #[tokio::test]
    async fn use_folder_moves_a_chat_into_a_project() {
        let base = std::env::temp_dir().join(format!("frog-use-folder-{}", new_id()));
        let (chat, project, store) = (base.join("chat"), base.join("project"), base.join("store"));
        for d in [&chat, &project, &store] {
            std::fs::create_dir_all(d).unwrap();
        }
        let project = project.canonicalize().unwrap();
        let move_to = Block::ToolUse {
            id: "f".into(),
            name: crate::folder::TOOL.into(),
            input: json!({ "path": project.to_str().unwrap() }),
        };
        let pwd = Block::ToolUse {
            id: "p".into(),
            name: "Bash".into(),
            input: json!({ "command": "pwd -P" }),
        };
        let script = vec![
            reply(vec![move_to], Stop::ToolUse),
            reply(vec![pwd], Stop::ToolUse),
            reply(vec![text("done")], Stop::End),
        ];
        let mut profile = Profile::new(ProviderKind::Ollama, "test");
        profile.tool_mode = ToolMode::Native;
        let opts = Options {
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
            profile_name: "test".into(),
            profile,
            cwd: chat,
            mode: Mode::Default,
            can_ask: true,
            resume: None,
            store: Some(store.clone()),
            sandbox: false,
            rich: false,
            subagent: false,
            chat: true,
        };
        let mut h = start(opts, Provider::Scripted(scripted::Client::new(script))).unwrap();
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "what's in my project?".into(),
                images: Vec::new(),
            })
            .unwrap();
        let mut evs = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            if let Event::PermissionRequest {
                id, name, always, ..
            } = &env.event
            {
                if name == crate::folder::TOOL {
                    assert!(always.is_empty(), "moving folders can't be always-allowed");
                }
                h.ops
                    .send(Op::Permission {
                        id: id.clone(),
                        decision: Decision::Allow,
                    })
                    .unwrap();
            }
            let idle = matches!(env.event, Event::Idle);
            evs.push(env);
            if idle {
                break;
            }
        }
        assert!(
            evs.iter()
                .any(|e| matches!(&e.event, Event::FolderChanged { cwd } if *cwd == project))
        );
        let pwd_out = evs
            .iter()
            .find_map(|e| match &e.event {
                Event::ItemCompleted {
                    item: Item::ToolCall { name, output, .. },
                    ..
                } if name == "Bash" => Some(output.clone()),
                _ => None,
            })
            .expect("Bash ran after the move");
        assert!(pwd_out.contains(project.to_str().unwrap()), "{pwd_out}");
        let session = session::list(&store, Some(&project)).unwrap();
        assert_eq!(session.len(), 1, "the session file moved to the project");
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(base);
    }

    fn chat_engine(script: Vec<Response>, cwd: PathBuf) -> Handle {
        let mut profile = Profile::new(ProviderKind::Ollama, "test");
        profile.tool_mode = ToolMode::Native;
        let opts = Options {
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
            profile_name: "test".into(),
            profile,
            cwd,
            mode: Mode::Yolo,
            can_ask: true,
            resume: None,
            store: None,
            sandbox: false,
            rich: false,
            subagent: false,
            chat: true,
        };
        start(opts, Provider::Scripted(scripted::Client::new(script))).unwrap()
    }

    /// A chat isn't offered Bash, so a model that calls it anyway gets an error, and nothing
    /// runs, even in yolo mode.
    #[tokio::test]
    async fn a_tool_that_was_not_offered_does_not_run() {
        let dir = std::env::temp_dir().join(format!("frog-unoffered-{}", new_id()));
        std::fs::create_dir_all(&dir).unwrap();
        let marker = dir.join("ran");
        let bash = Block::ToolUse {
            id: "b".into(),
            name: "Bash".into(),
            input: json!({ "command": format!("touch {}", marker.display()) }),
        };
        let script = vec![
            reply(vec![bash], Stop::ToolUse),
            reply(vec![text("ok")], Stop::End),
        ];
        let mut h = chat_engine(script, dir.clone());
        let evs = run(&mut h, "make a file").await;
        assert!(!marker.exists(), "Bash ran in a chat");
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::ItemCompleted { item: Item::ToolCall { name, outcome: ToolOutcome::Error, .. }, .. } if name == "Bash"
        )));
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// `!cmd` in a chat says it needs a folder instead of running.
    #[tokio::test]
    async fn a_chat_refuses_shell_commands() {
        let dir = std::env::temp_dir().join(format!("frog-chat-shell-{}", new_id()));
        std::fs::create_dir_all(&dir).unwrap();
        let marker = dir.join("ran");
        let mut h = chat_engine(Vec::new(), dir.clone());
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Shell {
                command: format!("touch {}", marker.display()),
            })
            .unwrap();
        let evs = until_idle(&mut h).await;
        assert!(!marker.exists(), "the command ran in a chat");
        assert!(
            notices(&evs).iter().any(|n| n.contains("need a folder")),
            "{:?}",
            notices(&evs)
        );
        assert!(
            !evs.iter()
                .any(|e| matches!(e.event, Event::ItemStarted { .. }))
        );
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
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
                images: Vec::new(),
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
    async fn subscribe_while_starting_replays_before_the_first_idle() {
        let dir = tmp_store();
        let mut h = engine_at(
            vec![reply(vec![text("hello")], Stop::End)],
            true,
            Some(dir.clone()),
            None,
        );
        let sid = run(&mut h, "hi").await[0].session.clone();
        shutdown(h).await;

        let mut h = engine_at(
            vec![reply(vec![text("again")], Stop::End)],
            true,
            Some(dir),
            Some(sid.clone()),
        );
        // Asked for straight away, as the app does: answered without waiting to start up.
        h.ops.send(Op::Subscribe { after: 0 }).unwrap();
        let boot = until_idle(&mut h).await;
        assert!(
            matches!(&boot[0].event, Event::Status(_)),
            "the model is named first"
        );
        let synced = boot
            .iter()
            .position(|e| matches!(e.event, Event::Synced { .. }))
            .expect("the replay finishes before the first Idle");
        let replayed: Vec<_> = boot[..synced]
            .iter()
            .filter(|e| e.event.is_durable())
            .collect();
        assert_eq!(
            replayed.len(),
            4,
            "turn_started, item_started, item_completed, turn_ended"
        );
        assert!(matches!(&replayed[0].event, Event::TurnStarted { input, .. } if input == "hi"));

        h.ops
            .send(Op::Submit {
                text: "more".into(),
                images: Vec::new(),
            })
            .unwrap();
        let second = until_idle(&mut h).await;
        assert!(matches!(
            second[0].event,
            Event::TurnStarted { turn: 2, .. }
        ));
        assert!(
            second[0].seq > boot[synced].seq,
            "seq continues past the replay"
        );
        shutdown(h).await;
    }

    /// Append a `turn_started` for turn 1 to a session log, as an engine does when a turn begins.
    fn log_turn_started(dir: &std::path::Path, id: &str) -> Result<()> {
        let mut log = Log::open(dir, id)?;
        log.append(&Record::Event {
            env: Envelope {
                seq: 1,
                session: id.to_string(),
                created: 0,
                event: Event::TurnStarted {
                    turn: 1,
                    input: "go".into(),
                    images: Vec::new(),
                },
            },
        })?;
        Ok(())
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

        drop(log_turn_started(&dir, &id));
        let h = engine_at(vec![], true, Some(dir.clone()), Some(id.clone()));
        shutdown(h).await;
        let loaded = session::load(&dir, &id).unwrap();
        // The turn it died in is ended, cancelled, not left running.
        assert!(loaded.events.iter().any(|e| matches!(
            &e.event,
            Event::TurnEnded {
                turn: 1,
                reason: EndReason::Cancelled,
                ..
            }
        )));
        let last = loaded.messages.last().unwrap();
        assert_eq!(last.role, Role::User);
        assert!(
            last.content
                .iter()
                .any(|b| matches!(b, Block::ToolResult { id, is_error: true, .. } if id == "t1"))
        );
    }

    /// After a restart, `Continue` runs a new turn on the repaired history, telling the model
    /// its last turn was interrupted.
    #[tokio::test]
    async fn continue_after_a_crash_runs_a_new_turn_with_the_note() {
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
        log.append(&Record::Push {
            message: Message {
                role: Role::Assistant,
                content: vec![Block::ToolUse {
                    id: "t1".into(),
                    name: "Bash".into(),
                    input: json!({ "command": "ls" }),
                }],
            },
        })
        .unwrap();
        drop(log);
        drop(log_turn_started(&dir, &id));

        let (mut h, sent) = engine_sent(
            vec![reply(vec![text("done")], Stop::End)],
            Some(dir.clone()),
            Some(id.clone()),
            None,
            std::env::temp_dir(),
        );
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops.send(Op::Continue { note: None }).unwrap();
        let evs = until_idle(&mut h).await;
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::TurnStarted { turn: 2, input, .. } if input == crate::protocol::CONTINUE_NOTE
        )));
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::TurnEnded {
                turn: 2,
                reason: EndReason::Complete,
                ..
            }
        )));
        let req = sent.lock().unwrap().last().cloned().unwrap();
        assert!(req.contains("resumed after the app restarted"));
        assert!(
            req.contains("t1"),
            "the repaired tool call is still in the history"
        );
        shutdown(h).await;
    }

    #[tokio::test]
    async fn memory_commands_answer_without_a_model_call() {
        let root = tmp_store();
        let project = root.join("repo");
        std::fs::create_dir_all(project.join(".git")).unwrap();
        // No scripted replies: a model call would fail the turn.
        let mut h = engine_with(
            vec![],
            true,
            Some(root.join("sessions")),
            None,
            None,
            project,
        );
        let notices = |evs: &[Envelope]| -> Vec<String> {
            evs.iter()
                .filter_map(|e| match &e.event {
                    Event::Notice { message, .. } => Some(message.clone()),
                    _ => None,
                })
                .collect()
        };
        let evs = run(&mut h, "/remember use npm, not pnpm").await;
        assert!(!names(&evs).contains(&"turn_started".to_string()));
        assert!(notices(&evs)[0].starts_with("remembered for this project as `use-npm-not-pnpm`"));
        assert!(root.join("memory/global").read_dir().is_err());

        h.ops
            .send(Op::Submit {
                text: "/memory".into(),
                images: Vec::new(),
            })
            .unwrap();
        let evs = until_idle(&mut h).await;
        assert!(notices(&evs)[0].contains("[project] use-npm-not-pnpm: use npm, not pnpm"));
        shutdown(h).await;
    }

    fn notices(evs: &[Envelope]) -> Vec<String> {
        evs.iter()
            .filter_map(|e| match &e.event {
                Event::Notice { message, .. } => Some(message.clone()),
                _ => None,
            })
            .collect()
    }

    /// Every `.md` under `dir`, recursively.
    fn md_files(dir: &std::path::Path) -> Vec<PathBuf> {
        let mut out = Vec::new();
        let Ok(entries) = std::fs::read_dir(dir) else {
            return out;
        };
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                out.extend(md_files(&p));
            } else if p.extension().is_some_and(|x| x == "md") {
                out.push(p);
            }
        }
        out
    }

    #[tokio::test]
    async fn turns_write_a_summary_that_recall_and_remember_that_find() {
        let root = tmp_store();
        let project = root.join("repo");
        std::fs::create_dir_all(project.join(".git")).unwrap();
        std::fs::create_dir_all(project.join("src")).unwrap();
        std::fs::write(project.join("src/widget.rs"), "pub fn draw() {}\n").unwrap();
        let edit = Block::ToolUse {
            id: "e1".into(),
            name: "Edit".into(),
            input: json!({
                "file_path": "src/widget.rs",
                "old_string": "draw() {}",
                "new_string": "draw() { paint(); }"
            }),
        };
        let read = Block::ToolUse {
            id: "r1".into(),
            name: "Read".into(),
            input: json!({ "file_path": "src/widget.rs" }),
        };
        let script = vec![
            reply(vec![read, edit], Stop::ToolUse),
            reply(vec![text("Fixed the widget paint call.")], Stop::End),
            reply(vec![text("hi")], Stop::End),
        ];
        let mut h = engine_with(
            script,
            true,
            Some(root.join("sessions")),
            None,
            None,
            project.clone(),
        );
        h.ops
            .send(Op::SetMode {
                mode: Mode::AcceptEdits,
            })
            .unwrap();
        // Startup, then the mode change.
        until_idle(&mut h).await;
        until_idle(&mut h).await;
        h.ops
            .send(Op::Submit {
                text: "fix the widget\nit doesn't paint".into(),
                images: Vec::new(),
            })
            .unwrap();
        let evs = until_idle(&mut h).await;
        let sid = evs[0].session.clone();

        let sessions = root.join("memory/projects");
        let files = md_files(&sessions);
        assert_eq!(files.len(), 1, "{files:?} {:?}", notices(&evs));
        let path = &files[0];
        assert_eq!(
            path.file_name().unwrap().to_str().unwrap(),
            format!("{sid}.md")
        );
        assert!(path.parent().unwrap().ends_with("sessions"));
        let summary = std::fs::read_to_string(path).unwrap();
        assert!(summary.contains("title: \"fix the widget\"\n"), "{summary}");
        assert!(
            summary.contains("files: [\"src/widget.rs (+1/-1)\"]\n"),
            "{summary}"
        );
        assert!(summary.contains("outcome: complete\n"));
        assert!(summary.contains(
            "1. User: fix the widget Ran Read, Edit; edited src/widget.rs (+1/-1). Reply: Fixed the widget paint call."
        ), "{summary}");

        // /recall answers from the summary without a model call, by keyword and by file.
        h.ops
            .send(Op::Submit {
                text: "/recall widget paint".into(),
                images: Vec::new(),
            })
            .unwrap();
        let evs = until_idle(&mut h).await;
        assert!(!names(&evs).contains(&"turn_started".to_string()));
        let n = &notices(&evs)[0];
        assert!(
            n.starts_with("1 hit for \"widget paint\":\n- [session "),
            "{n}"
        );
        assert!(n.contains(&sid));
        assert!(n.contains("files: src/widget.rs"));
        h.ops
            .send(Op::Submit {
                text: "/recall file:widget.rs".into(),
                images: Vec::new(),
            })
            .unwrap();
        let evs = until_idle(&mut h).await;
        assert!(notices(&evs)[0].contains(&sid));

        // "Remember that …" saves a note and the turn still runs.
        h.ops
            .send(Op::Submit {
                text: "Remember that widgets paint lazily. Now say hi".into(),
                images: Vec::new(),
            })
            .unwrap();
        let evs = until_idle(&mut h).await;
        assert!(names(&evs).contains(&"turn_started".to_string()));
        assert!(notices(&evs)[0].starts_with("remembered as `widgets-paint-lazily`"));
        assert!(
            root.join("memory/projects")
                .join(
                    md_files(&root.join("memory/projects"))
                        .iter()
                        .find(|p| p.ends_with("widgets-paint-lazily.md"))
                        .unwrap()
                )
                .exists()
        );
        // The note is in the next turn's system prompt and Recall finds both sources.
        h.ops
            .send(Op::Submit {
                text: "/recall lazily".into(),
                images: Vec::new(),
            })
            .unwrap();
        let evs = until_idle(&mut h).await;
        assert!(notices(&evs)[0].contains("[note "), "{}", notices(&evs)[0]);
        shutdown(h).await;
        // The summary now has both turns.
        let summary = std::fs::read_to_string(path).unwrap();
        assert!(
            summary.contains("2. User: Remember that widgets paint lazily. Now say hi"),
            "{summary}"
        );
    }

    #[tokio::test]
    async fn scoped_rules_go_before_the_first_matching_read() {
        let dir = tmp_store();
        std::fs::create_dir_all(dir.join(".frog/rules")).unwrap();
        std::fs::create_dir_all(dir.join("src/api")).unwrap();
        std::fs::write(
            dir.join(".frog/rules/api.md"),
            "---\npaths: [\"src/api/**\"]\n---\nHandlers return Result.\n",
        )
        .unwrap();
        std::fs::write(dir.join(".frog/rules/style.md"), "Two-space indent.\n").unwrap();
        std::fs::write(dir.join("src/api/a.rs"), "fn a() {}\n").unwrap();
        std::fs::write(dir.join("src/api/b.rs"), "fn b() {}\n").unwrap();
        std::fs::write(dir.join("src/lib.rs"), "fn lib() {}\n").unwrap();
        let read = |id: &str, path: &str| Block::ToolUse {
            id: id.into(),
            name: "Read".into(),
            input: json!({ "file_path": path }),
        };
        let script = vec![
            reply(
                vec![read("r1", "src/lib.rs"), read("r2", "src/api/a.rs")],
                Stop::ToolUse,
            ),
            reply(vec![read("r3", "src/api/b.rs")], Stop::ToolUse),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_with(script, true, Some(dir.clone()), None, None, dir.clone());
        let evs = run(&mut h, "look around").await;
        let sid = evs[0].session.clone();
        shutdown(h).await;
        let results: Vec<(String, String)> = logged_blocks(&dir, &sid)
            .into_iter()
            .filter_map(|(_, b)| match b {
                Block::ToolResult { id, content, .. } => Some((id, content)),
                _ => None,
            })
            .collect();
        assert_eq!(results.len(), 3);
        assert!(!results[0].1.contains("<rules"), "lib.rs matches no rule");
        assert!(
            results[1].1.starts_with(
                "<rules for src/api/a.rs>\n## api (src/api/**)\nHandlers return Result.\n</rules>\n"
            ),
            "{}",
            results[1].1
        );
        assert!(!results[2].1.contains("<rules"), "shown once per session");
    }

    #[tokio::test]
    async fn stale_reads_are_pruned_when_the_turn_ends_and_logged() {
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
            reply(vec![text("again")], Stop::End),
        ];
        // Size the window so the fixed prompt plus one read fits under PRUNE_AT, and two land
        // past it but short of COMPACT_AT.
        let fixed = fixed_chars(
            &prompt::system_prompt(
                &dir,
                &Config {
                    hermetic: true,
                    ..Config::default()
                },
                "test",
            ),
            &[tools::specs(), vec![crate::present::spec(false)]].concat(),
        );
        let read_chars: usize = big.lines().map(|l| 6 + 1 + l.len() + 1).sum();
        let window = context::Estimator::default()
            .tokens(((fixed as f64 + 1.8 * read_chars as f64) / context::PRUNE_AT) as usize);
        let (mut h, sent) = engine_sent(script, Some(dir.clone()), None, Some(window), dir.clone());
        let evs = run(&mut h, "look at big.rs twice").await;
        let sid = evs[0].session.clone();
        // Past PRUNE_AT but short of COMPACT_AT: nothing in the turn rewrote what was sent.
        let sent = sent.lock().unwrap().clone();
        assert_eq!(sent.len(), 3);
        assert!(extends(&sent[0], &sent[1]) && extends(&sent[1], &sent[2]));
        assert!(sent[2].matches("fn line_799").count() == 2);
        // The prune comes after the reply, still inside the turn.
        let at = |name: &str| names(&evs).iter().position(|n| n == name).unwrap();
        assert!(
            at("context_pruned")
                > names(&evs)
                    .iter()
                    .rposition(|n| n == "item_completed")
                    .unwrap()
        );
        assert!(at("context_pruned") < at("turn_ended"));
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
        // The prune rewrote what the server has cached, and the next turn's call says so (here
        // nothing warms it: the scripted provider has no prefill).
        h.ops
            .send(Op::Submit {
                text: "again".into(),
                images: Vec::new(),
            })
            .unwrap();
        let next = calls(&until_idle(&mut h).await);
        assert_eq!(next.len(), 1);
        assert_eq!(next[0].extends, Some(false));
        assert!(next[0].reusable.unwrap() < 0.9);
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
    async fn an_edit_leaves_the_next_turns_prompt_cached() {
        let dir = tmp_store();
        std::fs::write(dir.join("lib.rs"), "pub fn one() {}\n").unwrap();
        let write = Block::ToolUse {
            id: "w1".into(),
            name: "Write".into(),
            input: json!({ "file_path": "two.rs", "content": "pub fn two() {}\n" }),
        };
        let script = vec![
            reply(vec![write], Stop::ToolUse),
            reply(vec![text("wrote it")], Stop::End),
            reply(vec![text("ok")], Stop::End),
        ];
        let (mut h, sent) = engine_sent(script, Some(dir.clone()), None, None, dir.clone());
        let first = calls(&run(&mut h, "add two.rs").await);
        h.ops
            .send(Op::Submit {
                text: "thanks".into(),
                images: Vec::new(),
            })
            .unwrap();
        let second = calls(&until_idle(&mut h).await);
        let sent = sent.lock().unwrap().clone();
        assert_eq!(sent.len(), 3);
        // A temporary directory outside a Git worktree has no repo map. Startup and the first
        // turn stay independent of a filesystem walk.
        // The new file changed the project, but not the system prompt the next turn sends.
        assert!(extends(&sent[1], &sent[2]));
        // And the calls say so, for `frog bench` to hold the server's cache to.
        let flags: Vec<_> = first.iter().chain(&second).map(|c| c.extends).collect();
        assert_eq!(flags, [None, Some(true), Some(true)]);
        let reusable = second[0].reusable.unwrap();
        assert!(reusable > 0.9 && reusable < 1.0, "{reusable}");
        shutdown(h).await;
    }

    /// A resumed engine sends the repo map (in the system prompt) its session last logged, not
    /// one rebuilt from the files as they are now: after an edit, that would differ from the map
    /// on, and the server would re-prefill the whole conversation.
    #[tokio::test]
    async fn a_resumed_session_sends_the_prompt_it_left_off_with() {
        let dir = tmp_store();
        std::fs::write(dir.join("lib.rs"), "pub fn one() {}\n").unwrap();
        let write = Block::ToolUse {
            id: "w1".into(),
            name: "Write".into(),
            input: json!({ "file_path": "two.rs", "content": "pub fn two() {}\n" }),
        };
        let script = vec![
            reply(vec![write], Stop::ToolUse),
            reply(vec![text("wrote it")], Stop::End),
        ];
        let (mut h, before) = engine_sent(script, Some(dir.clone()), None, None, dir.clone());
        let sid = run(&mut h, "add two.rs").await[0].session.clone();
        shutdown(h).await;
        // Reopened by a new engine, as when the app quits and comes back.
        let script = vec![reply(vec![text("ok")], Stop::End)];
        let (mut h, after) = engine_sent(script, Some(dir.clone()), Some(sid), None, dir.clone());
        run(&mut h, "thanks").await;
        shutdown(h).await;
        let (before, after) = (before.lock().unwrap(), after.lock().unwrap());
        // The server cached the last request; the resumed one should only append to it.
        assert!(
            extends(before.last().unwrap(), &after[0]),
            "the resumed request rewrites the prefix"
        );
    }

    /// Every block the session log holds, in order.
    fn logged_blocks(dir: &std::path::Path, sid: &str) -> Vec<(Role, Block)> {
        session::load(dir, sid)
            .unwrap()
            .messages
            .into_iter()
            .flat_map(|m| m.content.into_iter().map(move |b| (m.role, b)))
            .collect()
    }

    #[tokio::test]
    async fn named_files_are_inlined_and_count_as_read() {
        let dir = tmp_store();
        std::fs::write(dir.join("calc.py"), "def sub(a, b):\n    return a + b\n").unwrap();
        let edit = Block::ToolUse {
            id: "e1".into(),
            name: "Edit".into(),
            input: json!({
                "file_path": "calc.py",
                "old_string": "return a + b",
                "new_string": "return a - b"
            }),
        };
        let script = vec![
            reply(vec![edit], Stop::ToolUse),
            reply(vec![text("fixed")], Stop::End),
        ];
        let mut h = engine_with(script, true, Some(dir.clone()), None, None, dir.clone());
        h.ops
            .send(Op::SetMode {
                mode: Mode::AcceptEdits,
            })
            .unwrap();
        let evs = run(&mut h, "calc.py has a bug in sub(); fix it.").await;
        let sid = evs[0].session.clone();
        shutdown(h).await;
        let blocks = logged_blocks(&dir, &sid);
        let Block::Text { text: first } = &blocks[0].1 else {
            panic!("expected the user's text first");
        };
        assert!(first.starts_with("calc.py has a bug in sub(); fix it."));
        assert!(first.contains("<file path=\"calc.py\">\ndef sub(a, b):"));
        // Edit without a Read call: the inlined file counts as read.
        assert!(blocks.iter().any(|(_, b)| matches!(
            b,
            Block::ToolResult { id, is_error: false, .. } if id == "e1"
        )));
        assert_eq!(
            std::fs::read_to_string(dir.join("calc.py")).unwrap(),
            "def sub(a, b):\n    return a - b\n"
        );
    }

    #[tokio::test]
    async fn asking_for_a_file_is_nudged_once_toward_read() {
        let dir = tmp_store();
        std::fs::write(dir.join("calc.py"), "def sub(a, b):\n    return a + b\n").unwrap();
        let read = Block::ToolUse {
            id: "r1".into(),
            name: "Read".into(),
            input: json!({ "file_path": "calc.py" }),
        };
        let ask = "Could you please share the contents of calc.py?";
        let script = vec![
            reply(vec![text(ask)], Stop::End),
            reply(vec![read], Stop::ToolUse),
            reply(vec![text(ask)], Stop::End),
        ];
        let mut h = engine_with(script, true, Some(dir.clone()), None, None, dir.clone());
        let evs = run(&mut h, "the subtraction helper is broken; fix it.").await;
        let sid = evs[0].session.clone();
        let notices: Vec<&str> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::Notice { message, .. } => Some(message.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(notices.len(), 1, "{notices:?}");
        assert!(notices[0].contains("reminded it to use its tools"));
        // After tools have run, the same ask ends the turn: nudged at most once.
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
        shutdown(h).await;
        let blocks = logged_blocks(&dir, &sid);
        let nudge = blocks.iter().find_map(|(role, b)| match (role, b) {
            (Role::User, Block::Text { text }) if text.contains("don't ask me") => Some(text),
            _ => None,
        });
        assert!(
            nudge
                .expect("expected a nudge")
                .contains("use Read to open calc.py")
        );
        assert!(blocks.iter().any(|(_, b)| matches!(
            b,
            Block::ToolResult { id, is_error: false, .. } if id == "r1"
        )));
    }

    #[tokio::test]
    async fn plain_questions_are_not_nudged() {
        let mut h = engine(
            vec![reply(
                vec![text(
                    "Could you share more details about the expected behavior?",
                )],
                Stop::End,
            )],
            true,
        );
        let evs = run(&mut h, "something is off").await;
        assert!(!evs.iter().any(|e| matches!(e.event, Event::Notice { .. })));
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
    }

    #[tokio::test]
    async fn long_tool_turn_compacts_again_after_new_messages_fill_the_window() {
        let dir = tmp_store();
        std::fs::write(dir.join("small.txt"), "small result").unwrap();
        let work = |id: &str| {
            reply(
                vec![
                    text(&"Long implementation analysis. ".repeat(1200)),
                    Block::ToolUse {
                        id: id.into(),
                        name: "Read".into(),
                        input: json!({"file_path":"small.txt"}),
                    },
                ],
                Stop::ToolUse,
            )
        };
        let script = vec![
            work("first"),
            reply(vec![text("First summary.")], Stop::End),
            work("second"),
            reply(vec![text("Second summary.")], Stop::End),
            reply(vec![text("Finished.")], Stop::End),
        ];
        let (mut h, sent) = engine_sent(script, None, None, Some(8192), dir);
        let events = run(
            &mut h,
            "Keep the original target and continue until complete.",
        )
        .await;
        assert_eq!(
            events
                .iter()
                .filter(|e| matches!(e.event, Event::Compacted { .. }))
                .count(),
            2
        );
        let requests = sent.lock().unwrap();
        assert_eq!(requests.len(), 5);
        assert!(requests[4].contains("Second summary."));
        assert!(requests[4].contains("Keep the original target"));
        drop(requests);
        shutdown(h).await;
    }

    /// Compacting mid-turn sends the tools the turn's calls did, so the summary request only
    /// appends to what the server has cached instead of diverging after the system prompt.
    #[tokio::test]
    async fn compaction_keeps_the_cached_prefix() {
        let dir = tmp_store();
        std::fs::write(dir.join("small.txt"), "small result").unwrap();
        let script = vec![
            reply(
                vec![
                    text(&"Long implementation analysis. ".repeat(600)),
                    Block::ToolUse {
                        id: "r1".into(),
                        name: "Read".into(),
                        input: json!({"file_path":"small.txt"}),
                    },
                ],
                Stop::ToolUse,
            ),
            reply(vec![text("First summary.")], Stop::End),
            reply(vec![text("Finished.")], Stop::End),
        ];
        let (mut h, _) = engine_sent(script, None, None, Some(8192), dir);
        let calls = calls(&run(&mut h, &"Do the long thing. ".repeat(300)).await);
        shutdown(h).await;
        let flags: Vec<_> = calls.iter().map(|c| c.compact).collect();
        assert_eq!(flags, [false, true, false]);
        let reusable = calls[1].reusable.unwrap();
        // All of the last call is reused, only the reply and the instruction are new (without
        // the tools, only the system prompt would be).
        assert!(
            reusable > 0.4,
            "the summary request re-prefills: {reusable}"
        );
    }

    /// A Python stand-in for an MCP server over stdio that answers `initialize` after `delay`
    /// seconds, with instructions naming its one tool, `ping`.
    fn slow_mcp_server(dir: &Path, delay: f64) {
        mcp_server(dir, delay, &["ping"]);
    }

    /// The same, listing `tools` (each described as "Ping.") in the order given.
    fn mcp_server(dir: &Path, delay: f64, tools: &[&str]) {
        mcp_server_gated(dir, delay, tools, None);
    }

    /// The same, but `initialize` also waits until the `gate` file exists, so a test decides
    /// exactly when the server comes up instead of racing a sleep.
    fn mcp_server_gated(dir: &Path, delay: f64, tools: &[&str], gate: Option<&Path>) {
        let gate = gate.map(|g| g.display().to_string()).unwrap_or_default();
        let tools = json!(
            tools
                .iter()
                .map(|t| json!({"name": t, "description": "Ping.",
                    "inputSchema": {"type": "object", "properties": {}}}))
                .collect::<Vec<_>>()
        );
        let script = format!(
            r#"import json, os, sys, time
GATE = {gate:?}
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m:
        continue
    if m["method"] == "initialize":
        time.sleep({delay})
        while GATE and not os.path.exists(GATE):
            time.sleep(0.01)
        r = {{"protocolVersion": m["params"]["protocolVersion"], "capabilities": {{"tools": {{}}}},
             "serverInfo": {{"name": "slow", "version": "1"}},
             "instructions": "SLOW_MCP_READY: call `ping` to check in."}}
    elif m["method"] == "tools/list":
        r = {{"tools": json.loads('{tools}')}}
    else:
        r = {{}}
    print(json.dumps({{"jsonrpc": "2.0", "id": m["id"], "result": r}}), flush=True)
"#
        );
        std::fs::write(dir.join("slow_mcp.py"), script).unwrap();
        let cfg = json!({"mcpServers": {"slow": {
            "command": "python3",
            "args": [dir.join("slow_mcp.py").display().to_string()],
        }}});
        std::fs::write(dir.join(".mcp.json"), cfg.to_string()).unwrap();
    }

    /// A server that answers nothing must not hold engine startup or the first request.
    #[tokio::test]
    async fn startup_and_first_call_do_not_wait_for_hanging_mcp() {
        let dir = tmp_store();
        let script = vec![reply(vec![text("done")], Stop::End)];
        let hanging = format!("import sys,time\nfor line in sys.stdin:\n time.sleep(60)\n");
        std::fs::write(dir.join("hang_mcp.py"), hanging).unwrap();
        let cfg = json!({"mcpServers": {"hang": {
            "command": "python3",
            "args": [dir.join("hang_mcp.py").display().to_string()],
        }}});
        std::fs::write(dir.join(".mcp.json"), cfg.to_string()).unwrap();
        let started = Instant::now();
        let (mut h, sent) = engine_sent(script, None, None, None, dir);
        let events = run(&mut h, "start now").await;
        shutdown(h).await;
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(
            events
                .iter()
                .any(|e| matches!(e.event, Event::TurnEnded { .. }))
        );
        assert!(!sent.lock().unwrap()[0].contains("mcp__hang"));
    }

    #[tokio::test]
    async fn agent_startup_does_not_walk_a_large_non_repo_directory() {
        let base = std::env::temp_dir().join(format!("frog-large-startup-{}", new_id()));
        let cwd = base.join("project");
        let store = base.join("sessions");
        std::fs::create_dir_all(&cwd).unwrap();
        for i in 0..5_000 {
            std::fs::write(cwd.join(format!("file-{i}.rs")), "fn f() {}\n").unwrap();
        }
        let profile = Profile::new(ProviderKind::Ollama, "test");
        let opts = Options {
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
            profile_name: "test".into(),
            profile,
            cwd,
            mode: Mode::Default,
            can_ask: false,
            resume: None,
            store: Some(store),
            sandbox: false,
            rich: false,
            subagent: false,
            chat: false,
        };
        let started = Instant::now();
        let handle = start(opts, Provider::Scripted(scripted::Client::new(vec![]))).unwrap();
        assert!(started.elapsed() < Duration::from_millis(500));
        drop(handle);
        let _ = std::fs::remove_dir_all(base);
    }

    /// The same MCP tools always go out in the same order, after the built-in ones, however a
    /// server happens to list them.
    #[tokio::test]
    async fn mcp_tools_are_sent_in_a_stable_order_after_the_built_ins() {
        let mut lists = Vec::new();
        for order in [["zeta", "alpha", "mid"], ["mid", "zeta", "alpha"]] {
            let dir = tmp_store();
            mcp_server(&dir, 0.0, &order);
            let script = vec![reply(vec![text("ok")], Stop::End)];
            let (mut h, sent) = engine_sent(script, None, None, None, dir);
            // MCP connects in the background; give the local test server ample time (CI is slow).
            tokio::time::sleep(Duration::from_secs(3)).await;
            run(&mut h, "hi").await;
            shutdown(h).await;
            let sent = sent.lock().unwrap()[0].clone();
            let tools: Vec<String> = sent
                .match_indices("<tool ")
                .map(|(i, _)| sent[i + 6..].split('>').next().unwrap().to_string())
                .collect();
            lists.push(tools);
        }
        assert_eq!(lists[0], lists[1]);
        let mcp: Vec<_> = lists[0]
            .iter()
            .skip_while(|t| !t.starts_with("mcp__"))
            .collect();
        assert_eq!(
            mcp,
            ["mcp__slow__alpha", "mcp__slow__mid", "mcp__slow__zeta"]
        );
    }

    /// A server that comes up after the first call joins on the next turn.
    #[tokio::test]
    async fn late_mcp_tools_wait_for_the_next_turn() {
        let dir = tmp_store();
        // The server stays down until the first turn is over, so it is late by construction.
        let gate = dir.join("mcp.gate");
        mcp_server_gated(&dir, 0.0, &["ping"], Some(&gate));
        let script = vec![
            reply(vec![text("done")], Stop::End),
            reply(vec![text("ok")], Stop::End),
        ];
        let (mut h, sent) = engine_sent(script, None, None, None, dir);
        run(&mut h, "first").await;
        std::fs::write(&gate, "").unwrap();
        // The idle engine emits a status once the server's tools have arrived.
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                if matches!(h.events.recv().await.unwrap().event, Event::Status(_)) {
                    break;
                }
            }
        })
        .await
        .expect("MCP server never connected");
        h.ops
            .send(Op::Submit {
                text: "again".into(),
                images: Vec::new(),
            })
            .unwrap();
        until_idle(&mut h).await;
        shutdown(h).await;
        let sent = sent.lock().unwrap().clone();
        assert_eq!(sent.len(), 2);
        assert!(sent[1].contains("SLOW_MCP_READY"), "MCP never joined");
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
    async fn auto_starts_the_first_turn_then_falls_back_when_native_calls_fail() {
        let text_call =
            r#"<tool_call>{"name":"Glob","arguments":{"pattern":"*.nothing"}}</tool_call>"#;
        let script = vec![
            // The first real request starts in native mode. This model instead writes text calls.
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
    async fn thinking_is_switched_off_for_routine_steps_and_back_on_after_errors() {
        let thought = |t: &str| Block::Thinking {
            text: t.into(),
            signature: None,
        };
        let todo = |id: &str, what: &str| Block::ToolUse {
            id: id.into(),
            name: "TodoWrite".into(),
            input: json!({ "todos": [{ "content": what, "status": "in_progress" }] }),
        };
        let script = vec![
            reply(vec![thought("plan"), todo("t1", "a")], Stop::ToolUse),
            reply(vec![todo("t2", "b")], Stop::ToolUse),
            reply(
                vec![Block::ToolUse {
                    id: "t3".into(),
                    name: "Read".into(),
                    input: json!({ "file_path": "/nonexistent/frog-thinking-test.txt" }),
                }],
                Stop::ToolUse,
            ),
            reply(vec![thought("it's missing"), text("done")], Stop::End),
        ];
        let mut h = engine_qwen3_mode(script, ToolMode::Auto);
        let evs = run(&mut h, "plan it").await;
        let calls = evs
            .iter()
            .find_map(|e| match &e.event {
                Event::TurnEnded { usage, .. } => usage.timing.as_ref().map(|t| t.calls.clone()),
                _ => None,
            })
            .expect("turn timing");
        let no_think: Vec<bool> = calls.iter().map(|c| c.no_think).collect();
        // Plan, then skip after the first TodoWrite and the second, then think after the error.
        assert_eq!(no_think, [false, true, true, false]);
    }

    fn big_read(limit: u32) -> Block {
        Block::ToolUse {
            id: new_id(),
            name: "Read".into(),
            input: json!({ "file_path": "big.txt", "limit": limit }),
        }
    }

    /// Output text of every completed tool call, in order.
    fn tool_outputs(evs: &[Envelope]) -> Vec<String> {
        evs.iter()
            .filter_map(|e| match &e.event {
                Event::ItemCompleted {
                    item: Item::ToolCall { output, .. },
                    ..
                } => Some(output.clone()),
                _ => None,
            })
            .collect()
    }

    fn big_file_dir() -> PathBuf {
        let dir = tmp_store();
        let body: String = (1..=50).map(|i| format!("line {i}\n")).collect();
        std::fs::write(dir.join("big.txt"), body).unwrap();
        dir
    }

    #[tokio::test]
    async fn repeated_read_is_nudged_then_replanned_then_the_turn_stops() {
        let script = (0..LOOP_STOP)
            .map(|_| reply(vec![big_read(5)], Stop::ToolUse))
            .collect();
        let (mut h, sent) = engine_sent(script, None, None, None, big_file_dir());
        let evs = run(&mut h, "read it").await;
        let outs = tool_outputs(&evs);
        assert_eq!(outs.len() as u32, LOOP_STOP);
        // 1st: plain result. 2nd: the same result plus which lines were shown and how to go on.
        assert!(!outs[0].contains("Repeat #"));
        assert!(outs[1].contains("line 5") && outs[1].contains("Repeat #2"));
        assert!(outs[1].contains("lines 1-5") && outs[1].contains("offset=6"));
        // Only the 3rd and 5th calls carry a re-plan message.
        let requests = sent.lock().unwrap();
        let replans = |r: &str| r.matches("You have made the same call").count();
        assert_eq!(replans(&requests[2]), 0);
        assert_eq!(replans(&requests[3]), 1);
        assert!(requests[3].contains("Read big.txt") || requests[3].contains("big.txt"));
        assert_eq!(replans(&requests[5]), 2);
        drop(requests);
        // The last is refused, the turn ends as Looping, with a notice and the work kept.
        assert!(outs[LOOP_STOP as usize - 1].starts_with("Not run"));
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Looping,
                ..
            }
        )));
        assert!(notices(&evs).iter().any(|n| n.contains("Turn stopped")));
    }

    #[tokio::test]
    async fn switching_calls_after_a_replan_keeps_the_turn_going() {
        let grep = Block::ToolUse {
            id: new_id(),
            name: "Grep".into(),
            input: json!({ "pattern": "line 4" }),
        };
        let script = vec![
            reply(vec![big_read(5)], Stop::ToolUse),
            reply(vec![big_read(5)], Stop::ToolUse),
            reply(vec![big_read(5)], Stop::ToolUse),
            reply(vec![grep], Stop::ToolUse),
            reply(vec![text("found it")], Stop::End),
        ];
        let (mut h, sent) = engine_sent(script, None, None, None, big_file_dir());
        let evs = run(&mut h, "read it").await;
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
        assert!(!notices(&evs).iter().any(|n| n.contains("Turn stopped")));
        assert!(sent.lock().unwrap()[3].contains("You have made the same call"));
    }

    #[tokio::test]
    async fn replans_without_a_new_call_stop_the_turn() {
        // Two different calls, each repeated to its 3rd time: 2 re-plans, then a 3rd.
        let other = || Block::ToolUse {
            id: new_id(),
            name: "Glob".into(),
            input: json!({ "pattern": "*.nothing" }),
        };
        let script = vec![
            reply(vec![big_read(5)], Stop::ToolUse),
            reply(vec![other()], Stop::ToolUse),
            reply(vec![big_read(5)], Stop::ToolUse),
            reply(vec![other()], Stop::ToolUse),
            reply(vec![big_read(5)], Stop::ToolUse), // replan 1
            reply(vec![other()], Stop::ToolUse),     // replan 2
            reply(vec![big_read(5)], Stop::ToolUse), // 4th: no replan
            reply(vec![other()], Stop::ToolUse),     // 4th
            reply(vec![big_read(5)], Stop::ToolUse), // replan 3 -> stop
            reply(vec![text("unreachable")], Stop::End),
        ];
        let (mut h, _) = engine_sent(script, None, None, None, big_file_dir());
        let evs = run(&mut h, "read it").await;
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Looping,
                ..
            }
        )));
    }

    fn ask_call() -> Block {
        Block::ToolUse {
            id: "q".into(),
            name: "Ask".into(),
            input: json!({ "question": "Which fix?", "options": ["Truncate", "Checksum"] }),
        }
    }

    /// Submits a message and returns the Ask tool call's output, answering any question with
    /// `answer` (dismissing it, when `None`).
    async fn ask_turn(h: &mut Handle, answer: Option<Answer>) -> String {
        h.ops
            .send(Op::Submit {
                text: "fix it".into(),
                images: Vec::new(),
            })
            .unwrap();
        loop {
            match h.events.recv().await.unwrap().event {
                Event::Question {
                    id,
                    question,
                    options,
                    ..
                } => {
                    assert_eq!(question, "Which fix?");
                    assert_eq!(options.len(), 2);
                    let answer = answer.clone().unwrap_or_default();
                    h.ops.send(Op::Answer { id, answer }).unwrap();
                }
                Event::ItemCompleted {
                    item: Item::ToolCall { name, output, .. },
                    ..
                } if name == "Ask" => return output,
                _ => {}
            }
        }
    }

    #[tokio::test]
    async fn ask_waits_for_the_users_answer() {
        let script = vec![
            reply(vec![ask_call()], Stop::ToolUse),
            reply(vec![text("truncating")], Stop::End),
        ];
        let mut h = engine(script, true);
        h.ops
            .send(Op::SetClientCaps {
                panes: false,
                ask: true,
                sessions: false,
            })
            .unwrap();
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        let answer = Answer {
            choices: vec!["Truncate".into()],
            other: None,
        };
        assert_eq!(
            ask_turn(&mut h, Some(answer)).await,
            "The user chose: Truncate"
        );
    }

    #[tokio::test]
    async fn an_interrupt_dismisses_the_question() {
        let script = vec![reply(vec![ask_call()], Stop::ToolUse)];
        let mut h = engine(script, true);
        h.ops
            .send(Op::SetClientCaps {
                panes: false,
                ask: true,
                sessions: false,
            })
            .unwrap();
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "fix it".into(),
                images: Vec::new(),
            })
            .unwrap();
        let mut asked = None;
        loop {
            match h.events.recv().await.unwrap().event {
                Event::Question { id, .. } => {
                    asked = Some(id);
                    h.ops.send(Op::Interrupt).unwrap();
                }
                Event::QuestionResolved { id, answer } => {
                    assert_eq!(Some(id), asked);
                    assert!(answer.dismissed());
                }
                Event::TurnEnded { reason, .. } => {
                    assert_eq!(reason, EndReason::Cancelled);
                    break;
                }
                _ => {}
            }
        }
        assert!(asked.is_some());
    }

    #[tokio::test]
    async fn ask_needs_a_client_that_shows_questions() {
        let script = vec![
            reply(vec![ask_call()], Stop::ToolUse),
            reply(vec![text("ok")], Stop::End),
        ];
        let mut h = engine(script, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        assert!(
            ask_turn(&mut h, None)
                .await
                .starts_with("There's no `Ask` tool")
        );
    }

    fn list_sessions_call() -> Block {
        Block::ToolUse {
            id: "ls".into(),
            name: "ListSessions".into(),
            input: json!({}),
        }
    }

    fn caps(h: &Handle, sessions: bool) {
        h.ops
            .send(Op::SetClientCaps {
                panes: false,
                ask: false,
                sessions,
            })
            .unwrap();
    }

    #[tokio::test]
    async fn deliver_while_idle_starts_a_wrapped_turn() {
        let mut h = engine(vec![reply(vec![text("noted")], Stop::End)], true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Deliver {
                from: "s1".into(),
                from_name: "Chief".into(),
                message: "status?".into(),
            })
            .unwrap();
        loop {
            if let Event::TurnStarted { input, .. } = h.events.recv().await.unwrap().event {
                assert!(input.starts_with("<session-message from=\"s1\" name=\"Chief\">"));
                assert!(input.contains("status?"));
                break;
            }
        }
    }

    #[tokio::test]
    async fn deliver_while_busy_waits_for_the_turn_boundary() {
        let script = vec![
            reply(vec![list_sessions_call()], Stop::ToolUse),
            reply(vec![text("listed")], Stop::End),
            reply(vec![text("got it")], Stop::End),
        ];
        let mut h = engine(script, true);
        caps(&h, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "who's around?".into(),
                images: Vec::new(),
            })
            .unwrap();
        let mut order = Vec::new();
        loop {
            match h.events.recv().await.unwrap().event {
                Event::SessionRequest { id, tool, .. } => {
                    assert_eq!(tool, "ListSessions");
                    // Mid-turn: queued, not an interrupt.
                    h.ops
                        .send(Op::Deliver {
                            from: "s2".into(),
                            from_name: "Manager".into(),
                            message: "done".into(),
                        })
                        .unwrap();
                    h.ops
                        .send(Op::SessionReply {
                            id,
                            result: Some(json!([{ "id": "s2", "name": "Manager" }])),
                            error: None,
                        })
                        .unwrap();
                    order.push("request".to_string());
                }
                Event::ItemCompleted {
                    item: Item::ToolCall { name, output, .. },
                    ..
                } if name == "ListSessions" => {
                    assert!(output.contains("Manager"));
                    order.push("tool".into());
                }
                Event::TurnStarted { turn, input, .. } => {
                    order.push(format!(
                        "start {turn} {}",
                        input.starts_with("<session-message")
                    ));
                }
                Event::TurnEnded { turn, reason, .. } => {
                    assert!(matches!(reason, EndReason::Complete), "{reason:?}");
                    order.push(format!("end {turn}"));
                    if turn == 2 {
                        break;
                    }
                }
                _ => {}
            }
        }
        assert_eq!(
            order,
            [
                "start 1 false",
                "request",
                "tool",
                "end 1",
                "start 2 true",
                "end 2"
            ]
        );
    }

    #[tokio::test]
    async fn session_tools_need_a_client_that_hosts_sessions() {
        let script = vec![
            reply(vec![list_sessions_call()], Stop::ToolUse),
            reply(vec![text("ok")], Stop::End),
        ];
        let mut h = engine(script, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "list".into(),
                images: Vec::new(),
            })
            .unwrap();
        loop {
            match h.events.recv().await.unwrap().event {
                Event::SessionRequest { .. } => panic!("not offered without the capability"),
                Event::ItemCompleted {
                    item: Item::ToolCall { name, output, .. },
                    ..
                } if name == "ListSessions" => {
                    assert!(output.starts_with("There's no `ListSessions` tool"));
                    break;
                }
                _ => {}
            }
        }
    }

    #[tokio::test]
    async fn sessions_capability_offers_the_tools_and_frames_messages() {
        let (mut h, sent) = engine_sent(
            vec![reply(vec![text("ok")], Stop::End)],
            None,
            None,
            None,
            std::env::temp_dir(),
        );
        caps(&h, true);
        h.ops
            .send(Op::Submit {
                text: "hi".into(),
                images: Vec::new(),
            })
            .unwrap();
        while !matches!(
            h.events.recv().await.unwrap().event,
            Event::TurnEnded { .. }
        ) {}
        let req = sent.lock().unwrap().last().cloned().unwrap();
        for tool in ["ListSessions", "SendMessage", "StartSession"] {
            assert!(req.contains(tool), "{tool} not offered");
        }
        assert!(req.contains("no user authority"));
    }

    #[tokio::test]
    async fn turn_timing_keeps_permission_waits_out_of_tool_time() {
        let bash = Block::ToolUse {
            id: "b".into(),
            name: "Bash".into(),
            // Leaving the sandbox always asks.
            input: json!({ "command": "sleep 0.2", "unsandboxed": true }),
        };
        let script = vec![
            reply(vec![bash], Stop::ToolUse),
            reply(vec![text("slept")], Stop::End),
        ];
        let mut h = engine(script, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "nap".into(),
                images: Vec::new(),
            })
            .unwrap();
        loop {
            if let Event::PermissionRequest { id, .. } = h.events.recv().await.unwrap().event {
                tokio::time::sleep(Duration::from_millis(1500)).await;
                h.ops
                    .send(Op::Permission {
                        id,
                        decision: Decision::Allow,
                    })
                    .unwrap();
                break;
            }
        }
        let evs = until_idle(&mut h).await;
        let t = evs
            .iter()
            .find_map(|e| match &e.event {
                Event::TurnEnded { usage, .. } => usage.timing.clone(),
                _ => None,
            })
            .expect("turn_ended carries timing");
        assert!(t.user_ms >= 1500, "user wait {}", t.user_ms);
        // The tool sleeps 0.2 s; the 1.5 s permission wait must not be counted in it. The upper
        // bound leaves room for slow CI runners without letting the wait slip in.
        assert!(
            (200..1500).contains(&t.tool_ms),
            "tool time excludes the prompt: {}",
            t.tool_ms
        );
        assert_eq!(t.classifier_ms, 0);
        assert!(t.wall_ms >= t.user_ms + t.tool_ms);
        assert_eq!(
            t.other_ms,
            t.wall_ms - t.prefill_ms - t.decode_ms - t.tool_ms - t.user_ms
        );
        assert_eq!(t.calls.len(), 2);
        assert!(
            t.calls
                .iter()
                .all(|c| (c.prompt_tokens, c.output_tokens, c.compact) == (100, 10, false))
        );
        assert_eq!(t.tools.len(), 1);
        assert_eq!(
            (t.tools[0].id.as_str(), t.tools[0].name.as_str()),
            ("b", "Bash")
        );
        assert_eq!((t.tools[0].ms, t.tools[0].user_ms), (t.tool_ms, t.user_ms));
    }

    #[tokio::test]
    async fn denied_tools_are_timed_as_waiting_not_running() {
        let bash = Block::ToolUse {
            id: "b".into(),
            name: "Bash".into(),
            input: json!({ "command": "touch nope", "unsandboxed": true }),
        };
        let mut h = engine(
            vec![
                reply(vec![bash], Stop::ToolUse),
                reply(vec![text("ok")], Stop::End),
            ],
            false,
        );
        let evs = run(&mut h, "make a file").await;
        let t = evs
            .iter()
            .find_map(|e| match &e.event {
                Event::TurnEnded { usage, .. } => usage.timing.clone(),
                _ => None,
            })
            .unwrap();
        assert_eq!((t.tool_ms, t.tools.len(), t.tools[0].ms), (0, 1, 0));
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
                images: Vec::new(),
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
                images: Vec::new(),
            })
            .unwrap();
        until_idle(&mut h).await;
        h.ops
            .send(Op::Submit {
                text: "bump notes".into(),
                images: Vec::new(),
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
                images: Vec::new(),
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

    #[tokio::test]
    async fn preview_actions_ask_and_round_trip_through_the_client() {
        let open = Block::ToolUse {
            id: "o".into(),
            name: "Preview".into(),
            input: json!({ "action": "open", "url": "http://localhost:3000" }),
        };
        let click = Block::ToolUse {
            id: "c".into(),
            name: "Preview".into(),
            input: json!({ "action": "click", "selector": "#go" }),
        };
        let script = vec![
            reply(vec![open], Stop::ToolUse),
            reply(vec![click], Stop::ToolUse),
            reply(vec![text("clicked")], Stop::End),
        ];
        let mut h = engine(script, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::SetClientCaps {
                panes: true,
                ask: false,
                sessions: false,
            })
            .unwrap();
        until_idle(&mut h).await;
        h.ops
            .send(Op::Submit {
                text: "try it".into(),
                images: Vec::new(),
            })
            .unwrap();
        let (mut asked, mut requested, mut evs) = (Vec::new(), Vec::new(), Vec::new());
        loop {
            let env = h.events.recv().await.unwrap();
            match &env.event {
                Event::PermissionRequest { id, name, arg, .. } => {
                    asked.push((name.clone(), arg.clone()));
                    h.ops
                        .send(Op::Permission {
                            id: id.clone(),
                            decision: Decision::Allow,
                        })
                        .unwrap();
                }
                Event::PaneRequest {
                    call,
                    id,
                    action,
                    args,
                } => {
                    requested.push((id.clone(), *action, args.clone()));
                    h.ops
                        .send(Op::PaneReply {
                            call: call.clone(),
                            result: Some(json!({ "text": "clicked #go" })),
                            error: None,
                        })
                        .unwrap();
                }
                Event::Idle => break,
                _ => {}
            }
            evs.push(env);
        }
        // `open` is a read; `click` asks, then goes to the client's pane.
        assert_eq!(asked, [("Preview".to_string(), "click: #go".to_string())]);
        // `open` waits for the page to load; then the click.
        assert_eq!(
            requested,
            [
                (
                    "p1".to_string(),
                    crate::protocol::PaneAction::Navigate,
                    json!({ "url": "http://localhost:3000", "wait": true })
                ),
                (
                    "p1".to_string(),
                    crate::protocol::PaneAction::Click,
                    json!({ "selector": "#go" })
                )
            ]
        );
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::PaneOpened { id, kind: crate::protocol::PaneKind::Preview, url: Some(u), .. }
                if id == "p1" && u == "http://localhost:3000" && e.event.is_durable()
        )));
        let outputs: Vec<String> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::ItemCompleted {
                    item: Item::ToolCall { output, .. },
                    ..
                } => Some(output.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(
            outputs,
            [
                "Opened preview pane p1 at http://localhost:3000.",
                "clicked #go"
            ]
        );
    }

    #[tokio::test]
    async fn a_small_project_window_still_offers_visual_tools() {
        let mut script = Vec::new();
        for name in ["Image", "Screenshot", "Compare"] {
            script.push(reply(
                vec![Block::ToolUse {
                    id: name.into(),
                    name: name.into(),
                    input: json!({}),
                }],
                Stop::ToolUse,
            ));
        }
        script.push(reply(vec![text("done")], Stop::End));
        let mut h = engine_with(script, false, None, None, Some(8_192), std::env::temp_dir());
        let evs = run(&mut h, "generate, capture and compare").await;
        for name in ["Image", "Screenshot", "Compare"] {
            let outcome = evs.iter().find_map(|e| match &e.event {
                Event::ItemCompleted {
                    id,
                    item: Item::ToolCall { outcome, .. },
                } if id == name => Some(*outcome),
                _ => None,
            });
            // Offered tools reach their permission gate; missing tools return Error.
            assert_eq!(outcome, Some(ToolOutcome::Denied), "{name}");
        }
        shutdown(h).await;
    }

    #[tokio::test]
    async fn a_small_window_still_gets_the_panes() {
        let open = Block::ToolUse {
            id: "o".into(),
            name: "Preview".into(),
            input: json!({ "action": "open", "url": "http://localhost:3000" }),
        };
        let script = vec![
            reply(vec![open], Stop::ToolUse),
            reply(vec![text("open")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, Some(8_192), std::env::temp_dir());
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::SetClientCaps {
                panes: true,
                ask: false,
                sessions: false,
            })
            .unwrap();
        until_idle(&mut h).await;
        h.ops
            .send(Op::Submit {
                text: "open the preview".into(),
                images: Vec::new(),
            })
            .unwrap();
        let mut opened = false;
        loop {
            match h.events.recv().await.unwrap().event {
                Event::PaneOpened {
                    kind: crate::protocol::PaneKind::Preview,
                    ..
                } => opened = true,
                Event::PaneRequest { call, .. } => h
                    .ops
                    .send(Op::PaneReply {
                        call,
                        result: Some(json!({ "loaded": true })),
                        error: None,
                    })
                    .unwrap(),
                Event::Idle => break,
                _ => {}
            }
        }
        assert!(opened);
    }

    #[tokio::test]
    async fn a_preview_that_cannot_load_says_so() {
        let open = Block::ToolUse {
            id: "o".into(),
            name: "Preview".into(),
            input: json!({ "action": "open", "url": "3000" }),
        };
        let script = vec![
            reply(vec![open], Stop::ToolUse),
            reply(vec![text("down")], Stop::End),
        ];
        let mut h = engine(script, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::SetClientCaps {
                panes: true,
                ask: false,
                sessions: false,
            })
            .unwrap();
        until_idle(&mut h).await;
        h.ops
            .send(Op::Submit {
                text: "open it".into(),
                images: Vec::new(),
            })
            .unwrap();
        let mut result = None;
        loop {
            match h.events.recv().await.unwrap().event {
                Event::PaneRequest { call, .. } => h
                    .ops
                    .send(Op::PaneReply {
                        call,
                        result: None,
                        error: Some("Could not connect to the server.".into()),
                    })
                    .unwrap(),
                Event::ItemCompleted {
                    item:
                        Item::ToolCall {
                            output, outcome, ..
                        },
                    ..
                } => result = Some((output, outcome)),
                Event::Idle => break,
                _ => {}
            }
        }
        let (out, outcome) = result.unwrap();
        assert_eq!(outcome, ToolOutcome::Error);
        assert!(
            out.contains("couldn't load http://localhost:3000")
                && out.contains("Could not connect"),
            "{out}"
        );
    }

    #[tokio::test]
    async fn preview_needs_a_pane_client() {
        let open = Block::ToolUse {
            id: "o".into(),
            name: "Preview".into(),
            input: json!({ "action": "open", "url": "http://localhost:3000" }),
        };
        let mut h = engine(
            vec![
                reply(vec![open], Stop::ToolUse),
                reply(vec![text("no")], Stop::End),
            ],
            true,
        );
        let evs = run(&mut h, "try it").await;
        let out = evs.iter().find_map(|e| match &e.event {
            Event::ItemCompleted {
                item: Item::ToolCall {
                    output, outcome, ..
                },
                ..
            } => Some((output.clone(), *outcome)),
            _ => None,
        });
        let (out, outcome) = out.unwrap();
        // Without a client to host panes, Preview isn't offered, so a call to it is refused.
        assert_eq!(outcome, ToolOutcome::Error);
        assert!(out.contains("no `Preview` tool"), "{out}");
    }

    #[tokio::test]
    async fn pane_lifecycle_is_logged_but_screens_are_not() {
        let dir = tmp_store();
        let mut h = engine_at(
            vec![reply(vec![text("hello")], Stop::End)],
            true,
            Some(dir.clone()),
            None,
        );
        // A turn first, so the session log exists.
        let first = run(&mut h, "hi").await;
        let sid = first[0].session.clone();
        h.ops
            .send(Op::PaneOpen {
                kind: crate::protocol::PaneKind::Terminal,
                cwd: None,
                url: None,
                cols: Some(80),
                rows: Some(24),
            })
            .unwrap();
        let mut seen_screen = false;
        loop {
            let env = h.events.recv().await.unwrap();
            match env.event {
                Event::PaneOpened { ref id, .. } => {
                    assert_eq!(id, "t1");
                    h.ops
                        .send(Op::PaneInput {
                            id: id.clone(),
                            data: "echo pane-ok\n".into(),
                        })
                        .unwrap();
                }
                Event::PaneScreen { lines, cols, .. } => {
                    assert_eq!(cols, 80);
                    if lines.iter().any(|l| l.contains("pane-ok")) && !seen_screen {
                        seen_screen = true;
                        h.ops.send(Op::PaneClose { id: "t1".into() }).unwrap();
                    }
                }
                Event::PaneClosed { id, .. } => {
                    assert_eq!(id, "t1");
                    break;
                }
                _ => {}
            }
        }
        shutdown(h).await;
        let logged = names(&session::load(&dir, &sid).unwrap().events);
        assert!(logged.contains(&"pane_opened".to_string()));
        assert!(logged.contains(&"pane_closed".to_string()));
        assert!(!logged.contains(&"pane_screen".to_string()));
    }

    /// An engine in `dir` (edits allowed) whose provider streams each tool call's arguments
    /// and then keeps decoding for `decode`, with early tools on or off. Its session log goes
    /// to `store`, outside the project, as it does outside tests: a log inside the project
    /// changes between a reply ending and its tools running, so an early Grep would see an
    /// older log than a late one.
    fn engine_early(
        script: Vec<Response>,
        early: bool,
        tool_mode: ToolMode,
        decode: Duration,
        dir: &Path,
        store: &Path,
    ) -> (Handle, Arc<Mutex<Vec<String>>>) {
        let mut profile = Profile::new(ProviderKind::Ollama, "test");
        profile.tool_mode = tool_mode;
        let mut cfg = Config::default();
        cfg.early_tools = early;
        let opts = Options {
            cfg,
            profile_name: "test".into(),
            profile,
            cwd: dir.to_path_buf(),
            mode: Mode::AcceptEdits,
            can_ask: false,
            resume: None,
            store: Some(store.to_path_buf()),
            sandbox: false,
            rich: false,
            subagent: false,
            chat: false,
        };
        let mut client = scripted::Client::new(script);
        client.tool_args = Some(decode);
        let sent = client.sent.clone();
        (start(opts, Provider::Scripted(client)).unwrap(), sent)
    }

    fn turn_timing(evs: &[Envelope]) -> TurnTiming {
        evs.iter()
            .find_map(|e| match &e.event {
                Event::TurnEnded { usage, .. } => usage.timing.clone(),
                _ => None,
            })
            .expect("turn_ended carries timing")
    }

    /// A logged event with what differs from run to run (clock, session id, generated ids,
    /// timing) taken out.
    fn stable(env: &Envelope) -> Value {
        fn scrub(v: &mut Value) {
            match v {
                Value::Object(m) => {
                    for k in ["created", "session", "timing", "tokens_per_sec"] {
                        m.remove(k);
                    }
                    m.values_mut().for_each(scrub);
                }
                Value::Array(a) => a.iter_mut().for_each(scrub),
                Value::String(s) if s.starts_with("call_") => *s = "call_".into(),
                _ => {}
            }
        }
        let mut v = serde_json::to_value(env).unwrap();
        scrub(&mut v);
        v
    }

    /// One prompt through a fresh engine in a fresh project: the requests the model got, the
    /// session as logged (history, then events), and the turn's timing.
    async fn early_run(
        script: Vec<Response>,
        early: bool,
        tool_mode: ToolMode,
        files: &[(&str, &str)],
    ) -> (Vec<String>, String, Vec<String>, TurnTiming) {
        let (dir, store) = (tmp_store(), tmp_store());
        for (name, body) in files {
            std::fs::write(dir.join(name), body).unwrap();
        }
        let decode = Duration::from_millis(80);
        let (mut h, sent) = engine_early(script, early, tool_mode, decode, &dir, &store);
        let evs = run(&mut h, "look").await;
        let sid = evs[0].session.clone();
        shutdown(h).await;
        let logged = session::load(&store, &sid).unwrap();
        let here = |s: &str| s.replace(dir.to_str().unwrap(), "<dir>");
        let sent = sent.lock().unwrap().iter().map(|s| here(s)).collect();
        let history = here(&serde_json::to_string(&logged.messages).unwrap());
        let events = logged
            .events
            .iter()
            .map(|e| here(&stable(e).to_string()))
            .collect();
        (sent, history, events, turn_timing(&evs))
    }

    fn read_call(id: &str, path: &str) -> Block {
        Block::ToolUse {
            id: id.into(),
            name: "Read".into(),
            input: json!({ "file_path": path }),
        }
    }

    fn result_of(history: &str, call: &str) -> String {
        serde_json::from_str::<Vec<Message>>(history)
            .unwrap()
            .into_iter()
            .flat_map(|m| m.content)
            .find_map(|b| match b {
                Block::ToolResult { id, content, .. } if id == call => Some(content),
                _ => None,
            })
            .unwrap()
    }

    #[tokio::test]
    async fn early_reads_match_the_late_path_exactly() {
        let script = || {
            vec![
                reply(
                    vec![
                        text("Looking."),
                        read_call("r1", "a.rs"),
                        Block::ToolUse {
                            id: "g1".into(),
                            name: "Grep".into(),
                            input: json!({ "pattern": "fn", "output_mode": "content" }),
                        },
                        read_call("r2", "missing.rs"),
                    ],
                    Stop::ToolUse,
                ),
                reply(vec![text("done")], Stop::End),
            ]
        };
        let files = [("a.rs", "fn a() {}\n"), ("b.rs", "fn b() {}\n")];
        let on = early_run(script(), true, ToolMode::Native, &files).await;
        let off = early_run(script(), false, ToolMode::Native, &files).await;
        let early: Vec<bool> = on.3.tools.iter().map(|t| t.early).collect();
        assert_eq!(early, [true, true, true]);
        assert!(off.3.tools.iter().all(|t| !t.early));
        assert_eq!(off.3.early_ms, 0);
        // The model saw the same thing, the session logged the same history and events.
        assert_eq!(on.0, off.0);
        assert_eq!(on.1, off.1);
        assert_eq!(on.2, off.2);
        assert!(result_of(&on.1, "r1").contains("fn a()"));
        assert!(result_of(&on.1, "g1").contains("b.rs"));
        assert!(result_of(&on.1, "r2").contains("cannot read"));
        // They ran while the reply was still streaming, so the turn barely waited, and that
        // time isn't counted twice.
        let t = &on.3;
        assert!(t.tool_ms < 80, "waited {}ms", t.tool_ms);
        assert!(t.wall_ms >= t.prefill_ms + t.decode_ms + t.tool_ms);
    }

    #[tokio::test]
    async fn text_mode_calls_start_early_too() {
        let call = |path: &str| {
            format!(
                "<tool_call>\n{{\"name\": \"Read\", \"arguments\": {{\"file_path\": \"{path}\"}}}}\n</tool_call>\n"
            )
        };
        let script = || {
            vec![
                reply(
                    vec![text(&format!(
                        "Let me look.\n{}{}",
                        call("a.rs"),
                        call("b.rs")
                    ))],
                    Stop::End,
                ),
                reply(vec![text("done")], Stop::End),
            ]
        };
        let files = [("a.rs", "fn a() {}\n"), ("b.rs", "fn b() {}\n")];
        let on = early_run(script(), true, ToolMode::Text, &files).await;
        let off = early_run(script(), false, ToolMode::Text, &files).await;
        let early: Vec<bool> = on.3.tools.iter().map(|t| t.early).collect();
        assert_eq!(early, [true, true]);
        // Text-mode calls get fresh ids; everything else is the same.
        let unid = |v: String| {
            let re = regex::Regex::new(r#"call_[0-9a-f]+"#).unwrap();
            re.replace_all(&v, "call_").into_owned()
        };
        let unid_all = |v: &[String]| v.iter().cloned().map(unid).collect::<Vec<_>>();
        assert_eq!(unid_all(&on.0), unid_all(&off.0));
        assert_eq!(unid(on.1), unid(off.1));
        assert_eq!(on.2, off.2);
    }

    #[tokio::test]
    async fn edits_and_commands_never_start_early_nor_anything_after_them() {
        let edit = Block::ToolUse {
            id: "e1".into(),
            name: "Edit".into(),
            input: json!({ "file_path": "a.rs", "old_string": "fn a()", "new_string": "fn z()" }),
        };
        let bash = Block::ToolUse {
            id: "b1".into(),
            name: "Bash".into(),
            input: json!({ "command": "echo hi" }),
        };
        let script = || {
            vec![
                reply(vec![read_call("r1", "a.rs")], Stop::ToolUse),
                reply(
                    vec![
                        edit.clone(),
                        read_call("r2", "a.rs"),
                        bash.clone(),
                        read_call("r3", "b.rs"),
                    ],
                    Stop::ToolUse,
                ),
                reply(vec![text("done")], Stop::End),
            ]
        };
        let files = [("a.rs", "fn a() {}\n"), ("b.rs", "fn b() {}\n")];
        let on = early_run(script(), true, ToolMode::Native, &files).await;
        let off = early_run(script(), false, ToolMode::Native, &files).await;
        let early: Vec<(&str, bool)> =
            on.3.tools
                .iter()
                .map(|t| (t.name.as_str(), t.early))
                .collect();
        assert_eq!(
            early,
            [
                ("Read", true),
                ("Edit", false),
                ("Read", false),
                ("Bash", false),
                ("Read", false)
            ]
        );
        assert_eq!(on.1, off.1);
        assert_eq!(on.2, off.2);
        // The read after the edit saw the edit.
        let r2 = result_of(&on.1, "r2");
        assert!(r2.contains("fn z()"), "{r2}");
    }

    #[tokio::test(start_paused = true)]
    async fn a_broken_stream_discards_what_started_early() {
        let dir = tmp_store();
        std::fs::write(dir.join("a.rs"), "fn a() {}\n").unwrap();
        let edit = Block::ToolUse {
            id: "e1".into(),
            name: "Edit".into(),
            input: json!({ "file_path": "a.rs", "old_string": "fn a()", "new_string": "fn z()" }),
        };
        let script = (0..4)
            .map(|_| {
                // The read streams, then the stream ends without the server saying it's done;
                // every retry breaks the same way.
                reply(vec![read_call("r1", "a.rs")], Stop::Incomplete)
            })
            .chain(std::iter::once(reply(vec![edit], Stop::ToolUse)))
            .chain(std::iter::once(reply(vec![text("done")], Stop::End)))
            .collect();
        let (mut h, _) = engine_early(
            script,
            true,
            ToolMode::Native,
            Duration::from_millis(30),
            &dir,
            &dir,
        );
        let evs = run(&mut h, "look").await;
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Error { .. },
                ..
            }
        )));
        let tool_item = |e: &Envelope| {
            matches!(
                e.event,
                Event::ItemStarted {
                    kind: ItemKind::ToolCall { .. },
                    ..
                }
            )
        };
        assert!(!evs.iter().any(tool_item));
        // The early read never counted: the edit still needs a read first.
        h.ops
            .send(Op::Submit {
                text: "edit it".into(),
                images: Vec::new(),
            })
            .unwrap();
        let evs = until_idle(&mut h).await;
        let sid = evs[0].session.clone();
        shutdown(h).await;
        let results: Vec<(String, String)> = logged_blocks(&dir, &sid)
            .into_iter()
            .filter_map(|(_, b)| match b {
                Block::ToolResult { id, content, .. } => Some((id, content)),
                _ => None,
            })
            .collect();
        assert_eq!(results.len(), 1, "{results:?}");
        assert!(results[0].1.contains("must Read"), "{}", results[0].1);
    }

    #[tokio::test]
    async fn interrupting_cancels_early_tools() {
        let dir = tmp_store();
        std::fs::write(dir.join("a.rs"), "fn a() {}\n").unwrap();
        let script = vec![
            reply(vec![read_call("r1", "a.rs")], Stop::ToolUse),
            reply(vec![text("done")], Stop::End),
        ];
        let (mut h, _) = engine_early(
            script,
            true,
            ToolMode::Native,
            Duration::from_secs(30),
            &dir,
            &dir,
        );
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "look".into(),
                images: Vec::new(),
            })
            .unwrap();
        let mut evs = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            let read = matches!(&env.event, Event::Progress { label, .. } if label == "Read…");
            evs.push(env);
            if read {
                break;
            }
        }
        // The read started; the model is still "decoding" the rest of its reply.
        tokio::time::sleep(Duration::from_millis(50)).await;
        h.ops.send(Op::Interrupt).unwrap();
        evs.extend(until_idle(&mut h).await);
        let sid = evs[0].session.clone();
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Cancelled,
                ..
            }
        )));
        assert!(!evs.iter().any(|e| matches!(
            e.event,
            Event::ItemStarted {
                kind: ItemKind::ToolCall { .. },
                ..
            }
        )));
        shutdown(h).await;
        assert!(
            !logged_blocks(&dir, &sid)
                .iter()
                .any(|(_, b)| matches!(b, Block::ToolResult { .. }))
        );
    }

    fn call(id: &str, name: &str, input: Value) -> Block {
        Block::ToolUse {
            id: id.into(),
            name: name.into(),
            input,
        }
    }

    /// Collect events until `done` matches one, allowing every permission request on the way.
    async fn drive(h: &mut Handle, done: impl Fn(&Event) -> bool) -> Vec<Envelope> {
        let mut out = Vec::new();
        loop {
            let env = tokio::time::timeout(Duration::from_secs(30), h.events.recv())
                .await
                .expect("timed out waiting for events")
                .expect("event stream closed");
            if let Event::PermissionRequest { id, .. } = &env.event {
                h.ops
                    .send(Op::Permission {
                        id: id.clone(),
                        decision: Decision::Allow,
                    })
                    .unwrap();
            }
            let stop = done(&env.event);
            out.push(env);
            if stop {
                return out;
            }
        }
    }

    fn submit(h: &Handle, text: &str) {
        h.ops
            .send(Op::Submit {
                text: text.into(),
                images: Vec::new(),
            })
            .unwrap();
    }

    fn woke_with(evs: &[Envelope]) -> Option<String> {
        evs.iter().find_map(|e| match &e.event {
            Event::TurnStarted { input, .. } if input.contains("-done id=") => Some(input.clone()),
            _ => None,
        })
    }

    #[tokio::test]
    async fn a_finished_background_task_wakes_an_idle_parent() {
        let dir = tmp_store();
        script_child(
            &dir,
            vec![reply(
                vec![text("the parser lives in src/parse.rs:12")],
                Stop::End,
            )],
        );
        let task = call(
            "t",
            "Task",
            json!({"description": "find parser", "prompt": "where is the parser?", "background": true}),
        );
        let script = vec![
            reply(vec![task], Stop::ToolUse),
            reply(vec![text("started it")], Stop::End),
            reply(vec![text("thanks, found it")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, None, dir.clone());
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        submit(&h, "find the parser in the background");
        let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        let result = evs.iter().find_map(|e| match &e.event {
            Event::ItemCompleted {
                item: Item::ToolCall { output, .. },
                ..
            } => Some(output.clone()),
            _ => None,
        });
        assert!(result.unwrap().contains("task-1"));
        // With nothing else queued, the report starts a turn of its own.
        let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        let input = woke_with(&evs).expect("a turn started by the notice");
        assert!(input.starts_with("<task-done id=task-1>"), "{input}");
        assert!(input.contains("src/parse.rs:12"), "{input}");
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::BackgroundDone { id, status, .. } if id == "task-1" && status == "done"
        )));
        shutdown(h).await;
    }

    #[tokio::test]
    async fn write_mode_subagent_calls_ask_through_the_parent() {
        let dir = tmp_store();
        let write = call(
            "w",
            "Write",
            json!({"file_path": "new.txt", "content": "hi\n"}),
        );
        script_child(
            &dir,
            vec![
                reply(vec![write], Stop::ToolUse),
                reply(vec![text("wrote new.txt")], Stop::End),
            ],
        );
        let task = call(
            "t",
            "Task",
            json!({"description": "write file", "prompt": "create new.txt", "mode": "write"}),
        );
        let script = vec![
            reply(vec![task], Stop::ToolUse),
            reply(vec![text("done")], Stop::End),
        ];
        // Default mode: edits ask.
        let mut h = engine_with(script, true, None, None, None, dir.clone());
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        submit(&h, "have a subagent write it");
        let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        let asked = evs.iter().find_map(|e| match &e.event {
            Event::PermissionRequest {
                name,
                subagent,
                item,
                ..
            } => Some((name.clone(), subagent.clone(), item.clone())),
            _ => None,
        });
        assert_eq!(
            asked,
            Some(("Write".into(), Some("t".into()), "t".into())),
            "the subagent's edit asked the user, labelled with its id"
        );
        assert!(
            evs.iter()
                .any(|e| matches!(e.event, Event::PermissionResolved { .. }))
        );
        assert_eq!(
            std::fs::read_to_string(dir.join("new.txt")).unwrap(),
            "hi\n"
        );
        shutdown(h).await;
    }

    #[tokio::test]
    async fn a_denied_subagent_call_does_not_run() {
        let dir = tmp_store();
        let write = call(
            "w",
            "Write",
            json!({"file_path": "nope.txt", "content": "x"}),
        );
        script_child(
            &dir,
            vec![
                reply(vec![write], Stop::ToolUse),
                reply(vec![text("couldn't write")], Stop::End),
            ],
        );
        let task = call(
            "t",
            "Task",
            json!({"description": "w", "prompt": "write", "mode": "write"}),
        );
        let script = vec![
            reply(vec![task], Stop::ToolUse),
            reply(vec![text("ok")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, None, dir.clone());
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        submit(&h, "go");
        loop {
            if let Event::PermissionRequest { id, .. } = h.events.recv().await.unwrap().event {
                h.ops
                    .send(Op::Permission {
                        id,
                        decision: Decision::Deny,
                    })
                    .unwrap();
                break;
            }
        }
        drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        assert!(!dir.join("nope.txt").exists());
        shutdown(h).await;
    }

    #[tokio::test]
    async fn a_finished_bash_job_reports_its_exit_and_output() {
        let dir = tmp_store();
        let job = call(
            "b",
            "Bash",
            json!({"command": "echo building; echo built ok", "run_in_background": true}),
        );
        let script = vec![
            reply(vec![job], Stop::ToolUse),
            reply(vec![text("it's running")], Stop::End),
            reply(vec![text("the build passed")], Stop::End),
        ];
        let store = tmp_store();
        let mut h = engine_with(script, true, Some(store.clone()), None, None, dir.clone());
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        submit(&h, "build in the background");
        drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        let input = woke_with(&evs).expect("woken by the job");
        assert!(input.starts_with("<job-done id=job-1 exit=0>"), "{input}");
        assert!(input.contains("building\nbuilt ok"), "{input}");
        let sid = evs[0].session.clone();
        // Its output file sits next to the session log; start and finish are logged.
        assert!(store.join(format!("{sid}.jobs/job-1.log")).exists());
        shutdown(h).await;
        let logged = session::events_after(&store, &sid, 0).unwrap();
        assert!(
            logged
                .iter()
                .any(|e| matches!(e.event, Event::BackgroundStarted { .. }))
        );
        assert!(
            logged
                .iter()
                .any(|e| matches!(e.event, Event::BackgroundDone { .. }))
        );
    }

    #[tokio::test]
    async fn background_work_stops_when_the_session_ends() {
        let dir = tmp_store();
        let marker = dir.join("survived");
        let cmd = format!("sleep 2; touch {}", marker.display());
        let script = vec![
            reply(
                vec![
                    call(
                        "b",
                        "Bash",
                        json!({"command": cmd, "run_in_background": true}),
                    ),
                    call("m", "Monitor", json!({"after_s": 1})),
                ],
                Stop::ToolUse,
            ),
            reply(vec![text("started")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, None, dir.clone());
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        submit(&h, "start things");
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        h.ops.send(Op::Shutdown).unwrap();
        let mut stopped = 0;
        while let Some(env) = h.events.recv().await {
            if matches!(&env.event, Event::BackgroundDone { status, .. } if status == "stopped") {
                stopped += 1;
            }
            assert!(
                !matches!(env.event, Event::TurnStarted { .. }),
                "no wakeup after the end"
            );
        }
        assert_eq!(stopped, 2);
        tokio::time::sleep(Duration::from_millis(2_500)).await;
        assert!(!marker.exists(), "the job was killed");
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
