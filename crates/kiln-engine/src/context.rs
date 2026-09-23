//! Keeping the prompt inside the model's context window.
//!
//! Staged, cheapest first (arXiv 2609.20804, 2606.11213):
//! 1. Deterministic pruning: stale file reads, then old tool output, oldest first. No LLM call.
//! 2. LLM summarization, only when pruning isn't enough.
//!
//! Pruning rewrites the prompt prefix, which throws away provider-side prompt/KV caches, so it
//! runs with hysteresis: start at [`PRUNE_AT`] of the window and cut down to [`PRUNE_TO`], so it
//! happens rarely and in one big step.

use crate::message::{Block, Message};
use std::collections::HashMap;

/// Start pruning when the estimated prompt passes this fraction of the window…
pub const PRUNE_AT: f64 = 0.60;
/// …and prune down to this fraction.
pub const PRUNE_TO: f64 = 0.45;
/// If pruning can't get below this, summarize with the LLM.
pub const COMPACT_AT: f64 = 0.80;
/// The most recent tool results are never pruned.
pub const KEEP_RECENT: usize = 4;
/// Results smaller than this aren't worth pruning.
const MIN_PRUNE_CHARS: usize = 600;

/// Chars→tokens, calibrated against what the provider reports.
#[derive(Clone, Copy, Debug)]
pub struct Estimator {
    pub chars_per_token: f64,
}

impl Default for Estimator {
    fn default() -> Self {
        Self {
            chars_per_token: 3.5,
        }
    }
}

impl Estimator {
    pub fn tokens(&self, chars: usize) -> u64 {
        (chars as f64 / self.chars_per_token).ceil() as u64
    }

    pub fn chars(&self, tokens: u64) -> usize {
        (tokens as f64 * self.chars_per_token) as usize
    }

    /// Blend in an observation: `chars` were sent and the provider counted `tokens`.
    pub fn calibrate(&mut self, chars: usize, tokens: u64) {
        if tokens < 200 {
            return;
        }
        let observed = (chars as f64 / tokens as f64).clamp(1.5, 8.0);
        self.chars_per_token = 0.5 * self.chars_per_token + 0.5 * observed;
    }
}

pub fn block_chars(b: &Block) -> usize {
    match b {
        Block::Text { text } | Block::Thinking { text, .. } => text.len(),
        Block::ToolUse { name, input, .. } => name.len() + input.to_string().len(),
        Block::ToolResult { content, .. } => content.len(),
    }
}

pub fn history_chars(msgs: &[Message]) -> usize {
    msgs.iter().flat_map(|m| &m.content).map(block_chars).sum()
}

fn is_pruned(content: &str) -> bool {
    content.starts_with("[stale:") || content.contains("[… pruned ")
}

struct Result_<'a> {
    id: &'a str,
    name: &'a str,
    path: Option<&'a str>,
    len: usize,
    content: &'a str,
}

/// Which tool results to rewrite, and with what, so the history fits in `budget_chars`.
/// Stale reads go first, then everything but the last [`KEEP_RECENT`] results, oldest first.
pub fn plan_prune(msgs: &[Message], budget_chars: usize) -> Vec<(String, String)> {
    let mut total = history_chars(msgs);
    if total <= budget_chars {
        return Vec::new();
    }
    let inputs: HashMap<&str, &serde_json::Value> = msgs
        .iter()
        .flat_map(|m| &m.content)
        .filter_map(|b| match b {
            Block::ToolUse { id, input, .. } => Some((id.as_str(), input)),
            _ => None,
        })
        .collect();
    let results: Vec<Result_> = msgs
        .iter()
        .flat_map(|m| &m.content)
        .filter_map(|b| match b {
            Block::ToolResult {
                id, name, content, ..
            } => Some(Result_ {
                id,
                name,
                path: inputs
                    .get(id.as_str())
                    .and_then(|i| i["file_path"].as_str()),
                len: content.len(),
                content,
            }),
            _ => None,
        })
        // Loaded skills are standing instructions; trimming them silently degrades the agent.
        .filter(|r| r.name != crate::skills::TOOL)
        .collect();

    let mut plan: Vec<(String, String)> = Vec::new();
    let take =
        |r: &Result_, replacement: String, total: &mut usize, plan: &mut Vec<(String, String)>| {
            *total = total.saturating_sub(r.len.saturating_sub(replacement.len()));
            plan.push((r.id.to_string(), replacement));
        };

    // 1. A Read whose file was read, written, or edited again later is stale.
    for (i, r) in results.iter().enumerate() {
        if total <= budget_chars {
            break;
        }
        let (Some(path), "Read") = (r.path, r.name) else {
            continue;
        };
        if is_pruned(r.content) || r.len < MIN_PRUNE_CHARS {
            continue;
        }
        let later = results[i + 1..]
            .iter()
            .any(|l| l.path == Some(path) && matches!(l.name, "Read" | "Write" | "Edit"));
        if later {
            take(
                r,
                format!("[stale: {path} was read or modified again later; see the newer result]"),
                &mut total,
                &mut plan,
            );
        }
    }

    // 2. Old output, oldest first.
    let cutoff = results.len().saturating_sub(KEEP_RECENT);
    for r in &results[..cutoff] {
        if total <= budget_chars {
            break;
        }
        if is_pruned(r.content) || r.len < MIN_PRUNE_CHARS || plan.iter().any(|(id, _)| id == r.id)
        {
            continue;
        }
        let head: Vec<&str> = r.content.lines().take(3).collect();
        let rest = r.content.lines().count().saturating_sub(head.len());
        let replacement = format!(
            "{}\n[… pruned {rest} more lines to save context. Re-run the tool if you need them.]",
            head.join("\n")
        );
        take(r, replacement, &mut total, &mut plan);
    }
    plan
}

