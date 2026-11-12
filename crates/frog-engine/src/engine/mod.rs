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
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

mod call;
mod compact;
mod dispatch;
mod permit;
mod project;
mod turn;
mod window;

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
/// Calls to tools this conversation doesn't have, in one turn, before the turn stops (a
/// coding model in a chat with no folder reaches for Write, then Bash, then …).
const LOOP_UNAVAILABLE: u32 = 3;
/// Distinct calls a re-plan message lists.
const LOOP_RECENT: usize = 8;

/// What a call to a tool that isn't offered gets back: in a chat (no folder), where the file and
/// shell tools a coding model reaches for don't exist, a way forward rather than a refusal.
fn unavailable_tool(name: &str, chat: bool) -> (String, &'static str) {
    if chat {
        (
            format!(
                "Not run: there's no `{name}` tool here. This conversation has no folder, so there are no files to \
write and nowhere to run commands. Answer in chat instead (code goes in a fenced code block), or, if the user \
needs it on disk, ask them to pick a folder (offer {}). Don't call file or shell tools again.",
                crate::folder::TOOL
            ),
            "no folder: answer in chat",
        )
    } else {
        (
            format!(
                "There's no `{name}` tool in this conversation. Use only the tools you were given."
            ),
            "not an available tool",
        )
    }
}

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
    /// Calls this turn to tools that weren't offered.
    unavailable: u32,
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
const MAX_CONTINUES: u32 = 2;
/// Output budget requested from hosted APIs that don't set their own: well within what current
/// frontier and open models accept, and far above the defaults that cut thinking short.
const CLOUD_MAX_OUTPUT: u32 = 32_768;
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

/// The hosts a command opens a remote shell or copy to (`ssh`, `scp`, `rsync`,
/// `mosh`): `user@host` stripped to the host, `host:path` to the host.
fn remote_hosts(cmd: &str) -> Vec<String> {
    let segments = crate::shell::segments(cmd).unwrap_or_else(|| vec![cmd.to_string()]);
    let mut out = Vec::new();
    for seg in segments {
        let ws = crate::approval::words(&seg);
        let Some(prog) = ws.first() else { continue };
        let prog = prog.rsplit('/').next().unwrap_or(prog);
        if !matches!(prog, "ssh" | "scp" | "rsync" | "mosh" | "sftp") {
            continue;
        }
        let mut skip = false;
        for w in &ws[1..] {
            if skip {
                skip = false;
                continue;
            }
            if w.starts_with('-') {
                // ssh options that take a value.
                skip = prog == "ssh" && matches!(w.as_str(), "-p" | "-i" | "-l" | "-o" | "-F" | "-J" | "-L" | "-R" | "-D");
                continue;
            }
            let host = w.split_once('@').map_or(w.as_str(), |(_, h)| h);
            let remote = prog == "ssh" || prog == "mosh" || prog == "sftp" || host.contains(':') || w.contains('@');
            if !remote {
                continue;
            }
            let host = host.split(':').next().unwrap_or(host);
            if !host.is_empty() && !out.iter().any(|h: &String| h == host) {
                out.push(host.to_string());
            }
            // ssh's first operand is the host; the rest is the remote command.
            if prog == "ssh" || prog == "mosh" {
                break;
            }
        }
    }
    out
}

/// One tool call's identity for the repeat-denial checks: its tool and its exact arguments.
fn call_hash(name: &str, input: &Value) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    name.hash(&mut h);
    input.to_string().hash(&mut h);
    h.finish()
}

/// How the chief route ended for a still-flagged call (docs/design/delegation.md).
enum Chief {
    /// The chief answered: run or deny, no card.
    Decided(Decision),
    /// The chief was asked but couldn't decide (no broker, error, timeout, unreadable).
    Fallback,
    /// No chief route: no chief configured, or the class isn't granted.
    NoRoute,
}

