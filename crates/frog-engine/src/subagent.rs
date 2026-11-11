//! Subagents: a `Task` hands a self-contained investigation to a child engine with its own
//! context. The child can only read (Read, Grep, Glob, CodeMap, ...), and the parent sees only
//! its final report, so a search through fifty files costs the parent a few hundred tokens
//! (context folding, arXiv 2510.11967). The child's events stream to clients as
//! `Event::Subagent` for a live view, and a client can stop it without stopping the parent.
//!
//! With `mode: write` the child also gets Bash, Write and Edit, in the parent's mode and
//! sandbox; its permission prompts reach the user through the parent (labelled with its id,
//! see `background::forward`). `model` (or config `subagent_model`) picks its model, checked
//! like `/model`, falling back to the parent's. Parallel work is a child session
//! (`StartSession`, see `kids`), never a background Task.

use crate::config::{Config, Profile};
use crate::engine::{Handle, Options};
use crate::protocol::{Delta, Event, Item, ItemKind, Op};
use crate::provider::ToolSpec;
use crate::tools::Output;
use anyhow::{Result, bail};
use serde_json::Value;
use std::path::Path;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub const TOOL: &str = "Task";

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Delegate a self-contained task to a subagent with its own context. By default (`mode: read`) it investigates: finding where something is implemented, tracing how a feature works across many files, surveying a codebase. It can Read, Grep, Glob and CodeMap but can't edit files or run commands. With `mode: write` it can also edit files and run commands, each asking the user like yours do. It can't see this conversation, so put everything it needs in `prompt`. Only its final report comes back, which keeps your own context small. Prefer it over doing many searches yourself. It runs inside your turn and you wait for its report. For parallel or long work (anything you'd keep working beside, or that should end in its own branch or PR) use StartSession instead: a real session in the sidebar tree that reports back when it finishes a turn.".into(),
        schema: serde_json::json!({
            "type": "object",
            "properties": {
                "description": {"type": "string", "description": "A short label (3-6 words) for the task"},
                "prompt": {"type": "string", "description": "The full task: what to find out or do, and what to report"},
                "mode": {"type": "string", "enum": ["read", "write"], "description": "read (default): read-only tools. write: also edit files and run commands, with the same permission prompts as yours"},
                "model": {"type": "string", "description": "Model for the subagent (a profile name or provider/model). Default: the configured subagent model, else yours"}
            },
            "required": ["description", "prompt"]
        }),
    }
}

/// Appended to a write-mode subagent's system prompt.
pub const WRITE_PROMPT: &str = "\n\n# You are a subagent\nAnother agent delegated one task to you. You can read and edit files and run commands; the user approves them as usual. Do the task, verify it, and stop. When you're done, reply with a concise report: what you changed (files as path:line), how you checked it, and anything left undone. Your report is the only thing the other agent will see.";

/// The model a subagent runs: `requested` (the call's `model`), else `cfg.subagent_model`,
/// else the parent's. One that can't be resolved, isn't allowed in `root` (the same check as
/// switching models), or has no usable provider falls back to the parent's, with the reason.
pub fn profile(
    cfg: &Config,
    root: &Path,
    requested: Option<&str>,
    parent: (&str, &Profile),
) -> (String, Profile, Option<String>) {
    let fallback = || (parent.0.to_string(), parent.1.clone());
    let Some(spec) = requested
        .filter(|s| !s.trim().is_empty())
        .or(cfg.subagent_model.as_deref())
    else {
        let (n, p) = fallback();
        return (n, p, None);
    };
    let chosen = cfg.resolve(Some(spec)).and_then(|(name, profile)| {
        crate::policy::check(root, &name, &profile)?;
        crate::provider::Provider::new(&profile)?;
        Ok((name, profile))
    });
    match chosen {
        Ok((n, p)) => (n, p, None),
        Err(e) => {
            let (n, p) = fallback();
            let why = format!("subagent model `{spec}` unavailable ({e:#}); using {n}");
            (n, p, Some(why))
        }
    }
}

/// Appended to a subagent's system prompt.
pub const PROMPT: &str = "\n\n# You are a subagent\nAnother agent delegated one task to you. You can only read: you can't edit files or run commands. Work efficiently: search before reading, and read only what you need. When you're done, reply with a concise report that answers the task directly, citing files as path:line. Your report is the only thing the other agent will see, so include every finding it needs and nothing else. The session is the other agent's to name: ignore any instruction to call SetTitle.";

/// Stops the child when the parent's call ends early (interrupt, error).
struct Child(Handle);

