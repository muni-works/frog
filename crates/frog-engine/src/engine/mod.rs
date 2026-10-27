//! The agent loop. Runs as a background task; clients drive it with [`Op`]s and receive
//! [`Envelope`]s. See `protocol.rs` for the event lifecycle.

use crate::config::{Config, Profile, ProviderKind, Thinking, ToolMode};
use crate::context::{self, Estimator};
use crate::harness::{self, Tier};
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
    std::env::var("FROG_MAX_STEPS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(u32::MAX)
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
                Op::DismissWakes => router.bg.dismiss(),
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
                    router.journal.emit(Event::Notice {
                        level: Level::Info,
                        message: msg.to_string(),
                    });
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
        // Restore MCP tools that were loaded in a previous session
        if !agent.loaded_tools.is_empty() {
            agent.mcp.restore_loaded(&agent.loaded_tools);
            agent.loaded_tools.clear();
        }
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
            let op = if let Some(op) = held.take() {
                Some(op)
            } else {
                tokio::select! {
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
                }
            };
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
            if held.is_none() && shared.bg.has_notices() && !shared.wake_hold.load(Ordering::SeqCst)
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
    /// Tool-call mode, tier and capabilities for the current model, and what it fell back to.
    harness: harness::Harness,
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
    /// MCP tools that were loaded via `McpTools` in a previous session, to be restored on resume.
    loaded_tools: Vec<String>,
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
        let harness = harness::Harness::for_profile(&o.profile);
        let system = format!(
            "{}{}",
            prompt::system_prompt(&o.cwd, &o.cfg, &o.profile.model),
            harness::guidance(harness.tier)
        );
        // Panes open when the session was last saved, to close in the log (their shells died
        // with that process) so a resumed client doesn't expect them.
        let mut stale_panes: Vec<String> = Vec::new();
        // Background ids the log used, and pieces it says were still running (the engine
        // that ran them died with them): (id, kind, label).
        let mut bg_ids: Vec<String> = Vec::new();
        let mut lost_bg: Vec<(String, String, String)> = Vec::new();
        let mut resumed_map = None;
        // The mode the session last ran in (its last `mode_changed`): a resumed engine keeps
        // it, rather than silently reverting to whatever the flags say — the picker and the
        // engine must agree on the effective mode.
        let mut resumed_mode = None;
        // MCP tools that were loaded via `McpTools` in a previous session, to be restored on resume.
        let mut loaded_tools: Vec<String> = Vec::new();
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
                loaded_tools = l.loaded;
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
                        Event::BackgroundStarted {
                            id, kind, label, ..
                        } => {
                            bg_ids.push(id.clone());
                            lost_bg.push((id.clone(), kind.clone(), label.clone()));
                        }
                        Event::BackgroundDone { id, .. } => lost_bg.retain(|(b, ..)| b != id),
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
        shared.bg.seed_ids(bg_ids.iter().map(String::as_str));
        shared.bg.lost_on_restart(&lost_bg);
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
            harness,
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
            loaded_tools,
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
            tool_mode: self.harness.tool_mode,
            tier: self.harness.tier,
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
        if self.harness.tool_mode == ToolMode::Text && self.profile.tool_mode != ToolMode::Text {
            out.push(Degraded {
                kind: DegradedKind::TextTools,
                what: "text tool calls".into(),
                why: self.text_mode_why(),
            });
        }
        let norm = |m: &str| crate::providers::normalize(m);
        if !self.intended_model.is_empty() && norm(&self.intended_model) != norm(&self.profile_name)
        {
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
        self.harness
            .text_why
            .clone()
            .unwrap_or_else(|| "its capability probe found native tool calls not working".into())
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
            self.emit(Event::ChapterTitled {
                turn: closed.start,
                title,
            });
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
            journal.emit(Event::ChapterTitled {
                turn: closed.start,
                title,
            });
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
                    format!(
                        "turn ended: blocked on an approval that was already denied ({denial})"
                    ),
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
            | Op::DismissWakes
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
        let mut budget = if self.harness.tier == Tier::Strong {
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
        self.turn_with(&notices.join("\n\n"), Vec::new(), more)
            .await
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
                    if e.downcast_ref::<HttpError>()
                        .is_some_and(HttpError::context_overflow)
                    {
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
                                anyhow::bail!(
                                    "compaction failed; the history can't fit the context window"
                                );
                            }
                            continue;
                        }
                        self.emit(Event::CompactionFailed {
                            detail: format!("{e:#}"),
                        });
                        anyhow::bail!(
                            "the request still exceeds the model's context window after compaction"
                        );
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
        self.harness.apply(&self.profile);
        let base = if self.chat {
            prompt::chat_prompt(&self.cfg, &self.profile.model)
        } else {
            prompt::system_prompt(&self.root, &self.cfg, &self.profile.model)
        };
        let rules = crate::rules::prompt_section(
            &self.rules,
            crate::rules::prompt_budget(self.harness.tier),
        );
        self.system = format!("{base}{rules}{}", harness::guidance(self.harness.tier));
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
        let (index, omitted) = crate::memory::index(&self.notes, self.harness.tier, self.window);
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
        let budget = match crate::repomap::budget(self.harness.tier) {
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
        crate::rules::block(&due, &rel, crate::rules::inject_budget(self.harness.tier))
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
            let reply = crate::recall::command(&sources, query, self.harness.tier);
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
        let can_switch = match &self.harness.caps {
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
        if self.harness.reprobed
            || !harness::reprobe_due(&self.profile, self.harness.caps.as_ref(), now_ms())
        {
            return;
        }
        self.harness.reprobed = true;
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
                self.harness.caps = Some(caps);
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
        self.harness.recovers_text_calls(&self.profile)
    }

    /// The model botched the tool-call format (text calls under native, invalid JSON args, or
    /// JSON mode not honored). Under `auto`, two strikes moves to text mode for this session
    /// only: the finding is never written to the capability cache (see `harness::save`), and a
    /// model whose native tools are known to work never moves.
    fn note_format_failure(&mut self, why: &str) {
        let Some(from) = self.harness.note_format_failure(&self.profile, why) else {
            return;
        };
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
        if self.profile.tool_mode != ToolMode::Auto || self.harness.tool_mode != ToolMode::Text {
            return;
        }
        let when = self
            .harness
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
        // Mark that MCP servers are configured, so McpTools is offered even before they connect
        self.mcp.expect_servers();
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
            specs.push(crate::present::spec(self.harness.tier == Tier::Weak));
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
            return crate::recall::run(&sources, input, self.harness.tier);
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
            return crate::present::run(input, &self.ctx.root, self.harness.tier == Tier::Weak);
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
            let out = hub.call(id, name, input).await;
            // Record loaded tools if McpTools was called
            if name == crate::mcp::SEARCH_TOOL {
                if out.is_ok() {
                    let loaded = hub.loaded();
                    if !loaded.is_empty() {
                        self.record(crate::session::Record::LoadedTools { tools: loaded });
                    }
                }
            }
            return out;
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
                self.pending_gists.push((item_id, command, out_head));
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
        match self.harness.tool_mode {
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
        self.harness.caps = (!harness::native_known(&self.profile))
            .then(|| harness::cached(&self.profile))
            .flatten();
        self.harness.mode_failures = 0;
        self.harness.text_why = None;
        self.harness.reprobed = false;
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
        let json_mode = self.harness.tool_mode == ToolMode::Json;
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
            let (cwd, weak) = (self.ctx.root.clone(), self.harness.tier == Tier::Weak);
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
                        format!(
                            "{e:#} — retrying in {}s ({attempt}/{budget})",
                            wait.as_secs()
                        ),
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
        if kind == Kind::Net
            && (name == "WebSearch"
                || crate::tools::web::public_host(input["url"].as_str().unwrap_or("")))
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
        if let Some(server) = crate::auto::mcp_write(name).filter(|s| self.cfg.mcp_write_trusted(s))
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
            self.decision(
                item,
                "trust",
                "allow",
                &format!("write grant for {server}"),
                0,
            );
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
        if name == "Screenshot" && self.mode == Mode::Auto && crate::auto::local_capture(input) {
            self.decision(
                item,
                "rule",
                "allow",
                "captures only the session's own work",
                0,
            );
            return Decision::Allow;
        }
        // A path prefix the user allowed for this program earlier this session.
        if name == "Bash"
            && !crate::shell::touches_credentials(cmd)
            && crate::approval::prefix_allows(cmd, &self.ctx.cwd, &self.prefix_allow)
        {
            self.decision(
                item,
                "session",
                "allow",
                "under a path prefix allowed this session",
                0,
            );
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
            self.decision(
                item,
                "provenance",
                "allow",
                "touches only the project or its own scratch",
                0,
            );
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
                self.decision(
                    item,
                    "provenance",
                    "allow",
                    "writes only its own scratch",
                    0,
                );
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
            self.decision(
                item,
                "provenance",
                "allow",
                "writes only its own scratch",
                0,
            );
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
                if self.session_allow.contains(&key) {
                    "session"
                } else {
                    "rule"
                },
                "allow",
                if self.session_allow.contains(&key) {
                    "allowed earlier this session"
                } else {
                    "mode allows it"
                },
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
                    self.decision(
                        item,
                        "classifier",
                        "allow",
                        "the classifier approved it",
                        took,
                    );
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
                    if mins >= 1 {
                        format!("{mins} min")
                    } else {
                        format!("{timeout_secs} s")
                    }
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
            self.decision(
                item,
                "repeat",
                "deny",
                &format!("already denied this turn: {denial}"),
                0,
            );
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
            Some(crate::auto::Verdict::Ask(reason)) => {
                Err(format!("the classifier said: {reason}"))
            }
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
                Err(e) => {
                    return Err(
                        self.classifier_failed(fallback, format!("it couldn't start ({e:#})"))
                    );
                }
            }
        }
        let slot = if fallback {
            &self.classifier_fallback
        } else {
            &self.classifier
        };
        let model = slot
            .as_ref()
            .map(|c| c.profile_name.clone())
            .unwrap_or_default();
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
                format!(
                    "auto mode's classifier ({primary}) is down ({why}); using {using}: {rest}."
                ),
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
        let keep_prefix = matches!(self.harness.tool_mode, ToolMode::Native | ToolMode::Auto);
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
        let compacted_label = format!(
            "{}. Work continues from this alone.)",
            context::COMPACTION_LABEL
        );
        // Timers and monitors outlive compaction (the Registry is untouched), but the calls
        // that set them are summarized away: keep what's pending, or the model re-arms them.
        let pending = self.shared.bg.pending_block();
        let pending = if pending.is_empty() {
            pending
        } else {
            format!("\n\n{pending}")
        };
        let mut compacted = Message::user(format!(
            "{compacted_label}\n\nSummary:\n{summary}\n\n{record}{pending}"
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
        if let Some(closed) = self
            .chapters
            .compacted(self.active_turn.unwrap_or(self.turn))
        {
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
mod tests;
