//! Compaction, repairing an interrupted history, and `!` shell commands.

use super::*;

/// The transcript line when compaction fails, and the turn's error: what happened and what to
/// do, in one sentence. The raw failure rides `Event::CompactionFailed` to the engine log.
pub(super) fn compaction_error(model: &str, e: &anyhow::Error) -> anyhow::Error {
    if is_overflow(e) {
        anyhow::anyhow!(
            "couldn't summarize this conversation to fit {model}'s context window. Nothing was \
             lost: switch to a model with a bigger window and send your message again, or start \
             a new session from this one's summary."
        )
    } else {
        anyhow::anyhow!(
            "couldn't summarize this conversation: the call to {model} failed. Nothing was lost: \
             send your message again to retry, switch models, or start a new session from this \
             one's summary."
        )
    }
}

/// A "the prompt is longer than the context window" rejection, however it arrived: an HTTP
/// 400/413 ([`HttpError::context_overflow`]), or the same words as an error event inside a
/// 2xx stream, which is how a local server says it ("prompt is 138220 tokens; the context
/// window is 32768").
pub(super) fn is_overflow(e: &anyhow::Error) -> bool {
    if e.downcast_ref::<HttpError>()
        .is_some_and(HttpError::context_overflow)
    {
        return true;
    }
    e.downcast_ref::<crate::provider::StreamError>()
        .is_some_and(|s| {
            let m = s.message.to_lowercase();
            [
                "context window",
                "context length",
                "context_length_exceeded",
                "prompt is too long",
                "prompt too long",
                "input too long",
            ]
            .iter()
            .any(|needle| m.contains(needle))
        })
}

/// One message of the history as plain text, for a summary request that carries a slice of
/// the conversation as a transcript instead of as the conversation itself.
fn transcript_line(m: &Message) -> String {
    let mut out = String::from(match m.role {
        Role::User => "## user\n",
        Role::Assistant => "## assistant\n",
    });
    for b in &m.content {
        match b {
            Block::Text { text } => out.push_str(text),
            // Reasoning isn't part of the record a summary keeps.
            Block::Thinking { .. } => continue,
            Block::ToolUse { name, input, .. } => {
                out.push_str(&format!("[tool call: {name} {input}]"))
            }
            Block::ToolResult {
                name,
                content,
                is_error,
                ..
            } => out.push_str(&format!(
                "[tool result: {name}{}]\n{content}",
                if *is_error { " (failed)" } else { "" }
            )),
            Block::Image { .. } => out.push_str("[image]"),
        }
        out.push('\n');
    }
    out
}

/// `text` in pieces of at most `budget` bytes, cut on char boundaries.
fn split_chars(text: &str, budget: usize) -> Vec<&str> {
    let mut out = Vec::new();
    let mut rest = text;
    while rest.len() > budget {
        let cut = rest.floor_char_boundary(budget).max(1);
        let cut = (cut..=rest.len())
            .find(|&i| rest.is_char_boundary(i))
            .unwrap_or(rest.len());
        let (head, tail) = rest.split_at(cut);
        out.push(head);
        rest = tail;
    }
    if !rest.is_empty() {
        out.push(rest);
    }
    out
}

/// Consecutive `pieces` packed into chunks of at most `budget` bytes each; a piece longer than
/// that is split across chunks.
fn pack(pieces: &[String], budget: usize) -> Vec<String> {
    let mut chunks: Vec<String> = Vec::new();
    for piece in pieces {
        for part in split_chars(piece, budget) {
            match chunks.last_mut() {
                Some(c) if c.len() + part.len() <= budget => c.push_str(part),
                _ => chunks.push(part.to_string()),
            }
        }
    }
    chunks
}

const MAP_PROMPT: &str = "Below is one part of a long working session between a user and a coding assistant, as a \
transcript. It is too long to read at once, so it is being summarized part by part. Write a thorough summary of \
this part alone: what the user asked for, what was done (with file paths), decisions and why, code details \
(types, functions, constants, test names), errors and their fixes, and what was in progress when the part ends. \
Keep names, paths and error text verbatim. Do not call any tools. Output only the summary.";

const REDUCE_PROMPT: &str = "Below are summaries of consecutive parts of one long working session, oldest first. \
Merge them into one summary of the whole session, keeping every detail that matters for continuing the work. \
Keep names, paths and error text verbatim. Do not call any tools. Output only the summary.";

