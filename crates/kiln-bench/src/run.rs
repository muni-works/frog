//! One bench run: seed a workspace, drive the engine through one prompt, then check the result.

use crate::task::{self, Task};
use anyhow::Result;
use kiln_engine::config::{Config, ToolMode};
use kiln_engine::{EndReason, Event, Item, Mode, Op, Options, ToolOutcome};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunResult {
    pub task: String,
    pub model: String,
    /// The mode asked for (`auto`, `native`, …).
    pub mode: String,
    /// What `auto` resolved to, from the engine's status.
    pub resolved_mode: Option<String>,
    pub tier: Option<String>,
    pub rep: u32,
    pub pass: bool,
    /// How the turn ended: complete, looping, step_limit, error, timeout, …
    pub end: String,
    pub error: Option<String>,
    pub secs: f64,
    pub model_calls: u32,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub tool_calls: u32,
    pub tool_errors: u32,
    pub refused_repeats: u32,
    pub pruned: u32,
    pub compacted: u32,
    pub session: String,
    pub workspace: PathBuf,
    pub check_output: String,
}

fn end_name(r: &EndReason) -> String {
    serde_json::to_value(r)
        .ok()
        .and_then(|v| v["type"].as_str().map(String::from))
        .unwrap_or_default()
}

fn lower<T: std::fmt::Debug>(t: T) -> String {
    format!("{t:?}").to_lowercase()
}

pub struct Run<'a> {
    pub cfg: &'a Config,
    pub model: &'a str,
    pub mode: ToolMode,
    pub task: &'a Task,
    pub rep: u32,
    pub workspace: PathBuf,
    pub sessions: &'a Path,
}

pub async fn run(r: Run<'_>) -> Result<RunResult> {
    task::seed(r.task, &r.workspace)?;
    let (profile_name, mut profile) = r.cfg.resolve(Some(r.model))?;
    profile.tool_mode = r.mode;
    let mut h = kiln_engine::spawn(Options {
        cfg: r.cfg.clone(),
        profile_name,
        profile,
        cwd: r.workspace.clone(),
        mode: Mode::Yolo,
        can_ask: false,
        resume: None,
        store: Some(r.sessions.to_path_buf()),
        sandbox: true,
        rich: false,
        subagent: false,
        chat: false,
    })?;
    h.ops.send(Op::Submit {
        text: r.task.prompt.clone(),
    })?;
    h.ops.send(Op::Shutdown)?;

    let mut out = RunResult {
        task: r.task.name.clone(),
        model: r.model.to_string(),
        mode: lower(r.mode),
        resolved_mode: None,
        tier: None,
        rep: r.rep,
        pass: false,
        end: "none".into(),
        error: None,
        secs: 0.0,
        model_calls: 0,
        input_tokens: 0,
        output_tokens: 0,
        tool_calls: 0,
        tool_errors: 0,
        refused_repeats: 0,
        pruned: 0,
        compacted: 0,
        session: String::new(),
        workspace: r.workspace.clone(),
        check_output: String::new(),
    };

    let started = Instant::now();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(r.task.timeout_secs);
    let mut timed_out = false;
    loop {
        let env = if timed_out {
            // Give the engine a moment to wind down after the interrupt.
            match tokio::time::timeout(Duration::from_secs(15), h.events.recv()).await {
                Ok(env) => env,
                Err(_) => break,
            }
        } else {
            match tokio::time::timeout_at(deadline, h.events.recv()).await {
                Ok(env) => env,
                Err(_) => {
                    timed_out = true;
                    let _ = h.ops.send(Op::Interrupt);
                    continue;
                }
            }
        };
        let Some(env) = env else { break };
        out.session = env.session.clone();
        match env.event {
            Event::Status(s) => {
                out.resolved_mode = Some(lower(s.tool_mode));
                out.tier = Some(lower(s.tier));
            }
            Event::ItemCompleted {
                item: Item::ToolCall {
                    outcome, display, ..
                },
                ..
            } => {
                out.tool_calls += 1;
                if outcome != ToolOutcome::Ok {
                    out.tool_errors += 1;
                }
                if display.is_some_and(|d| d.starts_with("refused")) {
                    out.refused_repeats += 1;
                }
            }
            Event::ContextPruned { .. } => out.pruned += 1,
            Event::Compacted { .. } => out.compacted += 1,
            Event::TurnEnded { reason, usage, .. } => {
                out.end = end_name(&reason);
                if let EndReason::Error { error } = &reason {
                    out.error = Some(error.to_string());
                }
                out.model_calls = usage.model_calls;
                out.input_tokens = usage.input_tokens;
                out.output_tokens = usage.output_tokens;
            }
            Event::Error { error } => out.error = Some(error.to_string()),
            _ => {}
        }
    }
    out.secs = started.elapsed().as_secs_f64();
    if timed_out {
        out.end = "timeout".into();
    }

    let (pass, output) = check(&r.task.check, &r.workspace).await;
    out.pass = pass;
    out.check_output = output;
    Ok(out)
}

async fn check(cmd: &str, dir: &Path) -> (bool, String) {
    let child = tokio::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(cmd)
        .current_dir(dir)
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(Duration::from_secs(120), child).await {
        Ok(Ok(o)) => {
            let mut text = String::from_utf8_lossy(&o.stdout).into_owned();
            text.push_str(&String::from_utf8_lossy(&o.stderr));
            let text: String = text.chars().take(2000).collect();
            (o.status.success(), text)
        }
        Ok(Err(e)) => (false, format!("check failed to run: {e}")),
        Err(_) => (false, "check timed out".into()),
    }
}
