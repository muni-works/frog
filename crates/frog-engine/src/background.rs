//! Background work: subagents started with `Task { background: true }`, shell jobs started
//! with `Bash { run_in_background: true }`, and `Monitor`s (a command polled until its output
//! matches or it exits a given way, or a plain timer).
//!
//! Each piece runs as its own tokio task and is tracked here by id. When one finishes it
//! leaves a notice for the model (`<task-done id=…>`, `<job-done …>`, `<monitor-done …>`,
//! `<wakeup …>`) and wakes the engine: an idle engine starts a turn with it, a busy one picks
//! it up at the start of its next turn. Start and finish are durable events
//! ([`Event::BackgroundStarted`], [`Event::BackgroundDone`]); live output goes out as
//! [`Event::BackgroundProgress`]. Everything still running is stopped when the session ends
//! or the user cancels.
//!
//! Nothing here asks for permission: the engine runs its normal permission check on the
//! starting call (a job or a polled command is checked exactly like Bash), and a background
//! subagent's own tool calls go through the parent's flow via [`Registry::relay`].

use crate::protocol::{Decision, Event, Op};
use crate::provider::ToolSpec;
use crate::tools::{Ctx, Output, int_arg, str_arg, strip_ansi};
use anyhow::{Result, bail};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub const TASK_OUTPUT: &str = "TaskOutput";
pub const TASK_STOP: &str = "TaskStop";
pub const JOB_OUTPUT: &str = "JobOutput";
pub const JOB_STOP: &str = "JobStop";
pub const MONITOR: &str = "Monitor";

/// Tools this module answers.
pub fn handles(name: &str) -> bool {
    matches!(
        name,
        TASK_OUTPUT | TASK_STOP | JOB_OUTPUT | JOB_STOP | MONITOR
    )
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Task,
    Job,
    Monitor,
    Timer,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Task => "task",
            Kind::Job => "job",
            Kind::Monitor => "monitor",
            Kind::Timer => "timer",
        }
    }

    fn prefix(self) -> &'static str {
        match self {
            Kind::Task => "task",
            Kind::Job => "job",
            Kind::Monitor | Kind::Timer => "mon",
        }
    }
}

struct Entry {
    kind: Kind,
    label: String,
    running: bool,
    status: String,
    /// A task's report (so far, then final); a monitor's last poll; empty for jobs.
    output: String,
    /// A job's output file.
    file: Option<PathBuf>,
    stop: CancellationToken,
    started: Instant,
}

type Emit = Box<dyn Fn(Event) + Send + Sync>;

pub struct Registry {
    entries: Mutex<BTreeMap<String, Entry>>,
    next: AtomicU64,
    notices: Mutex<Vec<String>>,
    /// The engine's queue, to start a turn when work finishes. Weak, so it never keeps the
    /// engine alive.
    wake: Mutex<Option<mpsc::WeakUnboundedSender<Op>>>,
    /// Permission requests from subagents, by request id: answers go to that subagent.
    relay: Mutex<HashMap<String, mpsc::UnboundedSender<Op>>>,
    emit: Emit,
}

impl Registry {
    pub fn new(emit: impl Fn(Event) + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(Self {
            entries: Default::default(),
            next: AtomicU64::new(1),
            notices: Default::default(),
            wake: Default::default(),
            relay: Default::default(),
            emit: Box::new(emit),
        })
    }

    pub fn set_wake(&self, tx: &mpsc::UnboundedSender<Op>) {
        *self.wake.lock().unwrap() = Some(tx.downgrade());
    }

    pub fn emit(&self, event: Event) {
        (self.emit)(event)
    }

    fn new_id(&self, kind: Kind) -> String {
        format!(
            "{}-{}",
            kind.prefix(),
            self.next.fetch_add(1, Ordering::Relaxed)
        )
    }

    fn begin(&self, id: &str, kind: Kind, label: &str, file: Option<PathBuf>) -> CancellationToken {
        let stop = CancellationToken::new();
        self.entries.lock().unwrap().insert(
            id.to_string(),
            Entry {
                kind,
                label: label.to_string(),
                running: true,
                status: "running".into(),
                output: String::new(),
                file,
                stop: stop.clone(),
                started: Instant::now(),
            },
        );
        self.emit(Event::BackgroundStarted {
            id: id.to_string(),
            kind: kind.as_str().into(),
            label: label.to_string(),
        });
        stop
    }

