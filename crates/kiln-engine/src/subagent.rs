//! Subagents: a `Task` hands a self-contained investigation to a child engine with its own
//! context. The child can only read (Read, Grep, Glob, CodeMap, ...), and the parent sees only
//! its final report, so a search through fifty files costs the parent a few hundred tokens
//! (context folding, arXiv 2510.11967). The child's steps stream into the parent's tool card.

use crate::engine::{Handle, Options};
use crate::protocol::{Event, Item, ItemKind, Op};
use crate::provider::ToolSpec;
use crate::tools::Output;
use anyhow::{Result, bail};
use serde_json::Value;

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

/// Run a subagent to completion. `progress` gets a line per step, for the live view.
pub async fn run(opts: Options, input: &Value, progress: impl Fn(String)) -> Result<Output> {
    let prompt = input["prompt"].as_str().unwrap_or("").trim().to_string();
    if prompt.is_empty() {
        bail!("`prompt` is required: describe the task in full");
    }
    let mut child = Child(crate::engine::spawn(opts)?);
    child.0.ops.send(Op::Submit { text: prompt })?;
    let (mut report, mut steps, mut started) = (String::new(), 0u32, false);
    while let Some(env) = child.0.events.recv().await {
        match env.event {
            Event::TurnStarted { .. } => started = true,
            Event::ItemStarted {
                kind: ItemKind::ToolCall { name, arg },
                ..
            } => {
                steps += 1;
                progress(format!("{name} {arg}\n"));
            }
            Event::ItemCompleted {
                item: Item::Message { text },
                ..
            } => report = text,
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
            _ => {}
        }
    }
    let plural = if steps == 1 { "" } else { "s" };
    Ok(Output {
        display: Some(format!("{report}\n\n({steps} step{plural})")),
        content: report,
        ..Default::default()
    })
}
