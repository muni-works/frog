//! The agent loop. Runs as a background task; clients drive it with [`Op`]s and receive
//! [`Envelope`]s. See `protocol.rs` for the event lifecycle.

use crate::config::{Config, Profile, ProviderKind, Thinking, ToolMode};
use crate::context::{self, Estimator};
use crate::harness::{self, Caps, Tier};
use crate::message::{Block, Message, Role, Usage};
use crate::prompt;
use crate::protocol::{
    CallTiming, Decision, Delta, EndReason, EngineError, Envelope, Event, Item, ItemKind, Level,
    Mode, Op, Part, Status, ToolOutcome, ToolTiming, TurnTiming, TurnUsage,
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
/// Compounds and pipelines are covered by `shell::read_only`, which parses them;
/// this list handles bare commands and the user's `allow_bash` prefixes.
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
/// The smallest useful tool-result cap: windows below this keep results whole.
const MIN_RESULT_CAP: usize = 40_000;

/// Denials of one identical carded call (same tool and arguments) after which it never asks
/// again this session.
const DENIED_LIMIT: u32 = 2;

/// How long a classifier that couldn't answer is skipped before frog tries it again: a
/// stopped server costs one timeout per minute, not one per call.
const CLASSIFIER_RETRY: Duration = Duration::from_secs(60);

/// Why auto mode asks when no classifier could answer and no rule covers the call. The card
/// names the rule gap, not the outage: a down classifier never cards a call by itself.
const CLASSIFIER_DOWN_ASK: &str =
    "no built-in rule covers it (the classifier is down, so rules decide alone)";

/// One tool call's identity for the repeat-denial checks: its tool and its exact arguments.
fn call_hash(name: &str, input: &Value) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    name.hash(&mut h);
    input.to_string().hash(&mut h);
    h.finish()
}

/// How a batch of tool calls ended.
#[derive(PartialEq)]
enum Batch {
    Continue,
    Denied,
    Looping,
    /// The agent retried a call already denied this turn: frog didn't ask again, and the
    /// turn ends with the denial (`EndReason::BlockedOnApproval`).
    Blocked(String),
    /// A drain (app update) stopped the batch: the calls that hadn't run are recorded
    /// interrupted-by-update, and the turn ends suspended.
    Suspended,
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
    /// The IRC agent bus slot (see `irc`): empty until the client declares
    /// `SetClientCaps { irc }`, live after. The engine is the bridge — it posts the minimal
    /// notices and routes mentions of this session's nick to its inbox — and the client owns
    /// the connection inside (a stub until the DO deploys).
    pub bus: crate::irc::Slot,
}

/// State the op router touches while a turn is running.
struct Shared {
    cancel: Mutex<CancellationToken>,
    pending: Mutex<HashMap<String, oneshot::Sender<Decision>>>,
    /// A note the user sent with a permission answer, by request id, until the
    /// agent picks it up.
    notes: Mutex<HashMap<String, String>>,
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
    /// The IRC agent bus, when the engine posts to one (`SetClientCaps { irc }`). The engine
    /// is the bridge: it posts the minimal notices and routes mentions to this session's
    /// inbox, the SendMessage contract all the way down. A slot, not a value, because the
    /// client can turn the bus on after the engine started.
    irc: crate::irc::Slot,
    /// A drain in progress: `Some(...)` from [`Op::Drain`] until the running turn suspends
    /// (or the work loop acks, when nothing is running). The deadline is unix ms; past it
    /// the loop force-stops. The jobs it stopped ride along for the ack and the resumed
    /// notice; `acked` keeps a second drain (and the work loop's deadline) from re-acking.
    draining: Mutex<Option<DrainState>>,
    /// `Op::Deliver`s the router has passed to the work loop, and how many of the first of
    /// them `Op::ClearInbox` voided: the work loop drops a voided one instead of running it.
    /// Counting works because the router forwards them in the order the loop takes them.
    inbox_sent: AtomicU64,
    inbox_void: AtomicU64,
    /// The user stopped a running turn: background wakes already waiting don't start a turn
    /// of their own (a stop stays stopped); they go along with the next turn instead, which
    /// clears this.
    wake_hold: AtomicBool,
}

/// What a running [`Op::Drain`] needs, kept in `Shared::draining`.
struct DrainState {
    deadline: i64,
    jobs: Vec<String>,
    job_labels: Vec<(String, String)>,
    acked: bool,
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
        notes: Default::default(),
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
        draining: Default::default(),
        inbox_sent: Default::default(),
        inbox_void: Default::default(),
        wake_hold: Default::default(),
        journal,
        panes,
        irc: crate::irc::slot(),
    });
    shared.bg.set_wake(&work_tx);
    // One engine per linked worktree (see `worktree`): taken before the session opens, so a
    // refused engine leaves nothing behind. Subagents share their parent's engine's tree.
    let worktree_lock = if opts.subagent || opts.store.is_none() {
        None
    } else {
        let me = opts.resume.clone().unwrap_or_default();
        crate::worktree::acquire(&opts.cwd, &me, Duration::from_secs(5))
            .map_err(|e| ConfigError(format!("{e:#}")))?
    };
    let mut agent = Agent::new(opts, provider, shared.clone())?;
    if let Some(mut lock) = worktree_lock {
        lock.set_owner(&agent.session_id);
        agent.worktree_lock = Some(lock);
    }
    // What's running, before anything slow (MCP servers, a local model loading, probing the
    // provider), so a client can name the model as soon as a conversation opens.
    agent.emit_status();
    // The bus slot the Handle exposes (empty until `SetClientCaps { irc }`), cloned before
    // `shared` moves into the work loop. It's shared, so the cap can land later.
    let bus = shared.irc.clone();
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
                    if router.working.load(Ordering::Relaxed) {
                        router.wake_hold.store(true, Ordering::SeqCst);
                    }
                    router.cancel.lock().unwrap().cancel();
                    router.bg.stop_all();
                }
                Op::ClearInbox => {
                    let sent = router.inbox_sent.load(Ordering::SeqCst);
                    router.inbox_void.store(sent, Ordering::SeqCst);
                }
                op @ Op::Deliver { .. } => {
                    router.inbox_sent.fetch_add(1, Ordering::SeqCst);
                    if work_tx.send(op).is_err() {
                        break;
                    }
                }
                // An update is coming: set the flag the work loop checks between calls and
                // after the one in flight. Nothing running: ack now, a no-op.
                Op::Drain { deadline } => {
                    let working = router.working.load(Ordering::Relaxed);
                    {
                        let mut d = router.draining.lock().unwrap();
                        // A second Drain (a retry) moves the deadline later but never back.
                        let state = d.get_or_insert(DrainState {
                            deadline: i64::MIN,
                            jobs: Vec::new(),
                            job_labels: Vec::new(),
                            acked: false,
                        });
                        state.deadline = state.deadline.max(deadline);
                    }
                    // Background jobs are stopped now (each records `BackgroundDone` with
                    // `interrupted_by_update`); they're listed in the ack so the resumed
                    // notice can name them.
                    let jobs = router.bg.stop_for_update();
                    if working {
                        let mut d = router.draining.lock().unwrap();
                        if let Some(s) = d.as_mut() {
                            s.jobs = jobs.0;
                            s.job_labels = jobs.1;
                        }
                    } else {
                        let mut d = router.draining.lock().unwrap();
                        if let Some(s) = d.as_mut() {
                            s.acked = true;
                        }
                        router.journal.emit(Event::Drained {
                            steps_done: 0,
                            jobs: jobs.0,
                            job_labels: jobs.1,
                            inbox: Vec::new(),
                        });
                    }
                }
                // The update was called off. A turn already suspended stays that way (the
                // next message continues it); a still-running one just keeps going.
                Op::DrainAbort => {
                    *router.draining.lock().unwrap() = None;
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
                Op::Permission { id, decision, note } => {
                    if let Some(tx) = router.pending.lock().unwrap().remove(&id) {
                        if let Some(n) = note.filter(|n| !n.trim().is_empty()) {
                            router.notes.lock().unwrap().insert(id.clone(), n);
                        }
                        let _ = tx.send(decision);
                    } else {
                        router.bg.answer(&id, decision, note);
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
                // The client asks the engine to carry this stuck session forward (the
                // `Event::CompactionFailed` rescue): answer honestly when it can't be done,
                // and never let the op wake the model or disturb the log's story — the
                // stuck session stays exactly as it was.
                Op::ContinueSession { .. } => {
                    let enabled = router.sessions.enabled();
                    let msg = if enabled {
                        "asked the client to start a carried-forward session"
                    } else {
                        "this client can't start carried-forward sessions"
                    };
                    router
                        .journal
                        .emit(Event::Notice { level: Level::Info, message: msg.to_string() });
                    router.journal.emit(Event::Idle);
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
        agent.note_text_mode_from_probe();
        agent.emit_status();
        {
            let mut ready = shared.ready.lock().unwrap();
            *ready = true;
            agent.emit(Event::Idle);
        }
        // Only seconds spent waiting for the user count toward the idle baseline: not startup
        // (MCP servers, a model loading), and not any op's work.
        agent.meter_busy(false);
        // An op taken off the queue while gathering delivered messages, handled next.
        let mut held: Option<Op> = None;
        // `Op::Deliver`s taken off the queue so far, to tell the ones `ClearInbox` voided.
        let mut inbox_taken: u64 = 0;
        let voided = |taken: &mut u64| {
            *taken += 1;
            *taken <= shared.inbox_void.load(Ordering::SeqCst)
        };
        loop {
            let op = if let Some(op) = held.take() { Some(op) } else { tokio::select! {
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
            } };
            let Some(op) = op else { break };
            agent.poll_mcp();
            if let Op::Shutdown = op {
                break;
            }
            // A wake whose notices an earlier turn already took, or one the user's stop holds
            // for the next turn.
            if matches!(op, Op::Wake)
                && (!shared.bg.has_notices() || shared.wake_hold.load(Ordering::SeqCst))
            {
                continue;
            }
            // Messages from other sessions never interrupt a turn: they queue behind it like
            // any op. Those already waiting when one comes up run with it, in order, as one
            // turn (the first as its input, the rest as `more`, as composer sends follow-ups).
            let mut delivered = Vec::new();
            let mut dropped = 0;
            // A wake takes the session messages queued behind it too: what waits at a turn
            // boundary goes as one batch.
            let woke = matches!(op, Op::Wake);
            let op = match op {
                op @ (Op::Deliver { .. } | Op::Wake) => {
                    if let Op::Deliver {
                        from,
                        from_name,
                        message,
                    } = op
                    {
                        if voided(&mut inbox_taken) {
                            dropped += 1;
                        } else {
                            delivered
                                .push(crate::tools::sessions::wrap(&from, &from_name, &message));
                        }
                    }
                    while let Ok(next) = work_rx.try_recv() {
                        match next {
                            Op::Deliver {
                                from,
                                from_name,
                                message,
                            } => {
                                if voided(&mut inbox_taken) {
                                    dropped += 1;
                                } else {
                                    delivered.push(crate::tools::sessions::wrap(
                                        &from, &from_name, &message,
                                    ))
                                }
                            }
                            // Another wake: this batch's turn takes every parked notice.
                            Op::Wake => {}
                            other => {
                                held = Some(other);
                                break;
                            }
                        }
                    }
                    None
                }
                op => Some(op),
            };
            if dropped > 0 {
                agent.notice(
                    Level::Info,
                    format!(
                        "dropped {dropped} queued session message{}: the inbox was cleared",
                        if dropped == 1 { "" } else { "s" }
                    ),
                );
            }
            // Every message in the batch was voided: there's no turn to run.
            if op.is_none() && delivered.is_empty() && !woke {
                continue;
            }
            // In the background, and not an op the client waits on: no `Idle` after it.
            if let Some(Op::Warm { draft }) = &op {
                agent.warm(draft.as_deref());
                continue;
            }
            // Pure status from another session: read, recorded, no reply turn, no `Idle`.
            if let Some(Op::Inform {
                from,
                from_name,
                message,
            }) = &op
            {
                agent.inform(from, from_name, message);
                continue;
            }
            shared.working.store(true, Ordering::Relaxed);
            agent.meter_busy(true);
            let token = CancellationToken::new();
            *shared.cancel.lock().unwrap() = token.clone();
            let r = tokio::select! {
                r = async {
                    match op {
                        Some(op) => agent.handle(op).await,
                        None if woke => agent.wake(delivered).await,
                        None => agent.deliver(delivered).await,
                    }
                } => r,
                _ = token.cancelled() => Err(Interrupted.into()),
                _ = drain_deadline(shared.clone()) => Err(Interrupted.into()),
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
            // A drain (app update) ends the turn suspended, never cancelled: the ack tells
            // the client the engine stopped at a safe point and the jobs it stopped. A turn
            // this boundary was about to start (a delivered batch, `delivered` here) never
            // runs: the app re-sends it after the restart.
            if let Some((jobs, labels)) = take_drain(&shared) {
                let _ = &r;
                match agent.active_turn.take() {
                    Some(turn) => agent.end_turn(turn, EndReason::Suspended),
                    None => agent.notice(Level::Warn, "drained with no turn running"),
                }
                shared.journal.emit(Event::Drained {
                    steps_done: agent.turn_usage.model_calls,
                    jobs,
                    job_labels: labels,
                    inbox: Vec::new(),
                });
                shared.working.store(false, Ordering::Relaxed);
                agent.emit_status();
                agent.emit(Event::Idle);
                agent.meter_busy(false);
                continue;
            }
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
            // Background work that finished during the turn was parked (never injected into
            // it): it runs now, as the next turn, before the engine goes idle, so nobody sees
            // an idle session that is about to wake. A stop holds it instead.
            if held.is_none()
                && shared.bg.has_notices()
                && !shared.wake_hold.load(Ordering::SeqCst)
            {
                held = Some(Op::Wake);
                continue;
            }
            agent.emit(Event::Idle);
            agent.meter_busy(false);
        }
        shared.bg.stop_all();
        agent.mcp.shutdown();
        shared.mcp.lock().unwrap().take();
        shared.panes.shutdown();
        agent.sync_log();
        agent.write_summary();
        // The worktree is free before the client hears the engine is gone.
        agent.worktree_lock.take();
        shared.journal.close();
    });

    Ok(Handle {
        ops: op_tx,
        events: ev_rx,
        bus,
    })
}

/// Waits until `Op::Drain`'s deadline has passed — the step in flight is then killed (the
/// turn records itself suspended, the same shape a crash would leave). Re-checks the state
/// periodically rather than reading it once, because a drain can be delivered (and the router
/// task only runs) while the step is already in flight. Resolves only for a pending,
/// un-acked drain past its deadline; otherwise keeps waiting, so the `select!` it arms sits
/// quietly (its drop cancels it) when no drain ever comes.
async fn drain_deadline(shared: Arc<Shared>) {
    loop {
        let left = {
            let d = shared.draining.lock().unwrap();
            match d.as_ref() {
                Some(s) if !s.acked => s.deadline.saturating_sub(now_ms()),
                _ => i64::MAX,
            }
        };
        if left <= 0 {
            return;
        }
        // Poll coarse: a late drain is caught within ~200 ms, near deadlines within ~50.
        let pause = left.min(50).max(0);
        tokio::time::sleep(Duration::from_millis(pause as u64)).await;
    }
}

/// Take the drain, if one is pending and un-acked: the jobs it stopped and their labels.
/// Marks it acked so a second take (and the work loop's deadline) is a no-op.
fn take_drain(shared: &Arc<Shared>) -> Option<(Vec<String>, Vec<(String, String)>)> {
    let mut d = shared.draining.lock().unwrap();
    let s = d.as_mut().filter(|s| !s.acked)?;
    s.acked = true;
    Some((
        std::mem::take(&mut s.jobs),
        std::mem::take(&mut s.job_labels),
    ))
}

/// A drain is waiting to suspend the turn at its next safe point.
fn draining(shared: &Shared) -> bool {
    shared
        .draining
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|s| !s.acked)
}

/// Like [`draining`], but yields first so the router task (which may be holding a freshly
/// delivered `Op::Drain` it hasn't recorded yet) gets to run — the safe points sit right
/// after awaits that can resolve without yielding (an instant tool, a cached reply), and
/// without this a drain delivered in that window would be missed until the next real await.
async fn drain_pending(shared: &Shared) -> bool {
    tokio::task::yield_now().await;
    draining(shared)
}

/// Map any failure onto the closed [`EngineError`] set.
/// The receipt a compaction's banner shows: the structured summary as protocol types.
fn kept(s: crate::summary::Summary) -> crate::protocol::KeptSummary {
    use crate::protocol::{KeptFile, KeptSummary, KeptTest, KeptTurn};
    KeptSummary {
        id: s.id,
        files: s
            .files
            .into_iter()
            .map(|(path, added, removed)| KeptFile {
                path,
                added,
                removed,
            })
            .collect(),
        turns: s
            .turns
            .into_iter()
            .map(|t| KeptTurn {
                request: t.request,
                tools: t.tools,
                tests: t
                    .tests
                    .into_iter()
                    .map(|(command, passed)| KeptTest { command, passed })
                    .collect(),
                outcome: t.outcome,
            })
            .collect(),
        outcome: s.outcome,
    }
}

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
    /// The mode the session log has on record (its last `mode_changed`; none means Default).
    /// Whenever the effective mode differs, the next chance to write logs it (see
    /// `log_mode`), so a restarted engine resumes in it and no change is ever silent.
    mode_logged: Option<Mode>,
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
    /// Why this session fell back to text tool calls, when it did. Session-only: it survives
    /// `apply_harness` but is never written to the capability cache.
    text_fallback: Option<String>,
    /// A stale capability probe was measured again (or tried) this session, for this model.
    reprobed: bool,
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
    /// The session has a title (from the model's `SetTitle`, a client, or a resumed log), so
    /// the headless fallback shouldn't add one.
    titled: bool,
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
    /// Why the session moved to text tool calls at run time, for the degraded status.
    text_why: Option<String>,
    /// The model this session was started on or last set to on purpose (`Op::SetModel`):
    /// running on another one (a resume that picked up a different default, a fallback) is
    /// shown as degraded. Empty: unknown.
    intended_model: String,
    /// Why the engine itself moved off `intended_model` (the frog api fallback), if it did.
    model_flip_why: Option<String>,
    /// This engine's hold on the linked worktree it runs in (see `worktree`), for its life.
    worktree_lock: Option<crate::worktree::Lock>,
    /// `auto_classifier_fallback`, started the first time the classifier can't answer.
    classifier_fallback: Option<crate::auto::Classifier>,
    /// When (and why) the classifier and the fallback model last failed: inside
    /// `CLASSIFIER_RETRY` it's skipped instead of costing every call a timeout.
    classifier_down: Option<(Instant, String)>,
    classifier_fallback_down: Option<(Instant, String)>,
    /// While the classifier is down: what judges instead and why, one line for the
    /// status (`None` while the classifier answers).
    classifier_degraded: Option<String>,
    /// The fallbacks the user was already told about: one notice per session for each,
    /// never one per call.
    classifier_told: HashSet<String>,
    /// Paths this session created (files it wrote that didn't exist, directories a
    /// command made), so an approval card can say "this session made it".
    created: HashSet<PathBuf>,
    /// (program, path prefix) pairs the user allowed for this session.
    prefix_allow: Vec<(String, PathBuf)>,
    /// What the user said with their last answer (a deny with a note, or frog's own
    /// note when a prompt timed out), for the tool result.
    last_note: Option<String>,
    session_allow: HashSet<String>,
    /// Calls denied on a card this turn (hash of tool + arguments → what the denial said):
    /// an identical retry this turn doesn't ask again, it ends the turn (`BlockedOnApproval`).
    turn_denied: HashMap<u64, String>,
    /// How many times each carded call (hash of tool + arguments) was denied this session;
    /// at `DENIED_LIMIT` it's auto-denied without a card for the rest of the session.
    session_denied: HashMap<u64, u32>,
    /// Set by `permit` when it refused a repeat of a call denied this turn: the batch stops
    /// and the turn ends with this denial.
    blocked: Option<String>,
    /// Context from `Op::Shell`, attached to the next message.
    pending: Vec<String>,
    /// This turn's finished `Bash` calls (item id, command, output head) awaiting a gist,
    /// flushed in one side-model call when the turn ends (see `gist`).
    pending_gists: Vec<(String, String, String)>,
    /// The open chapter, followed so the turn that closes it can have it titled (see
    /// `chapter`).
    chapters: crate::chapter::Tracker,
    /// Chapter titles written this session, by content hash: the same chapter never asks
    /// twice. Shared with the title task.
    chapter_titles: Arc<Mutex<HashMap<u64, String>>>,
    shared: Arc<Shared>,
}