    /// Running pieces of this kind.
    pub fn running(&self, kind: Kind) -> usize {
        self.entries
            .lock()
            .unwrap()
            .values()
            .filter(|e| e.running && e.kind == kind)
            .count()
    }

    /// Live output: kept as the entry's latest output when `keep`, and sent to clients.
    fn progress(&self, id: &str, text: &str, keep: bool) {
        if keep && let Some(e) = self.entries.lock().unwrap().get_mut(id) {
            e.output = text.to_string();
        }
        let text: String = text.chars().take(500).collect();
        self.emit(Event::BackgroundProgress {
            id: id.to_string(),
            text,
        });
    }

    /// Record how a piece ended. If it was still running (not stopped), tell clients and leave
    /// `notice` for the model, waking the engine.
    fn finish(&self, id: &str, status: &str, output: String, notice: String) {
        let (kind, was_running) = {
            let mut entries = self.entries.lock().unwrap();
            let Some(e) = entries.get_mut(id) else {
                return;
            };
            let was = e.running;
            e.running = false;
            if was {
                e.status = status.to_string();
            }
            if !output.is_empty() {
                e.output = output;
            }
            (e.kind, was)
        };
        if !was_running {
            return;
        }
        self.emit(Event::BackgroundDone {
            id: id.to_string(),
            kind: kind.as_str().into(),
            status: status.to_string(),
            summary: notice.clone(),
        });
        self.notices.lock().unwrap().push(notice);
        let wake = self.wake.lock().unwrap().as_ref().and_then(|w| w.upgrade());
        if let Some(tx) = wake {
            let _ = tx.send(Op::Wake);
        }
    }

    /// Stop one piece. Its end is recorded as `stopped`, with no notice (whoever stopped it
    /// knows). False if there's no such piece running.
    pub fn stop(&self, id: &str) -> bool {
        let kind = {
            let mut entries = self.entries.lock().unwrap();
            let Some(e) = entries.get_mut(id).filter(|e| e.running) else {
                return false;
            };
            e.running = false;
            e.status = "stopped".into();
            e.stop.cancel();
            e.kind
        };
        self.emit(Event::BackgroundDone {
            id: id.to_string(),
            kind: kind.as_str().into(),
            status: "stopped".into(),
            summary: String::new(),
        });
        true
    }

    /// Stop everything still running (session end, cancel) and drop undelivered notices.
    pub fn stop_all(&self) {
        let ids: Vec<String> = self
            .entries
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, e)| e.running)
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            self.stop(&id);
        }
        self.relay.lock().unwrap().clear();
    }

    pub fn has_notices(&self) -> bool {
        !self.notices.lock().unwrap().is_empty()
    }

    pub fn take_notices(&self) -> Vec<String> {
        std::mem::take(&mut *self.notices.lock().unwrap())
    }

    /// Route a permission answer to the subagent that asked. False if none did.
    pub fn answer(&self, id: &str, decision: Decision, note: Option<String>) -> bool {
        let Some(tx) = self.relay.lock().unwrap().remove(id) else {
            return false;
        };
        let _ = tx.send(Op::Permission {
            id: id.to_string(),
            decision,
            note,
        });
        true
    }

    /// Something running: none means nothing to wait for.
    pub fn any_running(&self) -> bool {
        self.entries.lock().unwrap().values().any(|e| e.running)
    }
}