impl Agent {
    /// Summarize the conversation and continue from the summary.
    pub(super) async fn compact(&mut self, focus: Option<&str>) -> Result<()> {
        if self.conv.messages.is_empty() {
            return Ok(());
        }
        // If the history itself is over the window (one huge result that no cap caught), the
        // summarization request would overflow too: clip every oversized result first,
        // deterministically, recent ones included, so the summary request fits.
        if self.estimate() > self.window {
            let per_result = (self.result_cap() / 2).max(1_000);
            let plan = context::plan_emergency(&self.conv.messages, per_result);
            for (id, content) in &plan {
                self.record(Record::Replace {
                    id: id.clone(),
                    content: content.clone(),
                });
                context::apply(&mut self.conv.messages, id, content);
            }
            if !plan.is_empty() {
                self.emit(Event::ContextPruned {
                    results: plan.len(),
                    tokens_before: self.conv.usage.context(),
                    tokens_after: self.estimate(),
                });
                self.rebased();
            }
        }
        let (summary, out_tokens) = self.summarize(focus).await?;
        let before = self.conv.usage.context();
        // Loaded skills' instructions are summarized away; let them load again.
        self.conv.skills_loaded.clear();
        // The structured record, recovered verbatim across repeated compactions: user
        // inputs, files, the latest todos, commands and significant tool calls.
        let record =
            context::pinned_record(&self.conv.inputs, &self.ctx.todos, &self.conv.messages);
        // A record that filled the window would leave nothing for the summary it follows,
        // so it scales to the window, capped: small models get the essentials.
        let budget = (self.est.chars(self.window) / 8).clamp(1_000, 16_000);
        let record = context::render_record(&record, budget);
        let visual = context::pinned_visual_context(
            &self.conv.messages,
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
        self.conv.usage = Usage {
            input: out_tokens,
            ..Default::default()
        };
        self.emit(Event::Compacted {
            tokens_before: before,
            tokens_after: out_tokens,
            summary: self.build_summary().map(kept),
        });
        if let Some(closed) = self
            .conv
            .chapters
            .compacted(self.active_turn.unwrap_or(self.conv.turn))
        {
            self.title_chapter(closed);
        }
        self.rebased();
        Ok(())
    }

    /// Tokens kept free for the summary a request asks for.
    fn summary_room(&self) -> u64 {
        (self.window / 10).min(4_096)
    }

    /// The summary of the history, and what it cost in output tokens. The history goes to
    /// the session's model whole when the known window holds it, as an extension of the
    /// conversation (so the server's cache of it holds). When the window can't hold it — the
    /// model was switched to a smaller one mid-session, or the provider says the request is
    /// too long after all — it's summarized in parts sized to the window and the parts are
    /// merged, instead of failing the turn.
    async fn summarize(&mut self, focus: Option<&str>) -> Result<(String, u64)> {
        let mut instr = COMPACT_PROMPT.to_string();
        if let Some(f) = focus {
            instr.push_str(&format!("\nFocus especially on: {f}"));
        }
        // What one stand-alone request can carry besides the system prompt, the instruction
        // and the reply, with a fifth held back for the estimate being off.
        let fixed = self.est.tokens(fixed_chars(&self.system, &[]))
            + self
                .est
                .tokens(MAP_PROMPT.len().max(instr.len() + REDUCE_PROMPT.len()));
        let room = self.window.saturating_sub(fixed + self.summary_room());
        let mut budget = self.est.chars(room) * 4 / 5;
        let request = self.estimate() + self.est.tokens(instr.len());
        // Whole unless the known window plainly can't hold it. The estimate runs high and a
        // configured window can be lower than the server's, so a request somewhat over still
        // goes whole (it keeps the server's cache, and a refusal lands in the parts path
        // below); one half again over the window is never going to fit.
        if request <= self.window + self.window / 2 {
            match self.summarize_whole(&instr).await {
                Err(e) if is_overflow(&e) => {
                    self.notice(
                        Level::Warn,
                        "the summary request exceeded the model's context window; summarizing in parts",
                    );
                    // The window is smaller than it was taken to be, so the known one sizes
                    // nothing: start from half of what was just refused.
                    let total: usize = self
                        .conv
                        .messages
                        .iter()
                        .map(|m| transcript_line(m).len())
                        .sum();
                    budget = budget.min(total.div_ceil(2));
                }
                r => return r,
            }
        } else {
            self.notice(
                Level::Warn,
                format!(
                    "the history (~{request} tokens) is larger than this model's context window \
                     ({}); summarizing it in parts",
                    self.window
                ),
            );
        }
        // In parts. The estimate is only an estimate: if a part still overflows, halve the
        // parts and go once more before giving up.
        match self.summarize_parts(&instr, budget).await {
            Err(e) if is_overflow(&e) => {
                self.notice(
                    Level::Warn,
                    "a part still exceeded the model's context window; retrying with smaller parts",
                );
                self.summarize_parts(&instr, budget / 2).await
            }
            r => r,
        }
    }

    /// The whole history in one request, with the summary instruction as its last message.
    async fn summarize_whole(&mut self, instr: &str) -> Result<(String, u64)> {
        let mut msgs = self.conv.messages.clone();
        match msgs.last_mut() {
            Some(m) if m.role == Role::User => m.content.push(Block::Text { text: instr.into() }),
            _ => msgs.push(Message::user(instr)),
        }
        // A summary needs no reasoning.
        let think = self.think_switch(false);
        // Native tools ride outside the text, so offering the same ones keeps the request an
        // extension of the last call and the server's cache of it holds: without them it
        // diverges right after the system prompt and the whole history is prefilled again.
        let keep_prefix = matches!(self.harness.tool_mode, ToolMode::Native | ToolMode::Auto);
        let (mut resp, streamed) = self
            .call("compacting", &msgs, true, keep_prefix, think, None, None)
            .await?;
        self.count_call(resp.usage.clone(), &streamed, true);
        // It called a tool instead of summarizing: ask again with none to call.
        if keep_prefix && resp.message.text().trim().is_empty() {
            let (r, streamed) = self
                .call("compacting", &msgs, true, false, think, None, None)
                .await?;
            self.count_call(r.usage.clone(), &streamed, true);
            resp = r;
        }
        let summary = resp.message.text();
        if summary.trim().is_empty() {
            anyhow::bail!("compaction produced an empty summary; keeping the full history");
        }
        Ok((summary, resp.usage.output))
    }

    /// One summary request that stands alone: `text` as the only message, no tools.
    async fn summarize_text(&mut self, text: String) -> Result<(String, u64)> {
        let think = self.think_switch(false);
        let (resp, streamed) = self
            .call(
                "compacting",
                &[Message::user(text)],
                true,
                false,
                think,
                None,
                None,
            )
            .await?;
        self.count_call(resp.usage.clone(), &streamed, true);
        let summary = resp.message.text();
        if summary.trim().is_empty() {
            anyhow::bail!("compaction produced an empty summary; keeping the full history");
        }
        Ok((summary, resp.usage.output))
    }

    /// Map then reduce: the history as a transcript, cut into parts of at most `budget` bytes,
    /// each summarized on its own, then the summaries merged — in rounds, when even they
    /// don't fit one request.
    async fn summarize_parts(&mut self, instr: &str, budget: usize) -> Result<(String, u64)> {
        let budget = budget.max(2_000);
        let lines: Vec<String> = self.conv.messages.iter().map(transcript_line).collect();
        let chunks = pack(&lines, budget);
        let n = chunks.len();
        let mut parts = Vec::with_capacity(n);
        for (i, chunk) in chunks.into_iter().enumerate() {
            let (part, _) = self
                .summarize_text(format!(
                    "{MAP_PROMPT}\n\nPart {} of {n}:\n<transcript>\n{chunk}\n</transcript>",
                    i + 1
                ))
                .await?;
            parts.push(part);
        }
        // Reduce. A part summary longer than a third of a request is clipped, so every round
        // merges at least two and the rounds end.
        loop {
            let labelled: Vec<String> = parts
                .iter()
                .enumerate()
                .map(|(i, p)| {
                    format!(
                        "Part {} of {}:\n{}\n\n",
                        i + 1,
                        parts.len(),
                        crate::tools::truncate_middle(p, budget / 3)
                    )
                })
                .collect();
            let mut groups = pack(&labelled, budget);
            // Never a round that merges nothing: what one request holds is what's kept.
            if groups.len() >= parts.len() {
                groups.truncate(1);
            }
            if groups.len() <= 1 {
                let all = groups.into_iter().next().unwrap_or_default();
                return self
                    .summarize_text(format!("{REDUCE_PROMPT}\n\n{all}\n{instr}"))
                    .await;
            }
            let mut merged = Vec::with_capacity(groups.len());
            for group in groups {
                let (m, _) = self
                    .summarize_text(format!("{REDUCE_PROMPT}\n\n{group}"))
                    .await?;
                merged.push(m);
            }
            parts = merged;
        }
    }

    /// After an interrupt or error: give every dangling tool call a result so the history stays valid.
    pub(super) fn repair(&mut self) {
        if let Some(ai) = self
            .conv
            .messages
            .iter()
            .rposition(|m| m.role == Role::Assistant)
        {
            let uses = self.conv.messages[ai].tool_uses();
            if !uses.is_empty() {
                if ai + 1 == self.conv.messages.len() {
                    self.push_msg(Message {
                        role: Role::User,
                        content: Vec::new(),
                    });
                }
                let done: HashSet<String> = self.conv.messages[ai + 1]
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
        if self
            .conv
            .messages
            .last()
            .is_some_and(|m| m.role == Role::User)
        {
            self.push_user("[Request interrupted by user]".into());
        }
    }

    pub(super) async fn shell(&mut self, cmd: &str) {
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
        self.conv.pending.push(format!(
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
                widget: None,
                images: Vec::new(),
                app: None,
            },
        });
    }
}