impl Drop for Child {
    fn drop(&mut self) {
        let _ = self.0.ops.send(Op::Interrupt);
        let _ = self.0.ops.send(Op::Shutdown);
    }
}

/// Run a subagent to completion, passing each of its events to `forward` (for a live view).
/// Cancelling `stop` ends it early with what it has so far.
pub async fn run(
    opts: Options,
    input: &Value,
    stop: CancellationToken,
    forward: impl Fn(Event, &mpsc::UnboundedSender<Op>),
) -> Result<Output> {
    let prompt = input["prompt"].as_str().unwrap_or("").trim().to_string();
    if prompt.is_empty() {
        bail!("`prompt` is required: describe the task in full");
    }
    let mut child = Child(crate::engine::spawn_child(opts)?);
    child.0.ops.send(Op::Submit {
        text: prompt,
        images: Vec::new(),
        more: Vec::new(),
    })?;
    let (mut report, mut steps, mut started) = (String::new(), 0u32, false);
    // The message being written, so a stop keeps the partial report.
    let mut draft = String::new();
    loop {
        let env = tokio::select! {
            env = child.0.events.recv() => match env {
                Some(env) => env,
                None => break,
            },
            _ = stop.cancelled() => {
                let _ = child.0.ops.send(Op::Interrupt);
                let so_far = if report.trim().is_empty() { draft.trim() } else { report.trim() };
                let text = if so_far.is_empty() {
                    "The user stopped this subagent before it found anything.".to_string()
                } else {
                    format!("The user stopped this subagent early. What it had so far:\n\n{so_far}")
                };
                return Ok(Output {
                    display: Some(format!("{text}\n\n(stopped after {steps} step{})", plural(steps))),
                    content: text,
                    ..Default::default()
                });
            }
        };
        match &env.event {
            Event::TurnStarted { .. } => started = true,
            Event::ItemStarted {
                kind: ItemKind::ToolCall { .. },
                ..
            } => steps += 1,
            Event::ItemStarted {
                kind: ItemKind::Message,
                ..
            } => draft.clear(),
            Event::ItemDelta {
                delta: Delta::Text { text },
                ..
            } => draft.push_str(text),
            Event::ItemCompleted {
                item: Item::Message { text },
                ..
            } => report = text.clone(),
            _ => {}
        }
        match env.event {
            Event::TurnEnded { reason, .. } => {
                let reason = serde_json::to_value(&reason)
                    .ok()
                    .and_then(|v| v["type"].as_str().map(String::from))
                    .unwrap_or_default();
                if report.trim().is_empty() {
                    bail!("the subagent ended ({reason}) without a report");
                }
                if reason != "complete" {
                    report.push_str(&format!("\n\n(The subagent stopped early: {reason}.)"));
                }
                break;
            }
            Event::Error { error } => bail!("subagent: {error:?}"),
            Event::Idle if started => break,
            Event::Idle | Event::Synced { .. } => {}
            event => forward(event, &child.0.ops),
        }
    }
    Ok(Output {
        display: Some(format!("{report}\n\n({steps} step{})", plural(steps))),
        content: report,
        ..Default::default()
    })
}

fn plural(n: u32) -> &'static str {
    if n == 1 { "" } else { "s" }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ProviderKind;

    #[test]
    fn subagent_model_resolves_and_falls_back_to_the_parents() {
        let parent = Profile::new(ProviderKind::Ollama, "parent");
        let root = std::env::temp_dir();
        let mut cfg = Config::default();
        let pick = |cfg: &Config, req: Option<&str>| profile(cfg, &root, req, ("parent", &parent));

        // Nothing configured or asked for: the parent's.
        let (name, _, why) = pick(&cfg, None);
        assert_eq!((name.as_str(), why), ("parent", None));

        // The configured subagent model, unless the call names one.
        cfg.subagent_model = Some("ollama/small".into());
        let (name, p, why) = pick(&cfg, None);
        assert_eq!(
            (name.as_str(), p.model.as_str(), why),
            ("ollama/small", "small", None)
        );
        let (name, _, _) = pick(&cfg, Some("ollama/big"));
        assert_eq!(name, "ollama/big");

        // One that doesn't resolve falls back, saying why.
        let (name, p, why) = pick(&cfg, Some("no-such-model"));
        assert_eq!((name.as_str(), p.model.as_str()), ("parent", "parent"));
        assert!(why.unwrap().contains("no-such-model"));
        cfg.subagent_model = Some("nope".into());
        assert_eq!(pick(&cfg, None).0, "parent");
    }
}