/// Passes a subagent's events on: its permission requests go to the user through the parent
/// (labelled with `item`, answered via [`Registry::answer`]), everything else is wrapped in
/// [`Event::Subagent`]. With `background`, its steps and messages are progress too.
pub fn forward(
    reg: Arc<Registry>,
    item: String,
    background: bool,
) -> impl Fn(Event, &mpsc::UnboundedSender<Op>) + Send + Sync + 'static {
    move |event, ops| match event {
        Event::PermissionRequest {
            id,
            item: _,
            name,
            arg,
            always,
            preview,
            reason,
            subagent: _,
            card,
        } => {
            reg.relay.lock().unwrap().insert(id.clone(), ops.clone());
            reg.emit(Event::PermissionRequest {
                id,
                item: item.clone(),
                name,
                arg,
                always,
                preview,
                reason,
                subagent: Some(item.clone()),
                card,
            });
        }
        Event::PermissionResolved { id, decision } => {
            reg.relay.lock().unwrap().remove(&id);
            reg.emit(Event::PermissionResolved { id, decision });
        }
        inner => {
            if background {
                match &inner {
                    Event::ItemStarted {
                        kind: crate::protocol::ItemKind::ToolCall { name, arg },
                        ..
                    } => reg.progress(&item, &format!("{name}({arg})"), false),
                    Event::ItemCompleted {
                        item: crate::protocol::Item::Message { text },
                        ..
                    } => reg.progress(&item, text, true),
                    _ => {}
                }
            }
            reg.emit(Event::Subagent {
                item: item.clone(),
                inner: Box::new(inner),
            });
        }
    }
}

/// `Task { background: true }`: run the subagent as its own task and return its id.
pub fn start_task(
    reg: &Arc<Registry>,
    opts: crate::engine::Options,
    input: &Value,
    max: usize,
) -> Result<Output> {
    if input["prompt"].as_str().unwrap_or("").trim().is_empty() {
        bail!("`prompt` is required: describe the task in full");
    }
    if reg.running(Kind::Task) >= max {
        bail!(
            "{max} background tasks are already running (the limit). Wait for one to finish, or stop one with TaskStop."
        );
    }
    let id = reg.new_id(Kind::Task);
    let label = input["description"].as_str().unwrap_or("task").to_string();
    let stop = reg.begin(&id, Kind::Task, &label, None);
    let (reg2, id2, input) = (reg.clone(), id.clone(), input.clone());
    tokio::spawn(async move {
        let fwd = forward(reg2.clone(), id2.clone(), true);
        let r = crate::subagent::run(opts, &input, stop, fwd).await;
        match r {
            Ok(out) => {
                let notice = format!("<task-done id={id2}>\n{}\n</task-done>", out.content.trim());
                reg2.finish(&id2, "done", out.content, notice);
            }
            Err(e) => {
                let msg = format!("{e:#}");
                let notice = format!("<task-done id={id2} status=failed>\n{msg}\n</task-done>");
                reg2.finish(&id2, "failed", msg, notice);
            }
        }
    });
    Ok(Output::text(format!(
        "Started background task {id}. It runs on its own; you'll get a <task-done id={id}> message with its report when it finishes. TaskOutput {{\"id\": \"{id}\"}} shows its progress, TaskStop stops it."
    )))
}

/// The bits of a context a background command needs: where it runs and its sandbox.
fn shell_ctx(ctx: &Ctx) -> Ctx {
    let mut c = Ctx::new(ctx.cwd.clone());
    c.root = ctx.root.clone();
    c.sandbox = ctx.sandbox.clone();
    c.shell_sandbox = ctx.shell_sandbox.clone();
    c.sandbox_extra = ctx.sandbox_extra.clone();
    c
}

/// Kill a command's whole process group.
fn kill_group(pid: Option<u32>) {
    if let Some(pid) = pid.filter(|p| *p > 0) {
        unsafe {
            libc::killpg(pid as i32, libc::SIGKILL);
        }
    }
}

/// The last `lines` lines of a file (at most ~16 KB of it), ANSI stripped.
fn tail_file(path: &Path, lines: usize) -> String {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut f) = std::fs::File::open(path) else {
        return String::new();
    };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let _ = f.seek(SeekFrom::Start(len.saturating_sub(16_384)));
    let mut buf = Vec::new();
    let _ = f.read_to_end(&mut buf);
    tail(&strip_ansi(&String::from_utf8_lossy(&buf)), lines)
}

fn tail(text: &str, lines: usize) -> String {
    let all: Vec<&str> = text.trim_end().lines().collect();
    all[all.len().saturating_sub(lines)..].join("\n")
}