/// Rewrite the content of tool results by id.
pub fn apply(msgs: &mut [Message], id: &str, replacement: &str) {
    for b in msgs.iter_mut().flat_map(|m| &mut m.content) {
        if let Block::ToolResult {
            id: bid, content, ..
        } = b
            && bid == id
        {
            *content = replacement.to_string();
        }
    }
}

/// The user's own words, which a summary must not paraphrase away (arXiv 2606.22528,
/// 2608.22752). Keeps the first request plus as many recent ones as fit in `cap` chars.
pub fn pinned_inputs(inputs: &[String], cap: usize) -> Vec<String> {
    let clip = |s: &str| -> String {
        if s.len() > 2000 {
            format!("{}…", &s[..s.floor_char_boundary(2000)])
        } else {
            s.to_string()
        }
    };
    let Some(first) = inputs.first() else {
        return Vec::new();
    };
    let mut used = first.len().min(2000);
    let mut recent: Vec<String> = Vec::new();
    for s in inputs[1..].iter().rev() {
        let s = clip(s);
        if used + s.len() > cap {
            break;
        }
        used += s.len();
        recent.push(s);
    }
    recent.reverse();
    let skipped = inputs.len() - 1 - recent.len();
    let mut out = vec![clip(first)];
    if skipped > 0 {
        out.push(format!("[{skipped} earlier messages omitted]"));
    }
    out.extend(recent);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::Role;
    use serde_json::json;

    fn call(id: &str, name: &str, path: &str) -> Message {
        Message {
            role: Role::Assistant,
            content: vec![Block::ToolUse {
                id: id.into(),
                name: name.into(),
                input: json!({ "file_path": path }),
            }],
        }
    }

    fn result(id: &str, name: &str, len: usize) -> Message {
        let content = (0..len / 10)
            .map(|i| format!("line {i:04}\n"))
            .collect::<String>();
        Message {
            role: Role::User,
            content: vec![Block::ToolResult {
                id: id.into(),
                name: name.into(),
                content,
                is_error: false,
            }],
        }
    }

    fn history() -> Vec<Message> {
        let mut h = vec![Message::user("start")];
        // a.rs read twice; the first read is stale.
        h.extend([call("r1", "Read", "a.rs"), result("r1", "Read", 5000)]);
        h.extend([call("b1", "Bash", ""), result("b1", "Bash", 5000)]);
        h.extend([call("r2", "Read", "a.rs"), result("r2", "Read", 5000)]);
        for i in 0..4 {
            let id = format!("k{i}");
            h.extend([call(&id, "Bash", ""), result(&id, "Bash", 5000)]);
        }
        h
    }

    #[test]
    fn nothing_to_do_under_budget() {
        assert!(plan_prune(&history(), 1_000_000).is_empty());
    }

    #[test]
    fn stale_reads_go_first_then_oldest_and_recent_are_kept() {
        let h = history();
        let total = history_chars(&h);
        // Just enough pressure to prune one result.
        let plan = plan_prune(&h, total - 1000);
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].0, "r1");
        assert!(plan[0].1.starts_with("[stale: a.rs"));

        // Heavy pressure: everything prunable goes, but the last KEEP_RECENT never do.
        let plan = plan_prune(&h, 0);
        let ids: Vec<&str> = plan.iter().map(|(id, _)| id.as_str()).collect();
        assert_eq!(ids, ["r1", "b1", "r2"]);
    }

    #[test]
    fn applied_plan_fits_and_is_idempotent() {
        let mut h = history();
        let budget = history_chars(&h) - 8000;
        for (id, rep) in plan_prune(&h, budget) {
            apply(&mut h, &id, &rep);
        }
        assert!(history_chars(&h) <= budget);
        assert!(plan_prune(&h, budget).is_empty());
    }

    #[test]
    fn pinned_inputs_keep_first_and_recent() {
        let inputs: Vec<String> = (0..10)
            .map(|i| format!("msg{i} {}", "x".repeat(100)))
            .collect();
        let p = pinned_inputs(&inputs, 400);
        assert!(p[0].starts_with("msg0"));
        assert!(p[1].contains("omitted"));
        assert!(p.last().unwrap().starts_with("msg9"));
    }

    #[test]
    fn calibration_moves_toward_observation() {
        let mut e = Estimator::default();
        e.calibrate(40_000, 10_000);
        assert!(e.chars_per_token > 3.5 && e.chars_per_token < 4.0);
    }
}
