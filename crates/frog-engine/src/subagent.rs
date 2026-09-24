//! Subagents: a `Task` hands a self-contained investigation to a child engine with its own
//! context. The child can only read (Read, Grep, Glob, CodeMap, ...), and the parent sees only
//! its final report, so a search through fifty files costs the parent a few hundred tokens
//! (context folding, arXiv 2510.11967). The child's events stream to clients as
//! `Event::Subagent` for a live view, and a client can stop it without stopping the parent.

use crate::engine::{Handle, Options};
use crate::protocol::{Delta, Event, Item, ItemKind, Op};
use crate::provider::ToolSpec;
use crate::tools::Output;
use anyhow::{Result, bail};
use serde_json::Value;
use tokio_util::sync::CancellationToken;

pub const TOOL: &str = "Task";

/// Steps a subagent may take before it has to report.
pub const MAX_STEPS: u32 = 30;

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Delegate a self-contained, read-only investigation to a subagent with its own context: finding where something is implemented, tracing how a feature works across many files, surveying a codebase. It can Read, Grep, Glob and CodeMap but can't edit files or run commands. It can't see this conversation, so put everything it needs in `prompt`. Only its final report comes back, which keeps your own context small. Prefer it over doing many searches yourself.".into(),
        schema: serde_json::json!({
            "type": "object",
            "properties": {
                "description": {"type": "string", "description": "A short label (3-6 words) for the task"},
                "prompt": {"type": "string", "description": "The full task: what to find out and what to report"}
            },
            "required": ["description", "prompt"]
        }),
    }
}

/// Appended to a subagent's system prompt.
pub const PROMPT: &str = "\n\n# You are a subagent\nAnother agent delegated one task to you. You can only read: you can't edit files or run commands. Work efficiently: search before reading, and read only what you need. When you're done, reply with a concise report that answers the task directly, citing files as path:line. Your report is the only thing the other agent will see, so include every finding it needs and nothing else.";

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
    forward: impl Fn(Event),
) -> Result<Output> {
    let prompt = input["prompt"].as_str().unwrap_or("").trim().to_string();
    if prompt.is_empty() {
        bail!("`prompt` is required: describe the task in full");
    }
    let mut child = Child(crate::engine::spawn(opts)?);
    child.0.ops.send(Op::Submit {
        text: prompt,
        images: Vec::new(),
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
            event => forward(event),
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