/// `Bash { run_in_background: true }` (already permitted): start the job, its output going to
/// a file in `dir`, and return its id.
pub fn start_job(reg: &Arc<Registry>, input: &Value, ctx: &Ctx, dir: &Path) -> Result<Output> {
    let cmd = str_arg(input, "command")?.to_string();
    let (mut command, _) = crate::tools::bash::shell(input, &shell_ctx(ctx))?;
    std::fs::create_dir_all(dir)?;
    let id = reg.new_id(Kind::Job);
    let file = dir.join(format!("{id}.log"));
    let out = std::fs::File::create(&file)?;
    let mut child = command
        .arg(format!("{{\n{cmd}\n}} 2>&1"))
        .stdin(std::process::Stdio::null())
        .stdout(out.try_clone()?)
        .stderr(out)
        .process_group(0)
        .kill_on_drop(true)
        .spawn()?;
    let label = cmd.lines().next().unwrap_or("").to_string();
    let stop = reg.begin(&id, Kind::Job, &label, Some(file.clone()));
    let (reg2, id2, file2) = (reg.clone(), id.clone(), file.clone());
    tokio::spawn(async move {
        let pid = child.id();
        let mut tick = tokio::time::interval(Duration::from_secs(2));
        let mut seen = 0u64;
        let status = loop {
            tokio::select! {
                s = child.wait() => break Some(s),
                _ = stop.cancelled() => break None,
                _ = tick.tick() => {
                    let len = std::fs::metadata(&file2).map(|m| m.len()).unwrap_or(0);
                    if len > seen {
                        seen = len;
                        let last = tail_file(&file2, 1);
                        reg2.progress(&id2, &last, false);
                    }
                }
            }
        };
        let Some(status) = status else {
            kill_group(pid);
            return;
        };
        let code = status.ok().and_then(|s| s.code()).unwrap_or(-1);
        let out = tail_file(&file2, 20);
        let notice = format!("<job-done id={id2} exit={code}>\n{out}\n</job-done>");
        let state = if code == 0 { "done" } else { "failed" };
        reg2.finish(&id2, state, String::new(), notice);
    });
    Ok(Output::text(format!(
        "Started background job {id}, writing its output to {}. You'll get a <job-done id={id}> message (exit code and the tail of its output) when it exits. JobOutput {{\"id\": \"{id}\"}} reads its output, JobStop stops it.",
        file.display()
    )))
}