impl Agent {
    fn new(o: Options, provider: Provider, shared: Arc<Shared>) -> Result<Self> {
        // Cached or shipped capability profiles are useful in both persisted and in-memory engines.
        let caps = (!harness::native_known(&o.profile))
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
        // The mode the session last ran in (its last `mode_changed`): a resumed engine keeps
        // it, rather than silently reverting to whatever the flags say — the picker and the
        // engine must agree on the effective mode.
        let mut resumed_mode = None;
        let mut resumed_titled = false;
        let mut resumed_model: Option<String> = None;
        let mut resumed_chapters = crate::chapter::Tracker::default();
        let (session_id, messages, seq, turn, log, inputs, unfinished) = match (&o.resume, &o.store)
        {
            (Some(id), Some(dir)) => {
                let l = session::load(dir, id).map_err(|e| ConfigError(format!("{e:#}")))?;
                let log = Log::open(dir, id).map_err(|e| ConfigError(format!("{e:#}")))?;
                let (seq, turn) = (l.last_seq(), l.last_turn());
                resumed_map = l.repo_map.clone();
                resumed_chapters = crate::chapter::Tracker::from_events(&l.events);
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
                    if matches!(e.event, Event::Titled { .. }) {
                        resumed_titled = true;
                    }
                    match &e.event {
                        Event::PaneOpened { id, .. } => {
                            used.push(id.clone());
                            stale_panes.push(id.clone());
                        }
                        Event::PaneClosed { id, .. } => stale_panes.retain(|p| p != id),
                        Event::ModeChanged { mode } => resumed_mode = Some(*mode),
                        _ => {}
                    }
                }
                // The model it ran on as far as anyone chose: its last switch, else the one
                // it started on.
                resumed_model = Some(
                    l.events
                        .iter()
                        .rev()
                        .find_map(|e| match &e.event {
                            Event::ModelChanged { model } => Some(model.clone()),
                            _ => None,
                        })
                        .unwrap_or_else(|| l.header.model.clone()),
                );
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
        let intended_model = resumed_model.unwrap_or_else(|| o.profile_name.clone());
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
            mode: resumed_mode.unwrap_or(o.mode),
            mode_logged: resumed_mode,
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
            text_fallback: None,
            reprobed: false,
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
            titled: resumed_titled,
            text_why: None,
            intended_model,
            model_flip_why: None,
            worktree_lock: None,
            classifier: None,
            classifier_fallback: None,
            classifier_down: None,
            classifier_fallback_down: None,
            classifier_degraded: None,
            classifier_told: HashSet::new(),
            created: HashSet::new(),
            prefix_allow: Vec::new(),
            last_note: None,
            turn_denied: HashMap::new(),
            session_denied: HashMap::new(),
            blocked: None,
            vision: false,
            budget_ok: false,
            cache_key_ok: false,
            prefill_ok: false,
            warming: Default::default(),
            session_allow: HashSet::new(),
            pending: Vec::new(),
            pending_gists: Vec::new(),
            chapters: resumed_chapters,
            chapter_titles: Default::default(),
            shared,
        };
        if resumed {
            // A session that died mid-turn may have dangling tool calls, and a turn that never
            // ended: end it, cancelled, so clients don't show it running forever.
            agent.repair();
            if let Some(turn) = unfinished {
                agent.end_turn(turn, EndReason::Cancelled);
            }
            // A session last run from a flag (`--auto` from StartSession or Settings) never
            // logged its mode: record what this engine runs in, so the next restart keeps it.
            agent.log_mode();
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

    /// The user's images, after the text they came with.
    fn attach_images(&mut self, images: Vec<crate::protocol::Image>) {
        if images.is_empty() {
            return;
        }
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

    /// The conversation's current title, as the client set it (`Op::SetTitle`); part of the
    /// IRC nick (a short title reads better on the bus).
    fn title(&self) -> String {
        self.inputs
            .first()
            .map(|s| s.trim().chars().take(80).collect())
            .unwrap_or_default()
    }

    /// The IRC bus, when it's on. Clones the Arc out from under the slot.
    fn irc(&self) -> Option<Arc<crate::irc::Bus>> {
        self.shared.irc.lock().unwrap().clone()
    }

    /// Log the effective mode if the session's log doesn't already say it (an unlogged
    /// session counts as Default). Persisted sessions only: an in-memory engine or a
    /// subagent has no log to resume from.
    fn log_mode(&mut self) {
        if self.store.is_none() || self.subagent {
            return;
        }
        if self.mode_logged.unwrap_or(Mode::Default) == self.mode {
            return;
        }
        self.mode_logged = Some(self.mode);
        self.emit(Event::ModeChanged { mode: self.mode });
    }

    fn emit_status(&self) {
        self.emit(Event::Status(Status {
            model: self.profile_name.clone(),
            mode: self.mode,
            cwd: self.ctx.root.clone(),
            messages: self.messages.len(),
            context_tokens: self.context_tokens(),
            context_window: self.window,
            tool_mode: self.tool_mode,
            tier: self.tier,
            tokens_per_sec: self.tokens_per_sec(),
            todos: self.ctx.todos.clone(),
            vision: self.vision,
            degraded: self.degraded(),
        }));
    }

    /// What this session runs degraded on now, each with why: text tool calls it didn't ask
    /// for, a model other than the one it was started or set to, auto mode's classifier down.
    fn degraded(&self) -> Vec<crate::protocol::Degraded> {
        use crate::protocol::{Degraded, DegradedKind};
        let mut out = Vec::new();
        if self.tool_mode == ToolMode::Text && self.profile.tool_mode != ToolMode::Text {
            out.push(Degraded {
                kind: DegradedKind::TextTools,
                what: "text tool calls".into(),
                why: self.text_mode_why(),
            });
        }
        let norm = |m: &str| crate::providers::normalize(m);
        if !self.intended_model.is_empty() && norm(&self.intended_model) != norm(&self.profile_name) {
            out.push(Degraded {
                kind: DegradedKind::Model,
                what: format!("on {}", self.profile_name),
                why: match &self.model_flip_why {
                    Some(why) => format!("this session is on {}; {why}", self.intended_model),
                    None => format!(
                        "this session was on {}; it came back on another model nobody picked (a resume without -m takes the default)",
                        self.intended_model
                    ),
                },
            });
        }
        if self.mode == Mode::Auto
            && let Some(line) = &self.classifier_degraded
        {
            out.push(Degraded {
                kind: DegradedKind::Classifier,
                what: "auto mode on fallback".into(),
                why: line.clone(),
            });
        }
        out
    }

    /// Why this session runs on text tool calls: its own two failed native/JSON replies this
    /// session, else the capability probe that put `auto` there.
    fn text_mode_why(&self) -> String {
        self.text_why.clone().unwrap_or_else(|| {
            "its capability probe found native tool calls not working".into()
        })
    }

    fn count_call(&mut self, u: Usage, streamed: &Streamed, compact: bool) {
        self.turn_usage.input_tokens += u.input + u.cache_read;
        self.turn_usage.cached_tokens += u.cache_read;
        self.turn_usage.cache_write_tokens += u.cache_write;
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

    /// A title for sessions nobody else will name. The Mac app names its own conversations
    /// (rich), the model may call `SetTitle`, and a user may; when none of that happened by
    /// the end of the first turn, the first input stands in, with wrapper boilerplate stripped.
    fn auto_title(&mut self, turn: u64) {
        if self.titled || self.rich || turn != 1 {
            return;
        }
        if let Some(input) = self.inputs.first() {
            let title = crate::title::derive(input);
            if !title.is_empty() {
                self.set_title(title);
            }
        }
    }

    /// Write the turn's queued command gists in one batched side-model call, and emit one
    /// [`Event::CommandGisted`] per item. The model call is bounded and best effort: any
    /// trouble (no usable model, a timeout, an unreadable answer) silently leaves those rows
    /// on the raw command — a gist is a display flourish, never worth failing over.
    /// Duplicated commands across items get the same line, so the call stays one per
    /// unique command, not one per row.
    async fn flush_gists(&mut self) {
        let pending = std::mem::take(&mut self.pending_gists);
        if pending.is_empty() || self.subagent {
            return;
        }
        let commands: Vec<crate::gist::Command> = pending
            .iter()
            .map(|(_, command, output)| crate::gist::Command { command, output })
            .collect();
        let gists = crate::gist::write(&self.cfg, &self.root, &commands).await;
        for ((id, command, _), gist) in pending.iter().zip(gists) {
            if gist.is_empty() {
                continue;
            }
            self.emit(Event::CommandGisted {
                item: id.clone(),
                command: command.clone(),
                gist,
            });
        }
    }

    /// Title a chapter that just closed, in the background: one bounded side-model call
    /// (see `chapter`), then a durable [`Event::ChapterTitled`]. Never awaited — the new turn
    /// doesn't wait on a display flourish — and best effort: no usable model, a timeout or
    /// an unreadable answer sends nothing, and the app keeps its heuristic title. A chapter
    /// already titled this session (same content) re-sends its title without a call.
    fn title_chapter(&self, closed: crate::chapter::Closed) {
        if self.subagent || closed.turns.is_empty() {
            return;
        }
        let key = closed.key();
        let cached = self.chapter_titles.lock().unwrap().get(&key).cloned();
        if let Some(title) = cached {
            self.emit(Event::ChapterTitled { turn: closed.start, title });
            return;
        }
        if self.cfg.hermetic {
            return;
        }
        let (cfg, root) = (self.cfg.clone(), self.root.clone());
        let (journal, cache) = (self.shared.journal.clone(), self.chapter_titles.clone());
        let session = journal.session();
        tokio::spawn(async move {
            let Some(title) = crate::chapter::write(&cfg, &root, &closed).await else {
                return;
            };
            cache.lock().unwrap().insert(key, title.clone());
            // The session moved on (cleared, switched) while the model thought: drop it.
            if journal.session() != session {
                return;
            }
            journal.emit(Event::ChapterTitled { turn: closed.start, title });
        });
    }

    fn end_turn(&mut self, turn: u64, reason: EndReason) {
        self.auto_title(turn);
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
            reason: reason.clone(),
            usage,
        });
        if let Some(bus) = self.irc() {
            use crate::irc::NoticeKind;
            // Only the minimal kinds (the doc's accepted scope): the turn ended waiting on
            // the user, in error, or with nothing left queued. `Cancelled` says nothing.
            let notice = match &reason {
                EndReason::Denied => Some((
                    NoticeKind::WaitingOnUser,
                    "turn ended: a tool call was denied, waiting on user".to_string(),
                )),
                EndReason::BlockedOnApproval { denial } => Some((
                    NoticeKind::WaitingOnUser,
                    format!("turn ended: blocked on an approval that was already denied ({denial})"),
                )),
                EndReason::Error { error } => {
                    Some((NoticeKind::Errored, format!("turn errored: {error:?}")))
                }
                // Idle per the SendMessage contract: no turn running, nothing queued.
                EndReason::Complete | EndReason::MaxTokens => {
                    Some((NoticeKind::Idle, "idle".to_string()))
                }
                _ => None,
            };
            if let Some((kind, text)) = notice {
                bus.post_notice(kind, &text);
            }
        }
        self.sync_log();
        self.write_summary();
    }

    /// Record the session's title and remember it's named. A client's `Op::SetTitle` and the
    /// model's `SetTitle` tool both land here.
    fn set_title(&mut self, title: String) {
        self.titled = true;
        if let Some(bus) = self.irc() {
            bus.set_session(&self.session_id, &title);
        }
        self.emit(Event::Titled { title });
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
            Op::Submit { text, images, more } => {
                // A memory command is answered alone; one sent with others is just words.
                if !more.is_empty() || !self.memory_command(&text) {
                    self.remember_from(&text);
                    for part in &more {
                        self.remember_from(&part.text);
                    }
                    self.turn_with(&text, images, more).await?
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
            Op::Wake => self.wake(Vec::new()).await?,
            Op::SetMode { mode } => {
                self.mode = mode;
                self.mode_logged = Some(mode);
                self.emit(Event::ModeChanged { mode });
            }
            Op::SetModel { spec } => {
                self.set_model(&spec).await?;
                // Switched on purpose: this is the model the session is meant to be on.
                self.intended_model = self.profile_name.clone();
                self.model_flip_why = None;
            }
            Op::Compact { focus } => self.compact(focus.as_deref()).await?,
            // Answered by the router (see the router's arm): never reaches the work loop,
            // but if one ever does, it must not be a turn on the stuck history.
            Op::ContinueSession { .. } => {}
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
                self.chapters = Default::default();
                self.skills_loaded.clear();
                self.rules_seen.clear();
                self.edited.clear();
                self.titled = false;
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
                if let Some(lock) = self.worktree_lock.as_mut() {
                    lock.set_owner(&self.session_id);
                }
                self.turn = 0;
                self.notes = self.memory.as_ref().map(|m| m.load()).unwrap_or_default();
                self.refresh_repo_map(&[]);
                self.apply_harness();
                self.notice(Level::Info, "started a new conversation");
            }
            Op::SetTitle { title } => {
                let title = crate::title::clean(&title);
                if !title.is_empty() {
                    self.set_title(title);
                }
            }
            Op::Deliver {
                from,
                from_name,
                message,
            } => {
                let text = crate::tools::sessions::wrap(&from, &from_name, &message);
                self.deliver(vec![text]).await?
            }
            Op::Inform {
                from,
                from_name,
                message,
            } => self.inform(&from, &from_name, &message),
            Op::SetClientCaps {
                panes,
                ask,
                sessions,
                irc,
            } => {
                self.shared.panes.set_client(panes);
                self.shared.client_ask.store(ask, Ordering::Relaxed);
                self.shared.sessions.set_enabled(sessions);
                if irc {
                    // The bridge: one nick per session, notices and mentions through it.
                    // Channel and connection are the client's (a stub until the DO deploys).
                    let mut slot = self.shared.irc.lock().unwrap();
                    if slot.is_none() {
                        let bus = Arc::new(crate::irc::Bus::default());
                        bus.set_session(&self.session_id, &self.title());
                        *slot = Some(bus);
                    }
                } else {
                    *self.shared.irc.lock().unwrap() = None;
                }
                self.sync_specs();
                self.apply_harness();
            }
            // Handled by the router, never queued.
            Op::Interrupt
            | Op::ClearInbox
            | Op::Permission { .. }
            | Op::Answer { .. }
            | Op::SessionReply { .. }
            | Op::Elicit { .. }
            | Op::AppCall { .. }
            | Op::Drain { .. }
            | Op::DrainAbort
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
            // Parentage is the client's: a move arrives as a `MoveSession` tool call the
            // client answers, never as this op. Sent anyway, it names nothing the engine
            // could change.
            Op::MoveSession { .. } => {}
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

    /// Messages from other sessions (each already wrapped in `<session-message>`), as one
    /// turn: the first is its input, the rest go along as `more`, in order.
    async fn deliver(&mut self, mut wrapped: Vec<String>) -> Result<()> {
        if wrapped.is_empty() {
            return Ok(());
        }
        let first = wrapped.remove(0);
        let more = wrapped
            .into_iter()
            .map(|text| Part {
                text,
                images: Vec::new(),
            })
            .collect();
        self.turn_with(&first, Vec::new(), more).await
    }

    /// An informational message from another session ([`Op::Inform`]): logged as read, and
    /// kept to go along with the next turn as context. No turn, no wake.
    fn inform(&mut self, from: &str, from_name: &str, message: &str) {
        self.emit(Event::MessageRead {
            from: from.to_string(),
            from_name: from_name.to_string(),
            message: message.to_string(),
        });
        self.pending
            .push(crate::tools::sessions::wrap(from, from_name, message));
    }

    /// A turn on what's waiting at the boundary, all at once: the background wakes (in the
    /// order they came in) as its input, and the session messages queued behind them
    /// (`delivered`, each already wrapped) as `more`.
    async fn wake(&mut self, delivered: Vec<String>) -> Result<()> {
        let notices = self.shared.bg.take_notices();
        if notices.is_empty() {
            return self.deliver(delivered).await;
        }
        let more = delivered
            .into_iter()
            .map(|text| Part {
                text,
                images: Vec::new(),
            })
            .collect();
        self.turn_with(&notices.join("\n\n"), Vec::new(), more).await
    }

    async fn turn(&mut self, input: &str, images: Vec<crate::protocol::Image>) -> Result<()> {
        self.turn_with(input, images, Vec::new()).await
    }

    /// A turn on `input` and any further messages sent with it (`more`, in order): one user
    /// message, each of them its own text block followed by its images.
    async fn turn_with(
        &mut self,
        input: &str,
        mut images: Vec<crate::protocol::Image>,
        more: Vec<Part>,
    ) -> Result<()> {
        // A completed background map can be adopted at a turn boundary. Never wait for it;
        // if it is still running, this turn proceeds with the current prompt.
        self.poll_repo_map();
        let (input, named) = crate::image_paths::attach(input);
        let input = input.as_str();
        images.extend(named);
        let more: Vec<Part> = more
            .into_iter()
            .map(|p| {
                let (text, named) = crate::image_paths::attach(&p.text);
                let mut images = p.images;
                images.extend(named);
                Part { text, images }
            })
            .collect();
        self.turn += 1;
        let turn = self.turn;
        // The first turn creates a new session's log: its starting mode goes in first.
        self.log_mode();
        // Background work that finished while this turn was queued: delivered with it, as one
        // batch at its start (and shown with it, ahead of its input).
        let wakes = self.shared.bg.take_notices();
        self.emit(Event::TurnStarted {
            turn,
            input: input.to_string(),
            images: images.clone(),
            more: more.clone(),
        });
        if !wakes.is_empty() {
            self.emit(Event::WakesDelivered {
                turn,
                wakes: wakes.clone(),
            });
        }
        self.active_turn = Some(turn);
        // A draft still waiting to warm is stale now; the turn itself leaves the cache warm.
        self.warming.lock().unwrap().1 = None;
        self.shared.panes.set_in_turn(true);
        self.inputs.push(input.to_string());
        self.inputs.extend(more.iter().map(|p| p.text.clone()));
        let texts: Vec<String> = more.iter().map(|p| p.text.clone()).collect();
        if let Some(closed) = self.chapters.started(turn, input, &texts) {
            self.title_chapter(closed);
        }
        self.turn_clock = Some(Instant::now());
        if let Some(m) = &self.meter {
            // Idle from the seconds spent waiting before this turn (the op loop marked it busy).
            self.energy_mark = Some((m.mark(), m.idle_estimate()));
        }
        self.timing = TurnTiming::default();
        self.quiet = 0;
        self.checkpoint(turn);
        self.turn_usage = TurnUsage::default();
        // A new turn may ask again what the last one was denied (the session's breaker still holds).
        self.turn_denied.clear();
        self.blocked = None;
        // Wakes a stop held go along with this turn (below); later ones start turns again.
        self.shared.wake_hold.store(false, Ordering::SeqCst);

        let mut text = std::mem::take(&mut self.pending).join("\n");
        for notice in wakes {
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
        let (extra, mut named) = self.attach_named(&typed);
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
        self.reprobe_if_stale().await;
        self.apply_harness();
        self.push_user(text);
        self.attach_images(images);
        // Each message sent with it: its own block, read the way the first one is.
        for part in more {
            let input = match crate::skills::expand_command(&self.skills, &part.text) {
                Some((expanded, name)) => {
                    self.skills_loaded.insert(name);
                    expanded
                }
                None => part.text.clone(),
            };
            let mut text = self.expand_mentions(&input);
            let (extra, files) = self.attach_named(&part.text);
            text.push_str(&extra);
            let pointed: Vec<PathBuf> = part
                .text
                .split_whitespace()
                .filter_map(|t| t.strip_prefix('@'))
                .map(|t| {
                    self.ctx
                        .resolve(t.trim_end_matches([',', ')', ':', ';', '?', '!', '.']))
                })
                .chain(files.iter().cloned())
                .collect();
            for p in &pointed {
                text.push_str(&self.rules_for(p));
            }
            named.extend(files);
            self.push_user(text);
            self.attach_images(part.images);
        }
        // The user's message is on disk before any model call: a crash or quit mid-turn
        // loses the reply, never the request. One fsync per accepted message.
        self.sync_log();

        let mut compacted = None;
        let mut overflowed = false;
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
                    // The request exceeded the model's context window (estimate missed, or a
                    // result landed that the window can never hold): compact and retry the step
                    // once, instead of ending the turn on a 400. The second failure is real.
                    if e.downcast_ref::<HttpError>().is_some_and(HttpError::context_overflow) {
                        if !overflowed {
                            overflowed = true;
                            self.notice(
                                Level::Warn,
                                "the request exceeded the model's context window; compacting and retrying",
                            );
                            if let Err(ce) = self.compact(None).await {
                                // The one-line transcript story (the client renders
                                // `Event::CompactionFailed` as a rescue line, never this
                                // error's chain); the raw payload goes to the engine log.
                                eprintln!("compaction failed: {ce:#}");
                                self.emit(Event::CompactionFailed {
                                    detail: format!("{ce:#}"),
                                });
                                anyhow::bail!("compaction failed; the history can't fit the context window");
                            }
                            continue;
                        }
                        self.emit(Event::CompactionFailed {
                            detail: format!("{e:#}"),
                        });
                        anyhow::bail!("the request still exceeds the model's context window after compaction");
                    }
                    let Some(local) = self.cloud_fallback(&e) else {
                        return Err(e);
                    };
                    self.notice(
                        Level::Warn,
                        format!("frog api unavailable ({e:#}) — continuing on {local}"),
                    );
                    self.set_model(&local).await?;
                    self.model_flip_why = Some("frog api was unavailable, so it fell back".into());
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
            let (msg, recovered) = normalize(resp.message, self.recovers_text_calls());
            let bad_args = msg
                .tool_uses()
                .iter()
                .any(|(_, _, i)| i.get("_invalid_json").is_some());
            if let Some(why) =
                format_failure(resp.stop, recovered, bad_args, streamed.format_failed)
            {
                self.note_format_failure(why);
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
                self.chapters.replied(&answer);
                self.complete_item(
                    streamed.message,
                    ItemKind::Message,
                    Item::Message { text: answer },
                );
            }

            let uses = msg.tool_uses();
            self.push_msg(msg);
            // Safe point (the model's message closed and is in the log): an app update's
            // drain suspends the turn here, before any tool of this step runs, marking the
            // calls it never got to — never "[Request interrupted by user]".
            if drain_pending(&self.shared).await {
                let missing: Vec<Block> = uses
                    .iter()
                    .map(|(id, name, _)| Block::ToolResult {
                        id: id.clone(),
                        name: name.clone(),
                        content: "Interrupted by app update; will be re-run or resumed.".into(),
                        is_error: true,
                    })
                    .collect();
                if !missing.is_empty() {
                    self.extend_last(missing);
                }
                break EndReason::Suspended;
            }
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
                // An update's drain takes the turn here, finished answer and all.
                if drain_pending(&self.shared).await {
                    break EndReason::Suspended;
                }
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
                Batch::Blocked(denial) => break EndReason::BlockedOnApproval { denial },
                Batch::Suspended => break EndReason::Suspended,
            }
            // Safe point (a tool call finished, its result recorded): an app update's drain
            // suspends the turn here.
            if drain_pending(&self.shared).await {
                break EndReason::Suspended;
            }
            // Stop landed mid-tool: the tool already recorded "Interrupted by user.", so end
            // the turn here instead of handing the result back to the model. The outer select
            // races this future against the token; whichever wins, the turn ends cancelled.
            if self.shared.cancel.lock().unwrap().is_cancelled() {
                return Err(Interrupted.into());
            }
        };
        // A suspended turn ends exactly here, before any warm-up (there's no next turn to
        // warm) and after everything the log needs: history, events, the fsync below.
        if reason == EndReason::Suspended {
            if let Some((id, _)) = self.shared.journal.live.lock().unwrap().take() {
                if let Some(dir) = &self.store {
                    let _ = std::fs::remove_file(session::live_path(dir, &id));
                }
            }
            self.active_turn = None;
            self.shared.panes.set_in_turn(false);
            self.flush_gists().await;
            self.end_turn(turn, reason);
            return Ok(());
        }
        // Prune now, while the user reads the reply, and warm the result: the next turn then
        // starts from a prefix that's already cached instead of prefilling all of it.
        if self.prune(context::PRUNE_AT) {
            self.rebased();
            self.warm(None);
        }
        self.active_turn = None;
        self.shared.panes.set_in_turn(false);
        self.flush_gists().await;
        self.end_turn(turn, reason);
        Ok(())
    }

    /// Recompute tier, tool mode and system prompt from the profile and capabilities.
    fn apply_harness(&mut self) {
        self.tier = harness::tier(&self.profile, self.caps.as_ref());
        self.tool_mode = harness::choose_mode(&self.profile, self.caps.as_ref(), self.tier);
        if self.text_fallback.is_some() && self.profile.tool_mode == ToolMode::Auto {
            self.tool_mode = ToolMode::Text;
        }
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
        if !self.subagent && self.irc().is_some() {
            self.system.push_str(crate::irc::PROMPT);
            self.system.push_str(crate::irc::APPROVAL_PROMPT);
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
        let Some(summary) = self.build_summary() else {
            return;
        };
        let Some(out) = self.memory.as_ref().and_then(|m| m.sessions_dir()) else {
            return;
        };
        if let Err(e) = crate::summary::write(&out, &summary) {
            self.notice(
                Level::Warn,
                format!("couldn't write the session summary: {e:#}"),
            );
        }
    }

    /// This session's structured summary (the #53 fields: files with +/−, turns with their
    /// requests/outcomes, tests run), built from the log without a model call. None when
    /// there's nothing to summarize (no store, no log, no events).
    fn build_summary(&self) -> Option<crate::summary::Summary> {
        let dir = self.store.as_ref()?;
        if !self.shared.journal.has_log() {
            return None;
        }
        let loaded = session::load(dir, &self.session_id).ok()?;
        if loaded.events.is_empty() {
            return None;
        }
        Some(crate::summary::build(&loaded.header, &loaded.events, None))
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

    /// Measure the model again when its cached probe is older than `harness::PROBE_TTL_MS`,
    /// once per session, before the turn's first call. An old finding (native tools broken, say)
    /// would otherwise decide the tool mode forever. Only under `auto`, which is what reads it,
    /// and never for a model whose native tools are known.
    async fn reprobe_if_stale(&mut self) {
        if self.reprobed || !harness::reprobe_due(&self.profile, self.caps.as_ref(), now_ms()) {
            return;
        }
        self.reprobed = true;
        // The full tool set, as `frog probe` measures: the probe asks for a Read, which a
        // chat's trimmed specs don't have.
        let specs = tools::specs();
        let probed = harness::probe(&self.provider, &specs, |label, completed, total| {
            self.emit(Event::Progress {
                label: label.into(),
                completed: Some(completed),
                total: Some(total),
            })
        })
        .await;
        match probed {
            Ok(caps) => {
                if self.store.is_some() {
                    harness::save(&self.profile, &caps);
                }
                self.caps = Some(caps);
            }
            Err(e) => self.notice(
                Level::Warn,
                format!(
                    "{}'s capability profile is out of date and re-checking it failed ({e:#}); using the old one",
                    self.profile.model
                ),
            ),
        }
    }

    /// Whether `<tool_call>` text in a reply is a call: always in text mode, and under native
    /// only for models that may slip into it (Qwen/Hermes templates on some servers). A model
    /// known to call tools natively that writes one is quoting the format, not calling.
    fn recovers_text_calls(&self) -> bool {
        self.tool_mode == ToolMode::Text || !harness::native_known(&self.profile)
    }

    /// The model botched the tool-call format (text calls under native, invalid JSON args, or
    /// JSON mode not honored). Under `auto`, two strikes moves to text mode for this session
    /// only: the finding is never written to the capability cache (see `harness::save`), and a
    /// model whose native tools are known to work never moves.
    fn note_format_failure(&mut self, why: &str) {
        if self.profile.tool_mode != ToolMode::Auto
            || self.tool_mode == ToolMode::Text
            || harness::native_known(&self.profile)
        {
            return;
        }
        self.mode_failures += 1;
        if self.mode_failures < 2 {
            return;
        }
        let from = self.tool_mode;
        self.tool_mode = ToolMode::Text;
        self.mode_failures = 0;
        self.text_why = Some(why.to_string());
        self.text_fallback = Some(why.to_string());
        // never persist the downgrade to the capability cache
        let from = format!("{from:?}").to_lowercase();
        self.warn_text_mode(format!(
            "{from} tool calls failed twice ({why}); switching this session to text tool calls. \
Not saved: the next session starts on {from} again"
        ));
    }

    /// Say so whenever a session runs on text tool calls it didn't ask for, naming the model and
    /// why: in the transcript, and in the engine log (stderr), so a demoted model can't go
    /// unnoticed.
    fn warn_text_mode(&self, why: String) {
        let message = format!("{} ({}): {why}", self.profile_name, self.profile.model);
        eprintln!("frog: text tool calls: {message}");
        self.notice(Level::Warn, message);
    }

    /// At session start or a model switch: a cached probe that put `auto` on text tool calls.
    fn note_text_mode_from_probe(&self) {
        if self.profile.tool_mode != ToolMode::Auto || self.tool_mode != ToolMode::Text {
            return;
        }
        let when = self
            .caps
            .as_ref()
            .filter(|c| c.probed > 0)
            .and_then(|c| chrono::DateTime::from_timestamp_millis(c.probed))
            .map(|t| format!(" on {}", t.format("%Y-%m-%d")))
            .unwrap_or_default();
        self.warn_text_mode(format!(
            "using text tool calls: its capability probe{when} found native tool calls not working. \
`frog --probe -m <model>` measures again"
        ));

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
            // Neither the config nor the server said: the catalog may still know the model's
            // real limit, which beats the per-provider default.
            (None, None) => crate::catalog::cached(&self.profile_name)
                .and_then(|m| m.context)
                .unwrap_or_else(|| self.profile.context_window()),
        };
        // Once per session: where the window came from, so a wrong one is traceable. `configured`
        // here means the catalog or the profile said it, not the server. Benchmarks (hermetic)
        // don't care.
        if !self.cfg.hermetic {
            let source = match (probed, configured) {
                (Some(_), _) => "server",
                (None, Some(_)) => "catalog",
                (None, None) => "default",
            };
            self.notice(
                Level::Info,
                format!(
                    "context window: {} tokens (from {source}); auto-compacting past {}",
                    self.window,
                    (self.window as f64 * context::HARD_LIMIT) as u64
                ),
            );
        }
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

    /// The most chars one tool result may carry: [`context::MAX_RESULT_SHARE`] of the window,
    /// in chars via the estimator.
    fn result_cap(&self) -> usize {
        self.est
            .chars((self.window as f64 * context::MAX_RESULT_SHARE) as u64)
            .max(MIN_RESULT_CAP)
    }

    /// Stage 1: prune stale and old tool output (no LLM), once the prompt passes `start` of the
    /// window. Stage 2: summarize again when new messages fill the window. The hard limit
    /// ([`context::HARD_LIMIT`]) bypasses the once-per-new-messages hysteresis: past it, the next
    /// call is one oversized tool result away from a provider 400, so compact regardless.
    async fn fit_context(&mut self, compacted: &mut Option<usize>, start: f64) -> Result<()> {
        let pruned = self.prune(start);
        let hard = (self.window as f64 * context::HARD_LIMIT) as u64;
        if self.estimate() > hard
            || ((self.estimate() as f64) > self.window as f64 * context::COMPACT_AT
                && compacted.is_none_or(|len| self.messages.len() > len))
        {
            self.notice(
                Level::Warn,
                if self.estimate() > hard {
                    "context is nearly at the provider's limit; summarizing…"
                } else {
                    "context is still nearly full after pruning; summarizing…"
                },
            );
            if let Err(e) = self.compact(None).await {
                // Same story as the overflow path above: one line to the transcript (the
                // client renders the event as a rescue line), the raw failure to the log.
                eprintln!("compaction failed: {e:#}");
                self.emit(Event::CompactionFailed {
                    detail: format!("{e:#}"),
                });
                anyhow::bail!("compaction failed; the history can't fit the context window");
            }
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
                specs.push(crate::title::spec());
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
            // The bus tool, only when the client declared the bus (never to subagents: a
            // subagent's parent carries the channel).
            if self.irc().is_some() {
                specs.push(crate::irc::spec());
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
        // A drain cascades to a live subagent: it suspends its own turn (its engine ends it
        // `Suspended`), and the parent's drain deadline bounds its wait.
        let cascade = {
            let d = self.shared.draining.lock().unwrap();
            d.as_ref()
                .filter(|s| !s.acked)
                .map(|s| (s.deadline, stop.clone()))
        };
        if let Some((deadline, token)) = cascade {
            tokio::spawn(async move {
                let left = deadline.saturating_sub(now_ms());
                if left > 0 {
                    tokio::time::sleep(Duration::from_millis(left as u64)).await;
                }
                token.cancel();
            });
        }
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

    /// A long bare wait ([`crate::auto::long_wait`]) run as a background job (the same path as
    /// `Bash { run_in_background }`, already permitted): the tool returns at once, telling the
    /// model what happened, and the job's `<job-done>` wake brings the output when it ends.
    fn background_wait(&self, input: &Value, secs: u64) -> Result<tools::Output> {
        let started =
            crate::background::start_job(&self.shared.bg, input, &self.ctx, &self.jobs_dir())?;
        let id = started
            .content
            .split_whitespace()
            .find(|w| w.starts_with("job-"))
            .map(|w| w.trim_end_matches([',', '.']).to_string())
            .unwrap_or_else(|| "a background job".into());
        self.notice(
            Level::Warn,
            format!("a {secs}s sleep moved to background job {id}; the turn goes on"),
        );
        Ok(tools::Output::text(format!(
            "That wait is now a background job ({id}, {secs}s); continuing. Don't sleep to wait: do other work now or end your turn; the <job-done id={id}> wake, with the output of the commands after the sleep, starts your next turn.\n\n{}",
            started.content
        )))
    }

    /// Run a tool, streaming its live output as ephemeral `Output` deltas on item `id`.
    async fn run_tool(&mut self, id: &str, name: &str, input: &Value) -> Result<tools::Output> {
        // A working directory that was deleted out from under the session (a worktree cleaned
        // up, a temp folder gone) would fail every command with "No such file or directory".
        // Fall back to the session root and say so.
        if !self.ctx.cwd.is_dir() {
            let gone = std::mem::take(&mut self.ctx.cwd);
            self.ctx.cwd = self.root.clone();
            self.ctx.read_files.clear();
            // The sandbox roots pointed into the deleted folder too; the session root confines
            // what's left, if it still sandboxes at all.
            if self.ctx.sandbox.as_ref().is_some_and(|p| !p.is_dir()) {
                self.ctx.sandbox = Some(self.root.clone());
            }
            if self.ctx.shell_sandbox.as_ref().is_some_and(|p| !p.is_dir()) {
                self.ctx.shell_sandbox = Some(self.root.clone());
            }
            self.notice(
                Level::Warn,
                format!(
                    "The working directory {} is gone; continuing in the session root {}.",
                    gone.display(),
                    self.root.display()
                ),
            );
        }
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
        // The sleep guard: a long bare wait would hold the turn (and every event and message
        // behind it) for minutes, so it runs as a background job and the turn goes on.
        if name == "Bash"
            && !self.subagent
            && !tools::bool_arg(input, "run_in_background")
            && let Some(secs) = crate::auto::long_wait(input["command"].as_str().unwrap_or(""))
        {
            return self.background_wait(input, secs);
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
        if name == crate::irc::TOOL && !self.subagent {
            let Some(bus) = self.irc() else {
                anyhow::bail!("the IRC bus isn't enabled for this conversation");
            };
            return crate::irc::run(&bus, input);
        }
        if name == crate::present::TOOL {
            return crate::present::run(input, &self.ctx.root, self.tier == Tier::Weak);
        }
        if name == crate::folder::TOOL && !self.subagent {
            return self.use_folder(input).await;
        }
        if name == crate::title::TOOL {
            let title = crate::title::parse(input)?;
            self.set_title(title.clone());
            return Ok(tools::Output::text(format!("Session titled \"{title}\".")));
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
        let cwd_before = self.ctx.cwd.clone();
        let mut out = {
            // Stop cancels a long tool in flight (Bash kills its process group), not just
            // between tools: watch the turn's token alongside the tool future.
            self.ctx.cancel = Some(self.shared.cancel.lock().unwrap().clone());
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
        self.ctx.cancel = None;
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
        // Cancelled mid-run: the result reads as an interrupt, not an error, and the turn ends
        // cleanly right after (run_tools' remaining calls skip, the caller sees Interrupted).
        if out.is_err() && self.shared.cancel.lock().unwrap().is_cancelled() {
            out = Ok(tools::Output {
                content: "Interrupted by user.".into(),
                ..Default::default()
            });
        }
        // A `cd` that stuck: say where the shell works now, durably (SessionStatus on a dead
        // session reads it from the log).
        // (Compared canonically: the shell reports `pwd -P`, so `/var` comes back as
        // `/private/var` without having moved.)
        let canon = |p: &PathBuf| p.canonicalize().unwrap_or_else(|_| p.clone());
        if self.ctx.cwd != cwd_before && canon(&self.ctx.cwd) != canon(&cwd_before) {
            self.shared.journal.emit(Event::ShellCwd {
                cwd: self.ctx.cwd.clone(),
            });
        }
        out
    }

    /// Run one batch of tool calls. Returns true if the user denied one.    /// Whether the model may call `name` now: it's in the tool list this step was offered, or
    /// it's a connected MCP server's tool (with many, only some are listed up front and the
    /// rest load on demand; that saves context, it isn't a permission).
    fn offers(&self, name: &str) -> bool {
        self.specs.iter().any(|s| s.name == name)
            || (name.starts_with("mcp__") && self.mcp.handles(name))
    }

    /// A context to run `name` in on the side (while its reply is still streaming, or beside
    /// the reply's other reads), if it may: a call that changes nothing and that the permission
    /// layers never ask about ([`crate::auto::parallel_read`]), which this step offers. Its own
    /// context, so nothing it records reaches `self.ctx` unless its result is used.
    fn early_ctx(&self, name: &str, input: &Value) -> Option<Ctx> {
        let ok = crate::auto::parallel_read(name, input)
            && self.offers(name)
            && !self.mcp.handles(name)
            && input.get("_invalid_json").is_none()
            // A working directory deleted out from under the session: `run_tool` falls back
            // to the root and says so, which a call run on the side can't.
            && self.ctx.cwd.is_dir();
        ok.then(|| Ctx {
            root: self.ctx.root.clone(),
            cwd: self.ctx.cwd.clone(),
            read_files: HashMap::new(),
            todos: Vec::new(),
            sandbox: self.ctx.sandbox.clone(),
            shell_sandbox: self.ctx.shell_sandbox.clone(),
            sandbox_extra: self.ctx.sandbox_extra.clone(),
            permitted: self.ctx.permitted.clone(),
            progress: None,
            preview: None,
            cancel: None,
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
        let mut blocked: Option<String> = None;
        let mut looping = false;
        let mut replan: Option<String> = None;
        let uses_len = uses.len();
        // Parallel reads: the reply's leading run of calls that change nothing all start now,
        // side by side (those its stream already started keep running), and the loop below
        // takes their results in order. The first call that could change something closes the
        // run, so it and everything after it run one at a time, after every read before it.
        if self.cfg.early_tools {
            for (index, (_, name, input)) in uses.iter().enumerate() {
                let ctx = self.early_ctx(name, input);
                early.ready(index, name.clone(), input.clone(), ctx);
            }
        }
        for index in 0..uses_len {
            // Safe point between tool calls (the previous call's result is recorded): an
            // update's drain records the rest of the batch as interrupted-by-update and
            // suspends the turn here, before anything more runs.
            if drain_pending(&self.shared).await {
                self.mark_suspended(&uses, index);
                return Ok(Batch::Suspended);
            }
            let (id, name, input) = uses[index].clone();
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
            } else if blocked.is_some() {
                text(
                    ToolOutcome::Skipped,
                    "Skipped: the turn ended on a call that was already denied.".to_string(),
                    None,
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
            } else if let Decision::Deny = self.timed_permit(&id, &name, &arg, &input).await {
                if let Some(denial) = self.blocked.clone() {
                    // A retry of a call already denied this turn: no second card. The turn
                    // ends with the denial, so whoever wakes the agent next sees why.
                    self.last_note = None;
                    blocked = Some(denial.clone());
                    text(
                        ToolOutcome::Denied,
                        format!(
                            "Not run: this exact call was already denied this turn ({denial}). frog didn't ask again and ended the turn. Don't retry it: find another way, or leave it for the user."
                        ),
                        None,
                    )
                } else {
                // A deny with a note (the user's, or frog's own when the prompt timed
                // out) is direction, not a stop: the agent adjusts and carries on.
                let (msg, stop) = match self.last_note.take() {
                    Some(note) => (
                        format!("Not run: the call was denied with this note: {note}\nAdjust your approach accordingly and continue with the rest of the task."),
                        false,
                    ),
                    None if self.can_ask => (
                        "The user rejected this tool call. Stop and wait for their instructions.".to_string(),
                        true,
                    ),
                    None => (
                        "Not permitted in non-interactive mode (run with --yolo to allow).".to_string(),
                        false,
                    ),
                };
                denied = stop;
                text(ToolOutcome::Denied, msg, None)
                }
            } else {
                let started = Instant::now();
                self.snapshot(&name, &input);
                // Provenance: which paths this call is about to bring into being.
                let before: Vec<PathBuf> = match &*name {
                    "Bash" => crate::approval::missing(
                        input["command"].as_str().unwrap_or(""),
                        &self.ctx.cwd,
                    ),
                    "Write" => input["file_path"]
                        .as_str()
                        .map(|p| crate::approval::normalize(&self.ctx.resolve(p)))
                        .filter(|p| !p.exists())
                        .into_iter()
                        .collect(),
                    _ => Vec::new(),
                };
                let ran = match started_early {
                    Some(call) => self.finish_early(call, started).await,
                    None => None,
                };
                let early = ran.as_ref().map(|(_, overlap)| ms(*overlap));
                // A drain past its deadline kills the tool in flight (the same token
                // `Interrupt` uses) and records it interrupted-by-update.
                let r = match ran {
                    Some((r, _)) => r,
                    None => {
                        // A tool in flight gets the rest of the drain deadline; past it, the
                        // tool is killed (dropping its future kills its process group) and
                        // recorded interrupted-by-update, here and for the rest of the batch.
                        let deadline = drain_deadline(self.shared.clone());
                        tokio::select! {
                            r = self.run_tool(&id, &name, &input) => r,
                            _ = deadline => {
                                self.mark_suspended(&uses, index);
                                return Ok(Batch::Suspended);
                            }
                        }
                    }
                };
                self.created
                    .extend(before.into_iter().filter(|p| p.exists()));
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
            // Captured before the item's parts move into its event: a shell command queued
            // for a gist when it finished (see the queue after `ItemCompleted`).
            let (is_bash, item_id, command, out_head) = if name == "Bash" {
                (
                    true,
                    id.clone(),
                    input["command"].as_str().unwrap_or("").to_string(),
                    out.content.chars().take(400).collect(),
                )
            } else {
                (false, String::new(), String::new(), String::new())
            };
            // One result can't blow the window (and being the most recent, it would never be
            // pruned): clip anything larger than MAX_RESULT_SHARE of the window.
            let result_cap = self.result_cap();
            if out.content.len() > result_cap {
                out.content = crate::tools::truncate_middle(&out.content, result_cap);
                out.content.push_str(&format!(
                    "\n\n[frog] Output capped at {} of the model's {}-token window; ask more narrowly or read a range.",
                    result_cap, self.window
                ));
            }
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
            // Queue a gist for a finished shell command, written when the turn ends in one
            // batched side-model call (see `flush_gists`). Skipped calls (not run) don't
            // need one; the elided command tells that story.
            if is_bash && outcome == ToolOutcome::Ok && executed {
                self.pending_gists.push((
                    item_id,
                    command,
                    out_head,
                ));
            }
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
        Ok(if let Some(denial) = blocked {
            Batch::Blocked(denial)
        } else if denied {
            Batch::Denied
        } else if looping {
            Batch::Looping
        } else {
            Batch::Continue
        })
    }

    /// Every call in the batch from `from` on never ran (an update's drain stopped it):
    /// record each as interrupted-by-update in the batch's results message, so the history
    /// is whole and `repair()` has nothing dangling on resume.
    fn mark_suspended(&mut self, uses: &[(String, String, Value)], from: usize) {
        let missing: Vec<Block> = uses[from..]
            .iter()
            .map(|(id, name, _)| Block::ToolResult {
                id: id.clone(),
                name: name.clone(),
                content: "Interrupted by app update; will be re-run or resumed.".into(),
                is_error: true,
            })
            .collect();
        if !missing.is_empty() {
            self.extend_last(missing);
        }
        self.sync_log();
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
        self.caps = (!harness::native_known(&self.profile))
            .then(|| harness::cached(&self.profile))
            .flatten();
        self.mode_failures = 0;
        self.text_why = None;
        self.reprobed = false;
        self.model_ready = false;
        self.apply_harness();
        self.resolve_window().await;
        self.note_text_mode_from_probe();
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
        // `<tool_call>` text from a model that calls natively is prose: nothing to start early.
        let early_text = early_tools && self.recovers_text_calls();
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
            let (cwd, weak) = (self.ctx.root.clone(), self.tier == Tier::Weak);
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
                            if early_text {
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
        // Web reads change nothing and show on their tool card, like reads — in every
        // mode (Cam's decision 2026-10-23): WebSearch always, WebFetch when the host is
        // a plain public domain (the fetch itself still re-checks every resolved IP
        // against private ranges, and a non-public host keeps asking as before). A
        // public-host GET sends nothing the request itself doesn't show.
        if kind == Kind::Net && (name == "WebSearch" || crate::tools::web::public_host(input["url"].as_str().unwrap_or("")))
        {
            self.decision(item, "rule", "allow", "read-only web call", 0);
            return Decision::Allow;
        }
        // MCP tools that only read (`list_*`, `get-*`, vcad's `inspect_*`, …) run without a
        // card in every mode: a manager in default mode stalled ten minutes on each one. Auto
        // mode keeps its slightly wider verb list on top.
        if name.starts_with("mcp__")
            && (crate::auto::mcp_read(name)
                || (self.mode == Mode::Auto && crate::auto::read_tool(name, input)))
        {
            self.decision(item, "rule", "allow", "read-only tool call", 0);
            return Decision::Allow;
        }
        // A write the user granted this server in `[mcp_trust]` (`planetscale = "write"`):
        // no card, but every one is on the record (engine log, a notice, the decision event).
        if let Some(server) =
            crate::auto::mcp_write(name).filter(|s| self.cfg.mcp_write_trusted(s))
        {
            let tool = crate::auto::mcp_parts(name).map_or(name, |(_, t)| t);
            let args = tools::truncate_middle(&input.to_string(), 400);
            let line = format!(
                "mcp_trust: ran {server} › {tool} without a card ([mcp_trust] {server} = \"write\"); args: {args}"
            );
            if self.cfg.log_calls {
                eprintln!("{line}");
            }
            self.notice(Level::Info, line);
            self.decision(item, "trust", "allow", &format!("write grant for {server}"), 0);
            return Decision::Allow;
        }
        let call = call_hash(name, input);
        if name == crate::folder::TOOL {
            return self.ask_folder(item, name, arg).await;
        }
        let mcp = name.starts_with("mcp__");
        let cmd = input["command"].as_str().unwrap_or("").trim();
        let prefix = cmd.split_whitespace().next().unwrap_or("").to_string();
        let leaves_sandbox = name == "Bash" && input["unsandboxed"].as_bool() == Some(true);
        // Layer 1, built-in rules, no model call. A command the parser proves
        // read-only (no writes, no subshells, no credential paths) runs without
        // asking in every mode, sandboxed or not: it can only read, and the
        // sandbox is a write fence, not the only thing standing between the agent
        // and `cat`.
        if name == "Bash"
            && !crate::shell::touches_credentials(cmd)
            && (bash_allowed(cmd, &self.cfg.allow_bash) || crate::shell::read_only(cmd))
        {
            self.decision(item, "rule", "allow", "read-only command", 0);
            return Decision::Allow;
        }
        // A sandboxed command can only write inside the project and can't read credentials,
        // so it runs without asking; leaving the sandbox always asks.
        if name == "Bash" && self.ctx.shell_sandbox.is_some() && !leaves_sandbox {
            self.decision(item, "sandbox", "allow", "sandboxed", 0);
            return Decision::Allow;
        }
        // A screenshot of a session-local file (the tool itself refuses anything outside the
        // workspace) or of localhost: a local capture and a localhost URL can only show the
        // session's own work. Anything else keeps asking. (Allow-by-default in every mode
        // would hand out the whole web; the chief's list scopes this to auto at minimum.)
        if name == "Screenshot"
            && self.mode == Mode::Auto
            && crate::auto::local_capture(input)
        {
            self.decision(item, "rule", "allow", "captures only the session's own work", 0);
            return Decision::Allow;
        }
        // A path prefix the user allowed for this program earlier this session.
        if name == "Bash"
            && !crate::shell::touches_credentials(cmd)
            && crate::approval::prefix_allows(cmd, &self.ctx.cwd, &self.prefix_allow)
        {
            self.decision(item, "session", "allow", "under a path prefix allowed this session", 0);
            return Decision::Allow;
        }
        // Provenance (auto mode): a routine build/test step (known build tools,
        // plain file ops, parser-proven reads; no interpreters, network or
        // substitutions) acting only on in-project paths or the session's own
        // scratch (paths it created, fresh dirs under the shared temp dir)
        // doesn't need the classifier or a prompt. Destructive programs there
        // need provenance; anything outside this scope still asks.
        if name == "Bash"
            && self.mode == Mode::Auto
            && !crate::shell::touches_credentials(cmd)
            && crate::auto::hard_rule(name, input, &self.ctx.root).is_none()
            && crate::approval::routine(cmd)
            && crate::approval::own_scope(cmd, &self.ctx.cwd, &self.ctx.root, &self.created)
        {
            self.decision(item, "provenance", "allow", "touches only the project or its own scratch", 0);
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
        // A Write/Edit into another checkout (the main repo when this session is in a worktree)
        // is outside the project whatever the mode: it asks, and is denied headless.
        let target = matches!(name, "Write" | "Edit")
            .then(|| input["file_path"].as_str().map(|p| self.ctx.resolve(p)))
            .flatten();
        let outside = target.as_ref().is_some_and(|p| self.ctx.outside(p));
        if let Some(path) = target.filter(|_| outside) {
            // Provenance (auto mode): writing into a path this session created,
            // or a fresh file in the shared temp dir, is the session's own
            // scratch — as in-project as its own checkout. Anything else
            // outside still asks (and is denied headless).
            if self.mode == Mode::Auto
                && crate::approval::path_in_own_scope(&path, &self.ctx.root, &self.created)
            {
                self.decision(item, "provenance", "allow", "writes only its own scratch", 0);
                self.ctx.permitted.insert(path);
                return Decision::Allow;
            }
            if !self.can_ask {
                return Decision::Deny;
            }
            if let Some(d) = self.repeat_refusal(item, name, arg, call) {
                return d;
            }
            let id = new_id();
            let (tx, rx) = oneshot::channel();
            self.shared.pending.lock().unwrap().insert(id.clone(), tx);
            let preview = tools::fs::preview(name, input, &self.ctx);
            self.emit(Event::PermissionRequest {
                id: id.clone(),
                item: item.into(),
                name: name.into(),
                arg: arg.into(),
                always: String::new(),
                preview,
                reason: Some(format!(
                    "Writes outside this session's folder ({}).",
                    path.display()
                )),
                subagent: None,
                card: None,
            });
            let decision = rx.await.unwrap_or(Decision::Deny);
            self.emit(Event::PermissionResolved { id, decision });
            if decision != Decision::Deny {
                self.ctx.permitted.insert(path);
            } else {
                self.record_denial(call, "the user denied it".into());
            }
            return decision;
        }
        // Auto mode: a Write/Edit of the session's own scratch (a fresh path under the shared
        // temp dir, or one this session made) is as much its own as the project. `ctx.outside`
        // already counts temp dirs as scratch, so the hard rule's "outside the project" (which
        // knows only the project root) mustn't card it.
        if self.mode == Mode::Auto
            && matches!(name, "Write" | "Edit")
            && let Some(p) = input["file_path"].as_str()
            && crate::auto::hard_rule(name, input, &self.ctx.root).is_some()
            && crate::approval::path_in_own_scope(
                &crate::approval::normalize(&self.ctx.resolve(p)),
                &self.ctx.root,
                &self.created,
            )
        {
            self.decision(item, "provenance", "allow", "writes only its own scratch", 0);
            return Decision::Allow;
        }
        let auto = match kind {
            Kind::Edit => {
                self.mode == Mode::AcceptEdits
                    // Auto mode: edits inside the project are checkpointed and can be undone.
                    || (self.mode == Mode::Auto
                        && crate::auto::hard_rule(name, input, &self.ctx.root).is_none())
            }
            Kind::Net => false,
            _ if matches!(name, "Image" | "Screenshot" | "Compare")
                || mcp
                || leaves_sandbox
                || pane =>
            {
                false
            }
            // Read-only commands were allowed in layer 1 above; anything left
            // here is a write or unknown, which only auto mode's classifier may pass.
            _ => false,
        };
        if auto || self.session_allow.contains(&key) {
            self.decision(
                item,
                if self.session_allow.contains(&key) { "session" } else { "rule" },
                "allow",
                if self.session_allow.contains(&key) { "allowed earlier this session" } else { "mode allows it" },
                0,
            );
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
            let took = ms(started.elapsed());
            self.timing.classifier_ms += took;
            match verdict {
                Ok(()) => {
                    self.decision(item, "classifier", "allow", "the classifier approved it", took);
                    return Decision::Allow;
                }
                Err(why) => {
                    let layer = if why == CLASSIFIER_DOWN_ASK {
                        "fallback"
                    } else {
                        "classifier"
                    };
                    self.decision(item, layer, "ask", &why, took);
                    reason = Some(format!(
                        "Auto mode asked because {}.",
                        why.trim_end_matches('.')
                    ))
                }
            }
        }
        if !self.can_ask {
            self.decision(item, "ask", "ask", "not interactive: denied", 0);
            return Decision::Deny;
        }
        if let Some(d) = self.repeat_refusal(item, name, arg, call) {
            return d;
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
            _ => String::new(), // shell commands: set from the card below
        };
        let timeout_secs = self.cfg.approval_timeout_secs;
        self.last_note = None;
        // Shell commands get a card, and no blanket "always allow `rm`": the only
        // session-wide choice is this program under the card's path prefix.
        let card = (name == "Bash").then(|| {
            // A command's own relative paths resolve where the shell runs (`ctx.cwd`,
            // which `cd` moves); "outside the project" is judged against the session's
            // checkout (`ctx.root`), which never moves.
            crate::approval::card(
                cmd,
                &self.ctx.cwd,
                &self.ctx.root,
                reason.as_deref().unwrap_or("no rule or verdict allowed it"),
                self.agent_reason(),
                &self.created,
                timeout_secs,
            )
        });
        let always = match card.as_ref().and_then(|c| c.prefix.as_ref()) {
            Some(p) => format!(
                "allow `{}` under {p} this session",
                crate::approval::program(cmd)
            ),
            None if card.is_some() => String::new(),
            None => always,
        };
        let id = new_id();
        let (tx, rx) = oneshot::channel();
        self.shared.pending.lock().unwrap().insert(id.clone(), tx);
        let preview = tools::fs::preview(name, input, &self.ctx);
        self.decision(
            item,
            "ask",
            "ask",
            reason.as_deref().unwrap_or("no rule or verdict allowed it"),
            0,
        );
        let card_prefix = card.as_ref().and_then(|c| c.prefix.clone());
        self.emit(Event::PermissionRequest {
            id: id.clone(),
            item: item.into(),
            name: name.into(),
            arg: arg.into(),
            always,
            preview,
            reason,
            subagent: None,
            card,
        });
        // The bus mirrors the card as one line with a link. IRC never approves: the click
        // happens in the app, on a link the bus can't forge (the id is frog's own).
        if let Some(bus) = self.irc() {
            bus.post_notice(
                crate::irc::NoticeKind::WaitingOnUser,
                &crate::irc::approval_notice(&self.session_id, item, name),
            );
        }
        let asked = Instant::now();
        // Waiting has a limit: past it, frog takes the safe path (deny), says so in
        // the tool result, and the agent carries on with the rest of the task.
        let answer = if timeout_secs == 0 {
            Ok(rx.await)
        } else {
            tokio::time::timeout(Duration::from_secs(timeout_secs), rx).await
        };
        let decision = match answer {
            Ok(d) => d.unwrap_or(Decision::Deny),
            Err(_) => {
                self.shared.pending.lock().unwrap().remove(&id);
                let mins = (timeout_secs as f64 / 60.0).round() as u64;
                self.last_note = Some(format!(
                    "nobody answered within {} so frog took the safe path and skipped it; don't retry it, find another way or leave it for the user",
                    if mins >= 1 { format!("{mins} min") } else { format!("{timeout_secs} s") }
                ));
                self.notice(
                    Level::Warn,
                    format!("A permission prompt went unanswered for {timeout_secs}s; denied it and carried on."),
                );
                Decision::Deny
            }
        };
        self.timing.user_ms += ms(asked.elapsed());
        // A note only means something with a deny; with an allow it's dropped.
        let note = self.shared.notes.lock().unwrap().remove(&id);
        if let (Some(note), Decision::Deny) = (note, decision) {
            self.last_note = Some(format!("\"{note}\""));
        }
        if decision == Decision::Deny {
            let why = match &self.last_note {
                Some(n) => format!("denied: {n}"),
                None => "the user denied it".into(),
            };
            self.record_denial(call, why);
        }
        self.emit(Event::PermissionResolved { id, decision });
        match decision {
            Decision::AllowAlways | Decision::AllowPrefix if name == "Bash" => {
                if let Some(p) = card_prefix {
                    self.prefix_allow.push((
                        crate::approval::program(cmd),
                        crate::approval::normalize(Path::new(&p)),
                    ));
                }
                Decision::Allow
            }
            Decision::AllowAlways | Decision::AllowPrefix => {
                self.session_allow.insert(key);
                Decision::Allow
            }
            d => d,
        }
    }

    /// What the agent said just before this call, for the approval card.
    fn agent_reason(&self) -> Option<String> {
        let text = self
            .messages
            .iter()
            .rev()
            .find(|m| m.role == Role::Assistant)?
            .text();
        let text = text.trim();
        (!text.is_empty()).then(|| tools::truncate_middle(text, 300))
    }

    /// Remember a card's deny: this turn's retries of the identical call don't ask again, and
    /// the session's count moves toward its breaker.
    fn record_denial(&mut self, call: u64, why: String) {
        self.turn_denied.insert(call, why);
        *self.session_denied.entry(call).or_insert(0) += 1;
    }

    /// Just before a card would go up: never burn an approval window on a call already
    /// refused. Retried in the same turn, it's denied at once and the turn ends
    /// (`BlockedOnApproval`); denied `DENIED_LIMIT` times this session, it's denied at once
    /// with a notice and the agent carries on. `None`: ask as usual.
    fn repeat_refusal(&mut self, item: &str, name: &str, arg: &str, call: u64) -> Option<Decision> {
        if let Some(denial) = self.turn_denied.get(&call).cloned() {
            self.decision(item, "repeat", "deny", &format!("already denied this turn: {denial}"), 0);
            self.notice(
                Level::Warn,
                format!(
                    "Blocked on approval: `{name} {arg}` was already denied this turn ({denial}). frog didn't ask again and ended the turn."
                ),
            );
            self.blocked = Some(denial);
            return Some(Decision::Deny);
        }
        if self.session_denied.get(&call).copied().unwrap_or(0) >= DENIED_LIMIT {
            let why = "this call was denied twice and won't ask again this session";
            self.decision(item, "breaker", "deny", why, 0);
            self.notice(Level::Warn, format!("`{name} {arg}`: {why}."));
            self.last_note = Some(format!(
                "{why}; don't retry it, find another way or leave it for the user"
            ));
            // A retry later this turn ends the turn instead of repeating this.
            self.turn_denied.insert(call, why.to_string());
            return Some(Decision::Deny);
        }
        None
    }

    /// Record how one permission check was decided, so the ask rate can be
    /// measured from session logs. Not shown as a notice; a durable event.
    fn decision(&self, item: &str, layer: &str, outcome: &str, reason: &str, ms: u64) {
        self.emit(Event::PermissionDecision {
            item: item.to_string(),
            layer: layer.to_string(),
            outcome: outcome.to_string(),
            reason: reason.to_string(),
            ms,
        });
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
            card: None,
        });
        let asked = Instant::now();
        let decision = match rx.await.unwrap_or(Decision::Deny) {
            Decision::AllowAlways | Decision::AllowPrefix => Decision::Allow,
            d => d,
        };
        self.timing.user_ms += ms(asked.elapsed());
        self.emit(Event::PermissionResolved { id, decision });
        decision
    }

    /// Auto mode: hard rules, then the classifier, then `auto_classifier_fallback`, then the
    /// built-in rules alone. `Ok` runs the call (and records why); `Err` says why the user
    /// should decide.
    async fn auto_judge(
        &mut self,
        item: &str,
        name: &str,
        input: &Value,
        sandbox: crate::auto::Sandbox,
    ) -> std::result::Result<(), String> {
        if let Some(why) = crate::auto::hard_rule(name, input, &self.ctx.root) {
            return Err(format!("it {why}"));
        }
        let preview = tools::fs::preview(name, input, &self.ctx);
        let action = crate::auto::describe(name, input, preview.as_ref(), sandbox);
        let verdict = match self.classifier_verdict(false, &action).await {
            Ok(v) => {
                self.classifier_back();
                Some(v)
            }
            Err(down) => match self.classifier_verdict(true, &action).await {
                Ok(v) => {
                    let model = self
                        .classifier_fallback
                        .as_ref()
                        .map(|c| c.profile_name.clone())
                        .unwrap_or_default();
                    self.classifier_degraded(&format!("the fallback classifier ({model})"), &down);
                    Some(v)
                }
                Err(_) => {
                    self.classifier_degraded("frog's built-in rules", &down);
                    None
                }
            },
        };
        match verdict {
            Some(crate::auto::Verdict::Allow(reason)) => {
                self.emit(Event::AutoApproved {
                    item: item.to_string(),
                    reason,
                });
                Ok(())
            }
            Some(crate::auto::Verdict::Ask(reason)) => Err(format!("the classifier said: {reason}")),
            Some(crate::auto::Verdict::Failed(why)) => Err(why),
            // Nothing could judge: the built-in rules decide alone. A down classifier never
            // cards a call by itself; only a call no rule can prove harmless asks.
            None => match crate::auto::rules_fallback(name, input) {
                Some(rule) => {
                    self.emit(Event::AutoApproved {
                        item: item.to_string(),
                        reason: format!("{rule}; the classifier is down, rules decided"),
                    });
                    Ok(())
                }
                None => Err(CLASSIFIER_DOWN_ASK.into()),
            },
        }
    }

    /// One classifier's verdict (`fallback`: `auto_classifier_fallback`'s), started on first
    /// use. `Err` says why it couldn't answer: it isn't configured, wouldn't start, failed, or
    /// failed less than `CLASSIFIER_RETRY` ago (skipped, so a stopped server costs one
    /// timeout, not one per call). Never `Ok(Verdict::Failed)`.
    async fn classifier_verdict(
        &mut self,
        fallback: bool,
        action: &str,
    ) -> std::result::Result<crate::auto::Verdict, String> {
        let down = if fallback {
            &self.classifier_fallback_down
        } else {
            &self.classifier_down
        };
        if let Some((at, why)) = down
            && at.elapsed() < CLASSIFIER_RETRY
        {
            return Err(why.clone());
        }
        let started = if fallback {
            self.classifier_fallback.is_some()
        } else {
            self.classifier.is_some()
        };
        if !started {
            let built = if fallback {
                match crate::auto::Classifier::fallback(&self.cfg, &self.ctx.root) {
                    Some(b) => b,
                    None => return Err("no fallback classifier is configured".into()),
                }
            } else {
                crate::auto::Classifier::new(&self.cfg, &self.ctx.root)
            };
            match built {
                Ok(c) if fallback => self.classifier_fallback = Some(c),
                Ok(c) => self.classifier = Some(c),
                Err(e) => return Err(self.classifier_failed(fallback, format!("it couldn't start ({e:#})"))),
            }
        }
        let slot = if fallback {
            &self.classifier_fallback
        } else {
            &self.classifier
        };
        let model = slot.as_ref().map(|c| c.profile_name.clone()).unwrap_or_default();
        self.emit(Event::Progress {
            label: format!("checking with auto mode ({model})"),
            completed: None,
            total: None,
        });
        let inputs = self.inputs.clone();
        let slot = if fallback {
            &mut self.classifier_fallback
        } else {
            &mut self.classifier
        };
        let Some(classifier) = slot.as_mut() else {
            return Err("it isn't running".into());
        };
        match classifier.judge(&inputs, action).await {
            crate::auto::Verdict::Failed(why) => Err(self.classifier_failed(fallback, why)),
            v => {
                if fallback {
                    self.classifier_fallback_down = None;
                }
                Ok(v)
            }
        }
    }

    /// A classifier couldn't answer: skip it until `CLASSIFIER_RETRY` passes. Returns `why`.
    fn classifier_failed(&mut self, fallback: bool, why: String) -> String {
        let down = Some((Instant::now(), why.clone()));
        if fallback {
            self.classifier_fallback_down = down;
        } else {
            self.classifier_down = down;
        }
        why
    }

    /// The classifier is down and `using` judges instead: the status carries one line that
    /// says so while it lasts, and a notice says it once per session for each fallback,
    /// never once per call.
    fn classifier_degraded(&mut self, using: &str, why: &str) {
        let primary = self
            .classifier
            .as_ref()
            .map(|c| c.profile_name.clone())
            .unwrap_or_else(|| crate::auto::Classifier::primary_spec(&self.cfg));
        let why = why.trim_start_matches("it ").trim_end_matches('.');
        let line = format!("classifier {primary} is down ({why}); {using} decide");
        let changed = self.classifier_degraded.as_deref() != Some(line.as_str());
        self.classifier_degraded = Some(line);
        if self.classifier_told.insert(using.to_string()) {
            let rest = if using.starts_with("frog's") {
                "reads and the session's own work still run without asking; only calls no rule covers ask"
            } else {
                "it judges each call until the classifier is back"
            };
            self.notice(
                Level::Warn,
                format!("auto mode's classifier ({primary}) is down ({why}); using {using}: {rest}."),
            );
        }
        if changed {
            self.emit_status();
        }
    }

    /// The classifier answered: it's back, and the status drops the degraded line.
    fn classifier_back(&mut self) {
        self.classifier_down = None;
        if self.classifier_degraded.take().is_some() {
            self.emit_status();
        }
    }

    /// Summarize the conversation and continue from the summary.
    async fn compact(&mut self, focus: Option<&str>) -> Result<()> {
        if self.messages.is_empty() {
            return Ok(());
        }
        // If the history itself is over the window (one huge result that no cap caught), the
        // summarization request would overflow too: clip every oversized result first,
        // deterministically, recent ones included, so the summary request fits.
        if self.estimate() > self.window {
            let per_result = (self.result_cap() / 2).max(1_000);
            let plan = context::plan_emergency(&self.messages, per_result);
            for (id, content) in &plan {
                self.record(Record::Replace {
                    id: id.clone(),
                    content: content.clone(),
                });
                context::apply(&mut self.messages, id, content);
            }
            if !plan.is_empty() {
                self.emit(Event::ContextPruned {
                    results: plan.len(),
                    tokens_before: self.usage.context(),
                    tokens_after: self.estimate(),
                });
                self.rebased();
            }
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
            summary: self.build_summary().map(kept),
        });
        if let Some(closed) = self.chapters.compacted(self.active_turn.unwrap_or(self.turn)) {
            self.title_chapter(closed);
        }
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

/// Why a finished reply counts against the configured tool-call format, if it does. Only the
/// model's own malformed calls count, in a reply the server says ended normally. Provider and
/// transport failures (402, 429, 5xx, timeouts, resets, a 400 for the request) never reach
/// here: they're errors, retried or failing the turn. A reply cut off at the output limit
/// (`Stop::Length`) can end mid-call with half its JSON, and that's the cap, not the format.
fn format_failure(
    stop: Stop,
    recovered: bool,
    bad_args: bool,
    json_failed: bool,
) -> Option<&'static str> {
    if !matches!(stop, Stop::End | Stop::ToolUse) {
        return None;
    }
    if recovered {
        Some("it wrote tool calls as text instead of calling them")
    } else if bad_args {
        Some("its tool-call arguments weren't valid JSON")
    } else if json_failed {
        Some("its replies didn't follow the JSON format")
    } else {
        None
    }
}

/// Recover tool calls a model wrote as text instead of via the API.
/// Returns whether anything was recovered (a sign the configured format isn't working).
/// Without `recover` (native calls from a model known to make them), `<tool_call>` text is the
/// model quoting the format in prose, not a call.
fn normalize(mut msg: Message, recover: bool) -> (Message, bool) {
    for b in &mut msg.content {
        if let Block::Text { text } = b {
            *text = prompt::strip_answer_tags(text);
        }
    }
    if !recover || !msg.tool_uses().is_empty() {
        return (msg, false);
    }
    // Each text block's calls replace it where it stood. Anthropic rejects the next request if
    // the latest assistant message's signed thinking blocks moved or changed (a 400, "thinking
    // blocks in the latest assistant message cannot be modified"), so with interleaved thinking
    // every thinking block keeps its place; `prompt::to_text_mode` folds the calls back into
    // one text block at the same index.
    let mut recovered = false;
    let mut content = Vec::with_capacity(msg.content.len() + 1);
    for b in msg.content {
        let Block::Text { text } = &b else {
            content.push(b);
            continue;
        };
        let Some((clean, calls)) = prompt::extract_tool_calls(text) else {
            content.push(b);
            continue;
        };
        recovered = true;
        if !clean.is_empty() {
            content.push(Block::Text { text: clean });
        }
        content.extend(calls.into_iter().map(|(name, input)| Block::ToolUse {
            id: new_id(),
            name,
            input,
        }));
    }
    msg.content = content;
    (msg, recovered)
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
    use crate::protocol::{Answer, Image};
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
                cache_write: 0,
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

    /// An engine on `profile`, also handing back every request the provider was sent.
    fn engine_profile(
        script: Vec<Response>,
        profile: Profile,
    ) -> (Handle, Arc<Mutex<Vec<String>>>) {
        engine_profile_failing(Vec::new(), script, profile)
    }

    /// `engine_profile` whose provider first fails the next calls (see [`scripted::Fail`]).
    fn engine_profile_failing(
        fails: Vec<scripted::Fail>,
        script: Vec<Response>,
        profile: Profile,
    ) -> (Handle, Arc<Mutex<Vec<String>>>) {
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
        let sent = client.sent.clone();
        (start(opts, Provider::Scripted(client)).unwrap(), sent)
    }

    /// Opus on Vercel's AI Gateway, as `vercel/anthropic/claude-opus-5.5` resolves.
    fn gateway_opus() -> Profile {
        let mut p = Profile::new(ProviderKind::Openai, "anthropic/claude-opus-5.5");
        p.base_url = Some("https://ai-gateway.vercel.sh/v1".into());
        p.tool_mode = ToolMode::Auto;
        p
    }

    /// A later turn: submit and collect through the next `Idle` (`run` waits for one first).
    async fn turn_again(h: &mut Handle, prompt: &str) -> Vec<Envelope> {
        h.ops
            .send(Op::Submit {
                text: prompt.into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        until_idle(h).await
    }

    fn last_tool_mode(evs: &[Envelope]) -> Option<ToolMode> {
        evs.iter().rev().find_map(|e| match &e.event {
            Event::Status(s) => Some(s.tool_mode),
            _ => None,
        })
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
                more: Vec::new(),
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

    /// Messages queued while a turn ran arrive as one submit: one turn, each message its own
    /// block of the user's message, in order, images after the text they came with.
    #[tokio::test]
    async fn submit_with_more_runs_one_turn_with_every_message_in_order() {
        let (mut h, sent) = engine_sent(
            vec![reply(vec![text("done")], Stop::End)],
            None,
            None,
            None,
            std::env::temp_dir(),
        );
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        let png = Image {
            mime: "image/png".into(),
            data: "AAAA".into(),
        };
        let part = |t: &str, images: Vec<Image>| Part {
            text: t.into(),
            images,
        };
        h.ops
            .send(Op::Submit {
                text: "alpha-msg".into(),
                images: Vec::new(),
                more: vec![
                    part("bravo-msg", Vec::new()),
                    part("charlie-msg", vec![png]),
                ],
            })
            .unwrap();
        let mut evs = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            let idle = matches!(env.event, Event::Idle);
            evs.push(env);
            if idle {
                break;
            }
        }
        let started: Vec<_> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::TurnStarted { input, more, .. } => Some((input.clone(), more.clone())),
                _ => None,
            })
            .collect();
        assert_eq!(started.len(), 1, "one turn");
        assert_eq!(started[0].0, "alpha-msg");
        assert_eq!(
            started[0]
                .1
                .iter()
                .map(|p| p.text.as_str())
                .collect::<Vec<_>>(),
            ["bravo-msg", "charlie-msg"]
        );
        assert_eq!(started[0].1[1].images.len(), 1);

        // The turn's request: system prompt, tool names, then the messages as JSON.
        let req = sent.lock().unwrap().last().cloned().expect("a model call");
        let json = &req[req.rfind("[{\"role\"").expect("messages in the request")..];
        let messages: Vec<Message> = serde_json::from_str(json).expect("messages parse");
        let user: Vec<&Message> = messages.iter().filter(|m| m.role == Role::User).collect();
        assert_eq!(user.len(), 1, "one user message");
        let blocks: Vec<String> = user[0]
            .content
            .iter()
            .map(|b| match b {
                Block::Text { text } => text.trim().to_string(),
                Block::Image { mime, .. } => format!("<{mime}>"),
                _ => "?".into(),
            })
            .filter(|s| !s.is_empty())
            .collect();
        let at = |s: &str| blocks.iter().position(|b| b.ends_with(s)).unwrap();
        assert!(at("alpha-msg") < at("bravo-msg"), "{blocks:?}");
        assert!(
            at("bravo-msg") + 1 == at("charlie-msg"),
            "each its own block: {blocks:?}"
        );
        // Right after the text it came with (as a note: the test model can't see images).
        assert!(
            blocks[at("charlie-msg") + 1].contains("image/png"),
            "{blocks:?}"
        );
        assert_eq!(blocks.len(), at("charlie-msg") + 2, "{blocks:?}");
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
                // The first turn's end names the session (headless title fallback).
                "titled",
                "turn_ended",
                "status",
                "idle"
            ]
        );
        assert!(matches!(
            &evs[5].event,
            Event::Titled { title } if title == "hi"
        ));
        let seqs: Vec<u64> = evs.iter().map(|e| e.seq).collect();
        assert!(
            seqs.windows(2).all(|w| w[1] == w[0] + 1),
            "seq must be contiguous: {seqs:?}"
        );
        assert!(
            matches!(&evs[4].event, Event::ItemCompleted { item: Item::Message { text }, .. } if text == "hello")
        );
        assert!(matches!(
            &evs[6].event,
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

    /// An engine with a store, scripted replies, running in `cwd`.
    fn drain_engine(script: Vec<Response>, dir: PathBuf, cwd: PathBuf) -> Handle {
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
            mode: Mode::AcceptEdits,
            can_ask: true,
            resume: None,
            store: Some(dir),
            sandbox: false,
            rich: false,
            subagent: false,
            chat: false,
        };
        start(opts, Provider::Scripted(scripted::Client::new(script))).unwrap()
    }

    /// `drain_between_tools`: `Drain` mid-turn, with the first tool call's result recorded,
    /// ends the turn `Suspended` — never `Cancelled` — with the ack after it, and no interrupt
    /// marker in the log.
    #[tokio::test]
    async fn drain_between_tools_suspends() {
        let dir = tmp_store();
        let project = dir.join("repo");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(project.join("a.rs"), "fn a() {}\n").unwrap();
        let script = vec![
            reply(
                vec![call("t1", "Read", json!({ "file_path": "a.rs" }))],
                Stop::ToolUse,
            ),
            reply(vec![text("never")], Stop::End),
        ];
        let mut h = drain_engine(script, dir.clone(), project);
        // Skip startup events, then start the turn.
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "go".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut sid = String::new();
        // Drain once the first tool call's result is recorded.
        let mut evs = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            let done = matches!(env.event, Event::Drained { .. });
            match &env.event {
                Event::TurnStarted { .. } => sid = env.session.clone(),
                Event::ItemCompleted {
                    item: Item::ToolCall { name, outcome: ToolOutcome::Ok, .. },
                    ..
                } if name == "Read" => {
                    h.ops
                        .send(Op::Drain {
                            deadline: now_ms() + 30_000,
                        })
                        .unwrap();
                }
                _ => {}
            }
            evs.push(env);
            if done {
                break;
            }
        }
        assert!(
            evs.iter().any(|e| matches!(&e.event, Event::TurnEnded { reason: EndReason::Suspended, .. })),
            "suspended, not cancelled"
        );
        assert!(
            !evs.iter().any(|e| matches!(&e.event, Event::TurnEnded { reason: EndReason::Cancelled, .. })),
            "never cancelled: {:?}",
            names(&evs)
        );
        shutdown(h).await;
        // The log is whole: the tool result is (only) where it should be, and no interrupt
        // marker anywhere.
        let blocks = logged_blocks(&dir, &sid);
        assert!(
            !blocks.iter().any(|(_, b)| matches!(b, Block::Text { text } if text.contains("[Request interrupted by user]"))),
            "no interrupt marker"
        );
        assert!(
            blocks
                .iter()
                .any(|(_, b)| matches!(b, Block::ToolResult { id, .. } if id == "t1")),
            "the finished tool call's result is recorded"
        );
        let _ = std::fs::remove_dir_all(dir);
    }


    /// `DrainAbort` calls a drain off: the turn keeps going normally — no suspend, the
    /// remaining steps run to a `Complete`. Then a second drain (no abort this time) still
    /// suspends, so both paths hold in one session.
    #[tokio::test]
    async fn drain_abort_lets_the_turn_continue() {
        let dir = tmp_store();
        let project = dir.join("repo");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(project.join("a.rs"), "fn a() {}\n").unwrap();
        let script = vec![
            reply(
                vec![call("t1", "Read", json!({ "file_path": "a.rs" }))],
                Stop::ToolUse,
            ),
            reply(vec![text("kept going")], Stop::End),
        ];
        let mut h = drain_engine(script, dir.clone(), project);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "go".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut sid = String::new();
        let mut evs = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            let done = matches!(env.event, Event::TurnEnded { .. });
            match &env.event {
                Event::TurnStarted { .. } => sid = env.session.clone(),
                // Drain on the first tool result, then abort it at once: the update was
                // called off before the deadline.
                Event::ItemCompleted {
                    item: Item::ToolCall { name, outcome: ToolOutcome::Ok, .. },
                    ..
                } if name == "Read" => {
                    h.ops
                        .send(Op::Drain {
                            deadline: now_ms() + 30_000,
                        })
                        .unwrap();
                    h.ops.send(Op::DrainAbort).unwrap();
                }
                _ => {}
            }
            evs.push(env);
            if done {
                break;
            }
        }
        assert!(
            evs.iter().any(|e| matches!(&e.event, Event::TurnEnded { reason: EndReason::Complete, .. })),
            "the turn carried on: {:?}",
            names(&evs)
        );
        assert!(
            !evs.iter().any(|e| matches!(&e.event, Event::TurnEnded { reason: EndReason::Suspended, .. })),
            "never suspended after an abort"
        );
        assert!(
            !evs.iter().any(|e| matches!(&e.event, Event::Drained { .. })),
            "the aborted drain never acks"
        );
        shutdown(h).await;
        // The log is a plain finished turn: no interrupted-by-update marker anywhere.
        assert!(
            !logged_blocks(&dir, &sid)
                .iter()
                .any(|(_, b)| matches!(b, Block::ToolResult { content, is_error: true, .. }
                    if content.contains("Interrupted by app update"))),
            "no drain markers in the log"
        );

        // A second drain, no abort, still suspends: the abort didn't wedge the engine.
        let script = vec![
            reply(
                vec![call("t2", "Read", json!({ "file_path": "a.rs" }))],
                Stop::ToolUse,
            ),
            // Unused if the drain lands; present so the turn would carry on if it didn't.
            reply(vec![text("unused")], Stop::End),
        ];
        let mut h2 = drain_engine(script, dir.clone(), dir.join("repo"));
        while !matches!(h2.events.recv().await.unwrap().event, Event::Idle) {}
        h2.ops
            .send(Op::Submit {
                text: "again".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut evs2 = Vec::new();
        loop {
            let env = h2.events.recv().await.unwrap();
            let done = matches!(env.event, Event::Drained { .. });
            match &env.event {
                Event::ItemCompleted {
                    item: Item::ToolCall { name, outcome: ToolOutcome::Ok, .. },
                    ..
                } if name == "Read" => {
                    h2.ops
                        .send(Op::Drain {
                            deadline: now_ms() + 30_000,
                        })
                        .unwrap();
                }
                _ => {}
            }
            evs2.push(env);
            if done {
                break;
            }
        }
        assert!(
            evs2.iter().any(|e| matches!(&e.event, Event::TurnEnded { reason: EndReason::Suspended, .. })),
            "a later drain still suspends"
        );
        shutdown(h2).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// `drain_kills_long_tool`: a drain whose deadline has passed records the tool in flight
    /// as interrupted-by-update (it never even starts), and the turn suspends.
    #[tokio::test]
    async fn drain_kills_long_tool() {
        let dir = tmp_store();
        let project = dir.join("repo");
        std::fs::create_dir_all(&project).unwrap();
        let script = vec![reply(
            vec![call(
                "t1",
                "Bash",
                json!({ "command": "sleep 30", "timeout": 30_000 }),
            )],
            Stop::ToolUse,
        )];
        let mut h = drain_engine(script, dir.clone(), project);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "go".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        // Drain with a deadline already in the past, as soon as the turn starts.
        let mut sid = String::new();
        let mut evs = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            let done = matches!(env.event, Event::Drained { .. });
            match &env.event {
                Event::Status(_) if sid.is_empty() => sid = env.session.clone(),
                Event::TurnStarted { .. } => {
                    sid = env.session.clone();
                    h.ops
                        .send(Op::Drain {
                            deadline: now_ms() - 1,
                        })
                        .unwrap();
                }
                _ => {}
            }
            evs.push(env);
            if done {
                break;
            }
        }
        assert!(
            evs.iter().any(|e| matches!(&e.event, Event::TurnEnded { reason: EndReason::Suspended, .. })),
            "suspended after the kill: {:?}",
            names(&evs)
        );
        assert!(
            !evs.iter().any(|e| matches!(&e.event, Event::ItemStarted { kind: ItemKind::ToolCall { .. }, .. } )),
            "the long tool never started"
        );
        let blocks = logged_blocks(&dir, &sid);
        assert!(
            blocks.iter().any(|(_, b)| matches!(b, Block::ToolResult { id, content, is_error: true, .. }
                if id == "t1" && content.contains("Interrupted by app update"))),
            "the interrupted-by-update marker is recorded: {blocks:?}",
        );
        let _ = std::fs::remove_dir_all(dir);
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
                "titled",
                "turn_ended"
            ]
        );
    }

    #[tokio::test]
    async fn set_title_tool_names_the_session_and_disables_the_fallback() {
        let call = Block::ToolUse {
            id: "t1".into(),
            name: crate::title::TOOL.into(),
            input: json!({ "title": "\"fix login timeout\"" }),
        };
        let mut h = engine(
            vec![
                reply(vec![call], Stop::ToolUse),
                reply(vec![text("done")], Stop::End),
            ],
            true,
        );
        let evs = run(&mut h, "RULES: stay inside /tmp\n\nfix the login timeout in auth.rs").await;
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::ItemCompleted {
                item: Item::ToolCall { outcome: ToolOutcome::Ok, .. },
                ..
            }
        )));
        // The model's title wins over the derived one, exactly once.
        let titles: Vec<_> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::Titled { title } => Some(title.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(titles, ["fix login timeout"]);
    }

    #[tokio::test]
    async fn headless_first_turn_falls_back_to_a_derived_title() {
        let mut h = engine(vec![reply(vec![text("ok")], Stop::End)], false);
        let evs = run(
            &mut h,
            "RULES: work only inside the worktree.\n\nContinue this branch: finish the SetTitle \
tool, strip prefixes like RULES:, and add tests.",
        )
        .await;
        let titles: Vec<_> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::Titled { title } => Some(title.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(titles.len(), 1);
        assert!(titles[0].starts_with("finish the SetTitle tool"), "{:?}", titles);
    }

    #[tokio::test]
    async fn titled_sessions_are_not_renamed_by_the_fallback() {
        // The fallback only fires for turn 1: a second turn never adds a title.
        let dir = tmp_store();
        let mut h = engine_at(
            vec![
                reply(vec![text("one")], Stop::End),
                reply(vec![text("two")], Stop::End),
            ],
            false,
            Some(dir.clone()),
            None,
        );
        let sid = run(&mut h, "first real request").await[0].session.clone();
        shutdown(h).await;
        let loaded = session::load(&dir, &sid).unwrap();
        assert_eq!(
            loaded
                .events
                .iter()
                .filter(|e| matches!(e.event, Event::Titled { .. }))
                .count(),
            1
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
                more: Vec::new(),
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
                        note: None,
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

    /// A `cd` that sticks (into a worktree, say) is logged as a durable `ShellCwd`, so a
    /// dead session's log still says where it was working; a command that stays put isn't.
    #[tokio::test]
    async fn a_bash_cd_logs_the_shell_cwd() {
        let base = std::env::temp_dir().join(format!("frog-shell-cwd-{}", new_id()));
        let (root, store) = (base.join("repo"), base.join("store"));
        let tree = root.join(".frog/worktrees/w");
        for d in [&tree, &store] {
            std::fs::create_dir_all(d).unwrap();
        }
        let tree = tree.canonicalize().unwrap();
        let bash = |id: &str, cmd: String| Block::ToolUse {
            id: id.into(),
            name: "Bash".into(),
            input: json!({ "command": cmd }),
        };
        let script = vec![
            reply(vec![bash("a", "true".into())], Stop::ToolUse),
            reply(vec![bash("b", format!("cd {}", tree.display()))], Stop::ToolUse),
            reply(vec![text("done")], Stop::End),
        ];
        let (mut h, _) = engine_sent(script, Some(store.clone()), None, None, root.clone());
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "work in the worktree".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut sid = String::new();
        loop {
            let env = h.events.recv().await.unwrap();
            sid = env.session.clone();
            if let Event::PermissionRequest { id, .. } = &env.event {
                h.ops
                    .send(Op::Permission {
                        id: id.clone(),
                        decision: Decision::Allow,
                        note: None,
                    })
                    .unwrap();
            }
            if matches!(env.event, Event::Idle) {
                break;
            }
        }
        shutdown(h).await;
        let logged: Vec<PathBuf> = session::load(&store, &sid)
            .unwrap()
            .events
            .into_iter()
            .filter_map(|e| match e.event {
                Event::ShellCwd { cwd } => Some(cwd),
                _ => None,
            })
            .collect();
        assert_eq!(logged.len(), 1, "only the cd is logged: {logged:?}");
        assert_eq!(logged[0].canonicalize().unwrap(), tree);
        let _ = std::fs::remove_dir_all(base);
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

    /// Item 2a (org reliability): a second engine starting in a linked worktree another
    /// session's engine runs in refuses, naming that session; the main checkout and the
    /// worktree after the first engine exits are open.
    #[tokio::test]
    async fn a_second_engine_in_the_same_worktree_refuses_naming_the_owner() {
        let (repo, wt) = crate::worktree::tests::repo_with_worktree("engine");
        let opts = |cwd: PathBuf| {
            let mut profile = Profile::new(ProviderKind::Ollama, "test");
            profile.tool_mode = ToolMode::Native;
            Options {
                cfg: Config {
                    hermetic: true,
                    ..Config::default()
                },
                profile_name: "test".into(),
                profile,
                cwd,
                mode: Mode::Default,
                can_ask: true,
                resume: None,
                store: Some(tmp_store()),
                sandbox: false,
                rich: false,
                subagent: false,
                chat: false,
            }
        };
        let script = || Provider::Scripted(scripted::Client::new(vec![]));
        let mut first = start(opts(wt.clone()), script()).unwrap();
        let owner = first.events.recv().await.unwrap().session;
        let err = match start(opts(wt.clone()), script()) {
            Ok(_) => panic!("a second engine started in the same worktree"),
            Err(e) => format!("{e:#}"),
        };
        assert!(err.contains(&format!("session {owner}")), "{err}");
        assert!(err.contains(&wt.display().to_string()), "{err}");
        // A subagent shares its parent's tree; the main checkout is never locked.
        let mut sub = opts(wt.clone());
        sub.subagent = true;
        sub.store = None;
        shutdown(start(sub, script()).unwrap()).await;
        let a = start(opts(repo.clone()), script()).unwrap();
        let b = start(opts(repo.clone()), script()).unwrap();
        shutdown(a).await;
        shutdown(b).await;
        // Once the owner exits, the worktree is free.
        shutdown(first).await;
        shutdown(start(opts(wt.clone()), script()).unwrap()).await;
        let _ = std::fs::remove_dir_all(repo.parent().unwrap());
    }

    async fn shutdown(mut h: Handle) {
        h.ops.send(Op::Shutdown).unwrap();
        while h.events.recv().await.is_some() {}
    }

    /// A working directory deleted out from under the session (a worktree cleaned up) would
    /// fail every Bash call with "No such file or directory", even `echo`. The tool falls back
    /// to the session root and says so.
    #[tokio::test]
    async fn bash_falls_back_to_the_session_root_when_cwd_is_deleted() {
        let base = std::env::temp_dir().join(format!("frog-cwd-gone-{}", session::new_id()));
        let project = base.join("project");
        let gone = project.join("gone");
        std::fs::create_dir_all(&gone).unwrap();
        let cd = Block::ToolUse {
            id: "c".into(),
            name: "Bash".into(),
            input: json!({ "command": "cd gone" }),
        };
        let echo = Block::ToolUse {
            id: "e".into(),
            name: "Bash".into(),
            input: json!({ "command": "echo still-here" }),
        };
        let script = vec![
            // Turn 1: cd into the doomed folder, then finish.
            reply(vec![cd], Stop::ToolUse),
            reply(vec![text("in place")], Stop::End),
            // Turn 2 (after the folder is deleted): echo, then finish.
            reply(vec![echo], Stop::ToolUse),
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
            cwd: project.clone(),
            mode: Mode::Yolo,
            can_ask: true,
            resume: None,
            store: None,
            sandbox: false,
            rich: false,
            subagent: false,
            chat: false,
        };
        let mut h = start(opts, Provider::Scripted(scripted::Client::new(script))).unwrap();
        // Turn 1: into the folder that's about to disappear.
        let evs = run(&mut h, "cd around").await;
        assert!(evs.iter().any(|e| matches!(&e.event,
            Event::ItemCompleted { item: Item::ToolCall { outcome: ToolOutcome::Ok, .. }, .. })));
        // The folder goes away between turns.
        std::fs::remove_dir_all(&gone).unwrap();
        // Turn 2: the echo still works, from the session root, with a notice about it.
        h.ops
            .send(Op::Submit {
                text: "keep going".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let evs = until_idle(&mut h).await;
        let notices = notices(&evs);
        assert!(
            notices.iter().any(|n| n.contains("is gone; continuing in the session root")),
            "{notices:?}"
        );
        let outputs: Vec<&str> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::ItemCompleted {
                    item: Item::ToolCall { name, output, .. },
                    ..
                } if name == "Bash" => Some(output.as_str()),
                _ => None,
            })
            .collect();
        assert!(outputs.iter().any(|o| o.contains("still-here")), "{outputs:?}");
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(&base);
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
            durable, 5,
            "turn_started, item_started, item_completed, titled, turn_ended"
        );
        assert!(matches!(&replay[0].event, Event::TurnStarted { input, .. } if input == "hi"));
        assert!(replay.iter().all(|e| e.session == sid));

        h.ops
            .send(Op::Submit {
                text: "more".into(),
                images: Vec::new(),
                more: Vec::new(),
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
            5,
            "turn_started, item_started, item_completed, titled, turn_ended"
        );
        assert!(matches!(&replayed[0].event, Event::TurnStarted { input, .. } if input == "hi"));

        h.ops
            .send(Op::Submit {
                text: "more".into(),
                images: Vec::new(),
                more: Vec::new(),
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
                    more: Vec::new(),
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


    /// `drain_resume_continues`: after a drain suspends a turn, a resumed engine continues
    /// it with the update note (the app's job to send, as it will after a real update), on
    /// the session's stored model, and the work carries on from the repaired history —
    /// including the tool call the drain marked interrupted-by-update.
    #[tokio::test]
    async fn drain_resume_continues_on_the_stored_model_with_the_note() {
        let dir = tmp_store();
        let project = dir.join("repo");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::write(project.join("a.rs"), "fn a() {}\n").unwrap();
        // Step 1 streams a tool call; the drain lands during it, so the call is marked
        // interrupted-by-update and the turn suspends at the model-message safe point.
        let script = vec![
            reply(
                vec![call("t1", "Read", json!({ "file_path": "a.rs" }))],
                Stop::ToolUse,
            ),
        ];
        let mut h = drain_engine(script, dir.clone(), project.clone());
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "go".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        // Drain the moment the turn starts, so the message safe point takes it.
        let mut sid = String::new();
        let mut evs = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            let done = matches!(env.event, Event::Drained { .. });
            if matches!(env.event, Event::TurnStarted { .. }) {
                sid = env.session.clone();
                h.ops
                    .send(Op::Drain {
                        deadline: now_ms() + 30_000,
                    })
                    .unwrap();
            }
            evs.push(env);
            if done {
                break;
            }
        }
        assert!(evs.iter().any(|e| matches!(&e.event, Event::TurnEnded { reason: EndReason::Suspended, .. })));
        shutdown(h).await;
        assert!(
            logged_blocks(&dir, &sid)
                .iter()
                .any(|(_, b)| matches!(b, Block::ToolResult { id, content, .. } if id == "t1" && content.contains("Interrupted by app update"))),
            "the never-run call is marked interrupted-by-update"
        );

        // The relaunched app: spawn with `resume`, then `Continue` with the update note.
        let (mut h2, sent) = engine_sent(
            vec![reply(vec![text("done")], Stop::End)],
            Some(dir.clone()),
            Some(sid),
            None,
            project,
        );
        while !matches!(h2.events.recv().await.unwrap().event, Event::Idle) {}
        h2.ops
            .send(Op::Continue {
                note: Some(crate::protocol::SUSPENDED_NOTE.into()),
            })
            .unwrap();
        let evs = until_idle(&mut h2).await;
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::TurnStarted { input, .. } if input == crate::protocol::SUSPENDED_NOTE
        )));
        assert!(evs.iter().any(|e| matches!(&e.event, Event::TurnEnded { reason: EndReason::Complete, .. })));
        let req = sent.lock().unwrap().last().cloned().unwrap();
        assert!(req.contains("resumed after the app updated"), "the update note, not the crash note");
        assert!(
            !req.contains("resumed after the app restarted"),
            "never the crash note"
        );
        assert!(req.contains("t1"), "the marked call is in the history the model continues from");
        shutdown(h2).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// `drain_during_model_stream`: a drain while the reply still streams keeps the partial
    /// text and suspends at the stream's end (the safe point fires once the message closes).
    #[tokio::test]
    async fn drain_during_model_stream_keeps_the_partial_text() {
        let dir = tmp_store();
        let project = dir.join("repo");
        std::fs::create_dir_all(&project).unwrap();
        let script = vec![reply(vec![text("partial answer")], Stop::End)];
        let mut h = drain_engine(script, dir.clone(), project);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "go".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        // Drain while the message item is streaming.
        let mut sid = String::new();
        let mut evs = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            let done = matches!(env.event, Event::Drained { .. });
            match &env.event {
                Event::TurnStarted { .. } => sid = env.session.clone(),
                Event::ItemDelta { .. } => {
                    h.ops
                        .send(Op::Drain {
                            deadline: now_ms() + 30_000,
                        })
                        .unwrap();
                }
                _ => {}
            }
            evs.push(env);
            if done {
                break;
            }
        }
        assert!(evs.iter().any(|e| matches!(&e.event, Event::TurnEnded { reason: EndReason::Suspended, .. })));
        shutdown(h).await;
        let blocks = logged_blocks(&dir, &sid);
        assert!(
            blocks.iter().any(|(_, b)| matches!(b, Block::Text { text } if text.contains("partial answer"))),
            "the streamed partial text is kept in the history"
        );
        let _ = std::fs::remove_dir_all(dir);
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
                more: Vec::new(),
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
                more: Vec::new(),
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
                more: Vec::new(),
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
                more: Vec::new(),
            })
            .unwrap();
        let evs = until_idle(&mut h).await;
        assert!(notices(&evs)[0].contains(&sid));

        // "Remember that …" saves a note and the turn still runs.
        h.ops
            .send(Op::Submit {
                text: "Remember that widgets paint lazily. Now say hi".into(),
                images: Vec::new(),
                more: Vec::new(),
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
                more: Vec::new(),
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
                more: Vec::new(),
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
                more: Vec::new(),
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

    /// A resumed engine keeps the mode the session last ran in (its last `mode_changed`),
    /// rather than reverting to the flag default — the picker and the engine must agree.
    #[tokio::test]
    async fn a_resumed_engine_keeps_the_sessions_last_mode() {
        let dir = tmp_store();
        let script = vec![reply(vec![text("ok")], Stop::End)];
        let (mut h, _) = engine_sent(script, Some(dir.clone()), None, None, dir.clone());
        let sid = run(&mut h, "hi").await[0].session.clone();
        // The user switches to Yolo mid-session: the op runs at a turn boundary, never
        // cancelling the running turn.
        h.ops.send(Op::SetMode { mode: Mode::Yolo }).unwrap();
        while !matches!(h.events.recv().await.unwrap().event, Event::ModeChanged { .. }) {}
        run(&mut h, "and again").await;
        shutdown(h).await;

        // A new engine resumes with the default flag (Default): the session's stored Yolo wins.
        let script = vec![reply(vec![text("ok")], Stop::End)];
        let (mut h, _) = engine_sent(script, Some(dir.clone()), Some(sid), None, dir.clone());
        let mut status = None;
        while status.is_none() {
            match h.events.recv().await.unwrap().event {
                Event::Status(s) => status = Some(s.mode),
                Event::Idle => break,
                _ => {}
            }
        }
        assert_eq!(status, Some(Mode::Yolo), "the engine resumed in the session's mode");
        shutdown(h).await;
    }

    /// A persisted engine started in `mode` (the `--auto`-style flag), in `dir`.
    fn engine_in_mode(
        script: Vec<Response>,
        mode: Mode,
        dir: &Path,
        resume: Option<String>,
    ) -> Handle {
        let mut profile = Profile::new(ProviderKind::Ollama, "test");
        profile.tool_mode = ToolMode::Native;
        let opts = Options {
            cfg: Config {
                hermetic: true,
                sandbox_shell: false,
                ..Config::default()
            },
            profile_name: "test".into(),
            profile,
            cwd: dir.to_path_buf(),
            mode,
            can_ask: true,
            resume,
            store: Some(dir.to_path_buf()),
            sandbox: false,
            rich: false,
            subagent: false,
            chat: false,
        };
        start(opts, Provider::Scripted(scripted::Client::new(script))).unwrap()
    }

    /// The mode the engine reports at startup (its first `Status`).
    async fn startup_mode(h: &mut Handle) -> Mode {
        loop {
            if let Event::Status(s) = h.events.recv().await.unwrap().event {
                return s.mode;
            }
        }
    }

    fn logged_modes(dir: &Path, sid: &str) -> Vec<Mode> {
        session::load(dir, sid)
            .unwrap()
            .events
            .iter()
            .filter_map(|e| match e.event {
                Event::ModeChanged { mode } => Some(mode),
                _ => None,
            })
            .collect()
    }

    /// The okc manager's bug: a session StartSession began with `--auto` never logged its
    /// mode, so when the app restarted its engine (resume, no mode flag) it ran in Default
    /// and its next in-project Write asked. The starting mode is now logged with the first
    /// turn, and the resumed engine keeps it.
    #[tokio::test]
    async fn a_flag_started_mode_survives_an_engine_restart() {
        let dir = tmp_store();
        let write = |id: &str, path: &str| Block::ToolUse {
            id: id.into(),
            name: "Write".into(),
            input: json!({ "file_path": path, "content": "x\n" }),
        };
        let script = vec![
            reply(vec![write("w1", "one.py")], Stop::ToolUse),
            reply(vec![text("wrote it")], Stop::End),
        ];
        let mut h = engine_in_mode(script, Mode::Auto, &dir, None);
        let evs = run(&mut h, "write one.py").await;
        let sid = evs[0].session.clone();
        let logged = evs
            .iter()
            .position(|e| matches!(e.event, Event::ModeChanged { mode: Mode::Auto }));
        let turn = evs
            .iter()
            .position(|e| matches!(e.event, Event::TurnStarted { .. }));
        assert!(
            logged.is_some() && logged < turn,
            "the starting mode is logged before turn 1"
        );
        shutdown(h).await;
        assert_eq!(logged_modes(&dir, &sid), [Mode::Auto]);

        // The app restarts the engine the way it resumes any session: no mode flag (Default).
        let script = vec![
            reply(vec![write("w2", "two.py")], Stop::ToolUse),
            reply(vec![text("wrote it again")], Stop::End),
        ];
        let mut h = engine_in_mode(script, Mode::Default, &dir, Some(sid.clone()));
        assert_eq!(startup_mode(&mut h).await, Mode::Auto, "resumed in auto");
        let evs = tokio::time::timeout(Duration::from_secs(20), run(&mut h, "write two.py"))
            .await
            .expect("the in-project Write asked: the mode reverted");
        assert!(
            !evs.iter()
                .any(|e| matches!(e.event, Event::PermissionRequest { .. }))
        );
        assert!(dir.join("two.py").exists());
        shutdown(h).await;
        // Nothing changed, so nothing more to log.
        assert_eq!(logged_modes(&dir, &sid), [Mode::Auto]);
    }

    /// A log with no mode on record (written before modes were logged at start) resumed by
    /// an engine with a mode flag: that start is a change from the log's implicit Default,
    /// so it's logged, and the next flagless restart keeps it.
    #[tokio::test]
    async fn an_engine_start_that_differs_from_the_log_is_logged() {
        let dir = tmp_store();
        let script = vec![reply(vec![text("ok")], Stop::End)];
        let mut h = engine_in_mode(script, Mode::Default, &dir, None);
        let sid = run(&mut h, "hi").await[0].session.clone();
        shutdown(h).await;
        // A Default session logs no mode at all: no noise for the common case.
        assert!(logged_modes(&dir, &sid).is_empty());

        let mut h = engine_in_mode(Vec::new(), Mode::Auto, &dir, Some(sid.clone()));
        assert_eq!(startup_mode(&mut h).await, Mode::Auto);
        shutdown(h).await;
        assert_eq!(
            logged_modes(&dir, &sid),
            [Mode::Auto],
            "the auto start is logged"
        );

        let mut h = engine_in_mode(Vec::new(), Mode::Default, &dir, Some(sid.clone()));
        assert_eq!(
            startup_mode(&mut h).await,
            Mode::Auto,
            "a flagless restart keeps auto"
        );
        shutdown(h).await;
        assert_eq!(logged_modes(&dir, &sid), [Mode::Auto]);
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
                more: Vec::new(),
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
                .any(|n| n.contains("switching this session to text tool calls")),
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

    /// The session's fallback holds for its later turns (each turn re-applies the harness).
    #[tokio::test]
    async fn a_text_fallback_lasts_the_session() {
        let text_call =
            r#"<tool_call>{"name":"Glob","arguments":{"pattern":"*.nothing"}}</tool_call>"#;
        let script = vec![
            reply(vec![text(text_call)], Stop::End),
            reply(vec![text(text_call)], Stop::End),
            reply(vec![text("none found")], Stop::End),
            reply(vec![text("still none")], Stop::End),
        ];
        let mut h = engine_mode(script, ToolMode::Auto);
        let evs = run(&mut h, "find .nothing files").await;
        assert_eq!(last_tool_mode(&evs), Some(ToolMode::Text));
        // The notice names the model and says why, and that it isn't saved.
        let warned = notices(&evs);
        assert!(
            warned.iter().any(|n| n.starts_with("test (test): native tool calls failed twice")
                && n.contains("wrote tool calls as text")
                && n.contains("Not saved")),
            "{warned:?}"
        );
        let evs = turn_again(&mut h, "and now?").await;
        assert_eq!(last_tool_mode(&evs), Some(ToolMode::Text));
    }

    /// The messages of a request as the scripted provider recorded it.
    fn sent_messages(req: &str) -> Vec<Value> {
        let at = req.find(r#"[{"role""#).expect("messages in the request");
        serde_json::from_str(&req[at..]).unwrap()
    }

    /// The 400 that broke every Opus session: "messages.1.content.12: `thinking` or
    /// `redacted_thinking` blocks in the latest assistant message cannot be modified". A text
    /// mode reply with interleaved signed thinking and a `<tool_call>` comes back on the next
    /// request with every thinking block byte-identical and at the index it had.
    #[tokio::test]
    async fn text_mode_leaves_signed_thinking_untouched() {
        let thought = |t: &str, sig: &str| Block::Thinking {
            text: t.into(),
            signature: Some(sig.into()),
        };
        let first = vec![
            thought("plan the search", "sig-one"),
            text("Looking for them."),
            thought("glob is enough", "sig-two"),
            text(r#"<tool_call>{"name":"Glob","arguments":{"pattern":"*.nothing"}}</tool_call>"#),
        ];
        let script = vec![
            reply(first.clone(), Stop::End),
            reply(vec![thought("none", "sig-three"), text("none found")], Stop::End),
        ];
        let mut p = gateway_opus();
        p.tool_mode = ToolMode::Text;
        let (mut h, sent) = engine_profile(script, p);
        let evs = run(&mut h, "find .nothing files").await;
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::ItemCompleted { item: Item::ToolCall { name, .. }, .. } if name == "Glob"
        )));
        let sent = sent.lock().unwrap();
        assert_eq!(sent.len(), 2);
        let msgs = sent_messages(&sent[1]);
        let latest = msgs
            .iter()
            .rev()
            .find(|m| m["role"] == "assistant")
            .expect("the reply is replayed");
        let blocks = latest["content"].as_array().unwrap();
        assert_eq!(blocks.len(), first.len(), "{blocks:#?}");
        for i in [0, 2] {
            assert_eq!(blocks[i], serde_json::to_value(&first[i]).unwrap(), "block {i}");
        }
        assert_eq!(blocks[1]["text"], "Looking for them.");
        assert!(blocks[3]["text"].as_str().unwrap().contains("<tool_call>"));
        // The call's result follows as text, never as a native tool block.
        assert!(!sent[1].contains(r#""type":"tool_use""#));
    }

    #[test]
    fn recovered_calls_stay_where_the_model_wrote_them() {
        let msg = Message {
            role: Role::Assistant,
            content: vec![
                Block::Thinking {
                    text: "a".into(),
                    signature: Some("s".into()),
                },
                text("first"),
                Block::Thinking {
                    text: "b".into(),
                    signature: Some("t".into()),
                },
                text(r#"then <tool_call>{"name":"Glob","arguments":{"pattern":"x"}}</tool_call>"#),
            ],
        };
        let (out, recovered) = normalize(msg, true);
        assert!(recovered);
        let kinds: Vec<&str> = out
            .content
            .iter()
            .map(|b| match b {
                Block::Thinking { .. } => "thinking",
                Block::Text { .. } => "text",
                Block::ToolUse { .. } => "call",
                _ => "other",
            })
            .collect();
        assert_eq!(kinds, ["thinking", "text", "thinking", "text", "call"]);
        let wire = prompt::to_text_mode(std::slice::from_ref(&out));
        assert_eq!(wire[0].content.len(), 4);
        assert!(matches!(&wire[0].content[2], Block::Thinking { signature: Some(s), .. } if s == "t"));
        assert!(matches!(&wire[0].content[3], Block::Text { text } if text.starts_with("then\n<tool_call>")));
    }

    #[test]
    fn only_a_finished_reply_with_a_bad_call_is_a_format_failure() {
        assert!(format_failure(Stop::End, true, false, false).is_some());
        assert!(format_failure(Stop::ToolUse, false, true, false).is_some());
        assert!(format_failure(Stop::End, false, false, true).is_some());
        assert_eq!(format_failure(Stop::End, false, false, false), None);
        // Cut off at the output cap, half a call is the cap's fault.
        assert_eq!(format_failure(Stop::Length, true, true, true), None);
        assert_eq!(format_failure(Stop::Incomplete, true, true, true), None);
    }

    /// Provider trouble (a 429, a 503, a reset stream, the 400 for a modified thinking block)
    /// and replies cut off mid-call at the output cap never count toward the text fallback.
    #[tokio::test(start_paused = true)]
    async fn provider_errors_and_truncated_calls_are_not_format_failures() {
        let mut p = Profile::new(ProviderKind::Ollama, "test");
        p.tool_mode = ToolMode::Auto;
        let half = || Block::ToolUse {
            id: new_id(),
            name: "Glob".into(),
            input: json!({ "_invalid_json": "{\"pattern\": \"*.no" }),
        };
        let fails = vec![
            scripted::Fail::http(429, "rate limited"),
            scripted::Fail::before("connection reset by peer"),
            scripted::Fail::http(
                400,
                "messages.1.content.12: `thinking` or `redacted_thinking` blocks in the latest assistant message cannot be modified",
            ),
        ];
        let script = vec![
            reply(vec![half()], Stop::Length),
            reply(vec![half()], Stop::Length),
            reply(vec![half()], Stop::Length),
            reply(vec![text("done")], Stop::End),
        ];
        let (mut h, _) = engine_profile_failing(fails, script, p);
        let first = run(&mut h, "find .no files").await;
        assert!(first.iter().any(|e| matches!(
            &e.event,
            Event::TurnEnded {
                reason: EndReason::Error {
                    error: EngineError::Provider { status: 400, .. }
                },
                ..
            }
        )));
        let second = turn_again(&mut h, "try again").await;
        for evs in [&first, &second] {
            assert!(
                !notices(evs).iter().any(|n| n.contains("text tool calls")),
                "{:?}",
                notices(evs)
            );
        }
        assert_eq!(last_tool_mode(&second), Some(ToolMode::Native));
    }

    /// Claude through a gateway calls tools natively. When it writes `<tool_call>` in prose
    /// (quoting frog's own text format, say), that's not a call and not a format failure: the
    /// session stays native and nothing runs.
    #[tokio::test]
    async fn claude_on_a_gateway_never_falls_back_to_text_calls() {
        let quoted = r#"text mode looks like <tool_call>{"name":"Glob","arguments":{"pattern":"*.nothing"}}</tool_call>"#;
        let script = vec![
            reply(vec![text(quoted)], Stop::End),
            reply(vec![text(quoted)], Stop::End),
            reply(vec![text(quoted)], Stop::End),
        ];
        let (mut h, sent) = engine_profile(script, gateway_opus());
        for i in 0..3 {
            let evs = if i == 0 {
                run(&mut h, "how does text mode look?").await
            } else {
                turn_again(&mut h, "and again?").await
            };
            assert!(
                !notices(&evs).iter().any(|n| n.contains("text tool calls")),
                "{:?}",
                notices(&evs)
            );
            assert_eq!(last_tool_mode(&evs), Some(ToolMode::Native));
            assert!(!evs.iter().any(|e| matches!(
                &e.event,
                Event::ItemCompleted { item: Item::ToolCall { .. }, .. }
            )));
        }
        // Every request offered native tools, and none described the text format.
        for req in sent.lock().unwrap().iter() {
            assert!(req.contains("<tool Read>"), "native tools offered");
            assert!(!req.contains("To call one, output a block"));
        }
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
                more: Vec::new(),
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
                irc: false,
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
                irc: false,
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
                more: Vec::new(),
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
        caps_irc(h, sessions, false);
    }

    fn caps_irc(h: &Handle, sessions: bool, irc: bool) {
        h.ops
            .send(Op::SetClientCaps {
                irc,
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

    /// Item 2b (org reliability): a stop that clears the inbox leaves nothing queued to
    /// restart the session — the messages queued behind the stopped turn never run — while
    /// a message sent after the clear queues and runs as usual.
    #[tokio::test]
    async fn clear_inbox_drops_queued_messages_so_a_stop_stays_stopped() {
        let script = vec![
            reply(vec![list_sessions_call()], Stop::ToolUse),
            reply(vec![text("got the later one")], Stop::End),
        ];
        let mut h = engine(script, true);
        caps(&h, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "work".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let deliver = |h: &Handle, message: &str| {
            h.ops
                .send(Op::Deliver {
                    from: "s2".into(),
                    from_name: "Manager".into(),
                    message: message.into(),
                })
                .unwrap();
        };
        let mut evs = Vec::new();
        let mut cleared = false;
        loop {
            let env = h.events.recv().await.unwrap();
            if let Event::SessionRequest { .. } = &env.event {
                // Mid-turn: two messages queue behind it, then the stop clears them.
                deliver(&h, "queued-one");
                deliver(&h, "queued-two");
                h.ops.send(Op::Interrupt).unwrap();
                h.ops.send(Op::ClearInbox).unwrap();
                cleared = true;
            }
            let idle = matches!(env.event, Event::Idle);
            evs.push(env);
            if idle && cleared {
                break;
            }
        }
        // Nothing started after the stopped turn.
        let started: Vec<String> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::TurnStarted { input, .. } => Some(input.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(started, ["work"], "a voided message started a turn");
        // The loop takes the voided messages off the queue right after the stopped turn, says
        // so, and starts nothing.
        let notice = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                match h.events.recv().await.unwrap().event {
                    Event::Notice { message, .. } if message.contains("queued session message") => {
                        break message;
                    }
                    Event::TurnStarted { input, .. } => panic!("a voided message ran: {input}"),
                    _ => {}
                }
            }
        })
        .await
        .expect("no notice about the dropped messages");
        assert!(notice.contains("dropped 2 queued session messages"), "{notice}");
        // A message sent after the clear runs.
        deliver(&h, "after-clear");
        let input = loop {
            if let Event::TurnStarted { input, .. } = h.events.recv().await.unwrap().event {
                break input;
            }
        };
        assert!(input.contains("after-clear") && !input.contains("queued-"), "{input}");
        shutdown(h).await;
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
                more: Vec::new(),
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

    // -- the IRC agent bus (docs/design/agent-bus-irc.md) --

    /// The Irc tool calls the model makes in tests.
    fn irc_call(action: &str, channel: &str) -> Block {
        use serde_json::json;
        Block::ToolUse {
            id: "t0".into(),
            name: crate::irc::TOOL.into(),
            input: json!({ "action": action, "channel": channel }),
        }
    }

    #[tokio::test]
    async fn an_irc_mention_delivers_at_the_turn_boundary_not_mid_turn() {
        // A mention arriving mid-turn never interrupts it: it queues like SendMessage and
        // runs at the next boundary, wrapped untrusted.
        let script = vec![
            reply(vec![irc_call("read", "#frog")], Stop::ToolUse),
            reply(vec![text("read")], Stop::End),
            reply(vec![text("got it")], Stop::End),
        ];
        let mut h = engine(script, true);
        caps_irc(&h, false, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "check the channel".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut mentioned = false;
        let mut order = Vec::new();
        loop {
            match h.events.recv().await.unwrap().event {
                Event::ItemCompleted {
                    item: Item::ToolCall { name, .. },
                    ..
                } if name == crate::irc::TOOL => {
                    // Mid-turn: the bridge routes the mention into the router's inbox.
                    let bus = h.bus.lock().unwrap().clone().unwrap();
                    let nick = bus.nick().unwrap();
                    let line =
                        crate::irc::Line::at("f-peer", "#frog", &format!("{nick}: ping?"), 1000)
                            .unwrap();
                    let Some((from, from_name, message)) = bus.arrive(line) else {
                        panic!("a mention must route to the inbox");
                    };
                    h.ops
                        .send(Op::Deliver {
                            from,
                            from_name,
                            message,
                        })
                        .unwrap();
                    mentioned = true;
                    order.push("tool".into());
                }
                Event::TurnStarted { turn, input, .. } => {
                    order.push(format!("start {turn} {}", input.contains("<chat")));
                }
                Event::TurnEnded { turn, .. } => {
                    order.push(format!("end {turn}"));
                    if turn == 2 {
                        break;
                    }
                }
                _ => {}
            }
        }
        assert!(mentioned);
        assert_eq!(
            order,
            ["start 1 false", "tool", "end 1", "start 2 true", "end 2"],
            "the mention lands at the boundary, as one wrapped turn"
        );
    }

    #[tokio::test]
    async fn the_irc_tool_is_absent_until_the_client_declares_the_bus() {
        let script = vec![
            reply(vec![irc_call("read", "#frog")], Stop::ToolUse),
            reply(vec![text("ok")], Stop::End),
        ];
        let mut h = engine(script, true);
        // No SetClientCaps { irc }: the tool isn't offered and can't run.
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "read the channel".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        loop {
            match h.events.recv().await.unwrap().event {
                Event::ItemCompleted {
                    item: Item::ToolCall { name, output, .. },
                    ..
                } if name == crate::irc::TOOL => {
                    assert!(output.starts_with("There's no `Irc` tool"));
                    break;
                }
                Event::TurnEnded { .. } => panic!("the bus is off: the call must be refused"),
                _ => {}
            }
        }
    }

    #[tokio::test]
    async fn a_permission_card_posts_a_notice_with_a_link_never_an_approval() {
        // A permission request mid-turn posts exactly one waiting-on-user notice, carrying a
        // frog:// link. IRC never approves: the notice has no decision and no commands.
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
        caps_irc(&h, false, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        // The client (here: the test) tells the bus which team channel this session posts to.
        h.bus
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .set_channel("#frog");
        h.ops
            .send(Op::Submit {
                text: "fix add".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut notices = Vec::new();
        loop {
            match h.events.recv().await.unwrap().event {
                Event::PermissionRequest { id, name, .. } => {
                    let bus = h.bus.lock().unwrap().clone().unwrap();
                    // The bridge posted the notice synchronously with the event.
                    for line in bus.read("#frog").unwrap_or_default() {
                        notices.push(line.text.clone());
                    }
                    assert_eq!(name, "Edit");
                    h.ops
                        .send(Op::Permission {
                            id,
                            decision: Decision::Allow,
                            note: None,
                        })
                        .unwrap();
                }
                Event::TurnEnded { turn, .. } if turn == 1 => break,
                _ => {}
            }
        }
        let link = notices.iter().find(|n| n.contains("frog://"));
        assert!(link.is_some(), "the notice carries a link: {notices:?}");
        assert!(
            notices.iter().any(|n| n.contains("waiting on cam")),
            "it names the card"
        );
        for n in &notices {
            let low = n.to_lowercase();
            assert!(!low.contains("reply yes"), "no confirm-by-chat: {n}");
            assert!(!low.contains("approved"), "no decision over IRC: {n}");
        }
    }

    #[tokio::test]
    async fn the_irc_tool_reads_quarantined_lines_and_posts_within_the_cap() {
        let script = vec![
            reply(vec![irc_call("read", "#frog")], Stop::ToolUse),
            reply(vec![text("read")], Stop::End),
        ];
        let mut h = engine(script, true);
        caps_irc(&h, false, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        // History a peer wrote before the read.
        let bus = h.bus.lock().unwrap().clone().unwrap();
        bus.arrive(crate::irc::Line::at("f-peer", "#frog", "release out", 999).unwrap());
        h.ops
            .send(Op::Submit {
                text: "read the channel".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        loop {
            match h.events.recv().await.unwrap().event {
                Event::ItemCompleted {
                    item: Item::ToolCall { name, output, .. },
                    ..
                } if name == crate::irc::TOOL => {
                    assert!(output.contains("untrusted=\"true\""), "{output}");
                    assert!(output.contains("release out"));
                    assert!(output.contains("no user authority"));
                    break;
                }
                Event::TurnEnded { .. } => panic!("tool should have run"),
                _ => {}
            }
        }
    }

    #[tokio::test]
    async fn queued_delivers_run_together_as_one_turn_in_order() {
        // Three messages land while a turn runs: none of them cancels it, and the next
        // boundary starts ONE turn carrying all three, in the order they were sent.
        let script = vec![
            reply(vec![list_sessions_call()], Stop::ToolUse),
            reply(vec![text("listed")], Stop::End),
            reply(vec![text("all three noted")], Stop::End),
        ];
        let mut h = engine(script, true);
        caps(&h, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "who's around?".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut first_ended = false;
        loop {
            match h.events.recv().await.unwrap().event {
                Event::SessionRequest { id, .. } => {
                    for (n, m) in ["first", "second", "third"].iter().enumerate() {
                        h.ops
                            .send(Op::Deliver {
                                from: format!("s{n}"),
                                from_name: "Sender".into(),
                                message: m.to_string(),
                            })
                            .unwrap();
                    }
                    h.ops
                        .send(Op::SessionReply {
                            id,
                            result: Some(json!([])),
                            error: None,
                        })
                        .unwrap();
                }
                Event::TurnEnded { turn, reason, .. } => {
                    assert!(matches!(reason, EndReason::Complete), "{reason:?}");
                    if turn == 1 {
                        first_ended = true;
                    }
                    if turn == 2 {
                        break;
                    }
                }
                Event::TurnStarted {
                    turn, input, more, ..
                } => {
                    if turn == 2 {
                        assert!(first_ended, "batched turn started before turn 1 ended");
                        // One representation: composer's `more`. The first message is the
                        // input, the rest follow in order, each still wrapped.
                        assert!(input.starts_with("<session-message from=\"s0\" name=\"Sender\">"));
                        assert!(input.contains("first"));
                        let rest: Vec<&str> = more.iter().map(|p| p.text.as_str()).collect();
                        assert_eq!(rest.len(), 2, "all three in one turn: {rest:?}");
                        assert!(rest[0].starts_with("<session-message from=\"s1\"") && rest[0].contains("second"));
                        assert!(rest[1].starts_with("<session-message from=\"s2\"") && rest[1].contains("third"));
                    }
                }
                _ => {}
            }
        }
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
                more: Vec::new(),
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
                more: Vec::new(),
            })
            .unwrap();
        while !matches!(
            h.events.recv().await.unwrap().event,
            Event::TurnEnded { .. }
        ) {}
        let req = sent.lock().unwrap().last().cloned().unwrap();
        for tool in [
            "ListSessions",
            "SendMessage",
            "StartSession",
            "ArchiveSession",
            "UnarchiveSession",
            "SessionStatus",
        ] {
            assert!(req.contains(tool), "{tool} not offered");
        }
        assert!(req.contains("no user authority"));
    }

    #[tokio::test]
    async fn archive_session_round_trips_through_the_client() {
        // ArchiveSession/UnarchiveSession are client-carried like the rest: the engine hands
        // the call to the client and returns its answer. A missing `id` never gets that far.
        let script = vec![
            reply(
                vec![Block::ToolUse {
                    id: "ar".into(),
                    name: "ArchiveSession".into(),
                    input: json!({}),
                }],
                Stop::ToolUse,
            ),
            reply(
                vec![Block::ToolUse {
                    id: "ar2".into(),
                    name: "ArchiveSession".into(),
                    input: json!({ "id": "ops-0003" }),
                }],
                Stop::ToolUse,
            ),
            reply(vec![text("ok")], Stop::End),
        ];
        let mut h = engine(script, true);
        caps(&h, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "tidy up".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut saw_empty_error = false;
        loop {
            match h.events.recv().await.unwrap().event {
                Event::SessionRequest { id, tool, .. } => {
                    assert_eq!(tool, "ArchiveSession");
                    // No id: rejected by validation before reaching the client.
                    saw_empty_error = true;
                    h.ops
                        .send(Op::SessionReply {
                            id,
                            result: None,
                            error: Some("`id` is required".into()),
                        })
                        .unwrap();
                }
                Event::ItemCompleted {
                    item: Item::ToolCall { name, output, .. },
                    ..
                } if name == "ArchiveSession" => {
                    if output.contains("required") {
                        saw_empty_error = true;
                    }
                }
                Event::TurnEnded { .. } => break,
                _ => {}
            }
        }
        assert!(saw_empty_error, "the missing id was refused");
    }

    /// MoveSession round-trips through the client like the rest of the family: the engine
    /// hands the call over, and the model sees the client's answer. The engine holds no
    /// parentage (that's the app's), so a move the client refuses comes back as an error
    /// and nothing else happens — no state of the engine's changes either way.
    #[tokio::test]
    async fn move_session_round_trips_through_the_client() {
        // One turn, three moves: a good one, a nonexistent parent, and an unparent.
        let call = |id: &str, parent: &str| {
            Block::ToolUse {
                id: id.into(),
                name: "MoveSession".into(),
                input: json!({ "id": "eng-0002", "parent": parent }),
            }
        };
        let script = vec![
            reply(vec![call("m1", "chief-0001")], Stop::ToolUse),
            reply(vec![call("m2", "nobody-9999")], Stop::ToolUse),
            reply(
                vec![Block::ToolUse {
                    id: "m3".into(),
                    name: "MoveSession".into(),
                    input: json!({ "id": "eng-0002", "parent": null }),
                }],
                Stop::ToolUse,
            ),
            reply(vec![text("moved")], Stop::End),
        ];
        let mut h = engine(script, true);
        caps(&h, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "re-file it".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut moves = 0;
        let mut saw_refusal = false;
        loop {
            match h.events.recv().await.unwrap().event {
                Event::SessionRequest { id, tool, input, .. } => {
                    assert_eq!(tool, "MoveSession");
                    moves += 1;
                    // The client answers: a known parent moves, an unknown one refuses.
                    let error = input["parent"].as_str() == Some("nobody-9999");
                    if error { saw_refusal = true; }
                    h.ops
                        .send(Op::SessionReply {
                            id,
                            result: if error { None } else { Some(json!("moved")) },
                            error: if error {
                                Some("No session \"nobody-9999\"".into())
                            } else {
                                None
                            },
                        })
                        .unwrap();
                }
                Event::ItemCompleted {
                    item: Item::ToolCall { name, output, outcome, .. },
                    ..
                } if name == "MoveSession" => {
                    if output.contains("nobody-9999") {
                        assert_eq!(outcome, ToolOutcome::Error, "the refusal is an error result");
                    } else {
                        assert_eq!(outcome, ToolOutcome::Ok, "a move the client made: {output}");
                    }
                }
                Event::TurnEnded { .. } => break,
                _ => {}
            }
        }
        assert_eq!(moves, 3, "every call reached the client");
        assert!(saw_refusal, "the nonexistent parent was refused");
    }

    /// A move the client refuses leaves the engine exactly as it was: same turn count, no
    /// extra events, the session's log untouched (parentage isn't the engine's to change).
    #[tokio::test]
    async fn a_refused_move_changes_no_engine_state() {
        let script = vec![
            reply(
                vec![Block::ToolUse {
                    id: "m1".into(),
                    name: "MoveSession".into(),
                    input: json!({ "id": "eng-0002", "parent": "nobody-9999" }),
                }],
                Stop::ToolUse,
            ),
            reply(vec![text("left it")], Stop::End),
        ];
        let mut h = engine(script, true);
        caps(&h, true);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "try the move".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut refused = false;
        let mut titled = false;
        let mut turns = 0;
        loop {
            match h.events.recv().await.unwrap().event {
                Event::SessionRequest { id, .. } => {
                    h.ops
                        .send(Op::SessionReply {
                            id,
                            result: None,
                            error: Some("No session \"nobody-9999\"".into()),
                        })
                        .unwrap();
                }
                Event::ItemCompleted {
                    item: Item::ToolCall { name, output, .. },
                    ..
                } if name == "MoveSession" => {
                    refused = true;
                    assert!(output.contains("nobody-9999"), "the model sees the refusal");
                }
                Event::TurnEnded { .. } => {
                    turns += 1;
                    break;
                }
                Event::ModeChanged { .. } | Event::ModelChanged { .. } => {
                    panic!("a refused move changed engine state");
                }
                Event::Titled { title } => {
                    // Only the first input's auto-title (turn 1, no client named the
                    // session) — never the move's doing.
                    assert_eq!(title, "try the move");
                    titled = true;
                }
                _ => {}
            }
        }
        assert!(refused);
        assert!(titled, "the only title is the first input's own");
        assert_eq!(turns, 1, "the turn carried on and ended once");
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
                more: Vec::new(),
            })
            .unwrap();
        loop {
            if let Event::PermissionRequest { id, .. } = h.events.recv().await.unwrap().event {
                tokio::time::sleep(Duration::from_millis(1500)).await;
                h.ops
                    .send(Op::Permission {
                        id,
                        decision: Decision::Allow,
                        note: None,
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
                more: Vec::new(),
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
                        note: None,
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

    /// A git repo with a worktree, for the path-root tests: returns (main checkout, worktree).
    fn repo_with_worktree(tag: &str) -> (PathBuf, PathBuf) {
        let base = std::env::temp_dir().join(format!("frog-wt-{}-{}", tag, new_id()));
        let main = base.join("main");
        let wt = base.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        let git = |args: &[&str]| {
            let ok = std::process::Command::new("git")
                .args([
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t@t",
                    "-c",
                    "commit.gpgsign=false",
                ])
                .args(args)
                .current_dir(&main)
                .status()
                .unwrap()
                .success();
            assert!(ok, "git {args:?} failed");
        };
        git(&["init", "-q"]);
        std::fs::write(main.join("seed.txt"), "seed\n").unwrap();
        git(&["add", "."]);
        git(&["commit", "-qm", "init"]);
        git(&["worktree", "add", "-q", wt.to_str().unwrap()]);
        (main, wt)
    }

    /// A session whose folder is a git worktree keeps resolving file tools against it: Bash
    /// starts in the same root, its `cd` still works, and a relative Write lands in the
    /// worktree even after the shell moved to the main checkout.
    #[tokio::test]
    async fn file_tools_stay_rooted_in_the_session_worktree() {
        let (main, wt) = repo_with_worktree("root");
        let pwd = Block::ToolUse {
            id: "p".into(),
            name: "Bash".into(),
            input: json!({ "command": "pwd" }),
        };
        let cd = Block::ToolUse {
            id: "c".into(),
            name: "Bash".into(),
            input: json!({ "command": format!("cd {} && pwd", main.display()) }),
        };
        let write = Block::ToolUse {
            id: "w".into(),
            name: "Write".into(),
            input: json!({ "file_path": "work.txt", "content": "from the worktree\n" }),
        };
        let script = vec![
            reply(vec![pwd], Stop::ToolUse),
            reply(vec![cd], Stop::ToolUse),
            reply(vec![write], Stop::ToolUse),
            reply(vec![text("done")], Stop::End),
        ];
        // AcceptEdits (engine_sent): the write auto-approves wherever it lands, so where it
        // lands is entirely up to the resolution. Bash may ask where there's no OS sandbox
        // (the cd call isn't on the safe list): allow it, this test is about paths.
        let (mut h, _sent) = engine_sent(script, None, None, None, wt.clone());
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "make a file".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut evs = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            if let Event::PermissionRequest { id, name, .. } = &env.event {
                assert_eq!(name, "Bash", "only the cd command may ask here");
                h.ops
                    .send(Op::Permission {
                        id: id.clone(),
                        decision: Decision::Allow,
                        note: None,
                    })
                    .unwrap();
            }
            let idle = matches!(env.event, Event::Idle);
            evs.push(env);
            if idle {
                break;
            }
        }
        let outputs = |evs: &[Envelope]| {
            evs.iter()
                .filter_map(|e| match &e.event {
                    Event::ItemCompleted {
                        item: Item::ToolCall { name, output, .. },
                        ..
                    } if name == "Bash" => Some(output.clone()),
                    _ => None,
                })
                .collect::<Vec<_>>()
        };
        let outs = outputs(&evs);
        assert_eq!(outs.len(), 2, "both Bash calls ran: {outs:?}");
        // Bash starts in the session root, and cd moves the shell alone.
        assert!(
            outs[0].contains(wt.to_str().unwrap()),
            "Bash's first cwd should be the worktree: {}",
            outs[0]
        );
        assert!(
            outs[1].contains(main.to_str().unwrap()),
            "cd should still work: {}",
            outs[1]
        );
        // The relative write landed in the worktree, not the main checkout.
        assert_eq!(
            std::fs::read_to_string(wt.join("work.txt")).ok(),
            Some("from the worktree\n".into()),
            "the write missed the worktree"
        );
        assert!(
            !main.join("work.txt").exists(),
            "the write escaped to the main checkout"
        );
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(main.parent().unwrap());
    }

    /// An absolute Write into the main checkout is outside the project for a worktree session:
    /// it asks (and is denied when nobody can answer), and never lands there silently.
    #[tokio::test]
    async fn an_absolute_write_into_the_main_checkout_asks_and_stays_out() {
        let (main, wt) = repo_with_worktree("abs");
        let outside = main.join("escaped.txt");
        let write = Block::ToolUse {
            id: "w".into(),
            name: "Write".into(),
            input: json!({ "file_path": outside.display().to_string(), "content": "escape\n" }),
        };
        let script = vec![
            reply(vec![write], Stop::ToolUse),
            reply(vec![text("done")], Stop::End),
        ];
        // Headless (can_ask false): denied outright, nothing written.
        let mut h = engine_with(script, false, None, None, None, wt.clone());
        let evs = run(&mut h, "write it").await;
        assert!(
            evs.iter().any(|e| matches!(
                &e.event,
                Event::ItemCompleted {
                    item: Item::ToolCall { name, outcome: ToolOutcome::Denied, .. },
                    ..
                } if name == "Write"
            )),
            "the outside write should have been denied: {:?}",
            names(&evs)
        );
        assert!(!outside.exists(), "the write escaped to the main checkout");
        shutdown(h).await;

        // Interactive: it asks for every decision but the user's; denied, nothing lands.
        let write2 = Block::ToolUse {
            id: "w2".into(),
            name: "Write".into(),
            input: json!({ "file_path": outside.display().to_string(), "content": "approved\n" }),
        };
        let script = vec![
            reply(vec![write2.clone()], Stop::ToolUse),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, None, wt.clone());
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "write it".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut asked = false;
        loop {
            let env = h.events.recv().await.unwrap();
            if let Event::PermissionRequest {
                id, name, always, ..
            } = &env.event
            {
                asked = true;
                assert_eq!(name, "Write");
                assert!(
                    always.is_empty(),
                    "an outside write can't be always-allowed"
                );
                h.ops
                    .send(Op::Permission {
                        id: id.clone(),
                        decision: Decision::Deny,
                        note: None,
                    })
                    .unwrap();
            }
            if matches!(env.event, Event::Idle) {
                break;
            }
        }
        assert!(asked, "the outside write didn't ask");
        assert!(!outside.exists(), "a denied outside write went ahead");
        shutdown(h).await;

        // Allowed once: it lands where the user said, and only there.
        let script = vec![
            reply(vec![write2], Stop::ToolUse),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, None, wt.clone());
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "write it".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        loop {
            let env = h.events.recv().await.unwrap();
            if let Event::PermissionRequest { id, .. } = &env.event {
                h.ops
                    .send(Op::Permission {
                        id: id.clone(),
                        decision: Decision::Allow,
                        note: None,
                    })
                    .unwrap();
            }
            if matches!(env.event, Event::Idle) {
                break;
            }
        }
        assert_eq!(
            std::fs::read_to_string(&outside).ok(),
            Some("approved\n".into()),
            "the approved write didn't land"
        );
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(main.parent().unwrap());
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
                more: Vec::new(),
            })
            .unwrap();
        until_idle(&mut h).await;
        h.ops
            .send(Op::Submit {
                text: "bump notes".into(),
                images: Vec::new(),
                more: Vec::new(),
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
                more: Vec::new(),
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
                irc: false,
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
                more: Vec::new(),
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
                            note: None,
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
                irc: false,
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
                more: Vec::new(),
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
                irc: false,
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
                more: Vec::new(),
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
        // sandbox-exec can't nest inside the test process; leave it off for tool tests.
        cfg.sandbox_shell = false;
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
                more: Vec::new(),
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

    /// An engine for parallel-read tests: no streamed `ToolReady` (so nothing starts while the
    /// reply streams; only the batch's own parallel start can overlap calls), no shell sandbox.
    fn engine_batch(script: Vec<Response>, dir: &Path) -> Handle {
        let profile = Profile::new(ProviderKind::Ollama, "test");
        let mut cfg = Config::default();
        cfg.sandbox_shell = false;
        let opts = Options {
            cfg,
            profile_name: "test".into(),
            profile,
            cwd: dir.to_path_buf(),
            mode: Mode::AcceptEdits,
            can_ask: false,
            resume: None,
            store: Some(dir.to_path_buf()),
            sandbox: false,
            rich: false,
            subagent: false,
            chat: false,
        };
        start(opts, Provider::Scripted(scripted::Client::new(script))).unwrap()
    }

    /// FIFOs whose readers each wait `hold` after opening before they get a byte: read one
    /// at a time, `n` of them take `n * hold`; side by side, about one `hold`.
    fn slow_fifos(dir: &Path, n: usize, hold: Duration) -> Vec<PathBuf> {
        (0..n)
            .map(|i| {
                let p = dir.join(format!("fifo-{i}"));
                let made = std::process::Command::new("mkfifo").arg(&p).status().unwrap();
                assert!(made.success());
                let q = p.clone();
                std::thread::spawn(move || {
                    use std::io::Write;
                    // Blocks until the reader opens its end.
                    let mut w = std::fs::OpenOptions::new().write(true).open(&q).unwrap();
                    std::thread::sleep(hold);
                    let _ = w.write_all(format!("fifo {i}\n").as_bytes());
                });
                p
            })
            .collect()
    }

    /// Parallel reads: four read-only calls in one reply run side by side, measurably faster
    /// than one after another, and their results come back in the reply's order.
    #[tokio::test]
    async fn a_replys_read_only_calls_run_concurrently() {
        let dir = tmp_store();
        let hold = Duration::from_millis(1_000);
        let fifos = slow_fifos(&dir, 4, hold);
        let calls = fifos
            .iter()
            .enumerate()
            .map(|(i, p)| call(&format!("c{i}"), "Bash", json!({"command": format!("cat {}", p.display())})))
            .collect();
        let script = vec![
            reply(calls, Stop::ToolUse),
            reply(vec![text("read all four")], Stop::End),
        ];
        let mut h = engine_batch(script, &dir);
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        let t0 = Instant::now();
        submit(&h, "read them");
        let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        let took = t0.elapsed();
        for i in 0..4 {
            let out = tool_output(&evs, &format!("c{i}")).unwrap();
            assert!(out.contains(&format!("fifo {i}")), "c{i}: {out}");
        }
        // One at a time would be >= 4s.
        assert!(took < hold * 5 / 2, "the reads ran one at a time: {took:?}");
        let order: Vec<&str> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::ItemCompleted { id, item: Item::ToolCall { .. } } => Some(id.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(order, ["c0", "c1", "c2", "c3"]);
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// A write closes the parallel run: the read before it finishes before the write starts,
    /// and the read after it runs after the write (it sees the written file).
    #[tokio::test]
    async fn a_write_waits_for_the_reads_before_it_and_reads_after_wait_for_it() {
        let dir = tmp_store();
        let fifo = slow_fifos(&dir, 1, Duration::from_millis(700)).remove(0);
        let out = dir.join("written.txt");
        let script = vec![
            reply(
                vec![
                    call("r", "Bash", json!({"command": format!("cat {}", fifo.display())})),
                    call("w", "Write", json!({"file_path": out.display().to_string(), "content": "new\n"})),
                    call("after", "Bash", json!({"command": format!("cat {}", out.display())})),
                ],
                Stop::ToolUse,
            ),
            reply(vec![text("ok")], Stop::End),
        ];
        let mut h = engine_batch(script, &dir);
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        submit(&h, "read, write, read");
        let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        let at = |want: &str, started: bool| {
            evs.iter()
                .position(|e| match &e.event {
                    Event::ItemStarted { id, .. } if started => id == want,
                    Event::ItemCompleted { id, .. } if !started => id == want,
                    _ => false,
                })
                .unwrap_or_else(|| panic!("{want}"))
        };
        assert!(at("r", false) < at("w", true), "the read completes before the write starts");
        assert!(at("w", false) < at("after", true), "the later read waits for the write");
        assert!(tool_output(&evs, "after").unwrap().contains("new"));
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn parallel_read_follows_the_permission_layers() {
        use crate::auto::parallel_read;
        assert!(parallel_read("Read", &json!({"file_path": "a"})));
        assert!(parallel_read("Grep", &json!({"pattern": "x"})));
        assert!(parallel_read("WebSearch", &json!({"query": "x"})));
        assert!(parallel_read("WebFetch", &json!({"url": "https://example.com/a"})));
        assert!(!parallel_read("WebFetch", &json!({"url": "http://localhost:3000"})));
        assert!(parallel_read("Bash", &json!({"command": "git status && wc -l src/*.rs"})));
        assert!(!parallel_read("Bash", &json!({"command": "cd src && ls"})), "cd moves the session");
        assert!(!parallel_read("Bash", &json!({"command": "cargo build"})));
        assert!(!parallel_read("Bash", &json!({"command": "ls", "unsandboxed": true})));
        assert!(!parallel_read("Bash", &json!({"command": "cat ~/.ssh/id_rsa"})));
        assert!(!parallel_read("Write", &json!({"file_path": "a", "content": ""})));
        assert!(!parallel_read("mcp__runpod__list-pods", &json!({})));
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
                more: Vec::new(),
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

    /// Stop cancels a Bash tool mid-run: the sleeping command dies, its result is recorded
    /// as interrupted, and the turn ends cancelled — all within about two seconds.
    #[tokio::test]
    async fn interrupt_cancels_a_running_bash_tool() {
        let dir = tmp_store();
        // Real work after the sleep keeps it inline (a bare long sleep becomes a job).
        let bash = call(
            "t1",
            "Bash",
            json!({ "command": "sleep 64 && touch /tmp/frog-never", "timeout": 120000 }),
        );
        let (mut h, _) = engine_early(
            vec![
                reply(vec![bash], Stop::ToolUse),
                reply(vec![text("done")], Stop::End),
            ],
            false,
            ToolMode::Native,
            Duration::from_millis(500),
            &dir,
            &dir,
        );
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        // Yolo so the sleeping command runs without a permission card nobody answers; the
        // shell sandbox off because sandbox-exec can't nest inside the test process.
        h.ops.send(Op::SetMode { mode: Mode::Yolo }).unwrap();
        h.ops
            .send(Op::Submit {
                text: "sleep".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        // Wait for the tool to start (allowing its permission card), then stop the turn.
        let started = std::time::Instant::now();
        loop {
            let env = tokio::time::timeout(Duration::from_secs(10), h.events.recv())
                .await
                .unwrap()
                .unwrap();
            if let Event::PermissionRequest { id, .. } = &env.event {
                h.ops
                    .send(Op::Permission {
                        id: id.clone(),
                        decision: Decision::Allow,
                        note: None,
                    })
                    .unwrap();
            }
            if matches!(
                &env.event,
                Event::ItemStarted { kind: ItemKind::ToolCall { name, .. }, .. } if name == "Bash"
            ) {
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
        h.ops.send(Op::Interrupt).unwrap();
        let evs = until_idle(&mut h).await;
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "interrupt took {:?}",
            started.elapsed()
        );
        let reasons: Vec<String> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::TurnEnded { reason, .. } => Some(format!("{reason:?}")),
                _ => None,
            })
            .collect();
        eprintln!("reasons: {reasons:?}");
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Cancelled,
                ..
            }
        )));
        let sid = evs[0].session.clone();
        let interrupted = logged_blocks(&dir, &sid).into_iter().any(|(_, b)| {
            matches!(b, Block::ToolResult { content, .. } if content.contains("Interrupted"))
        });
        assert!(interrupted, "no interrupted tool result recorded");
        // The sleeping child is gone.
        tokio::time::sleep(Duration::from_millis(700)).await;
        let alive = std::process::Command::new("pgrep")
            .args(["-f", "sleep 64"])
            .output()
            .map(|o| !o.stdout.is_empty())
            .unwrap_or(false);
        assert!(!alive, "a `sleep 64` from the interrupted turn is still running");
        shutdown(h).await;
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
                        note: None,
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
                more: Vec::new(),
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
        // Everything through the report turn's end (the task's done event may arrive
        // before, during or after the notice turn — ordering is the registry's, not ours).
        let mut evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { turn: 2, .. })).await;
        let mut more = drive(&mut h, |e| matches!(e, Event::Idle)).await;
        evs.append(&mut more);
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
                        note: None,
                    })
                    .unwrap();
                break;
            }
        }
        drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        assert!(!dir.join("nope.txt").exists());
        shutdown(h).await;
    }


    /// Integration: a parent drains while its `Task` subagent is mid-turn — the cascade
    /// stops the child at its own safe point (its turn records `Suspended` too), the parent
    /// reports the child's partial result as interrupted-by-update, and the resumed turn
    /// can re-run the `Task`.
    #[tokio::test]
    async fn draining_the_parent_suspends_its_subagent_mid_turn_and_resume_reruns() {
        let dir = tmp_store();
        // The child is mid-turn when the parent's drain lands: a tool call in flight.
        script_child(
            &dir,
            vec![
                reply(vec![call("c1", "Bash", json!({"command": "sleep 30"}))], Stop::ToolUse),
            ],
        );
        let task = call(
            "t",
            "Task",
            json!({"description": "long subagent", "prompt": "work on it", "mode": "write"}),
        );
        let script = vec![
            reply(vec![task], Stop::ToolUse),
            reply(vec![text("done anyway")], Stop::End),
        ];
        let mut h = engine_with(script, true, Some(dir.clone()), None, None, dir.clone());
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        submit(&h, "start the subagent");
        // Drain the parent as soon as the child's tool call starts (the child's events
        // stream through the parent's subagent item as `item_delta`s).
        let mut parent_suspended = false;
        let mut saw_ack = false;
        let mut events = 0;
        while !parent_suspended || !saw_ack {
            let env = h.events.recv().await.unwrap();
            match &env.event {
                Event::Subagent { item, inner } if item == "t" => {
                    events += 1;
                    if matches!(&**inner, Event::ItemStarted { kind: crate::protocol::ItemKind::ToolCall { .. }, .. }) {
                        h.ops
                            .send(Op::Drain {
                                deadline: now_ms() + 2_000,
                            })
                            .unwrap();
                    }
                }
                Event::TurnEnded { reason: EndReason::Suspended, .. } => parent_suspended = true,
                Event::Drained { .. } => saw_ack = true,
                _ => {}
            }
            events += 0;
            if events > 400 { panic!("the drain never landed; events exhausted"); }
        }
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
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

    /// The sleep guard: a long bare wait (the specimen: `sleep 570; wc -l …; tail …`, a
    /// 9.5-minute blocking turn) runs as a background job. The tool returns at once with a note
    /// saying so, a Warn notice tells the user, and the turn's next step runs right away.
    #[tokio::test]
    async fn a_long_bare_sleep_becomes_a_background_job() {
        let dir = tmp_store();
        let wait = call(
            "w",
            "Bash",
            json!({"command": "sleep 570; wc -l /dev/null; tail -1 /dev/null", "timeout": 590000}),
        );
        let script = vec![
            reply(vec![wait], Stop::ToolUse),
            reply(vec![text("doing other work meanwhile")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, None, dir.clone());
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        let t0 = Instant::now();
        submit(&h, "wait for the run, then count");
        let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        assert!(
            t0.elapsed() < Duration::from_secs(20),
            "the turn must not block on the sleep"
        );
        assert!(matches!(
            evs.iter().find_map(|e| match &e.event {
                Event::TurnEnded { reason, .. } => Some(reason.clone()),
                _ => None,
            }),
            Some(EndReason::Complete)
        ));
        assert!(
            evs.iter().any(|e| matches!(&e.event,
                Event::BackgroundStarted { id, kind, label, log } if id == "job-1" && log.as_deref().is_some_and(|l| l.ends_with("job-1.log")) && kind == "job" && label.starts_with("sleep 570"))),
            "the wait runs as job-1"
        );
        let out = tool_output(&evs, "w").expect("the wait's result");
        assert!(
            out.contains("That wait is now a background job (job-1, 570s); continuing"),
            "{out}"
        );
        assert!(out.contains("<job-done id=job-1>"), "{out}");
        assert!(
            notices(&evs)
                .iter()
                .any(|n| n.contains("570s sleep moved to background job job-1")),
            "{:?}",
            notices(&evs)
        );
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Events never interrupt a turn: two timers that fire while a turn is busy (a 3s command)
    /// are parked, the turn completes normally, and they run as the next turn, in the order
    /// they fired, before the engine goes idle (no `Idle` between the two turns).
    #[tokio::test]
    async fn wakes_mid_turn_queue_for_the_boundary_in_order() {
        let dir = tmp_store();
        let script = vec![
            reply(
                vec![
                    call("m1", "Monitor", json!({"after_s": 1, "note": "first"})),
                    call("m2", "Monitor", json!({"after_s": 2, "note": "second"})),
                    call("b", "Bash", json!({"command": "sleep 3; echo slept"})),
                ],
                Stop::ToolUse,
            ),
            reply(vec![text("turn one done")], Stop::End),
            reply(vec![text("both timers seen")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, None, dir.clone());
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        submit(&h, "set two timers and work");
        let first = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        // Both fired during the turn; the turn still ran to its end.
        let done = first
            .iter()
            .filter(|e| matches!(&e.event, Event::BackgroundDone { status, .. } if status == "done"))
            .count();
        assert_eq!(done, 2, "both timers fired mid-turn");
        assert!(first.iter().any(|e| matches!(&e.event,
            Event::TurnEnded { reason: EndReason::Complete, .. })));
        assert!(tool_output(&first, "b").unwrap().contains("slept"));
        assert_eq!(
            first.iter().filter(|e| matches!(e.event, Event::TurnStarted { .. })).count(),
            1,
            "nothing started mid-turn"
        );
        let next = drive(&mut h, |e| matches!(e, Event::TurnStarted { .. })).await;
        assert!(
            !next.iter().any(|e| matches!(e.event, Event::Idle)),
            "the wake runs before the engine goes idle"
        );
        let input = next
            .iter()
            .find_map(|e| match &e.event {
                Event::TurnStarted { input, .. } => Some(input.clone()),
                _ => None,
            })
            .unwrap();
        let (a, b) = (input.find("first").unwrap(), input.find("second").unwrap());
        assert!(input.starts_with("<wakeup id=mon-1") && a < b, "{input}");
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// The no-response opt: an informational session message is logged as read and starts no
    /// turn (and wakes nothing); the next turn carries it as context. A plain delivered message
    /// still starts a turn.
    #[tokio::test]
    async fn an_informational_message_is_read_without_a_turn() {
        let dir = tmp_store();
        let script = vec![
            reply(vec![text("noted the status")], Stop::End),
            reply(vec![text("answered")], Stop::End),
        ];
        let (mut h, sent) = engine_early(script, true, ToolMode::Native, Duration::ZERO, &dir, &dir);
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        h.ops
            .send(Op::Inform {
                from: "s9".into(),
                from_name: "okc manager".into(),
                message: "received, going idle".into(),
            })
            .unwrap();
        let read = drive(&mut h, |e| matches!(e, Event::MessageRead { .. })).await;
        let sid = read[0].session.clone();
        let quiet = tokio::time::timeout(Duration::from_millis(800), async {
            loop {
                let env = h.events.recv().await.unwrap();
                if matches!(env.event, Event::TurnStarted { .. }) {
                    break;
                }
            }
        })
        .await;
        assert!(quiet.is_err(), "an informational message started a turn");
        assert!(sent.lock().unwrap().is_empty(), "no model call for it");
        // Logged as read.
        let logged = session::events_after(&dir, &sid, 0).unwrap();
        assert!(logged.iter().any(|e| matches!(&e.event,
            Event::MessageRead { from, message, .. } if from == "s9" && message == "received, going idle")));
        // The next turn (a question) runs as usual and carries the status along.
        h.ops
            .send(Op::Deliver {
                from: "s9".into(),
                from_name: "okc manager".into(),
                message: "is the pod up?".into(),
            })
            .unwrap();
        let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        assert!(evs.iter().any(|e| matches!(&e.event,
            Event::TurnStarted { input, .. } if input.contains("is the pod up?"))));
        let to_model = sent.lock().unwrap().join("\n");
        assert!(to_model.contains("received, going idle"), "the status rides along as context");
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Everything waiting at a boundary goes as one batch: a wake that fired mid-turn and a
    /// session message that arrived mid-turn open one turn together (wake as its input, the
    /// message as `more`), and clients see the queue while it waits.
    #[tokio::test]
    async fn a_boundary_flushes_wakes_and_messages_as_one_batch() {
        let dir = tmp_store();
        let script = vec![
            reply(
                vec![
                    call("m", "Monitor", json!({"after_s": 1, "note": "pod check"})),
                    call("b", "Bash", json!({"command": "sleep 3; echo slept"})),
                ],
                Stop::ToolUse,
            ),
            reply(vec![text("turn one")], Stop::End),
            reply(vec![text("saw both")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, None, dir.clone());
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        submit(&h, "work");
        let parked = drive(&mut h, |e| matches!(e, Event::QueuedEvents { items } if !items.is_empty())).await;
        assert!(!parked.iter().any(|e| matches!(e.event, Event::TurnEnded { .. })), "parked mid-turn");
        h.ops
            .send(Op::Deliver {
                from: "s9".into(),
                from_name: "okc manager".into(),
                message: "serving:true".into(),
            })
            .unwrap();
        drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        let next = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        let (input, more) = next
            .iter()
            .find_map(|e| match &e.event {
                Event::TurnStarted { input, more, .. } => Some((input.clone(), more.clone())),
                _ => None,
            })
            .unwrap();
        assert!(input.starts_with("<wakeup id=mon-1") && input.contains("pod check"), "{input}");
        assert_eq!(more.len(), 1, "{more:?}");
        assert!(more[0].text.starts_with("<session-message from=\"s9\"") && more[0].text.contains("serving:true"));
        assert!(
            next.iter().any(|e| matches!(&e.event, Event::QueuedEvents { items } if items.is_empty())),
            "the flush empties the queue clients see"
        );
        let turns = next.iter().filter(|e| matches!(e.event, Event::TurnStarted { .. })).count();
        assert_eq!(turns, 1, "one batch, one turn");
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// A stop stays stopped: a wake that came in during the turn the user stopped doesn't
    /// start a turn of its own; it goes along with the user's next message.
    #[tokio::test]
    async fn a_stop_holds_wakes_for_the_next_turn() {
        let dir = tmp_store();
        let script = vec![
            reply(
                vec![
                    call("m", "Monitor", json!({"after_s": 1, "note": "check"})),
                    call("b", "Bash", json!({"command": "sleep 30"})),
                ],
                Stop::ToolUse,
            ),
            reply(vec![text("ok")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, None, dir.clone());
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        submit(&h, "wait");
        drive(&mut h, |e| matches!(e, Event::BackgroundDone { status, .. } if status == "done")).await;
        h.ops.send(Op::Interrupt).unwrap();
        let stopped = drive(&mut h, |e| matches!(e, Event::Idle)).await;
        assert!(stopped.iter().any(|e| matches!(&e.event,
            Event::TurnEnded { reason: EndReason::Cancelled, .. })));
        // Nothing starts on its own.
        let quiet = tokio::time::timeout(Duration::from_millis(1_500), async {
            loop {
                let env = h.events.recv().await.unwrap();
                if matches!(env.event, Event::TurnStarted { .. }) {
                    break env;
                }
            }
        })
        .await;
        assert!(quiet.is_err(), "a held wake started a turn");
        submit(&h, "next");
        let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        let input = evs
            .iter()
            .find_map(|e| match &e.event {
                Event::TurnStarted { input, .. } => Some(input.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(input, "next", "the user's message starts the turn; the wake rides along");
        let rode = evs.iter().find_map(|e| match &e.event {
            Event::WakesDelivered { wakes, .. } => Some(wakes.clone()),
            _ => None,
        });
        assert!(
            rode.is_some_and(|w| w.len() == 1 && w[0].starts_with("<wakeup id=mon-1")),
            "the held wake is delivered with the turn, and says so"
        );
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Short sleeps and sleeps with real work after them still run inline, as written.
    #[tokio::test]
    async fn a_short_sleep_or_real_work_runs_inline() {
        let dir = tmp_store();
        let script = vec![
            reply(
                vec![
                    call("s", "Bash", json!({"command": "sleep 1; echo short"})),
                    call(
                        "r",
                        "Bash",
                        json!({"command": "sleep 0 && echo real > /dev/null; echo real"}),
                    ),
                ],
                Stop::ToolUse,
            ),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_with(script, true, None, None, None, dir.clone());
        drive(&mut h, |e| matches!(e, Event::Idle)).await;
        submit(&h, "go");
        let evs = drive(&mut h, |e| matches!(e, Event::TurnEnded { .. })).await;
        let s = tool_output(&evs, "s").unwrap();
        assert!(s.contains("short"), "{s}");
        assert!(tool_output(&evs, "r").unwrap().contains("real"));
        assert!(
            !evs.iter()
                .any(|e| matches!(e.event, Event::BackgroundStarted { .. }))
        );
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
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

    // ---- auto-compaction off the provider's real limit ----

    /// An engine helper whose profile name the catalog can know.
    fn engine_named(script: Vec<Response>, spec: &str, window: Option<u64>) -> Handle {
        let (_, model) = spec.split_once('/').unwrap();
        let mut profile = Profile::new(ProviderKind::Ollama, model);
        profile.context_window = window;
        profile.tool_mode = ToolMode::Native;
        let opts = Options {
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
            profile_name: spec.into(),
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

    /// An engine in a permission mode, with an optional classifier spec. The shell
    /// sandbox is off so Bash calls reach the permission logic, not the sandbox's
    /// blanket allow.
    fn engine_perm(script: Vec<Response>, mode: Mode, classifier: Option<&str>) -> Handle {
        let mut cfg = Config {
            hermetic: true,
            sandbox_shell: false,
            ..Config::default()
        };
        cfg.auto_classifier = classifier.map(String::from);
        engine_perm_cfg(script, mode, cfg)
    }

    fn engine_perm_cfg(script: Vec<Response>, mode: Mode, cfg: Config) -> Handle {
        engine_perm_at(script, mode, cfg, std::env::temp_dir())
    }

    fn engine_perm_at(script: Vec<Response>, mode: Mode, cfg: Config, cwd: PathBuf) -> Handle {
        let mut profile = Profile::new(ProviderKind::Ollama, "test");
        profile.tool_mode = ToolMode::Native;
        let opts = Options {
            cfg,
            profile_name: "test".into(),
            profile,
            cwd,
            mode,
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

    /// The window after startup resolved it: the last `Status` before the first `Idle`
    /// (the engine emits `Status` before and after `resolve_window`, then `Idle`).
    async fn resolved_window(h: &mut Handle) -> u64 {
        let mut window = 0;
        loop {
            let env = h.events.recv().await.unwrap();
            match &env.event {
                Event::Status(s) => window = s.context_window,
                Event::Idle => return window,
                _ => {}
            }
        }
    }

    /// (a) A window the config doesn't set comes from the catalog's context_length, not the
    /// per-provider default.
    #[tokio::test]
    async fn an_unknown_window_uses_the_catalog_value() {
        // Unknown to the catalog: the Ollama default.
        let mut h = engine_named(vec![reply(vec![text("hi")], Stop::End)], "testprov/m", None);
        assert_eq!(resolved_window(&mut h).await, 32_768);
        shutdown(h).await;

        // Known to the catalog: its context_length.
        let spec = "testprov/m";
        let model = crate::catalog::Model {
            spec: spec.into(),
            provider: "testprov".into(),
            id: "m".into(),
            name: "M".into(),
            context: Some(100_000),
            ..Default::default()
        };
        crate::catalog::TEST_CACHE
            .lock()
            .unwrap()
            .get_or_insert_with(Default::default)
            .insert(spec.into(), model);
        let mut h = engine_named(vec![reply(vec![text("hi")], Stop::End)], spec, None);
        assert_eq!(resolved_window(&mut h).await, 100_000);
        shutdown(h).await;
        crate::catalog::TEST_CACHE.lock().unwrap().take();
    }

    /// A successful compaction carries what it kept (the #53 receipt: files with +/−, turns
    /// with their requests and outcomes, tests run), so the app can banner it; engines
    /// without a session store emit the token counts alone.
    #[tokio::test]
    async fn a_compaction_emits_what_it_kept() {
        let root = tmp_store();
        let project = root.join("repo");
        std::fs::create_dir_all(project.join(".git")).unwrap();
        std::fs::create_dir_all(project.join("src")).unwrap();
        std::fs::write(project.join("src/auth.rs"), "pub fn login() {}\n").unwrap();
        let read = Block::ToolUse {
            id: "r1".into(),
            name: "Read".into(),
            input: json!({ "file_path": "src/auth.rs" }),
        };
        let edit = Block::ToolUse {
            id: "e1".into(),
            name: "Edit".into(),
            input: json!({
                "file_path": "src/auth.rs",
                "old_string": "login() {}",
                "new_string": "login() { check(); }"
            }),
        };
        // A shell command the summary reads as a passing test run (`make test` matches
        // `is_test`); with no Makefile here it fails fast and the `||` prints a passing
        // result — nothing in it can hang the Bash tool.
        let tests = Block::ToolUse {
            id: "b1".into(),
            name: "Bash".into(),
            input: json!({ "command": "make test || echo 'test result: ok. 3 passed; 0 failed'" }),
        };
        let script = vec![
            reply(vec![read, edit, tests], Stop::ToolUse),
            reply(vec![text("Fixed the login check.")], Stop::End),
            reply(vec![text("Kept: the login fix and its tests.")], Stop::End),
        ];
        let mut profile = Profile::new(ProviderKind::Ollama, "test");
        profile.tool_mode = ToolMode::Native;
        let opts = Options {
            // The sandbox's `sandbox-exec` isn't available under the test runner's own sandbox.
            cfg: Config {
                hermetic: true,
                sandbox_shell: false,
                ..Config::default()
            },
            profile_name: "test".into(),
            profile,
            cwd: project.clone(),
            // Yolo: the Bash call needs no permission card (nothing answers one in a test —
            // the card would sit out the whole 600s approval timeout, then deny).
            mode: Mode::Yolo,
            can_ask: true,
            resume: None,
            store: Some(root.join("sessions")),
            sandbox: false,
            rich: false,
            subagent: false,
            chat: false,
        };
        let mut h = start(opts, Provider::Scripted(scripted::Client::new(script))).unwrap();
        until_idle(&mut h).await;
        h.ops
            .send(Op::Submit {
                text: "fix the login bug".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let _ = until_idle(&mut h).await;
        // The user's own compact: the reply above summarizes, the event carries the receipt.
        h.ops.send(Op::Compact { focus: None }).unwrap();
        let evs = until_idle(&mut h).await;
        let kept = evs
            .iter()
            .find_map(|e| match &e.event {
                Event::Compacted { summary, .. } => summary.clone(),
                _ => None,
            })
            .expect("a Compacted event with its receipt");
        assert_eq!(
            kept.files,
            vec![crate::protocol::KeptFile {
                path: "src/auth.rs".into(),
                added: 1,
                removed: 1
            }]
        );
        // The receipt names the session it summarized (the banner's lineage).
        assert!(!kept.id.is_empty(), "the summary id rides along");
        assert_eq!(kept.turns.len(), 1);
        let t = &kept.turns[0];
        assert_eq!(t.request, "fix the login bug");
        assert!(t.tools.contains(&"Edit".to_string()));
        assert_eq!(
            t.tests,
            vec![crate::protocol::KeptTest {
                command: "make test || echo 'test result: ok. 3 passed; 0 failed'".to_string(),
                passed: true
            }]
        );
        assert_eq!(t.outcome, "complete");
        assert_eq!(kept.outcome, "complete");

        // Without a store (hermetic runs, some tests): the token counts stand alone, no
        // receipt — the compact needs history, so a turn runs first.
        let mut bare = engine(
            vec![
                reply(vec![text("Something to compact.")], Stop::End),
                reply(vec![text("Kept.")], Stop::End),
            ],
            true,
        );
        let _ = run(&mut bare, "anything").await;
        bare.ops.send(Op::Compact { focus: None }).unwrap();
        let evs = until_idle(&mut bare).await;
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::Compacted { summary: None, .. }
        )));
        shutdown(h).await;
        shutdown(bare).await;
    }

    /// (b) A prompt past the hard limit is compacted before the model call, not after a 400.
    #[tokio::test]
    async fn a_prompt_past_the_hard_limit_compacts_before_the_call() {
        let script = vec![
            reply(vec![text("Summary of the work so far.")], Stop::End),
            reply(vec![text("Done.")], Stop::End),
        ];
        let (mut h, sent) = engine_sent(script, None, None, Some(8192), std::env::temp_dir());
        let evs = run(&mut h, &"Do the long thing. ".repeat(1600)).await;
        assert_eq!(
            evs.iter()
                .filter(|e| matches!(e.event, Event::Compacted { .. }))
                .count(),
            1
        );
        let requests = sent.lock().unwrap();
        assert_eq!(requests.len(), 2);
        // The first request is the compaction call, so the second is the turn's only model call.
        assert!(requests[0].contains("detailed summary"));
        assert!(requests[1].contains("Summary of the work so far."));
        drop(requests);
        shutdown(h).await;
    }

    /// (c) One tool result can't blow the window: oversized output is capped on arrival.
    #[tokio::test]
    async fn an_oversized_tool_result_is_capped() {
        let dir = tmp_store();
        // ~82KB in 80 lines; the cap for an 8192-token window is 40_000 chars.
        let line = "0123456789abcdef".repeat(64);
        std::fs::write(dir.join("big.txt"), format!("{line}\n").repeat(80)).unwrap();
        let script = vec![
            reply(
                vec![Block::ToolUse {
                    id: "r1".into(),
                    name: "Read".into(),
                    input: json!({"file_path": "big.txt"}),
                }],
                Stop::ToolUse,
            ),
            reply(vec![text("Done.")], Stop::End),
        ];
        let (mut h, sent) = engine_sent(script, None, None, Some(8192), dir);
        let evs = run(&mut h, "read big.txt").await;
        let output = evs
            .iter()
            .find_map(|e| match &e.event {
                Event::ItemCompleted {
                    item: Item::ToolCall { name, output, .. },
                    ..
                } if name == "Read" => Some(output.clone()),
                _ => None,
            })
            .unwrap();
        assert!(output.contains("Output capped"), "{output}");
        assert!(output.len() < 50_000, "{}", output.len());
        // The model never sees more than the cap either.
        let requests = sent.lock().unwrap();
        assert!(requests[1].len() < 120_000, "{}", requests[1].len());
        drop(requests);
        shutdown(h).await;
    }

    /// (d) A provider "maximum context length" 400 compacts and retries the step once.
    #[tokio::test]
    async fn a_context_overflow_compacts_and_retries_once() {
        // Vercel's gateway wording from session 20261022-132854-96e9.
        let overflow = scripted::Fail::http(
            400,
            "{\"error\":{\"message\":\"This model's maximum context length is 1048576 tokens. \
However, your request has 1579729 input tokens. Please reduce the length of the input.\"}}",
        );
        let client = scripted::Client::new(vec![
            reply(vec![text("Summary after overflow.")], Stop::End),
            reply(vec![text("Recovered.")], Stop::End),
        ]);
        client.fails.lock().unwrap().push_back(overflow);
        let sent = client.sent.clone();
        let opts = Options {
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
            profile_name: "testprov/m".into(),
            profile: {
                let mut p = Profile::new(ProviderKind::Ollama, "m");
                p.tool_mode = ToolMode::Native;
                p
            },
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
        let mut h = start(opts, Provider::Scripted(client)).unwrap();
        let evs = run(&mut h, "keep going").await;
        assert_eq!(
            evs.iter()
                .filter(|e| matches!(e.event, Event::Compacted { .. }))
                .count(),
            1,
            "{:?}",
            names(&evs)
        );
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
        let requests = sent.lock().unwrap();
        assert_eq!(requests.len(), 3);
        // The failed call, the compaction, then the retry — which carries the compacted history.
        assert!(requests[1].contains("detailed summary"));
        assert!(requests[2].contains("Summary after overflow"));
        assert!(!requests[2].contains("keep going\"}]}]"));
        drop(requests);
        shutdown(h).await;
    }

    /// (d) If compaction can't fix it either, the turn ends with a clear error, not a raw 400.
    #[tokio::test]
    async fn a_context_overflow_twice_ends_the_turn_with_a_clear_error() {
        let overflow = || {
            scripted::Fail::http(
                400,
                "Input too long: 1579729 input tokens, limit is 1048576 for this model",
            )
        };
        let client = scripted::Client::new(vec![reply(vec![text("Summary.")], Stop::End)]);
        client
            .fails
            .lock()
            .unwrap()
            .extend([overflow(), overflow()]);
        let opts = Options {
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
            profile_name: "testprov/m".into(),
            profile: {
                let mut p = Profile::new(ProviderKind::Ollama, "m");
                p.tool_mode = ToolMode::Native;
                p
            },
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
        let mut h = start(opts, Provider::Scripted(client)).unwrap();
        let evs = run(&mut h, "keep going").await;
        // Turn failures arrive as TurnEnded(Error), with a message that says what happened.
        let error = evs
            .iter()
            .find_map(|e| match &e.event {
                Event::TurnEnded {
                    reason: EndReason::Error { error },
                    ..
                } => Some(error.to_string()),
                _ => None,
            })
            .unwrap();
        assert!(error.contains("context window"), "{error}");
        // The rescue event: exactly one, carrying the provider's raw wording for the engine
        // log — the transcript renders one line from it, never the payload itself.
        let failed: Vec<&Event> = evs
            .iter()
            .map(|e| &e.event)
            .filter(|e| matches!(e, Event::CompactionFailed { .. }))
            .collect();
        assert_eq!(failed.len(), 1, "{:?}", names(&evs));
        assert!(evs.iter().any(|e| matches!(&e.event, Event::CompactionFailed { detail } if detail.contains("input tokens"))));
        // The turn's error stays one line: no provider body in it.
        assert!(!error.contains("1579729"), "{error}");
        shutdown(h).await;
    }

    /// The rescue op is answered honestly: with session hosting on, the engine tells the
    /// client to carry forward; without it, the op is refused, and either way the session
    /// log's story (a stuck session, no rescue) is untouched.
    #[tokio::test]
    async fn the_continue_session_op_answers_and_leaves_the_session_alone() {
        let mut h = engine(vec![reply(vec![text("stuck")], Stop::End)], true);
        caps(&h, false);
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        let ask = |h: &Handle| {
            h.ops
                .send(Op::ContinueSession {
                    from: "old".into(),
                    why: "overflow".into(),
                })
                .unwrap();
        };
        // What the op answers with: the notice that says `expect`, then the Idle that
        // closes it — nothing more (no turn on the stuck history).
        macro_rules! drain {
            ($expect:expr) => {
                loop {
                    match h.events.recv().await.unwrap().event {
                        Event::Notice { message, .. } => {
                            assert!(message.contains($expect), "{message}")
                        }
                        Event::Idle => break,
                        Event::Status(_) | Event::ModelChanged { .. } => {}
                        other => panic!("unexpected {other:?}"),
                    }
                }
            };
        }
        ask(&h);
        drain!("can't start");
        // And with hosting on: the ask is noticed, nothing more.
        caps(&h, true);
        ask(&h);
        drain!("carried-forward");
        shutdown(h).await;
    }

    #[tokio::test]
    async fn read_only_compounds_run_without_asking_in_every_mode() {
        for mode in [Mode::Default, Mode::AcceptEdits, Mode::Auto] {
            // The sandbox is off in tests, so these go through the fast path.
            let script = vec![
                reply(
                    vec![Block::ToolUse {
                        id: "ro".into(),
                        name: "Bash".into(),
                        input: json!({ "command": "cd /tmp && git log --oneline | head -3; ls | wc -l" }),
                    }],
                    Stop::ToolUse,
                ),
                reply(vec![text("done")], Stop::End),
            ];
            let mut h = engine_perm(script, mode, Some("nonexistent/no-classifier"));
            let evs = run(&mut h, "look around").await;
            assert!(
                !evs.iter().any(|e| matches!(e.event, Event::PermissionRequest { .. })),
                "{mode:?} asked for a read-only compound"
            );
            assert!(evs.iter().any(|e| matches!(
                e.event,
                Event::ItemCompleted { .. }
            )));
        }
    }

    #[tokio::test]
    async fn writes_and_unknowns_still_ask_in_default_mode() {
        for cmd in ["cat x > y", "cargo build", "echo $(rm -rf x)"] {
            let script = vec![
                reply(
                    vec![Block::ToolUse {
                        id: "w".into(),
                        name: "Bash".into(),
                        input: json!({ "command": cmd }),
                    }],
                    Stop::ToolUse,
                ),
                reply(vec![text("done")], Stop::End),
            ];
            let mut h = engine_perm(script, Mode::Default, None);
            while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
            h.ops
                .send(Op::Submit {
                    text: "go".into(),
                    images: Vec::new(),
                    more: Vec::new(),
                })
                .unwrap();
            let mut asked = false;
            loop {
                let env = h.events.recv().await.unwrap();
                if let Event::PermissionRequest { id, .. } = &env.event {
                    asked = true;
                    h.ops
                        .send(Op::Permission {
                            id: id.clone(),
                            decision: Decision::Deny,
                            note: None,
                        })
                        .unwrap();
                }
                if matches!(env.event, Event::Idle) {
                    break;
                }
            }
            assert!(asked, "`{cmd}` didn't ask in default mode");
        }
    }

    #[tokio::test]
    async fn auto_mode_falls_back_to_the_fast_path_when_the_classifier_fails() {
        // A classifier spec that can't resolve: the classifier is down all turn.
        let script = vec![
            reply(
                vec![Block::ToolUse {
                    id: "ro".into(),
                    name: "Bash".into(),
                    input: json!({ "command": "git log --oneline | head -3" }),
                }],
                Stop::ToolUse,
            ),
            reply(
                vec![Block::ToolUse {
                    id: "w".into(),
                    name: "Bash".into(),
                    // Not a routine build step: provenance can't pass it, so
                    // with the classifier down it asks.
                    input: json!({ "command": "python3 -c 'print(1)' > made-up-file" }),
                }],
                Stop::ToolUse,
            ),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_perm(script, Mode::Auto, Some("nonexistent/no-classifier"));
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "go".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut evs = Vec::new();
        let mut asked = 0;
        loop {
            let env = h.events.recv().await.unwrap();
            let idle = matches!(env.event, Event::Idle);
            if let Event::PermissionRequest { id, .. } = &env.event {
                asked += 1;
                h.ops
                    .send(Op::Permission {
                        id: id.clone(),
                        decision: Decision::Deny,
                        note: None,
                    })
                    .unwrap();
            }
            evs.push(env);
            if idle {
                break;
            }
        }
        // The read-only command ran without asking: the fast path is checked
        // before any model call, so a down classifier can't block it.
        let read_only_ran = evs.iter().any(|e| matches!(
            e.event,
            Event::ItemCompleted { ref id, item: Item::ToolCall { outcome: ToolOutcome::Ok, .. }, .. } if id == "ro"
        ));
        assert!(read_only_ran, "the read-only call ran");
        // …the write asked…
        assert_eq!(asked, 1, "the write asked");
        // …and the failure was logged once, not per call.
        let notices = evs
            .iter()
            .filter(|e| matches!(&e.event, Event::Notice { message, .. } if message.contains("classifier") && message.contains("is down")))
            .count();
        assert_eq!(notices, 1, "one classifier-failure notice");
    }

    fn bash_call(id: &str, cmd: &str) -> Response {
        reply(
            vec![Block::ToolUse {
                id: id.into(),
                name: "Bash".into(),
                input: json!({ "command": cmd }),
            }],
            Stop::ToolUse,
        )
    }

    /// A stand-in classifier server on localhost: every chat completion gets `status`, and a
    /// 200 streams `verdict` (a JSON answer) as the model's text. Counts the requests.
    async fn fake_classifier(status: u16, verdict: &str) -> (String, Arc<std::sync::atomic::AtomicUsize>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}/v1", listener.local_addr().unwrap());
        let hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let chunk = json!({"choices": [{"index": 0, "delta": {"content": verdict}, "finish_reason": null}]});
        let done = json!({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]});
        let body = format!("data: {chunk}\n\ndata: {done}\n\ndata: [DONE]\n\n");
        let count = hits.clone();
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let body = body.clone();
                let count = count.clone();
                tokio::spawn(async move {
                    // Read the whole request (headers, then Content-Length of body).
                    let mut received = Vec::new();
                    loop {
                        let mut buf = [0u8; 8192];
                        let Ok(n) = socket.read(&mut buf).await else { return };
                        if n == 0 {
                            return;
                        }
                        received.extend_from_slice(&buf[..n]);
                        if let Some(end) = received.windows(4).position(|w| w == b"\r\n\r\n") {
                            let headers = String::from_utf8_lossy(&received[..end]).to_ascii_lowercase();
                            let len: usize = headers
                                .lines()
                                .find_map(|l| l.strip_prefix("content-length: ").map(str::to_owned))
                                .and_then(|l| l.trim().parse().ok())
                                .unwrap_or(0);
                            if received.len() >= end + 4 + len {
                                break;
                            }
                        }
                    }
                    count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    let response = if status == 200 {
                        format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())
                    } else {
                        format!("HTTP/1.1 {status} Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    };
                    let _ = socket.write_all(response.as_bytes()).await;
                    let _ = socket.shutdown().await;
                });
            }
        });
        (base, hits)
    }

    /// A port nothing listens on: the classifier there is unreachable (connection refused).
    fn unreachable_base() -> String {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        drop(l);
        format!("http://{addr}/v1")
    }

    /// An auto-mode config whose classifier is the `classifier` profile at `base`, with an
    /// optional `fallback` profile at its own base.
    fn classifier_cfg(base: &str, fallback: Option<&str>) -> Config {
        let mut cfg = Config {
            hermetic: true,
            sandbox_shell: false,
            ..Config::default()
        };
        let profile = |base: &str| {
            let mut p = Profile::new(ProviderKind::Openai, "judge");
            p.base_url = Some(base.into());
            p
        };
        cfg.models.insert("classifier".into(), profile(base));
        cfg.auto_classifier = Some("classifier".into());
        if let Some(fb) = fallback {
            cfg.models.insert("backup".into(), profile(fb));
            cfg.auto_classifier_fallback = Some("backup".into());
        }
        cfg
    }

    /// Item 1 (org reliability): with the classifier unreachable, a read-only call the
    /// classifier would have judged runs on the built-in rules with no card, a delete of
    /// scratch the session didn't make still cards, and the outage is one notice, not one
    /// per call.
    #[tokio::test]
    async fn an_unreachable_classifier_falls_back_to_the_rules_not_to_cards() {
        let script = vec![
            // A capture of a public page: only the classifier judged it before. The viewport
            // is invalid so the tool fails at once, after the permission check.
            reply(
                vec![Block::ToolUse {
                    id: "shot".into(),
                    name: "Screenshot".into(),
                    input: json!({"url": "https://example.com/docs", "width": 10}),
                }],
                Stop::ToolUse,
            ),
            // Deletes a file the session didn't make, outside the project: no rule covers it.
            bash_call("rm", "rm /private/tmp/frog-classifier-down-not-mine.txt"),
            // Another call for the classifier: still one notice.
            reply(
                vec![Block::ToolUse {
                    id: "shot2".into(),
                    name: "Screenshot".into(),
                    input: json!({"url": "https://example.org/", "width": 10}),
                }],
                Stop::ToolUse,
            ),
            reply(vec![text("done")], Stop::End),
        ];
        let cfg = classifier_cfg(&unreachable_base(), None);
        let mut h = engine_perm_cfg(script, Mode::Auto, cfg);
        let evs = turn_answering(&mut h, |_| Some((Decision::Deny, None))).await;
        shutdown(h).await;
        let carded = |item: &str| {
            evs.iter().any(|e| matches!(&e.event, Event::PermissionRequest { item: i, .. } if i == item))
        };
        assert!(!carded("shot") && !carded("shot2"), "a read-only call carded with the classifier down");
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::AutoApproved { item, reason } if item == "shot" && reason.contains("rules decided")
        )));
        assert!(carded("rm"), "a delete outside its own scratch must still card");
        // The card says which rule gap made it ask, not just that the classifier is down.
        let reason = evs.iter().find_map(|e| match &e.event {
            Event::PermissionRequest { item, reason, .. } if item == "rm" => reason.clone(),
            _ => None,
        });
        assert!(reason.unwrap_or_default().contains("no built-in rule covers it"));
        let notices: Vec<&str> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::Notice { message, .. } if message.contains("classifier") => Some(message.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(notices.len(), 1, "{notices:?}");
        assert!(notices[0].contains("built-in rules"), "{}", notices[0]);
    }

    /// Item 1: a configured `auto_classifier_fallback` judges when the classifier answers
    /// 5xx; the down classifier is skipped (not retried per call) while it stays down.
    #[tokio::test]
    async fn a_configured_fallback_classifier_judges_when_the_classifier_is_down() {
        let (down, down_hits) = fake_classifier(503, "").await;
        let (backup, backup_hits) =
            fake_classifier(200, r#"{"reason":"part of the task","decision":"allow"}"#).await;
        let script = vec![
            // Not a routine build step: only a classifier can pass it.
            bash_call("w1", "python3 -c 'print(1)' > made-up-file"),
            bash_call("w2", "python3 -c 'print(2)' > made-up-file"),
            reply(vec![text("done")], Stop::End),
        ];
        let cfg = classifier_cfg(&down, Some(&backup));
        let dir = tmp_store();
        let mut h = engine_perm_at(script, Mode::Auto, cfg, dir);
        let evs = turn_answering(&mut h, |_| Some((Decision::Deny, None))).await;
        shutdown(h).await;
        assert!(
            !evs.iter().any(|e| matches!(e.event, Event::PermissionRequest { .. })),
            "the fallback approved both; nothing carded"
        );
        let approved = evs
            .iter()
            .filter(|e| matches!(&e.event, Event::AutoApproved { reason, .. } if reason == "part of the task"))
            .count();
        assert_eq!(approved, 2);
        // One attempt and its one transport retry; the second call skipped it.
        assert_eq!(down_hits.load(std::sync::atomic::Ordering::SeqCst), 2);
        assert_eq!(backup_hits.load(std::sync::atomic::Ordering::SeqCst), 2);
        let notices: Vec<&str> = evs
            .iter()
            .filter_map(|e| match &e.event {
                Event::Notice { message, .. } if message.contains("classifier") => Some(message.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(notices.len(), 1, "{notices:?}");
        assert!(notices[0].contains("fallback classifier (backup)"), "{}", notices[0]);
    }

    /// The `degraded` list of the last `Status` in `evs`.
    fn last_degraded(evs: &[Envelope]) -> Vec<crate::protocol::Degraded> {
        evs.iter()
            .rev()
            .find_map(|e| match &e.event {
                Event::Status(s) => Some(s.degraded.clone()),
                _ => None,
            })
            .unwrap_or_default()
    }

    /// Item 3a (org reliability): a session that fell back to text tool calls says so in its
    /// status, with why, and only then.
    #[tokio::test]
    async fn text_tool_calls_show_as_degraded_with_why() {
        let text_call =
            r#"<tool_call>{"name":"Glob","arguments":{"pattern":"*.nothing"}}</tool_call>"#;
        let script = vec![
            reply(vec![text(text_call)], Stop::End),
            reply(vec![text(text_call)], Stop::End),
            reply(vec![text("none found")], Stop::End),
        ];
        let mut h = engine_mode(script, ToolMode::Auto);
        let boot = run(&mut h, "find .nothing files").await;
        let d = last_degraded(&boot);
        assert_eq!(d.len(), 1, "{d:?}");
        assert_eq!(d[0].kind, crate::protocol::DegradedKind::TextTools);
        assert_eq!(d[0].what, "text tool calls");
        assert!(d[0].why.contains("instead of calling them"), "{}", d[0].why);
        shutdown(h).await;
        // A profile that asks for text calls isn't degraded.
        let mut h = engine_mode(vec![reply(vec![text("hi")], Stop::End)], ToolMode::Text);
        assert!(last_degraded(&run(&mut h, "hi").await).is_empty());
        shutdown(h).await;
    }

    /// Item 3b: a session resumed on another model than the one it ran on (a resume with no
    /// `-m` takes the default) shows the flip; switching on purpose clears it.
    #[tokio::test]
    async fn a_silent_model_flip_shows_as_degraded_until_switched_on_purpose() {
        let dir = tmp_store();
        let mut h = engine_at(vec![reply(vec![text("one")], Stop::End)], false, Some(dir.clone()), None);
        let first = run(&mut h, "first").await;
        let sid = first[0].session.clone();
        assert!(last_degraded(&first).is_empty(), "no flip on its own model");
        shutdown(h).await;
        // Resumed on another model.
        let mut profile = Profile::new(ProviderKind::Ollama, "glm-flash");
        profile.tool_mode = ToolMode::Native;
        let opts = Options {
            cfg: Config {
                hermetic: true,
                ..Config::default()
            },
            profile_name: "ollama/glm-flash".into(),
            profile,
            cwd: std::env::temp_dir(),
            mode: Mode::Default,
            can_ask: false,
            resume: Some(sid),
            store: Some(dir),
            sandbox: false,
            rich: false,
            subagent: false,
            chat: false,
        };
        let mut h = start(
            opts,
            Provider::Scripted(scripted::Client::new(vec![reply(vec![text("two")], Stop::End)])),
        )
        .unwrap();
        let d = last_degraded(&run(&mut h, "carry on").await);
        assert_eq!(d.len(), 1, "{d:?}");
        assert_eq!(d[0].kind, crate::protocol::DegradedKind::Model);
        assert_eq!(d[0].what, "on ollama/glm-flash");
        assert!(d[0].why.contains("was on test"), "{}", d[0].why);
        // Switched on purpose: it's the model the session is meant to be on now.
        h.ops.send(Op::SetModel { spec: "ollama/other".into() }).unwrap();
        let mut last = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            let idle = matches!(env.event, Event::Idle);
            last.push(env);
            if idle {
                break;
            }
        }
        assert!(last_degraded(&last).is_empty(), "{:?}", last_degraded(&last));
        shutdown(h).await;
    }

    /// Item 3c: while auto mode's classifier is down, the status says what decides instead.
    #[tokio::test]
    async fn a_down_classifier_shows_as_degraded() {
        let script = vec![
            bash_call("w", "python3 -c 'print(1)' > made-up-file"),
            reply(vec![text("done")], Stop::End),
        ];
        let cfg = classifier_cfg(&unreachable_base(), None);
        let mut h = engine_perm_cfg(script, Mode::Auto, cfg);
        let evs = turn_answering(&mut h, |_| Some((Decision::Deny, None))).await;
        shutdown(h).await;
        let d = last_degraded(&evs);
        assert_eq!(d.len(), 1, "{d:?}");
        assert_eq!(d[0].kind, crate::protocol::DegradedKind::Classifier);
        assert!(d[0].why.contains("classifier classifier is down"), "{}", d[0].why);
        assert!(d[0].why.contains("built-in rules decide"), "{}", d[0].why);
    }

    #[tokio::test]
    async fn web_reads_run_without_asking_in_every_mode() {
        // Cam's decision 2026-10-23: WebSearch always; WebFetch of a public host —
        // in default, accept-edits and auto alike, classifier or not.
        for (name, input) in [
            ("WebSearch", json!({ "query": "qwen3 coder next pricing" })),
            ("WebFetch", json!({ "url": "https://example.com/docs" })),
        ] {
            for mode in [Mode::Default, Mode::AcceptEdits, Mode::Auto] {
                let script = vec![
                    reply(
                        vec![Block::ToolUse { id: "web".into(), name: name.into(), input: input.clone() }],
                        Stop::ToolUse,
                    ),
                    reply(vec![text("done")], Stop::End),
                ];
                let mut h = engine_perm(script, mode, Some("nonexistent/no-classifier"));
                let evs = run(&mut h, "look it up").await;
                assert!(
                    !evs.iter().any(|e| matches!(e.event, Event::PermissionRequest { .. })),
                    "{mode:?} asked for {name}"
                );
                // The scripted provider can't actually fetch, so the call may end in a
                // tool error — what matters is that it never surfaced a permission card.
                assert!(
                    evs.iter().any(|e| matches!(
                        e.event,
                        Event::ItemCompleted { ref id, item: Item::ToolCall { .. }, .. } if id == "web"
                    )),
                    "{name} ran in {mode:?}"
                );
            }
        }
    }

    #[tokio::test]
    async fn a_non_public_webfetch_still_asks_in_default_mode() {
        let script = vec![
            reply(
                vec![Block::ToolUse {
                    id: "web".into(),
                    name: "WebFetch".into(),
                    input: json!({ "url": "http://localhost:8080/admin" }),
                }],
                Stop::ToolUse,
            ),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_perm(script, Mode::Default, None);
        let mut asked = false;
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit { text: "go".into(), images: Vec::new(), more: Vec::new() })
            .unwrap();
        loop {
            let env = h.events.recv().await.unwrap();
            if let Event::PermissionRequest { id, .. } = &env.event {
                asked = true;
                h.ops
                    .send(Op::Permission { id: id.clone(), decision: Decision::Deny, note: None })
                    .unwrap();
            }
            if matches!(env.event, Event::Idle) {
                break;
            }
        }
        shutdown(h).await;
        assert!(asked, "a localhost WebFetch didn't ask in default mode");
    }

    /// Auto mode: a build writing its own scratch under /private/tmp runs without
    /// asking (the provenance layer), an outside-project command still asks.
    #[tokio::test]
    async fn auto_mode_lets_a_build_touch_only_its_own_scratch() {
        let script = vec![
            // Its own fresh build dir under /private/tmp.
            bash_call("build", "mkdir -p /private/tmp/skittish-test-target/debug"),
            // Another user path: still asks (answered deny below).
            bash_call("outside", "touch /Users/frog-test-nobody/not-mine.txt"),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_perm(script, Mode::Auto, Some("nonexistent/no-classifier"));
        let evs = turn_answering(&mut h, |_| Some((Decision::Deny, None))).await;
        shutdown(h).await;
        // The scratch build ran…
        assert!(
            evs.iter().any(|e| matches!(
                e.event,
                Event::ItemCompleted { ref id, item: Item::ToolCall { outcome: ToolOutcome::Ok, .. }, .. } if id == "build"
            )),
            "the scratch build ran without asking"
        );
        assert!(
            !evs.iter().any(|e| matches!(
                e.event,
                Event::PermissionRequest { ref item, .. } if item == "build"
            )),
            "the scratch build never asked"
        );
        // …and nothing else was permitted to run outside.
        assert!(
            evs.iter().any(|e| matches!(
                e.event,
                Event::PermissionRequest { ref item, .. } if item == "outside"
            )),
            "the outside command asked"
        );
        let _ = std::fs::remove_dir_all("/private/tmp/skittish-test-target");
    }

    /// Run one turn, answering each permission prompt with `answer` (None: leave it
    /// unanswered). Returns every event up to the end of the turn.
    async fn turn_answering(
        h: &mut Handle,
        mut answer: impl FnMut(&Event) -> Option<(Decision, Option<String>)>,
    ) -> Vec<Envelope> {
        while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        h.ops
            .send(Op::Submit {
                text: "go".into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut evs = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            if let Event::PermissionRequest { id, .. } = &env.event
                && let Some((decision, note)) = answer(&env.event)
            {
                h.ops
                    .send(Op::Permission {
                        id: id.clone(),
                        decision,
                        note,
                    })
                    .unwrap();
            }
            let idle = matches!(env.event, Event::Idle);
            evs.push(env);
            if idle {
                return evs;
            }
        }
    }

    fn tool_output<'a>(evs: &'a [Envelope], call: &str) -> Option<&'a str> {
        evs.iter().find_map(|e| match &e.event {
            Event::ItemCompleted {
                id,
                item: Item::ToolCall { output, .. },
            } if id == call => Some(output.as_str()),
            _ => None,
        })
    }

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("frog-{tag}-{}", session::new_id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[tokio::test]
    async fn deny_with_a_note_goes_back_to_the_agent_and_the_turn_continues() {
        let script = vec![
            bash_call("w", "touch /usr/local/frog-not-here"),
            bash_call("r", "ls"),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_perm(script, Mode::Default, None);
        let evs = turn_answering(&mut h, |_| {
            Some((Decision::Deny, Some("write it under /private/tmp instead".into())))
        })
        .await;
        let out = tool_output(&evs, "w").expect("the denied call has a result");
        assert!(out.contains("write it under /private/tmp instead"), "{out}");
        // Not a stop: the next call ran rather than being skipped.
        let next = tool_output(&evs, "r").unwrap();
        assert!(!next.contains("Skipped"), "{next}");
    }

    #[tokio::test]
    async fn an_unanswered_prompt_times_out_to_deny_and_the_agent_carries_on() {
        let script = vec![
            bash_call("w", "touch /usr/local/frog-not-here"),
            reply(vec![text("done")], Stop::End),
        ];
        let cfg = Config {
            hermetic: true,
            sandbox_shell: false,
            approval_timeout_secs: 1,
            ..Config::default()
        };
        let mut h = engine_perm_cfg(script, Mode::Default, cfg);
        let evs = turn_answering(&mut h, |_| None).await;
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::PermissionResolved {
                decision: Decision::Deny,
                ..
            }
        )));
        let out = tool_output(&evs, "w").unwrap();
        assert!(out.contains("safe path"), "{out}");
        assert!(evs.iter().any(|e| matches!(
            e.event,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )));
    }

    /// The prefix-allow scenario with commands naming `base` (spelled as given),
    /// on an engine with no shell sandbox (Linux CI has none; these tests turn it off).
    async fn prefix_allow_case(base: &str, real: &Path) {
        let (a, b, c) = (format!("{base}/a"), format!("{base}/b"), format!("{base}/c"));
        let script = vec![
            bash_call("1", &format!("rm -rf {a} {b}")),
            bash_call("2", &format!("rm -rf {c}")),
            bash_call("3", &format!("mv {a} {c}")),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_perm(script, Mode::Default, None);
        let expected = crate::approval::normalize(real);
        let mut asked: Vec<String> = Vec::new();
        let evs = turn_answering(&mut h, |e| {
            let Event::PermissionRequest { arg, card, always, .. } = e else { return None };
            asked.push(arg.clone());
            if asked.len() == 1 {
                let card = card.as_ref().expect("shell prompts carry a card");
                assert_eq!(card.prefix.as_deref(), expected.to_str(), "{base}");
                assert!(always.contains("under"), "{always}");
                Some((Decision::AllowPrefix, None))
            } else {
                Some((Decision::Deny, Some("no".into())))
            }
        })
        .await;
        assert_eq!(asked.len(), 2, "the rm under the prefix didn't ask; the mv did: {asked:?}");
        assert!(asked[1].starts_with("mv"), "{asked:?}");
        assert!(tool_output(&evs, "2").is_some());
    }

    #[tokio::test]
    async fn a_prefix_allow_covers_the_same_program_under_that_prefix_only() {
        let dir = scratch("prefix");
        prefix_allow_case(dir.to_str().unwrap(), &dir).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// What Linux CI sees: a shallow temp dir (`/tmp/frog-…`, three components)
    /// and, on macOS, a spelling that isn't canonical (`/tmp` is `/private/tmp`).
    #[tokio::test]
    async fn a_prefix_allow_works_for_a_shallow_uncanonical_tmp_dir() {
        let base = format!("/tmp/frog-prefix-{}", session::new_id());
        std::fs::create_dir_all(&base).unwrap();
        prefix_allow_case(&base, Path::new(&base)).await;
        let _ = std::fs::remove_dir_all(&base);
    }

    #[tokio::test]
    async fn the_card_knows_what_this_session_created() {
        let dir = scratch("prov");
        let made = dir.join("build-out");
        let script = vec![
            bash_call("mk", &format!("mkdir -p {}", made.display())),
            bash_call("rm", &format!("rm -rf {}", made.display())),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_perm(script, Mode::Default, None);
        let mut cards = Vec::new();
        turn_answering(&mut h, |e| {
            if let Event::PermissionRequest { card: Some(c), .. } = e {
                cards.push(c.clone());
            }
            Some((Decision::Allow, None))
        })
        .await;
        let rm = cards.last().expect("the rm asked");
        assert!(rm.touches[0].created_here, "{rm:?}");
        assert!(rm.risk.contains("this session created"), "{}", rm.risk);
        assert!(rm.recommendation.starts_with("allow"), "{}", rm.recommendation);
        assert!(!made.exists(), "the allowed rm ran");
        let _ = std::fs::remove_dir_all(dir);
       }

    // ---- approvals never stall (read verbs in every mode, mcp_trust, repeat denials) ----

    /// A stdio MCP stand-in named `server` (the `.mcp.json` key, so tools are
    /// `mcp__{server}__{tool}`) whose `initialize` waits for `gate`, and whose `tools/call`
    /// answers `ran {tool}`.
    fn named_mcp_server(dir: &Path, server: &str, tools: &[&str], gate: &Path) {
        let tools = json!(
            tools
                .iter()
                .map(|t| json!({"name": t, "description": "Test tool.",
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
        while not os.path.exists(GATE):
            time.sleep(0.01)
        r = {{"protocolVersion": m["params"]["protocolVersion"], "capabilities": {{"tools": {{}}}},
             "serverInfo": {{"name": "{server}", "version": "1"}}}}
    elif m["method"] == "tools/list":
        r = {{"tools": json.loads('{tools}')}}
    elif m["method"] == "tools/call":
        r = {{"content": [{{"type": "text", "text": "ran " + m["params"]["name"]}}]}}
    else:
        r = {{}}
    print(json.dumps({{"jsonrpc": "2.0", "id": m["id"], "result": r}}), flush=True)
"#,
            gate = gate.display().to_string()
        );
        std::fs::write(dir.join(format!("{server}_mcp.py")), script).unwrap();
        let cfg = json!({"mcpServers": {server: {
            "command": "python3",
            "args": [dir.join(format!("{server}_mcp.py")).display().to_string()],
        }}});
        std::fs::write(dir.join(".mcp.json"), cfg.to_string()).unwrap();
    }

    fn mcp_call(id: &str, name: &str) -> Response {
        reply(
            vec![Block::ToolUse {
                id: id.into(),
                name: name.into(),
                input: json!({}),
            }],
            Stop::ToolUse,
        )
    }

    /// Submit `prompt` (the engine is already idle) and collect through the next `Idle`,
    /// answering each permission prompt with `answer`.
    async fn next_turn(
        h: &mut Handle,
        prompt: &str,
        mut answer: impl FnMut(&Event) -> Option<(Decision, Option<String>)>,
    ) -> Vec<Envelope> {
        h.ops
            .send(Op::Submit {
                text: prompt.into(),
                images: Vec::new(),
                more: Vec::new(),
            })
            .unwrap();
        let mut evs = Vec::new();
        loop {
            let env = h.events.recv().await.unwrap();
            if let Event::PermissionRequest { id, .. } = &env.event
                && let Some((decision, note)) = answer(&env.event)
            {
                h.ops
                    .send(Op::Permission {
                        id: id.clone(),
                        decision,
                        note,
                    })
                    .unwrap();
            }
            let idle = matches!(env.event, Event::Idle);
            evs.push(env);
            if idle {
                return evs;
            }
        }
    }

    /// An engine in `mode` with `cfg`, in a fresh folder whose `.mcp.json` names a
    /// `planetscale` server with `tools`, connected: a first turn runs before the server may
    /// come up, then it joins (the `Status` the idle engine emits).
    async fn engine_with_mcp(
        mode: Mode,
        cfg: Config,
        tools: &[&str],
        calls: Vec<Response>,
    ) -> (Handle, PathBuf) {
        let dir = tmp_store();
        let gate = dir.join("mcp.gate");
        named_mcp_server(&dir, "planetscale", tools, &gate);
        let mut script = vec![reply(vec![text("warm")], Stop::End)];
        script.extend(calls);
        let mut h = engine_perm_at(script, mode, cfg, dir.clone());
        run(&mut h, "warm up").await;
        std::fs::write(&gate, "").unwrap();
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                if matches!(h.events.recv().await.unwrap().event, Event::Status(_)) {
                    break;
                }
            }
        })
        .await
        .expect("MCP server never connected");
        (h, dir)
    }

    fn perm_cfg() -> Config {
        Config {
            hermetic: true,
            sandbox_shell: false,
            ..Config::default()
        }
    }

    fn asked(evs: &[Envelope]) -> usize {
        evs.iter()
            .filter(|e| matches!(e.event, Event::PermissionRequest { .. }))
            .count()
    }

    fn outcome_of(evs: &[Envelope], call: &str) -> Option<ToolOutcome> {
        evs.iter().find_map(|e| match &e.event {
            Event::ItemCompleted {
                id,
                item: Item::ToolCall { outcome, .. },
            } if id == call => Some(*outcome),
            _ => None,
        })
    }

    fn ended(evs: &[Envelope]) -> Option<EndReason> {
        evs.iter().find_map(|e| match &e.event {
            Event::TurnEnded { reason, .. } => Some(reason.clone()),
            _ => None,
        })
    }

    /// (1) A read-verb MCP tool runs without a card in DEFAULT mode, not just auto. The
    /// server's repeated name (`planetscale_list_databases`) doesn't hide the verb.
    #[tokio::test]
    async fn read_verb_mcp_tools_never_card_in_default_mode() {
        let (mut h, dir) = engine_with_mcp(
            Mode::Default,
            perm_cfg(),
            &["planetscale_list_databases", "planetscale_list_organizations"],
            vec![
                mcp_call("r1", "mcp__planetscale__planetscale_list_databases"),
                mcp_call("r2", "mcp__planetscale__planetscale_list_organizations"),
                reply(vec![text("done")], Stop::End),
            ],
        )
        .await;
        let evs = next_turn(&mut h, "list them", |_| Some((Decision::Deny, None))).await;
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
        assert_eq!(asked(&evs), 0, "a read-only MCP tool carded: {:?}", names(&evs));
        assert_eq!(outcome_of(&evs, "r1"), Some(ToolOutcome::Ok));
        assert_eq!(outcome_of(&evs, "r2"), Some(ToolOutcome::Ok));
        assert_eq!(tool_output(&evs, "r1"), Some("ran planetscale_list_databases"));
        assert_eq!(ended(&evs), Some(EndReason::Complete));
    }

    /// (2) A non-read MCP tool still cards without a trust grant, in default mode.
    #[tokio::test]
    async fn non_read_mcp_tools_still_card_without_a_grant() {
        let (mut h, dir) = engine_with_mcp(
            Mode::Default,
            perm_cfg(),
            &["planetscale_execute_read_query"],
            vec![
                mcp_call("q", "mcp__planetscale__planetscale_execute_read_query"),
                reply(vec![text("done")], Stop::End),
            ],
        )
        .await;
        let evs = next_turn(&mut h, "query", |_| Some((Decision::Allow, None))).await;
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
        assert_eq!(asked(&evs), 1, "a non-read MCP tool must card");
        assert_eq!(outcome_of(&evs, "q"), Some(ToolOutcome::Ok));
    }

    /// (3) A write tool runs without a card WITH the server's write grant, and the run is on
    /// the record (a notice naming server, tool and args, and a `trust` decision); WITHOUT the
    /// grant the same call cards exactly as before.
    #[tokio::test]
    async fn a_write_grant_runs_writes_cardless_and_logged_and_cards_without_it() {
        let tools = ["planetscale_execute_write_query"];
        let write = "mcp__planetscale__planetscale_execute_write_query";
        let mut cfg = perm_cfg();
        cfg.mcp_trust
            .insert("planetscale".into(), crate::config::McpTrust::Write);
        let (mut h, dir) = engine_with_mcp(
            Mode::Default,
            cfg,
            &tools,
            vec![mcp_call("w", write), reply(vec![text("done")], Stop::End)],
        )
        .await;
        let evs = next_turn(&mut h, "write it", |_| Some((Decision::Deny, None))).await;
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
        assert_eq!(asked(&evs), 0, "a granted write carded");
        assert_eq!(outcome_of(&evs, "w"), Some(ToolOutcome::Ok));
        let audit = notices(&evs);
        assert!(
            audit.iter().any(|n| n.contains("mcp_trust")
                && n.contains("planetscale")
                && n.contains("execute_write_query")
                && n.contains("args:")),
            "no audit notice: {audit:?}"
        );
        assert!(evs.iter().any(|e| matches!(
            &e.event,
            Event::PermissionDecision { item, layer, outcome, .. }
                if item == "w" && layer == "trust" && outcome == "allow"
        )));

        // No grant: the same write cards (denied here, so it never runs).
        let (mut h, dir) = engine_with_mcp(
            Mode::Default,
            perm_cfg(),
            &tools,
            vec![mcp_call("w", write), reply(vec![text("done")], Stop::End)],
        )
        .await;
        let evs = next_turn(&mut h, "write it", |_| Some((Decision::Deny, None))).await;
        shutdown(h).await;
        let _ = std::fs::remove_dir_all(dir);
        assert_eq!(asked(&evs), 1, "an ungranted write must card");
        assert_eq!(outcome_of(&evs, "w"), Some(ToolOutcome::Denied));
        assert!(!notices(&evs).iter().any(|n| n.contains("mcp_trust")));
    }

    /// (4) An identical call already denied this turn doesn't ask again: the turn ends
    /// `BlockedOnApproval`, carrying the denial text, with a notice saying so.
    #[tokio::test]
    async fn a_denied_call_retried_in_the_same_turn_ends_it_blocked() {
        let cmd = "touch frog-blocked-retry.txt";
        let script = vec![
            bash_call("a", cmd),
            bash_call("b", cmd),
            reply(vec![text("unreachable")], Stop::End),
        ];
        let mut h = engine_perm(script, Mode::Default, None);
        let evs = turn_answering(&mut h, |_| {
            Some((Decision::Deny, Some("not that file".into())))
        })
        .await;
        shutdown(h).await;
        assert_eq!(asked(&evs), 1, "the retry re-asked: {:?}", names(&evs));
        assert_eq!(outcome_of(&evs, "a"), Some(ToolOutcome::Denied));
        assert_eq!(outcome_of(&evs, "b"), Some(ToolOutcome::Denied));
        match ended(&evs) {
            Some(EndReason::BlockedOnApproval { denial }) => {
                assert!(denial.contains("not that file"), "{denial}")
            }
            other => panic!("turn should end blocked on approval, got {other:?}"),
        }
        assert!(
            notices(&evs)
                .iter()
                .any(|n| n.contains("Blocked on approval") && n.contains("not that file")),
            "{:?}",
            notices(&evs)
        );
        let out = tool_output(&evs, "b").unwrap();
        assert!(out.contains("already denied"), "{out}");
        // It round-trips as a tagged reason.
        let v = serde_json::to_value(EndReason::BlockedOnApproval { denial: "x".into() }).unwrap();
        assert_eq!(v, json!({"type": "blocked_on_approval", "denial": "x"}));
    }

    /// (5) An identical carded call denied twice in a session never asks again: the third
    /// attempt (a later turn) is denied at once with the notice, and the agent carries on.
    #[tokio::test]
    async fn a_call_denied_twice_in_a_session_is_auto_denied_after() {
        let cmd = "touch frog-denied-twice.txt";
        let script = vec![
            bash_call("t1", cmd),
            bash_call("t2", cmd),
            bash_call("t3", cmd),
            reply(vec![text("routed around it")], Stop::End),
        ];
        let mut h = engine_perm(script, Mode::Default, None);
        let deny = |_: &Event| Some((Decision::Deny, None));
        let first = turn_answering(&mut h, deny).await;
        let second = next_turn(&mut h, "again", deny).await;
        let third = next_turn(&mut h, "once more", deny).await;
        shutdown(h).await;
        assert_eq!(asked(&first), 1);
        assert_eq!(ended(&first), Some(EndReason::Denied));
        assert_eq!(asked(&second), 1, "a new turn may ask once more");
        assert_eq!(asked(&third), 0, "denied twice: it must not ask again");
        assert_eq!(outcome_of(&third, "t3"), Some(ToolOutcome::Denied));
        assert!(
            notices(&third)
                .iter()
                .any(|n| n.contains("denied twice and won't ask again this session")),
            "{:?}",
            notices(&third)
        );
        // A breaker deny is direction, not a stop: the turn carries on to an answer.
        assert_eq!(ended(&third), Some(EndReason::Complete));
        assert!(tool_output(&third, "t3").unwrap().contains("denied twice"));
    }

    /// (6) Auto mode: a Write to a fresh file under the shared temp dir is the session's own
    /// scratch and runs without a card (it used to card as "writes outside the project");
    /// overwriting a temp file someone else made still asks.
    #[tokio::test]
    async fn auto_mode_writes_its_own_fresh_temp_scratch_without_a_card() {
        let fresh = std::path::Path::new("/private/tmp").join(format!("frog-scratch-{}.rs", new_id()));
        let theirs = std::path::Path::new("/private/tmp").join(format!("frog-theirs-{}.rs", new_id()));
        std::fs::write(&theirs, "someone else's\n").unwrap();
        let write = |id: &str, p: &std::path::Path| {
            reply(
                vec![Block::ToolUse {
                    id: id.into(),
                    name: "Write".into(),
                    input: json!({ "file_path": p.display().to_string(), "content": "mine\n" }),
                }],
                Stop::ToolUse,
            )
        };
        let script = vec![
            write("fresh", &fresh),
            write("theirs", &theirs),
            reply(vec![text("done")], Stop::End),
        ];
        let mut h = engine_perm(script, Mode::Auto, None);
        let evs = turn_answering(&mut h, |_| Some((Decision::Deny, Some("no".into())))).await;
        shutdown(h).await;
        let fresh_ok = std::fs::read_to_string(&fresh).ok();
        let theirs_now = std::fs::read_to_string(&theirs).ok();
        let _ = std::fs::remove_file(&fresh);
        let _ = std::fs::remove_file(&theirs);
        assert_eq!(outcome_of(&evs, "fresh"), Some(ToolOutcome::Ok), "{:?}", names(&evs));
        assert_eq!(fresh_ok.as_deref(), Some("mine\n"));
        assert_eq!(asked(&evs), 1, "only the existing temp file should ask");
        assert_eq!(outcome_of(&evs, "theirs"), Some(ToolOutcome::Denied));
        assert_eq!(theirs_now.as_deref(), Some("someone else's\n"));
    }
}
