//! Keeping the prompt inside the model's context window.
//!
//! Staged, cheapest first (arXiv 2609.20804, 2606.11213):
//! 1. Deterministic pruning: stale file reads, then old tool output, oldest first. No LLM call.
//! 2. LLM summarization, only when pruning isn't enough.
//!
//! Pruning rewrites the prompt prefix, which throws away provider-side prompt/KV caches, so it
//! runs with hysteresis: start at [`PRUNE_AT`] of the window and cut down to [`PRUNE_TO`], so it
//! happens rarely and in one big step. And between turns: once a turn ends, with the result
//! warmed in the background, so no turn pays to prefill it. Inside a turn it waits until
//! [`COMPACT_AT`].

use crate::message::{Block, Message, Role};
use serde_json::Value;
use std::collections::HashMap;

/// Start pruning when the estimated prompt passes this fraction of the window…
pub const PRUNE_AT: f64 = 0.60;
/// …and prune down to this fraction.
pub const PRUNE_TO: f64 = 0.45;
/// If pruning can't get below this, summarize with the LLM.
pub const COMPACT_AT: f64 = 0.80;
/// The estimate is calibrated from server-reported counts and the provider's limit is real: past
/// this fraction, compact now rather than risk one big tool result blowing the window on the next
/// call. [`KEEP_RECENT`] results are never pruned, so they can still cross it — the overflow
/// recovery in the engine handles that.
pub const HARD_LIMIT: f64 = 0.92;
/// The largest share of the window one tool result may occupy: a single oversized result can't
/// overflow the window (and, being recent, would never be pruned).
pub const MAX_RESULT_SHARE: f64 = 0.25;
/// The most recent tool results are never pruned.
pub const KEEP_RECENT: usize = 4;
/// Results smaller than this aren't worth pruning.
const MIN_PRUNE_CHARS: usize = 600;
/// The share of the window a local model's reply leaves unused, for the prompt estimate being
/// off (it's calibrated from counts a server may itself estimate).
pub const REPLY_MARGIN: f64 = 0.10;
/// The shortest reply worth asking for, even when the prompt has nearly filled the window.
pub const MIN_REPLY: u64 = 256;

/// How long a reply may be. The window holds the reply as well as the prompt, and a server told
/// no limit lets a rambling reply run until the window overflows (Apple's on-device model fails
/// at 8193 of 8192 tokens). What's left of `window` after `prompt`, less [`REPLY_MARGIN`] of the
/// window, at least [`MIN_REPLY`], and never more than a configured `cap`.
pub fn reply_budget(window: u64, prompt: u64, cap: Option<u32>) -> u32 {
    let margin = (window as f64 * REPLY_MARGIN) as u64;
    let room = window.saturating_sub(prompt + margin).max(MIN_REPLY);
    let room = u32::try_from(room).unwrap_or(u32::MAX);
    cap.map_or(room, |c| c.min(room))
}

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
        // What a model is charged for an image (~1.5k tokens), not its base64 size.
        Block::Image { .. } => 6_000,
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

/// Deterministic last resort before a summarization call that would itself overflow: clip every
/// oversized tool result — including the recent ones `plan_prune` keeps — down to `budget_chars`
/// apiece. What the window can never hold is trimmed so the summary request fits.
pub fn plan_emergency(msgs: &[Message], budget_chars: usize) -> Vec<(String, String)> {
    msgs.iter()
        .flat_map(|m| &m.content)
        .filter_map(|b| match b {
            Block::ToolResult {
                id, content, name, ..
            } if content.len() > budget_chars.max(MIN_PRUNE_CHARS) && *name != crate::skills::TOOL => {
                Some((id.clone(), truncate_oldest(content, budget_chars)))
            }
            _ => None,
        })
        .collect()
}