/// `Monitor` (already permitted when it runs a command).
pub fn start_monitor(reg: &Arc<Registry>, input: &Value, ctx: &Ctx) -> Result<Output> {
    let command = input["command"].as_str().map(str::trim).unwrap_or("");
    if command.is_empty() {
        let Some(after) = int_arg(input, "after_s") else {
            bail!("give a `command` with `until_regex` or `until_exit`, or `after_s` for a timer");
        };
        let id = reg.new_id(Kind::Timer);
        let note = input["note"].as_str().unwrap_or("").to_string();
        let stop = reg.begin(&id, Kind::Timer, &format!("wake in {after}s"), None);
        let (reg2, id2) = (reg.clone(), id.clone());
        tokio::spawn(async move {
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(after)) => {}
                _ = stop.cancelled() => return,
            }
            let notice = format!("<wakeup id={id2} after_s={after}>{note}</wakeup>");
            reg2.finish(&id2, "done", String::new(), notice);
        });
        return Ok(Output::text(format!(
            "Timer {id} set: you'll get a <wakeup id={id}> message in {after}s."
        )));
    }
    let regex = match input["until_regex"].as_str().filter(|s| !s.is_empty()) {
        Some(r) => Some(regex::Regex::new(r).map_err(|e| anyhow::anyhow!("bad until_regex: {e}"))?),
        None => None,
    };
    let until_exit = match &input["until_exit"] {
        Value::Bool(true) => Some(0),
        v => v
            .as_i64()
            .or_else(|| v.as_str().and_then(|s| s.parse().ok())),
    };
    if regex.is_none() && until_exit.is_none() {
        bail!(
            "give `until_regex` (a pattern to wait for in the output) or `until_exit` (an exit code to wait for)"
        );
    }
    let timeout = Duration::from_secs(int_arg(input, "timeout_s").unwrap_or(600).clamp(1, 86_400));
    let interval = Duration::from_secs(int_arg(input, "interval_s").unwrap_or(5).clamp(1, 3_600));
    // Check the command can be built (the sandbox exists) before saying it started.
    crate::tools::bash::shell(input, &shell_ctx(ctx))?;
    let id = reg.new_id(Kind::Monitor);
    let label = command.lines().next().unwrap_or("").to_string();
    let stop = reg.begin(&id, Kind::Monitor, &label, None);
    let (reg2, id2, input2, ctx2, command) = (
        reg.clone(),
        id.clone(),
        input.clone(),
        shell_ctx(ctx),
        command.to_string(),
    );
    tokio::spawn(async move {
        let start = Instant::now();
        let mut polls = 0u32;
        loop {
            polls += 1;
            let left = timeout.saturating_sub(start.elapsed());
            let poll = poll_once(&input2, &ctx2, &command, left.max(Duration::from_secs(1)));
            let (out, code) = tokio::select! {
                r = poll => r,
                _ = stop.cancelled() => return,
            };
            let last = tail(&out, 20);
            reg2.progress(&id2, &tail(&out, 1), false);
            if let Some(e) = reg2.entries.lock().unwrap().get_mut(&id2) {
                e.output = last.clone();
            }
            let matched = regex
                .as_ref()
                .and_then(|r| r.find(&out).map(|m| m.as_str().to_string()));
            let exited = until_exit.is_some() && code == until_exit;
            if matched.is_some() || exited {
                let why = match matched {
                    Some(m) => format!("matched {m:?}"),
                    None => format!("exit={}", code.unwrap_or(-1)),
                };
                let notice = format!(
                    "<monitor-done id={id2} status=matched polls={polls}>\n{why}\n{last}\n</monitor-done>"
                );
                reg2.finish(&id2, "matched", String::new(), notice);
                return;
            }
            if start.elapsed() + interval > timeout {
                let notice = format!(
                    "<monitor-done id={id2} status=timeout polls={polls}>\nno match after {}s. Last output:\n{last}\n</monitor-done>",
                    timeout.as_secs()
                );
                reg2.finish(&id2, "timeout", String::new(), notice);
                return;
            }
            tokio::select! {
                _ = tokio::time::sleep(interval) => {}
                _ = stop.cancelled() => return,
            }
        }
    });
    Ok(Output::text(format!(
        "Monitor {id} started: polling every {}s for up to {}s. You'll get a <monitor-done id={id}> message on a match or at the timeout. JobStop {{\"id\": \"{id}\"}} stops it.",
        interval.as_secs(),
        timeout.as_secs()
    )))
}

/// Run a monitor's command once: its output (stdout and stderr) and exit code.
async fn poll_once(
    input: &Value,
    ctx: &Ctx,
    cmd: &str,
    timeout: Duration,
) -> (String, Option<i64>) {
    let Ok((mut command, _)) = crate::tools::bash::shell(input, ctx) else {
        return (String::new(), None);
    };
    let child = command
        .arg(format!("{{\n{cmd}\n}} 2>&1"))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .process_group(0)
        .kill_on_drop(true)
        .spawn();
    let Ok(child) = child else {
        return (String::new(), None);
    };
    let pid = child.id();
    match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(Ok(o)) => {
            let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
            s.push_str(&String::from_utf8_lossy(&o.stderr));
            (strip_ansi(&s), o.status.code().map(i64::from))
        }
        _ => {
            kill_group(pid);
            (String::new(), None)
        }
    }
}