/// How a batch of tool calls ended.
#[derive(PartialEq)]
enum Batch {
    Continue,
    Denied,
    Looping,
    /// The model kept sleeping on a background wait: the turn ends as complete, and the
    /// job's wake starts the next.
    Waiting,
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
    /// Child sessions this engine owns (when no client hosts sessions; see `kids`).
    pub(crate) kids: Arc<crate::kids::Kids>,
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
    /// Deliveries sitting in the work queue right now: the non-destructive twin of
    /// `work_rx`'s depth, since its `try_recv` consumes and a running turn must be able to
    /// look without stealing. Incremented where the router pushes a `Deliver`, taken down
    /// wherever the work loop pops one (the boundary arm and the batch drain), and zeroed
    /// with the queue by `Op::ClearInbox` — the voided ones never run, so they stop
    /// counting. Saturating down: a clear that races a pop must not go negative.
    inbox_waiting: AtomicUsize,
    /// The mode the client asked for ([`Op::SetMode`]), as a [`Mode`] discriminant. The router
    /// stores it immediately (a safety setting, not conversation state), the permit path picks
    /// it up per decision, and the agent's `handle` reconciles its own copy and logs
    /// `ModeChanged` — so a turn that never reaches a boundary still obeys the change.
    mode: AtomicU8,
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
    /// The log couldn't be created for this session (the id's file is unwritable, say), and
    /// the one notice saying so has been sent. Appends stay silent no-ops rather than a
    /// warning per event. Cleared when the session switches (a new conversation or `Op::Clear`).
    dead: AtomicBool,
    /// For the header: cwd and model name.
    header: Mutex<(PathBuf, String)>,
    /// For the header: an agent started this session.
    worker: std::sync::atomic::AtomicBool,
    /// For the header: the session that started this one.
    parent: Mutex<Option<String>>,
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
            dead: AtomicBool::new(false),
            header: Mutex::new((PathBuf::new(), String::new())),
            worker: Default::default(),
            parent: Mutex::new(None),
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
        self.dead.store(false, Ordering::SeqCst);
    }

    fn has_log(&self) -> bool {
        self.log.lock().unwrap().is_some()
    }

    /// Append a record to the session log, creating the log on first use. An error means the
    /// session can't be saved, and that the caller should relay the error to the user once.
    fn record(&self, rec: Record) -> std::result::Result<(), String> {
        let Some(dir) = &self.store else {
            return Ok(());
        };
        let mut log = self.log.lock().unwrap();
        // The log already failed for this session: nothing more to say, and nothing to retry —
        // the error was a dead file, not a transient one.
        if log.is_none() && self.dead.load(Ordering::SeqCst) {
            return Ok(());
        }
        if log.is_none() {
            let (cwd, model) = self.header.lock().unwrap().clone();
            let header = Header {
                version: session::VERSION,
                id: self.session(),
                cwd,
                model,
                created: now_ms(),
                forked_from: None,
                worker: self.worker.load(Ordering::Relaxed),
                parent: self.parent.lock().unwrap().clone(),
            };
            match Log::create(dir, header) {
                Ok(l) => *log = Some(l),
                Err(e) => {
                    // Once per session, never per event — the turn endures without a log.
                    self.dead.store(true, Ordering::SeqCst);
                    return Err(format!(
                        "session log unavailable, running without persistence: {e:#}"
                    ));
                }
            }
        }
        if let Some(Err(e)) = log.as_mut().map(|l| l.append(&rec)) {
            *log = None;
            self.dead.store(true, Ordering::SeqCst);
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

/// Start the engine on a model its gateway currently lists (docs/design/model-policy.md):
/// `cloud/*` and this machine's models always start, a hosted BYOK model only while its
/// gateway's `/v1/models` (cached for a minute) has it. Checked here, once, at spawn — never
/// per call. Clients that can await should use this; [`spawn`] is the unchecked form.
pub async fn spawn_checked(opts: Options) -> Result<Handle> {
    crate::model_policy::check_spawn(&opts.profile_name, &opts.profile).await?;
    spawn(opts)
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
        kids: Default::default(),
        ready: Default::default(),
        working: Default::default(),
        bg: {
            let j = journal.clone();
            crate::background::Registry::new(move |e| j.emit(e))
        },
        draining: Default::default(),
        inbox_sent: Default::default(),
        inbox_void: Default::default(),
        inbox_waiting: Default::default(),
        mode: AtomicU8::new(opts.mode as u8),
        wake_hold: Default::default(),
        journal,
        panes,
        irc: crate::irc::slot(),
    });
    shared.bg.set_wake(&work_tx);
    shared.kids.set_inbox(&op_tx);
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
    // The atomic starts from the flag, but a resumed engine's mode is its log's last one:
    // seed it from the agent, or the first permit would "correct" the session back to the
    // flag (downgrading a session that resumed in yolo).
    shared.mode.store(agent.mode as u8, Ordering::SeqCst);
    if let Some(mut lock) = worktree_lock {
        lock.set_owner(&agent.conv.session_id);
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
        (Some(dir), true) => Some((dir.clone(), agent.conv.session_id.clone())),
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
                    // The queued deliveries are voided now: they never run, so they stop
                    // counting (and anything sent after the clear counts from zero).
                    router.inbox_waiting.store(0, Ordering::Relaxed);
                }
                Op::DismissWakes => router.bg.dismiss(),
                // A permission mode is a safety setting, not conversation state: it applies at
                // the next permission decision, not the next turn boundary. Stored here, where
                // the permit path reads it (see `Shared::mode`); the agent reconciles its copy
                // and logs `ModeChanged` at its next chance.
                Op::SetMode { mode } => {
                    router.mode.store(mode as u8, Ordering::SeqCst);
                    let _ = work_tx.send(Op::SetMode { mode });
                }
                op @ Op::Deliver { .. } => {
                    router.inbox_sent.fetch_add(1, Ordering::SeqCst);
                    if work_tx.send(op).is_err() {
                        break;
                    }
                    // Queued behind whatever turn is running: the model sees this count at
                    // its next step (see `turn`), before the delivery itself arrives.
                    router.inbox_waiting.fetch_add(1, Ordering::Relaxed);
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
        let unknown = agent.cfg.delegation.unknown_classes().join(", ");
        if !unknown.is_empty() {
            agent.notice(
                Level::Warn,
                format!("[delegation] chief_classes: ignoring unknown class(es) {unknown}"),
            );
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
                    // Off the queue: the waiting count goes down, voided or not (a clear
                    // already zeroed it; saturating keeps the doomed ones from going
                    // negative).
                    if matches!(op, Op::Deliver { .. }) {
                        shared
                            .inbox_waiting
                            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| {
                                Some(n.saturating_sub(1))
                            })
                            .ok();
                    }
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
                                shared
                                    .inbox_waiting
                                    .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| {
                                        Some(n.saturating_sub(1))
                                    })
                                    .ok();
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
                } else if let Some(b) = e.downcast_ref::<crate::engine::call::BillingRefused>() {
                    // A hard billing refusal ends the turn with the typed reason: the client
                    // shows "out of credit · add credit", not a provider error.
                    EndReason::BillingLimit {
                        window: b.window.clone(),
                        reason: b.reason.clone(),
                        balance_micro: b.balance_micro,
                    }
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
        shared.kids.shutdown();
        agent.mcp.shutdown();
        shared.mcp.lock().unwrap().take();
        shared.panes.shutdown();
        agent.finish_compiled_memory().await;
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
    // A billing refusal the billing arm didn't take (an op outside a turn, say): the
    // provider's clean message, never its raw JSON dump.
    if let Some(b) = e.downcast_ref::<crate::engine::call::BillingRefused>() {
        return EngineError::Billing {
            status: 402,
            message: b.reason.clone(),
        };
    }
    if let Some(h) = e.downcast_ref::<HttpError>() {
        // The one billing case classify can still see is a refusal this path never promised
        // to admit (a scripted provider's 402 outside a turn): typed as billing, with the
        // provider's own words, not its JSON envelope.
        if h.is_billing() {
            return EngineError::Billing {
                status: h.status,
                message: h.summary(),
            };
        }
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
    // The node pool's one line: nowhere to place the call, or the last node with the model
    // stopped answering (docs/node-protocol.md §7).
    if e.is::<crate::provider::node::NodeFailed>() || e.is::<crate::provider::node::NoPlacement>() {
        return EngineError::Connection {
            message: e.to_string(),
        };
    }
    if let Some(c) = e.downcast_ref::<ConfigError>() {
        return EngineError::Config {
            message: c.0.clone(),
        };
    }
    // The same transport classes retryable() accepts, plus a plain connect failure (which the
    // retry arm handles through cloud_fallback): all of them are the network, not frog.
    let network = e
        .chain()
        .filter_map(|c| c.downcast_ref::<reqwest::Error>())
        .any(|r| {
            r.is_connect() || r.is_timeout() || r.is_request() || r.is_body() || r.is_decode()
        });
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
    // A body-stream failure (a reset while reading the reply, after the headers arrived) is the
    // same class as a truncated stream: the partial is discarded by the retry arm and the step
    // re-runs from scratch, so it's worth another try. `bytes_stream` wraps a body read error in
    // reqwest's decode kind (is_decode), a reader with a timeout in the body kind (is_body) —
    // both are "the body stream broke", and neither is a clean end or a bad request.
    e.chain()
        .filter_map(|c| c.downcast_ref::<reqwest::Error>())
        .any(|r| r.is_timeout() || r.is_body() || r.is_decode() || (r.is_request() && !r.is_connect()))
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

/// The state of one conversation. `/clear` replaces it whole (see `Conversation::fresh`),
/// so nothing from the old conversation can leak into the new one.
#[derive(Default)]
struct Conversation {
    messages: Vec<Message>,
    usage: Usage,
    session_id: String,
    turn: u64,
    /// Everything the user has typed this session, kept verbatim through compaction.
    inputs: Vec<String>,
    skills_loaded: HashSet<String>,
    rules_seen: HashSet<PathBuf>,
    /// Files edited this session, relative to the root, for ranking the map.
    edited: Vec<String>,
    /// The session has a title (from the model's `SetTitle`, a client, or a resumed log), so
    /// the headless fallback shouldn't add one.
    titled: bool,
    /// This turn's `Next` suggestion, emitted when the turn completes (see `next`).
    next: Option<crate::next::Next>,
    /// Context from `Op::Shell`, attached to the next message.
    pending: Vec<String>,
    /// The open chapter, followed so the turn that closes it can have it titled (see
    /// `chapter`).
    chapters: crate::chapter::Tracker,
}

impl Conversation {
    /// A new, empty conversation with a new session id.
    fn fresh() -> Self {
        Conversation {
            session_id: session::new_id(),
            ..Default::default()
        }
    }
}

struct Agent {
    /// Everything that belongs to one conversation; `/clear` starts a fresh one.
    conv: Conversation,
    cfg: Config,
    profile_name: String,
    profile: Profile,
    provider: Provider,
    ctx: Ctx,
    mode: Mode,
    /// The mode the session log has on record (its last `mode_changed`; none means Default).
    /// Whenever the effective mode differs, the next chance to write logs it (see
    /// `log_mode`), so a restarted engine resumes in it and no change is ever silent.
    mode_logged: Option<Mode>,
    /// PRs bound to the session (`Op::BindPr`, or opened from its branch), from its log.
    prs: Vec<crate::prs::PrBinding>,
    can_ask: bool,
    rich: bool,
    subagent: bool,
    chat: bool,
    store: Option<PathBuf>,
    last_call: Duration,
    /// The model call in flight, if any: when this attempt started, which attempt it is, and
    /// the provider's `retry-after` when a busy answer gave one. `Status.waiting` reads it, so
    /// a session waiting on a slow or dead model says so instead of looking merely busy. A
    /// `Mutex` because the call path holds `&self`.
    call_started: Mutex<Option<(Instant, u32, Option<u64>)>>,
    active_turn: Option<u64>,
    /// The context window actually in effect (config, bounded by what the server reports).
    window: u64,
    est: Estimator,
    /// Tool-call mode, tier and capabilities for the current model, and what it fell back to.
    harness: harness::Harness,
    /// A Tang sidecar loads its weights on its first completion request. Keep that visible until
    /// the first response arrives, then regular request activity takes over.
    model_ready: bool,
    /// Model calls in a row this turn with thinking switched off.
    quiet: u32,
    /// The last note the turn loop made about the waiting inbox: (count, step). `None` at
    /// a turn start, so each turn announces fresh; kept so the note is rate-limited to
    /// changed counts, else one per 5 steps (see `turn`).
    inbox_told: Option<(usize, u32)>,
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
    /// The user's memory notes (none for subagents or in-memory engines), loaded when the
    /// session starts and after `/remember` or `/forget`, so the system prompt stays put.
    memory: Option<crate::memory::Store>,
    /// Compiled memory, while this model's server keeps it (see `compiled_memory`).
    compiled: Option<crate::compiled_memory::Session>,
    notes: Vec<crate::memory::Note>,
    /// Notes that didn't fit the current model's index.
    notes_omitted: usize,
    /// Rule files for this project, and the scoped ones already shown this session.
    rules: Vec<crate::rules::Rule>,
    /// The ranked repo map in the system prompt (small and mid-size models only), rebuilt
    /// between turns when files change.
    repo_map: crate::repomap::Map,
    map_build_tx: std::sync::mpsc::Sender<(crate::repomap::Map, bool)>,
    map_build_rx: Mutex<std::sync::mpsc::Receiver<(crate::repomap::Map, bool)>>,
    map_building: bool,
    /// Whether the session log holds the current `repo_map`.
    map_logged: bool,
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
    /// Today's delegation roll-up (docs/design/delegation.md): what the second
    /// pass allowed, what the chief decided, what carded the user. Date-keyed,
    /// midnight rollover; advisory (lost on crash, next session starts at 0).
    digest: crate::digest::Digest,
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
    /// This turn's finished tool calls awaiting a gist, flushed in one side-model call when
    /// the turn ends (see `gist`): item id, tool, argument, outcome, output head.
    pending_gists: Vec<(String, String, String, ToolOutcome, String)>,
    /// Chapter titles written this session, by content hash: the same chapter never asks
    /// twice. Shared with the title task.
    chapter_titles: Arc<Mutex<HashMap<u64, String>>>,
    shared: Arc<Shared>,
}

impl Agent {
    fn new(mut o: Options, provider: Provider, shared: Arc<Shared>) -> Result<Self> {
        // Cached or shipped capability profiles are useful in both persisted and in-memory engines.
        let harness = harness::Harness::for_profile(&o.profile);
        // The session's own facts last, so the shared head stays one prefix across sessions.
        let system = format!(
            "{}{}{}",
            prompt::system_head(&o.cwd, &o.cfg),
            harness::guidance(harness.tier),
            prompt::environment(&o.cwd, &o.profile.model)
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
        let mut resumed_prs = Vec::new();
        // MCP tools that were loaded via `McpTools` in a previous session, to be restored on resume.
        let mut loaded_tools: Vec<String> = Vec::new();
        let mut resumed_titled = false;
        let mut resumed_model: Option<String> = None;
        // An agent started it: the resume keeps its worker egress policy whatever the flags.
        let mut resumed_worker = false;
        let mut resumed_chapters = crate::chapter::Tracker::default();
        let (session_id, messages, seq, turn, log, inputs, unfinished) = match (&o.resume, &o.store)
        {
            (Some(id), Some(dir)) => {
                let l = session::load(dir, id).map_err(|e| ConfigError(format!("{e:#}")))?;
                resumed_worker = l.header.worker;
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
                        Event::Prs { prs } => resumed_prs = prs.clone(),
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
        o.cfg.worker |= resumed_worker;
        shared.journal.worker.store(o.cfg.worker, Ordering::Relaxed);
        *shared.journal.parent.lock().unwrap() = o.cfg.parent_session.clone();
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
        // A subagent shares its parent's; a chat runs no commands.
        let egress = match (&o.cfg.egress_parent, o.chat) {
            (Some(parent), _) => Some(parent.clone()),
            (None, true) => None,
            (None, false) => crate::egress::for_session(&o.cfg, &o.cwd),
        };
        if let (Some(e), None) = (&egress, &o.cfg.egress_parent) {
            e.set_session(&session_id);
        }
        let shell_root = o.cwd.canonicalize().unwrap_or_else(|_| o.cwd.clone());
        shared.panes.configure(o.cwd.clone());
        let (map_build_tx, map_build_rx) = std::sync::mpsc::channel();
        let mut agent = Self {
            conv: Conversation {
                messages,
                usage: Usage::default(),
                session_id,
                turn,
                inputs,
                skills_loaded: HashSet::new(),
                rules_seen: HashSet::new(),
                edited: Vec::new(),
                titled: resumed_titled,
                next: None,
                pending: Vec::new(),
                chapters: resumed_chapters,
            },
            cfg: o.cfg,
            profile_name: o.profile_name,
            profile: o.profile,
            provider,
            ctx: {
                let mut ctx = Ctx::new(o.cwd.clone());
                ctx.web = web;
                ctx.image = image;
                ctx.screenshot_endpoint = screenshot_endpoint;
                ctx.judge = judge;
                ctx.sandbox_extra = sandbox_extra;
                ctx.egress = egress;
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
            prs: resumed_prs,
            can_ask: o.can_ask,
            rich: o.rich,
            subagent: o.subagent,
            chat: o.chat,
            store: o.store,
            last_call: Duration::ZERO,
            call_started: Mutex::new(None),
            active_turn: None,
            window,
            est: Estimator::default(),
            harness,
            model_ready: false,
            quiet: 0,
            inbox_told: None,
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
            memory,
            compiled: None,
            notes,
            notes_omitted: 0,
            rules,
            repo_map: Default::default(),
            map_build_tx,
            map_build_rx: Mutex::new(map_build_rx),
            map_building: false,
            map_logged: false,
            intended_model,
            model_flip_why: None,
            worktree_lock: None,
            classifier: None,
            classifier_fallback: None,
            classifier_down: None,
            digest: crate::digest::Digest::default(),
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
            pending_gists: Vec::new(),
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
        self.conv.messages.push(message);
    }

    fn extend_last(&mut self, blocks: Vec<Block>) {
        self.record(Record::Extend {
            blocks: blocks.clone(),
        });
        if let Some(m) = self.conv.messages.last_mut() {
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
        self.conv.messages = messages;
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

    /// Session messages queued behind a running turn ([`Op::Deliver`]s in the work queue,
    /// counted where they're pushed and popped — see [`Shared::inbox_waiting`]). Zero
    /// between turns; read mid-turn before each model call to tell the model what will
    /// arrive when it's done.
    fn waiting_inbox(&self) -> usize {
        self.shared.inbox_waiting.load(Ordering::Relaxed)
    }

    /// The one line the model sees about its waiting inbox, with the count in words.
    fn waiting_note(n: usize) -> String {
        if n == 1 {
            "1 message is waiting for you (it'll be delivered when this turn ends).".into()
        } else {
            format!("{n} messages are waiting for you (they'll be delivered when this turn ends).")
        }
    }

    /// Turn the egress hits since the last flush into events. A hit from `command` (the tool
    /// call just finished) is tied to its item; anything else (a background job, a subagent)
    /// stands alone. A subagent leaves them for its parent, whose transcript keeps them.
    fn flush_egress(&self, item: Option<&str>, command: &str) {
        if self.subagent && self.cfg.egress_parent.is_some() {
            return;
        }
        let Some(egress) = &self.ctx.egress else {
            return;
        };
        let head = crate::egress::head(command);
        for hit in egress.drain() {
            let item = item
                .filter(|i| !i.is_empty() && !command.is_empty() && hit.command == head)
                .map(str::to_string);
            if self.cfg.log_calls {
                eprintln!(
                    "egress: {} {}:{} from {} `{}`",
                    if hit.enforced { "blocked" } else { "flagged" },
                    hit.host,
                    hit.port,
                    hit.tool,
                    hit.command
                );
            }
            self.emit(Event::EgressBlocked {
                host: hit.host,
                port: hit.port,
                item,
                tool: hit.tool,
                command: hit.command,
                enforced: hit.enforced,
            });
        }
    }

    /// Unknown (`None`) when the provider didn't report usage, rather than a misleading zero.
    fn context_tokens(&self) -> Option<u64> {
        let c = self.conv.usage.context();
        (c > 0).then_some(c)
    }

    fn tokens_per_sec(&self) -> Option<f64> {
        let secs = self.last_call.as_secs_f64();
        (secs > 0.0 && self.conv.usage.output > 0).then(|| self.conv.usage.output as f64 / secs)
    }

    /// The conversation's current title, as the client set it (`Op::SetTitle`); part of the
    /// IRC nick (a short title reads better on the bus).
    fn title(&self) -> String {
        self.conv
            .inputs
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

    /// What [`Op::SetMode`] last asked for (see `Shared::mode`): the permit path checks it
    /// per decision, so a mid-turn change takes effect at the next tool call. The agent's
    /// copy catches up in `handle` — that's where the durable `ModeChanged` is logged.
    fn live_mode(&self) -> Mode {
        match self.shared.mode.load(Ordering::SeqCst) {
            0 => Mode::Default,
            1 => Mode::AcceptEdits,
            2 => Mode::Auto,
            _ => Mode::Yolo,
        }
    }

    /// Adopt `Shared::mode` into `self.mode`, and log it if the log doesn't say it yet. A
    /// mode set mid-turn applies immediately (the permit path reads `Shared::mode`) and the
    /// agent's copy follows per tool call, so a status, a resume or a log written after the
    /// change is still exact.
    fn sync_mode(&mut self) {
        let mode = self.live_mode();
        if self.mode == mode {
            return;
        }
        self.mode = mode;
        self.log_mode();
    }

    fn emit_status(&self) {
        // The mode the permit path is running in (the client's last `Op::SetMode`, even
        // mid-turn); `self.mode` lags it until the next decision adopts it.
        let mode = if self.mode == self.live_mode() {
            self.mode
        } else {
            self.live_mode()
        };
        self.emit(Event::Status(Status {
            model: self.profile_name.clone(),
            mode,
            cwd: self.ctx.root.clone(),
            messages: self.conv.messages.len(),
            context_tokens: self.context_tokens(),
            context_window: self.window,
            tool_mode: self.harness.tool_mode,
            tier: self.harness.tier,
            tokens_per_sec: self.tokens_per_sec(),
            todos: self.ctx.todos.clone(),
            vision: self.vision,
            degraded: self.degraded(),
            ran_on: self.provider.ran_on(),
            waiting: self.waiting(),
        }));
    }

    /// The model call in flight, if one is: how long this attempt has run, which attempt it
    /// is, and any `retry-after` the provider gave. `None` between calls.
    fn waiting(&self) -> Option<crate::protocol::Waiting> {
        let held = self.call_started.lock().unwrap();
        let (started, attempt, retry_after_secs) = (*held)?;
        Some(crate::protocol::Waiting {
            seconds: started.elapsed().as_secs(),
            attempt,
            retry_after_secs,
        })
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
        if !compact {
            let served =
                crate::protocol::ServedBy::resolve(&self.profile_name, u.upstream.as_deref());
            self.turn_usage.served_by = served.or(self.turn_usage.served_by.take());
        }
        // A pooled model's call says where it ran: the chip moves when the node does.
        if u.ran_on.is_some() && u.ran_on != self.turn_usage.ran_on {
            self.turn_usage.ran_on = u.ran_on.clone();
            self.emit_status();
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
            ran_on: u.ran_on.as_ref().map(|r| r.name.clone()),
        });
    }

    /// A title for sessions nobody else will name. The Mac app names its own conversations
    /// (rich), the model may call `SetTitle`, and a user may; when none of that happened by
    /// the end of the first turn, the first input stands in, with wrapper boilerplate stripped.
    fn auto_title(&mut self, turn: u64) {
        if self.conv.titled || self.rich || turn != 1 {
            return;
        }
        if let Some(input) = self.conv.inputs.first() {
            let title = crate::title::derive(input);
            if !title.is_empty() {
                self.set_title(title);
            }
        }
    }

    /// Write the turn's queued tool-call gists in batched side-model calls, and emit one
    /// durable [`Event::ItemGisted`] per item. The model call is bounded and best effort: any
    /// trouble (no usable model, a timeout, an unreadable answer) silently leaves those rows
    /// on their own argument — a gist is a display flourish, never worth failing over.
    /// Duplicated calls across items get the same line, so the work stays one per unique
    /// call, not one per row.
    async fn flush_gists(&mut self) {
        let pending = std::mem::take(&mut self.pending_gists);
        if pending.is_empty() || self.subagent {
            return;
        }
        let calls: Vec<crate::gist::Call> = pending
            .iter()
            .map(|(_, tool, arg, outcome, output)| crate::gist::Call {
                tool,
                arg,
                outcome: *outcome,
                output,
            })
            .collect();
        let gists = crate::gist::write(&self.cfg, &self.root, &calls, crate::harness::is_cloud(&self.profile)).await;
        for ((id, ..), gist) in pending.iter().zip(gists) {
            if gist.is_empty() {
                continue;
            }
            self.emit(Event::ItemGisted {
                item: id.clone(),
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
        let cloud_ok = crate::harness::is_cloud(&self.profile);
        let (journal, cache) = (self.shared.journal.clone(), self.chapter_titles.clone());
        let session = journal.session();
        tokio::spawn(async move {
            let Some(title) = crate::chapter::write(&cfg, &root, &closed, cloud_ok).await else {
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
        // Background jobs' attempts since the last tool call.
        self.flush_egress(None, "");
        if let Some(next) = self.conv.next.take()
            && reason == EndReason::Complete
        {
            self.emit(Event::NextSuggested {
                turn,
                text: next.text,
                act: next.act,
            });
        }
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
                // Out of credit: waiting on the user (money), like a denial.
                EndReason::BillingLimit { .. } => Some((
                    NoticeKind::WaitingOnUser,
                    "turn ended: out of credit, waiting on user".to_string(),
                )),
                // Idle per the SendMessage contract: no turn running, nothing queued.
                EndReason::Complete | EndReason::MaxTokens { .. } => {
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

    /// Bind (or update) a PR and tell every client the new list. No change, no event.
    fn bind_pr(&mut self, pr: crate::prs::PrBinding) {
        if crate::prs::upsert(&mut self.prs, pr) {
            self.emit(Event::Prs { prs: self.prs.clone() });
        }
    }

    /// Record the session's title and remember it's named. A client's `Op::SetTitle` and the
    /// model's `SetTitle` tool both land here.
    fn set_title(&mut self, title: String) {
        self.conv.titled = true;
        if let Some(bus) = self.irc() {
            bus.set_session(&self.conv.session_id, &title);
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
                    self.turn_with(&text, images, more, true).await?
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
            Op::ApprovalDigest => {
                let summary = self.digest.summary();
                self.emit(Event::ApprovalDigest { summary });
            }
            Op::Wake => self.wake(Vec::new()).await?,
            Op::SetMode { mode } => {
                // The router already applied it (see `Shared::mode`), so the permit path has
                // been running in it since the call; this reconciles the agent's copy. Kept
                // idempotent so a re-delivered op logs nothing new.
                if self.mode != mode {
                    self.mode = mode;
                    self.log_mode();
                } else {
                    self.mode_logged = Some(mode);
                }
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
                        session::events_after(dir, &self.conv.session_id, after)?
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
                self.conv = Conversation::fresh();
                self.shared.wake_hold.store(false, Ordering::SeqCst);
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
                self.shared
                    .journal
                    .start_session(self.conv.session_id.clone(), 0, None);
                if let Some(lock) = self.worktree_lock.as_mut() {
                    lock.set_owner(&self.conv.session_id);
                }
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
            Op::BindPr { pr } => self.bind_pr(pr),
            Op::UnbindPr { repo, number } => {
                if crate::prs::remove(&mut self.prs, &repo, number) {
                    self.emit(Event::Prs { prs: self.prs.clone() });
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
                        bus.set_session(&self.conv.session_id, &self.title());
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