/// The head of `s` up to `budget_chars`, with a marker.
fn truncate_oldest(s: &str, budget_chars: usize) -> String {
    let cut = s.floor_char_boundary(budget_chars);
    format!(
        "{}\n[… clipped, {} of {} bytes cut to fit the context window …]",
        &s[..cut],
        s.len() - cut,
        s.len()
    )
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
/// 2608.22752). Keeps the first request plus as many recent ones as fit in `cap` bytes.
pub fn pinned_inputs(inputs: &[String], cap: usize) -> Vec<String> {
    if cap == 0 {
        return Vec::new();
    }
    let Some(first) = inputs.first() else {
        return Vec::new();
    };
    // The first request defines the task. Do not discard its later constraints
    // at an arbitrary 2K boundary when the pin budget can preserve it verbatim.
    let first = clip(first, cap);
    let mut used = first.len();
    let mut recent: Vec<String> = Vec::new();
    for s in inputs[1..].iter().rev() {
        let s = clip(s, cap.min(2000));
        if used + s.len() > cap {
            break;
        }
        used += s.len();
        recent.push(s);
    }
    recent.reverse();
    let skipped = inputs.len() - 1 - recent.len();
    let mut out = vec![first];
    if skipped > 0 {
        out.push(format!("[{skipped} earlier messages omitted]"));
    }
    out.extend(recent);
    out
}

/// Cap what a record field's text is clipped to, counting the labels.
const RECORD_FIELD_CAP: usize = 2_400;
/// A record list never grows past this many items.
const RECORD_LIST_CAP: usize = 64;
/// However big the window, the rendered record never exceeds this.
const RECORD_RENDER_CAP: usize = 16_000;

/// The engine's compacted message starts with this (see `Engine::compact`).
pub const COMPACTION_LABEL: &str = "(The earlier part of this session was compacted";

const L_INPUTS: &str = "User requests (verbatim, constraints still apply):";
const L_FILES: &str = "Files read (* = edited):";
const L_TODOS: &str = "Task list (latest):";
const L_COMMANDS: &str = "Commands run (oldest first):";
const L_CALLS: &str = "Tool calls:";
const L_PINNED: &str = "Kept verbatim (errors, the last request):";

/// What compaction keeps verbatim outside the model's prose summary. Structured fields, so
/// repeated compactions recover the same bounded record instead of degrading into a summary
/// of a summary. Each field is clipped on the way in ([`RECORD_FIELD_CAP`]) so re-rendering
/// is stable.
#[derive(Default)]
pub struct Record {
    /// The user's requests, verbatim (already capped by [`pinned_inputs`]).
    pub inputs: Vec<String>,
    /// Files read or written this session, an edit marker on the latest state of each:
    /// `path` when it was last read, `path*` when last written. Distinct, first-seen order.
    pub files: Vec<String>,
    /// The latest task list from TodoWrite, each as `☐ content` / `◐` / `☒`.
    pub todos: Vec<String>,
    /// Commands that ran (the head of each, marked `!`), oldest first.
    pub commands: Vec<String>,
    /// Other tool calls with their key arguments, for the calls whose result exceeded
    /// [`MIN_PRUNE_CHARS`]: `name(pattern: … | query: …)`. Distinct, first-seen order.
    pub calls: Vec<String>,
    /// Verbatim text the summary must not paraphrase away: outstanding errors,
    /// and the last request.
    pub pinned: Vec<String>,
}

/// An open TodoWrite list, one string per item, so a summary records it without
/// re-deriving markdown.
fn todo_list(todos: &[crate::tools::todo::Todo]) -> Vec<String> {
    todos
        .iter()
        .map(|t| {
            let mark = match t.status.as_str() {
                "completed" => "☒",
                "in_progress" => "◐",
                _ => "☐",
            };
            format!("{mark} {}", t.content)
        })
        .collect()
}

/// The arguments worth recording for a tool call: a few scalar keys.
fn call_args(input: &serde_json::Value) -> Vec<String> {
    const KEYS: [&str; 8] = [
        "pattern", "path", "query", "url", "command", "file_path", "todo_path", "prompt",
    ];
    let mut out = Vec::new();
    for k in KEYS {
        if let Some(s) = input[k].as_str()
            && !s.is_empty()
        {
            out.push(format!("{k}: {s}"));
            if out.len() >= 3 {
                return out;
            }
        }
    }
    out
}

/// Distinct in first-seen order, capped.
fn push_capped(list: &mut Vec<String>, item: String) {
    if list.len() < RECORD_LIST_CAP && !list.contains(&item) {
        list.push(item);
    }
}

/// Clip `s` to `limit` bytes on a char boundary, with an ellipsis.
fn clip(s: &str, limit: usize) -> String {
    if s.len() > limit && limit >= 3 {
        format!("{}…", &s[..s.floor_char_boundary(limit - 3)])
    } else {
        s[..s.floor_char_boundary(s.len().min(limit))].to_string()
    }
}

/// Build the record carried across compactions. Any record an earlier compaction rendered
/// into the history is parsed back and folded in, so a repeated compaction keeps the union
/// of files, calls and commands, the latest todos, the outstanding errors, and the user's
/// requests — everything the prose summary might have paraphrased away.
pub fn pinned_record(
    inputs: &[String],
    todos: &[crate::tools::todo::Todo],
    messages: &[Message],
) -> Record {
    let mut rec = parse_record(messages);
    // Live state replaces what was folded in.
    rec.inputs = pinned_inputs(inputs, 8_000);
    rec.todos = todo_list(todos);
    // Errors carried from before, then this stretch's, oldest first.
    rec.pinned.retain(|p| p.starts_with("[error]"));
    for p in pinned_text(messages) {
        push_capped(&mut rec.pinned, p);
    }
    // The calls and results in this stretch.
    let mut uses: HashMap<&str, (&str, &Value)> = HashMap::new();
    let mut results: HashMap<&str, &str> = HashMap::new();
    for m in messages {
        for b in &m.content {
            match b {
                Block::ToolUse { id, name, input } => {
                    uses.insert(id.as_str(), (name.as_str(), input));
                }
                Block::ToolResult { id, content, .. } => {
                    results.insert(id.as_str(), content.as_str());
                }
                _ => {}
            }
        }
    }
    for m in messages {
        for b in &m.content {
            let Block::ToolResult { id, name, .. } = b else {
                continue;
            };
            let Some(result) = results.get(id.as_str()) else {
                continue;
            };
            let Some((cname, input)) = uses.get(id.as_str()) else {
                continue;
            };
            let (cname, input) = (*cname, *input);
            match name.as_str() {
                "TodoWrite" => {}
                "Read" | "Write" | "Edit" => {
                    if let Some(path) = input["file_path"].as_str() {
                        // The marker tracks the latest state of the file.
                        let (keep, drop) = if name == "Read" {
                            (path.to_string(), format!("{path}*"))
                        } else {
                            (format!("{path}*"), path.to_string())
                        };
                        rec.files.retain(|f| f != &drop);
                        push_capped(&mut rec.files, keep);
                    }
                }
                "Bash" | crate::panes::TERMINAL => {
                    if let Some(cmd) = input["command"].as_str() {
                        let head: Vec<&str> = cmd.lines().take(2).collect();
                        let head = head.join(" ").trim().to_string();
                        if !head.is_empty() {
                            push_capped(&mut rec.commands, format!("! {head}"));
                        }
                    }
                }
                _ => {
                    if result.len() >= MIN_PRUNE_CHARS {
                        let args = call_args(input);
                        if !args.is_empty() {
                            push_capped(&mut rec.calls, format!("{cname}({})", args.join(" | ")));
                        }
                    }
                }
            }
        }
    }
    rec
}

/// Verbatim text that must survive: the first two lines of each error result, plus the
/// last user text before compaction.
fn pinned_text(messages: &[Message]) -> Vec<String> {
    let mut out = Vec::new();
    for m in messages.iter().rev() {
        for b in &m.content {
            if let Block::ToolResult { content, is_error, .. } = b
                && *is_error
            {
                let head: Vec<&str> = content.lines().take(2).collect();
                let head = head.join(" ").trim().to_string();
                if !head.is_empty() {
                    push_capped(&mut out, format!("[error] {head}"));
                }
            }
        }
    }
    out.reverse();
    if let Some(last) = messages
        .iter()
        .rev()
        .find_map(|m| {
            (m.role == Role::User && !m.content.is_empty())
                .then(|| m.text())
                // The earlier compacted message is a bookend, not a request.
                .filter(|t| !t.trim().is_empty() && !t.starts_with(COMPACTION_LABEL))
        })
    {
        let last = last.lines().take(4).collect::<Vec<_>>().join(" ");
        let last = last.trim().to_string();
        if !last.is_empty() {
            push_capped(&mut out, clip(&last, RECORD_FIELD_CAP));
        }
    }
    out
}

/// Recover a record an earlier compaction rendered into the history. The inverse of
/// [`render_record`]: a label opens a list, `  - ` starts an item, any other non-blank line
/// continues the previous item.
fn parse_record(messages: &[Message]) -> Record {
    enum Sec {
        Inputs,
        Files,
        Todos,
        Commands,
        Calls,
        Pinned,
    }
    let label = |l: &str| match l.trim() {
        L_INPUTS => Some(Sec::Inputs),
        L_FILES => Some(Sec::Files),
        L_TODOS => Some(Sec::Todos),
        L_COMMANDS => Some(Sec::Commands),
        L_CALLS => Some(Sec::Calls),
        L_PINNED => Some(Sec::Pinned),
        _ => None,
    };
    let mut rec = Record::default();
    // (where to push, the item being built)
    let mut cur: Option<(Sec, Vec<String>)> = None;
    let flush = |cur: &mut Option<(Sec, Vec<String>)>, rec: &mut Record| {
        if let Some((sec, items)) = cur.take() {
            let list = match sec {
                Sec::Inputs => &mut rec.inputs,
                Sec::Files => &mut rec.files,
                Sec::Todos => &mut rec.todos,
                Sec::Commands => &mut rec.commands,
                Sec::Calls => &mut rec.calls,
                Sec::Pinned => &mut rec.pinned,
            };
            for i in items {
                push_capped(list, i);
            }
        }
    };
    for m in messages {
        for b in &m.content {
            let Block::Text { text } = b else { continue };
            for line in text.lines() {
                if let Some(sec) = label(line) {
                    flush(&mut cur, &mut rec);
                    cur = Some((sec, Vec::new()));
                } else if let Some(item) = line.strip_prefix("  - ") {
                    if let Some((_, items)) = cur.as_mut() {
                        items.push(item.to_string());
                    }
                } else if !line.trim().is_empty()
                    && let Some((_, items)) = cur.as_mut()
                    && let Some(last) = items.last_mut()
                {
                    last.push('\n');
                    last.push_str(line.trim_start());
                }
            }
        }
    }
    flush(&mut cur, &mut rec);
    rec
}

/// Render the record as the text the model reads after compaction, within `budget` bytes:
/// least important lists (commands, calls, files) shed their oldest items first, and the
/// user's requests are kept to the last. The result parses back with [`parse_record`].
pub fn render_record(r: &Record, budget: usize) -> String {
    let budget = budget.clamp(1_000, RECORD_RENDER_CAP);
    let item = |i: &String| clip(i, RECORD_FIELD_CAP);
    // (label, items, trim rank): lower rank sheds items first.
    let mut secs: Vec<(&str, Vec<String>, u8)> = vec![
        (L_INPUTS, r.inputs.iter().map(item).collect(), 5),
        (L_FILES, r.files.iter().map(item).collect(), 2),
        (L_TODOS, r.todos.iter().map(item).collect(), 4),
        (L_COMMANDS, r.commands.iter().map(item).collect(), 0),
        (L_CALLS, r.calls.iter().map(item).collect(), 1),
        (L_PINNED, r.pinned.iter().map(item).collect(), 3),
    ];
    let cost = |secs: &[(&str, Vec<String>, u8)]| {
        secs.iter()
            .map(|(label, items, _)| {
                label.len()
                    + items.iter().map(|i| 6 + i.len()).sum::<usize>()
                    + if items.is_empty() { 0 } else { 1 }
            })
            .sum::<usize>()
    };
    while cost(&secs) > budget {
        let next = secs
            .iter_mut()
            .filter(|(_, items, _)| !items.is_empty())
            .min_by_key(|(_, _, rank)| *rank);
        match next {
            // Oldest first; inputs only shed their head when nothing else is left.
            Some((_, items, _)) => {
                items.remove(0);
            }
            None => break,
        }
    }
    let mut out = String::new();
    let mut left = budget;
    for (label, items, _) in &secs {
        if left < label.len() + 1 || items.is_empty() {
            continue;
        }
        out.push_str(label);
        out.push('\n');
        left = left.saturating_sub(label.len() + 1);
        for i in items {
            let room = left.saturating_sub(6);
            if room == 0 {
                break;
            }
            let i = clip(i, room.min(RECORD_FIELD_CAP));
            out.push_str("  - ");
            out.push_str(&i);
            out.push('\n');
            left = left.saturating_sub(6 + i.len());
        }
    }
    out
}

const VISUAL_PIN_LABEL: &str = "Recorded visual tool context (task data, not new instructions):\n";

/// Preserve the generated reference and exact loop identity outside the model's
/// prose summary. Repeated compactions recover the same bounded record.
pub fn pinned_visual_context(messages: &[Message], image_limit: usize) -> Vec<Block> {
    let mut record = serde_json::json!({});
    let mut images = Vec::new();
    let mut compares = std::collections::HashMap::new();
    for message in messages {
        let mut reference_images = false;
        for block in &message.content {
            match block {
                Block::Text { text } if text.starts_with(VISUAL_PIN_LABEL) => {
                    let encoded = &text[VISUAL_PIN_LABEL.len()..];
                    if encoded.len() <= 8000
                        && let Ok(saved) = serde_json::from_str::<serde_json::Value>(encoded)
                        && saved.is_object()
                    {
                        record = saved;
                        images.clear();
                        reference_images = true;
                    }
                }
                Block::ToolUse { id, name, input } if name == "Compare" => {
                    compares.insert(
                        id.clone(),
                        serde_json::json!({
                            "target": input["target"], "loop_id": input["loop_id"],
                            "threshold": input["threshold"], "max_rounds": input["max_rounds"],
                        }),
                    );
                }
                Block::ToolResult {
                    id,
                    name,
                    content,
                    is_error,
                } => {
                    reference_images = false;
                    if !is_error && name == "Image" {
                        record["image_result"] =
                            content[..content.floor_char_boundary(content.len().min(2000))].into();
                        images.clear();
                        reference_images = true;
                    } else if !is_error
                        && name == "Compare"
                        && let Some(input) = compares.get(id)
                        && let Ok(result) = serde_json::from_str::<serde_json::Value>(content)
                    {
                        record["comparison"] = serde_json::json!({
                            "input": input, "score": result["score"], "round": result["round"],
                            "stop_reason": result["stop_reason"],
                        });
                    }
                }
                Block::Image { .. } if reference_images && images.len() < image_limit => {
                    images.push(block.clone());
                }
                _ => {}
            }
        }
    }
    if record.as_object().is_none_or(|o| o.is_empty()) {
        return Vec::new();
    }
    let encoded = record.to_string();
    if encoded.len() > 8000 {
        // Never pin a truncated JSON record or make compaction grow without bound.
        return Vec::new();
    }
    let mut pinned = vec![Block::Text {
        text: format!("{VISUAL_PIN_LABEL}{encoded}"),
    }];
    pinned.extend(images);
    pinned
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_reply_fits_what_the_prompt_leaves_of_an_8k_window() {
        // Apple's on-device model: 8192 tokens for prompt and reply together.
        let window = 8192;
        // A prompt right at the compaction line leaves ~800 for the reply, and prompt + reply
        // stays a tenth under the window.
        let prompt = (window as f64 * COMPACT_AT) as u64;
        let reply = reply_budget(window, prompt, None) as u64;
        assert!(reply >= MIN_REPLY);
        assert!(prompt + reply <= window - (window as f64 * REPLY_MARGIN) as u64);
        // A configured limit still wins when it's tighter.
        assert_eq!(reply_budget(window, 1000, Some(512)), 512);
        // An over-full prompt still gets a short reply rather than zero or an underflow.
        assert_eq!(reply_budget(window, 9000, None) as u64, MIN_REPLY);
        // A big window leaves a big reply.
        assert_eq!(reply_budget(131_072, 1000, None), 131_072 - 1000 - 13_107);
    }

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
    fn visual_context_keeps_the_reference_and_loop_across_repeated_compactions() {
        let mut messages = vec![
            Message {
                role: Role::User,
                content: vec![
                    Block::ToolResult {
                        id: "image".into(),
                        name: "Image".into(),
                        content: "Saved assets: /project/assets/target.png".into(),
                        is_error: false,
                    },
                    Block::Image {
                        mime: "image/png".into(),
                        data: "reference".into(),
                    },
                ],
            },
            Message {
                role: Role::Assistant,
                content: vec![Block::ToolUse {
                    id: "compare".into(),
                    name: "Compare".into(),
                    input: serde_json::json!({"target":"/project/assets/target.png","actual":"round-2.png","loop_id":"bench","threshold":85,"max_rounds":6}),
                }],
            },
            Message {
                role: Role::User,
                content: vec![
                    Block::ToolResult {
                        id: "compare".into(),
                        name: "Compare".into(),
                        content: "{\"score\":60,\"round\":2,\"stop_reason\":\"continue\"}".into(),
                        is_error: false,
                    },
                    Block::ToolResult {
                        id: "capture".into(),
                        name: "Screenshot".into(),
                        content: "Captured round-2.png".into(),
                        is_error: false,
                    },
                    Block::Image {
                        mime: "image/png".into(),
                        data: "implementation".into(),
                    },
                ],
            },
        ];
        let pinned = pinned_visual_context(&messages, 1);
        assert_eq!(pinned.len(), 2);
        assert!(matches!(&pinned[1], Block::Image { data, .. } if data == "reference"));
        let Block::Text { text } = &pinned[0] else {
            panic!("missing record")
        };
        let record: serde_json::Value =
            serde_json::from_str(text.strip_prefix(VISUAL_PIN_LABEL).unwrap()).unwrap();
        assert_eq!(
            record["comparison"]["input"]["target"],
            "/project/assets/target.png"
        );
        assert_eq!(record["comparison"]["input"]["loop_id"], "bench");
        assert_eq!(record["comparison"]["round"], 2);
        messages = vec![Message {
            role: Role::User,
            content: pinned.clone(),
        }];
        assert_eq!(
            serde_json::to_value(pinned_visual_context(&messages, 1)).unwrap(),
            serde_json::to_value(&pinned).unwrap()
        );
        assert_eq!(pinned_visual_context(&messages, 0).len(), 1);
        messages.push(Message {
            role: Role::User,
            content: vec![Block::ToolResult {
                id: "failed".into(),
                name: "Image".into(),
                content: "Error: failed".into(),
                is_error: true,
            }],
        });
        assert_eq!(
            serde_json::to_value(pinned_visual_context(&messages, 1)).unwrap(),
            serde_json::to_value(&pinned).unwrap()
        );
    }

    #[test]
    fn pinned_inputs_preserve_late_constraints_in_a_long_first_request() {
        let first = format!(
            "{}\nDo not regenerate the target. Keep the same loop_id.",
            "x".repeat(3500)
        );
        let recent = "continue".to_string();
        assert_eq!(
            pinned_inputs(&[first.clone(), recent.clone()], 8000),
            [first, recent]
        );
    }

    #[test]
    fn pinned_inputs_clip_an_oversized_first_request_within_utf8_budget() {
        let first = "🐸".repeat(3000);
        let pinned = pinned_inputs(&[first], 2000);
        assert!(pinned[0].len() <= 2000);
        assert!(pinned[0].ends_with('…'));
        assert!(pinned_inputs(&["hello".into()], 0).is_empty());
        assert_eq!(pinned_inputs(&["hello".into()], 2), ["he"]);
    }

    #[test]
    fn record_recovered_across_repeated_compactions() {
        let inputs = vec!["fix the widget".to_string(), "continue".to_string()];
        let todos = vec![crate::tools::todo::Todo {
            content: "fix the widget".into(),
            status: "in_progress".into(),
        }];
        let mut messages = vec![
            Message::user("fix the widget"),
            Message {
                role: Role::Assistant,
                content: vec![Block::ToolUse {
                    id: "r1".into(),
                    name: "Read".into(),
                    input: json!({"file_path": "src/widget.rs"}),
                }],
            },
            Message {
                role: Role::User,
                content: vec![Block::ToolResult {
                    id: "r1".into(),
                    name: "Read".into(),
                    content: "x".repeat(MIN_PRUNE_CHARS + 1),
                    is_error: false,
                }],
            },
            Message {
                role: Role::Assistant,
                content: vec![Block::ToolUse {
                    id: "e1".into(),
                    name: "Edit".into(),
                    input: json!({"file_path": "src/widget.rs"}),
                }],
            },
            Message {
                role: Role::User,
                content: vec![Block::ToolResult {
                    id: "e1".into(),
                    name: "Edit".into(),
                    content: "ok".into(),
                    is_error: false,
                }],
            },
            Message {
                role: Role::Assistant,
                content: vec![Block::ToolUse {
                    id: "g1".into(),
                    name: "Grep".into(),
                    input: json!({"pattern": "widget", "path": "src"}),
                }],
            },
            Message {
                role: Role::User,
                content: vec![Block::ToolResult {
                    id: "g1".into(),
                    name: "Grep".into(),
                    content: "y".repeat(MIN_PRUNE_CHARS + 1),
                    is_error: false,
                }],
            },
            Message::user("continue"),
        ];
        let r = pinned_record(&inputs, &todos, &messages);
        assert!(r.inputs[0].contains("fix the widget"));
        assert_eq!(r.files, ["src/widget.rs*"]); // Read folded into the Edit marker
        assert_eq!(r.todos, ["◐ fix the widget"]);
        assert_eq!(r.calls, ["Grep(pattern: widget | path: src)"]);
        assert!(r.pinned.iter().any(|p| p.contains("continue")));

        // Round trip: the rendered text is the only thing a later compaction sees.
        let rendered = render_record(&r, 16_000);
        let folded = vec![Message::user(format!(
            "{}. Work continues from this alone.)\n\nSummary:\nOld.\n\n{rendered}",
            COMPACTION_LABEL
        ))];
        let r2 = pinned_record(&inputs, &todos, &folded);
        assert_eq!(r2.files, r.files, "files lost across compaction");
        assert_eq!(r2.calls, r.calls, "calls lost across compaction");
        assert_eq!(r2.todos, r.todos);
        assert!(r2.inputs.iter().any(|i| i.contains("fix the widget")));
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