/// `TaskOutput`, `TaskStop`, `JobOutput`, `JobStop`, and `Monitor` (with `ctx` for its command).
pub fn run(reg: &Arc<Registry>, name: &str, input: &Value, ctx: &Ctx) -> Result<Output> {
    if name == MONITOR {
        return start_monitor(reg, input, ctx);
    }
    let id = str_arg(input, "id")?;
    let entries = reg.entries.lock().unwrap();
    let Some(e) = entries.get(id) else {
        let known: Vec<&str> = entries.keys().map(String::as_str).collect();
        bail!(
            "no background task, job or monitor `{id}`. Known: {}",
            if known.is_empty() {
                "none".to_string()
            } else {
                known.join(", ")
            }
        );
    };
    let want_task = matches!(name, TASK_OUTPUT | TASK_STOP);
    if want_task != (e.kind == Kind::Task) {
        let other = if e.kind == Kind::Task {
            "TaskOutput/TaskStop"
        } else {
            "JobOutput/JobStop"
        };
        bail!("`{id}` is a {}: use {other}", e.kind.as_str());
    }
    let secs = e.started.elapsed().as_secs();
    match name {
        TASK_OUTPUT | JOB_OUTPUT => {
            let body = match &e.file {
                Some(f) => {
                    let lines = int_arg(input, "tail").unwrap_or(50).clamp(1, 2_000) as usize;
                    tail_file(f, lines)
                }
                None => e.output.clone(),
            };
            let body = if body.trim().is_empty() {
                "(no output yet)".into()
            } else {
                body
            };
            Ok(Output::text(format!(
                "{id} ({}, {}, {secs}s): {}\n\n{body}",
                e.label,
                e.status,
                e.kind.as_str()
            )))
        }
        _ => {
            let (label, so_far) = (e.label.clone(), e.output.clone());
            drop(entries);
            if !reg.stop(id) {
                return Ok(Output::text(format!(
                    "{id} ({label}) had already finished."
                )));
            }
            let mut text = format!("Stopped {id} ({label}).");
            if !so_far.trim().is_empty() {
                text.push_str(&format!(" What it had so far:\n\n{so_far}"));
            }
            Ok(Output::text(text))
        }
    }
}

