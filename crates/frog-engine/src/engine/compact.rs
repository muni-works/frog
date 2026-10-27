//! Compaction, repairing an interrupted history, and `!` shell commands.

use super::*;

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
        let mut msgs = self.conv.messages.clone();
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
            input: resp.usage.output,
            ..Default::default()
        };
        self.emit(Event::Compacted {
            tokens_before: before,
            tokens_after: resp.usage.output,
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
                images: Vec::new(),
                app: None,
            },
        });
    }
}