pub fn specs() -> Vec<ToolSpec> {
    let id = |what: &str| json!({"type": "string", "description": format!("The {what} id")});
    vec![
        ToolSpec {
            name: TASK_OUTPUT.into(),
            description: "Check a background Task: its status and its report so far (or final report).".into(),
            schema: json!({"type": "object", "properties": {"id": id("task")}, "required": ["id"]}),
        },
        ToolSpec {
            name: TASK_STOP.into(),
            description: "Stop a background Task. Returns what it had found so far.".into(),
            schema: json!({"type": "object", "properties": {"id": id("task")}, "required": ["id"]}),
        },
        ToolSpec {
            name: JOB_OUTPUT.into(),
            description: "Read the output of a background Bash job (or a Monitor's last poll).".into(),
            schema: json!({"type": "object", "properties": {
                "id": id("job or monitor"),
                "tail": {"type": "integer", "description": "How many of the last lines to show (default 50)"}
            }, "required": ["id"]}),
        },
        ToolSpec {
            name: JOB_STOP.into(),
            description: "Stop a background Bash job or a Monitor (kills the job's processes).".into(),
            schema: json!({"type": "object", "properties": {"id": id("job or monitor")}, "required": ["id"]}),
        },
        ToolSpec {
            name: MONITOR.into(),
            description: "Watch for something in the background and get a message when it happens, instead of polling yourself. With `command`: run it every `interval_s` seconds until its output matches `until_regex` or it exits with code `until_exit` (true means 0), or `timeout_s` passes. The command runs like Bash (same sandbox and permissions). With only `after_s`: a timer that wakes you after that many seconds.".into(),
            schema: json!({"type": "object", "properties": {
                "command": {"type": "string", "description": "Shell command to poll"},
                "until_regex": {"type": "string", "description": "Stop when the command's output matches this regex"},
                "until_exit": {"type": ["integer", "boolean"], "description": "Stop when the command exits with this code (true: 0)"},
                "timeout_s": {"type": "integer", "description": "Give up after this many seconds (default 600)"},
                "interval_s": {"type": "integer", "description": "Seconds between polls (default 5)"},
                "after_s": {"type": "integer", "description": "Timer only: wake after this many seconds"},
                "note": {"type": "string", "description": "Timer only: a reminder to include in the wakeup"}
            }}),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn registry() -> (Arc<Registry>, Arc<Mutex<Vec<Event>>>) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s = seen.clone();
        (Registry::new(move |e| s.lock().unwrap().push(e)), seen)
    }

    async fn wait_notice(reg: &Registry) -> String {
        for _ in 0..200 {
            if reg.has_notices() {
                return reg.take_notices().join("\n");
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("no notice");
    }

    fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!("frog-bg-{}", crate::session::new_id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[tokio::test]
    async fn a_finished_job_leaves_its_exit_code_and_tail() {
        let (reg, seen) = registry();
        let dir = tmp();
        let ctx = Ctx::new(dir.clone());
        let out = start_job(
            &reg,
            &json!({"command": "echo one; echo two; exit 3"}),
            &ctx,
            &dir.join("jobs"),
        )
        .unwrap();
        assert!(out.content.contains("job-1"));
        let notice = wait_notice(&reg).await;
        assert!(notice.starts_with("<job-done id=job-1 exit=3>"), "{notice}");
        assert!(notice.contains("one\ntwo"), "{notice}");
        let evs = seen.lock().unwrap();
        assert!(matches!(&evs[0], Event::BackgroundStarted { kind, .. } if kind == "job"));
        assert!(
            evs.iter()
                .any(|e| matches!(e, Event::BackgroundDone { status, .. } if status == "failed"))
        );
        let read = run(&reg, JOB_OUTPUT, &json!({"id": "job-1", "tail": 1}), &ctx).unwrap();
        assert!(read.content.ends_with("two"), "{}", read.content);
    }

    #[tokio::test]
    async fn monitor_matches_a_regex() {
        let (reg, _) = registry();
        let dir = tmp();
        let ctx = Ctx::new(dir.clone());
        // Appears on the second poll.
        let input = json!({"command": "echo tick >> n; wc -l < n | tr -d ' '; [ $(wc -l < n) -ge 2 ] && echo READY",
            "until_regex": "READY", "interval_s": 1, "timeout_s": 30});
        start_monitor(&reg, &input, &ctx).unwrap();
        let notice = wait_notice(&reg).await;
        assert!(notice.contains("status=matched polls=2"), "{notice}");
    }

    #[tokio::test]
    async fn monitor_times_out() {
        let (reg, seen) = registry();
        let ctx = Ctx::new(tmp());
        let input = json!({"command": "echo nope", "until_regex": "never", "interval_s": 1, "timeout_s": 1});
        start_monitor(&reg, &input, &ctx).unwrap();
        let notice = wait_notice(&reg).await;
        assert!(notice.contains("status=timeout"), "{notice}");
        assert!(notice.contains("nope"), "{notice}");
        assert!(
            seen.lock()
                .unwrap()
                .iter()
                .any(|e| matches!(e, Event::BackgroundDone { status, .. } if status == "timeout"))
        );
    }

    #[tokio::test]
    async fn monitor_waits_for_an_exit_code_and_timers_wake() {
        let (reg, _) = registry();
        let ctx = Ctx::new(tmp());
        start_monitor(
            &reg,
            &json!({"command": "true", "until_exit": true, "interval_s": 1}),
            &ctx,
        )
        .unwrap();
        assert!(wait_notice(&reg).await.contains("exit=0"));
        start_monitor(
            &reg,
            &json!({"after_s": 0, "note": "check the deploy"}),
            &ctx,
        )
        .unwrap();
        let n = wait_notice(&reg).await;
        assert!(
            n.starts_with("<wakeup id=mon-2") && n.contains("check the deploy"),
            "{n}"
        );
    }

    #[tokio::test]
    async fn stop_all_kills_jobs_without_notices() {
        let (reg, _) = registry();
        let dir = tmp();
        let ctx = Ctx::new(dir.clone());
        let marker = dir.join("survived");
        let cmd = format!("sleep 2; touch {}", marker.display());
        start_job(&reg, &json!({"command": cmd}), &ctx, &dir).unwrap();
        start_monitor(&reg, &json!({"after_s": 1}), &ctx).unwrap();
        assert!(reg.any_running());
        reg.stop_all();
        assert!(!reg.any_running());
        tokio::time::sleep(Duration::from_millis(2_500)).await;
        assert!(!marker.exists(), "the job's process was killed");
        assert!(!reg.has_notices());
    }
}
