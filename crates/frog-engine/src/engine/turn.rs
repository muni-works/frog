//! The turn: taking the user's input (and wakes) into one model loop.

use super::*;

impl Agent {
    /// Append user text, merging into a trailing user message so roles always alternate.
    pub(super) fn push_user(&mut self, text: String) {
        match self.conv.messages.last() {
            Some(m) if m.role == Role::User => self.extend_last(vec![Block::Text { text }]),
            _ => self.push_msg(Message::user(text)),
        }
    }

    /// `@path` mentions inline the file so the model doesn't need a Read round-trip; `@element`
    /// mentions the user picked in a preview pane inline what the pane said about them.
    pub(super) fn expand_mentions(&mut self, input: &str) -> String {
        let mut extra = String::new();
        for tok in input.split_whitespace().filter_map(|t| t.strip_prefix('@')) {
            let tok = tok.trim_end_matches([',', ')', ':', ';', '?', '!']);
            if let Some(context) = self.shared.panes.mention(&format!("@{tok}")) {
                extra.push_str(&format!(
                    "\n<element mention=\"@{tok}\">\n{context}\n</element>"
                ));
                continue;
            }
            let path = self.ctx.resolve(tok.trim_end_matches('.'));
            let Ok(meta) = std::fs::metadata(&path) else {
                continue;
            };
            if !meta.is_file() || meta.len() > 256_000 {
                continue;
            }
            if let Ok(text) = std::fs::read_to_string(&path) {
                extra.push_str(&format!(
                    "\n<file path=\"{}\">\n{text}\n</file>",
                    self.ctx.display(&path)
                ));
                self.ctx.mark_read(&path);
            }
        }
        if extra.is_empty() {
            input.to_string()
        } else {
            format!("{input}\n{extra}")
        }
    }

    /// Project files the user named without `@` ("calc.py has a bug"), which small models often
    /// ask the user to paste instead of reading. Below the strong tier, small text files are
    /// inlined like `@` mentions (within a slice of the window); otherwise a short note says
    /// they exist and can be Read. Returns the text to append and the files named.
    pub(super) fn attach_named(&mut self, input: &str) -> (String, Vec<PathBuf>) {
        if self.chat || self.subagent {
            return (String::new(), Vec::new());
        }
        let files = crate::named_files::named(input, &self.root);
        let mut budget = if self.harness.tier == Tier::Strong {
            0
        } else {
            (self.est.chars(self.window) / 10).min(24_000)
        };
        let (mut inlined, mut noted) = (String::new(), Vec::new());
        for path in &files {
            let mtime = std::fs::metadata(path).and_then(|m| m.modified()).ok();
            // Already inlined or read, and unchanged since.
            if self.ctx.read_files.get(path).is_some_and(|t| *t == mtime) {
                continue;
            }
            let shown = self.ctx.display(path);
            let text = std::fs::metadata(path)
                .is_ok_and(|m| budget > 0 && (m.len() as usize) <= budget)
                .then(|| std::fs::read_to_string(path).ok())
                .flatten()
                .filter(|t| !t.contains('\0'));
            match text {
                Some(text) => {
                    budget -= text.len();
                    inlined.push_str(&format!("\n<file path=\"{shown}\">\n{text}\n</file>"));
                    self.ctx.mark_read(path);
                }
                None => noted.push(shown),
            }
        }
        let mut extra = inlined;
        if !noted.is_empty() {
            extra.push_str(&format!(
                "\n(In this project: {}. Use Read to open them.)",
                noted.join(", ")
            ));
        }
        (extra, files)
    }

    /// A nudge for a reply that asked the user for code it could Read, or said it can't see
    /// files. `None` when the reply is fine, or asks for a named file that isn't here.
    pub(super) fn file_nudge(&self, reply: &str, named: &[PathBuf]) -> Option<String> {
        if self.chat || !self.specs.iter().any(|s| s.name == "Read") {
            return None;
        }
        if !crate::named_files::asks_for_files(reply) {
            return None;
        }
        let mut files = crate::named_files::named(reply, &self.root);
        for p in named {
            if !files.contains(p) {
                files.push(p.clone());
            }
        }
        if files.is_empty()
            && !crate::named_files::claims_no_access(reply)
            && !crate::named_files::candidates(reply).is_empty()
        {
            return None;
        }
        let how = match files.as_slice() {
            [] => "use Glob or Grep to find the relevant files and Read to open them".to_string(),
            fs => format!(
                "use Read to open {}",
                fs.iter()
                    .map(|p| self.ctx.display(p))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        };
        Some(format!(
            "You have tools and can open this project's files yourself, so don't ask me for them: {how}, then continue with the task."
        ))
    }

    /// Messages from other sessions (each already wrapped in `<session-message>`), as one
    /// turn: the first is its input, the rest go along as `more`, in order.
    pub(super) async fn deliver(&mut self, mut wrapped: Vec<String>) -> Result<()> {
        if wrapped.is_empty() {
            return Ok(());
        }
        let first = wrapped.remove(0);
        let more = wrapped
            .into_iter()
            .map(|text| Part {
                text,
                images: Vec::new(),
            })
            .collect();
        self.turn_with(&first, Vec::new(), more, true).await
    }

    /// An informational message from another session ([`Op::Inform`]): logged as read, and
    /// kept to go along with the next turn as context. No turn, no wake.
    pub(super) fn inform(&mut self, from: &str, from_name: &str, message: &str) {
        self.emit(Event::MessageRead {
            from: from.to_string(),
            from_name: from_name.to_string(),
            message: message.to_string(),
        });
        self.conv
            .pending
            .push(crate::tools::sessions::wrap(from, from_name, message));
    }

    /// A turn on what's waiting at the boundary, all at once: the background wakes (in the
    /// order they came in) as its input, and the session messages queued behind them
    /// (`delivered`, each already wrapped) as `more`.
    pub(super) async fn wake(&mut self, delivered: Vec<String>) -> Result<()> {
        let notices = self.shared.bg.take_notices();
        if notices.is_empty() {
            return self.deliver(delivered).await;
        }
        let more = delivered
            .into_iter()
            .map(|text| Part {
                text,
                images: Vec::new(),
            })
            .collect();
        // The notices are the turn's input (that's how it's shown) but not the user's words.
        self.turn_with(&notices.join("\n\n"), Vec::new(), more, false)
            .await
    }

    pub(super) async fn turn(
        &mut self,
        input: &str,
        images: Vec<crate::protocol::Image>,
    ) -> Result<()> {
        self.turn_with(input, images, Vec::new(), true).await
    }

    /// A turn on `input` and any further messages sent with it (`more`, in order): one user
    /// message, each of them its own text block followed by its images.
    pub(super) async fn turn_with(
        &mut self,
        input: &str,
        mut images: Vec<crate::protocol::Image>,
        more: Vec<Part>,
        // `input` is the user's words, not wake notices: only then do `@mentions`, `/skills`
        // and image paths in it expand, and it's kept verbatim through compaction.
        user: bool,
    ) -> Result<()> {
        // A completed background map can be adopted at a turn boundary. Never wait for it;
        // if it is still running, this turn proceeds with the current prompt.
        self.poll_repo_map();
        let (input, named) = match user {
            true => crate::image_paths::attach(input),
            false => (input.to_string(), Vec::new()),
        };
        let input = input.as_str();
        images.extend(named);
        let more: Vec<Part> = more
            .into_iter()
            .map(|p| {
                let (text, named) = crate::image_paths::attach(&p.text);
                let mut images = p.images;
                images.extend(named);
                Part { text, images }
            })
            .collect();
        self.conv.turn += 1;
        let turn = self.conv.turn;
        // The first turn creates a new session's log: its starting mode goes in first.
        self.log_mode();
        // Background work that finished while this turn was queued: delivered with it, as one
        // batch at its start (and shown with it, ahead of its input).
        let wakes = self.shared.bg.take_notices();
        // Refused waits count within a turn (see `Batch::Waiting`).
        self.shared.bg.long_wait_refusals.store(0, std::sync::atomic::Ordering::Relaxed);
        self.emit(Event::TurnStarted {
            turn,
            input: input.to_string(),
            images: images.clone(),
            more: more.clone(),
        });
        if !wakes.is_empty() {
            self.emit(Event::WakesDelivered {
                turn,
                wakes: wakes.clone(),
            });
        }
        self.active_turn = Some(turn);
        // A draft still waiting to warm is stale now; the turn itself leaves the cache warm.
        self.warming.lock().unwrap().1 = None;
        self.shared.panes.set_in_turn(true);
        if user {
            self.conv.inputs.push(input.to_string());
        }
        self.conv.inputs.extend(more.iter().map(|p| p.text.clone()));
        let texts: Vec<String> = more.iter().map(|p| p.text.clone()).collect();
        if let Some(closed) = self.conv.chapters.started(turn, input, &texts) {
            self.title_chapter(closed);
        }
        self.turn_clock = Some(Instant::now());
        if let Some(m) = &self.meter {
            // Idle from the seconds spent waiting before this turn (the op loop marked it busy).
            self.energy_mark = Some((m.mark(), m.idle_estimate()));
        }
        self.timing = TurnTiming::default();
        self.quiet = 0;
        // A new turn announces its waiting inbox fresh, not carrying the last turn's count.
        self.inbox_told = None;
        self.checkpoint(turn);
        self.turn_usage = TurnUsage::default();
        // A new turn may ask again what the last one was denied (the session's breaker still holds).
        self.turn_denied.clear();
        self.blocked = None;
        // Wakes a stop held go along with this turn (below); later ones start turns again.
        self.shared.wake_hold.store(false, Ordering::SeqCst);

        let mut text = std::mem::take(&mut self.conv.pending).join("\n");
        for notice in wakes {
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(&notice);
        }
        if !text.is_empty() {
            text.push('\n');
        }
        if !user {
            text.push_str(input);
        }
        let typed = if user { input } else { "" }.to_string();
        // `/skill-name ...` loads that skill ahead of the request.
        let input = match crate::skills::expand_command(&self.skills, &typed) {
            Some((expanded, name)) => {
                self.conv.skills_loaded.insert(name);
                expanded
            }
            None => typed.clone(),
        };
        text.push_str(&self.expand_mentions(&input));
        // Only the user's own words: not skill text or shell output.
        let (extra, mut named) = self.attach_named(&typed);
        text.push_str(&extra);
        // Files the user pointed at (`@path` or by name): their scoped rules, and on a session's
        // first turn a fresh repo map if they aren't on it. Both happen before the first model
        // call of the turn.
        let pointed: Vec<PathBuf> = typed
            .split_whitespace()
            .filter_map(|t| t.strip_prefix('@'))
            .map(|t| {
                self.ctx
                    .resolve(t.trim_end_matches([',', ')', ':', ';', '?', '!', '.']))
            })
            .chain(named.iter().cloned())
            .collect();
        for p in &pointed {
            text.push_str(&self.rules_for(p));
        }
        let mentioned: Vec<String> = pointed.iter().filter_map(|p| self.rel(p)).collect();
        // The map is part of the system prompt, so after the first turn it's rebuilt only where
        // the history is rewritten anyway (`rebased`): rebuilding it whenever a file changed
        // would re-prefill the whole conversation on the turn after every edit.
        if self.conv.messages.is_empty() {
            self.refresh_repo_map(&mentioned);
        }
        self.log_map();
        self.reprobe_if_stale().await;
        self.apply_harness();
        self.push_user(text);
        self.attach_images(images);
        // Each message sent with it: its own block, read the way the first one is.
        for part in more {
            let input = match crate::skills::expand_command(&self.skills, &part.text) {
                Some((expanded, name)) => {
                    self.conv.skills_loaded.insert(name);
                    expanded
                }
                None => part.text.clone(),
            };
            let mut text = self.expand_mentions(&input);
            let (extra, files) = self.attach_named(&part.text);
            text.push_str(&extra);
            let pointed: Vec<PathBuf> = part
                .text
                .split_whitespace()
                .filter_map(|t| t.strip_prefix('@'))
                .map(|t| {
                    self.ctx
                        .resolve(t.trim_end_matches([',', ')', ':', ';', '?', '!', '.']))
                })
                .chain(files.iter().cloned())
                .collect();
            for p in &pointed {
                text.push_str(&self.rules_for(p));
            }
            named.extend(files);
            self.push_user(text);
            self.attach_images(part.images);
        }
        // The user's message is on disk before any model call: a crash or quit mid-turn
        // loses the reply, never the request. One fsync per accepted message.
        self.sync_log();

        let mut compacted = None;
        let mut overflowed = false;
        let mut guard = LoopGuard::default();
        let mut steps = 0;
        // Cut-off replies continued in a row (reset whenever a reply runs tools).
        let mut continued = 0;
        // The message item a cut-off reply left open. The next call streams into it, so the
        // continuation joins that bubble instead of starting another.
        let mut reply_item: Option<String> = None;
        // Every part of that reply so far: the bubble's text is the whole answer, not the last
        // piece of it.
        let mut reply_text = String::new();
        // The continuation instruction for the next call. It steers that one call only and
        // never joins the history: the reply it continues stays one assistant message.
        let mut steer: Option<String> = None;
        // Set while this step's reply is the tail of a cut-off one: its blocks join that
        // message instead of starting another.
        let mut continuing = false;
        // A reply asking for files it could Read is nudged once, before any tool has run.
        let (mut nudged, mut used_tools) = (false, false);
        let reason = loop {
            steps += 1;
            let limit = if self.subagent {
                self.cfg.subagent_max_steps.max(1)
            } else {
                max_steps()
            };
            if steps > limit {
                break EndReason::StepLimit;
            }
            // MCP tools (and their servers' instructions) change the prompt's prefix, so they're
            // only taken on between turns, never mid-turn where the next call would re-prefill
            // everything the server has cached.
            if steps == 1 {
                self.poll_mcp();
                let mcp = self.mcp.clone();
                if mcp.refresh().await {
                    self.apply_harness();
                }
            }
            self.sync_specs();
            // What arrived while the last step ran (a session message, the cwd-gone note the
            // fallback pushed mid-turn): it joins the history here, so the next call — the
            // model's next look at the world — carries it, not the turn after this one. Turn
            // start also drains `pending` into the user's message; this catches the ones that
            // land between calls, where nothing else would pick them up.
            let queued = std::mem::take(&mut self.conv.pending);
            if !queued.is_empty() {
                self.push_user(queued.join("\n"));
            }
            // What the preview pane saw go wrong since the last call.
            let reports = self.shared.panes.take_queued();
            if !reports.is_empty() {
                self.push_user(reports.join("\n"));
            }
            // What's queued behind this turn (session messages): the queue is drained only
            // at the boundary, so a long turn would otherwise never know it has mail. One
            // line as a user message — the system prompt is static and cached, so it can't
            // carry a live count — and the same line as a notice, the transcript's quiet
            // activity row. Rate-limited to changed counts, else once per 5 steps.
            let waiting = self.waiting_inbox();
            if waiting > 0 {
                let told = match self.inbox_told {
                    Some((count, step)) => count != waiting || steps.saturating_sub(step) >= 5,
                    None => true,
                };
                if told {
                    self.inbox_told = Some((waiting, steps));
                    let note = Agent::waiting_note(waiting);
                    self.notice(Level::Info, note.clone());
                    self.push_user(note);
                }
            }
            // Between turns, pruning starts at PRUNE_AT; inside one, only once the window is
            // nearly full, since a prune rewrites the prefix the server has cached.
            let start = if steps == 1 {
                context::PRUNE_AT
            } else {
                context::COMPACT_AT
            };
            self.fit_context(&mut compacted, start).await?;
            let sent = self.fixed_chars() + context::history_chars(&self.conv.messages);
            let think = self.think_switch(thinking::wanted(&self.conv.messages, self.quiet));
            self.quiet = if think == Some(false) {
                self.quiet + 1
            } else {
                0
            };
            let budget = self.think_budget(think);
            let started = Instant::now();
            let activity = if !self.model_ready && self.profile.sidecar.is_some() {
                format!("loading {}", self.profile.model)
            } else {
                "thinking".into()
            };
            // A continued reply is steered by a note for this call only: it never joins the
            // history, so the reply it continues stays one assistant message there.
            let steered = steer.take().map(|note| {
                let mut msgs = self.conv.messages.clone();
                msgs.push(Message::user(note));
                msgs
            });
            let messages: &[Message] = steered.as_deref().unwrap_or(&self.conv.messages);
            let (resp, streamed) = match self
                .call(
                    &activity,
                    messages,
                    false,
                    true,
                    think,
                    budget,
                    reply_item.clone(),
                )
                .await
            {
                Ok(r) => r,
                Err(e) => {
                    // The request exceeded the model's context window (estimate missed, or a
                    // result landed that the window can never hold): compact and retry the step
                    // once, instead of ending the turn on a 400. The second failure is real.
                    if e.downcast_ref::<HttpError>()
                        .is_some_and(HttpError::context_overflow)
                    {
                        if !overflowed {
                            overflowed = true;
                            self.notice(
                                Level::Warn,
                                "the request exceeded the model's context window; compacting and retrying",
                            );
                            if let Err(ce) = self.compact(None).await {
                                // The one-line transcript story (the client renders
                                // `Event::CompactionFailed` as a rescue line, never this
                                // error's chain); the raw payload goes to the engine log.
                                eprintln!("compaction failed: {ce:#}");
                                self.emit(Event::CompactionFailed {
                                    detail: format!("{ce:#}"),
                                });
                                anyhow::bail!(
                                    "compaction failed; the history can't fit the context window"
                                );
                            }
                            continue;
                        }
                        self.emit(Event::CompactionFailed {
                            detail: format!("{e:#}"),
                        });
                        anyhow::bail!(
                            "the request still exceeds the model's context window after compaction"
                        );
                    }
                    let Some(local) = self.cloud_fallback(&e) else {
                        return Err(e);
                    };
                    self.notice(
                        Level::Warn,
                        format!("frog api unavailable ({e:#}) — continuing on {local}"),
                    );
                    self.set_model(&local).await?;
                    self.model_flip_why = Some("frog api was unavailable, so it fell back".into());
                    continue;
                }
            };
            self.model_ready = true;
            self.last_call = started.elapsed();
            self.conv.usage = resp.usage.clone();
            self.count_call(resp.usage.clone(), &streamed, false);
            for (id, name, input) in self.provider.take_codex_items() {
                let arg = input.to_string();
                self.emit(Event::ItemStarted {
                    id: id.clone(),
                    kind: ItemKind::ToolCall {
                        name: name.clone(),
                        arg: arg.clone(),
                    },
                });
                let output = input["output"].as_str().unwrap_or("").to_owned();
                self.emit(Event::ItemCompleted {
                    id,
                    item: Item::ToolCall {
                        name,
                        arg,
                        input,
                        outcome: ToolOutcome::Ok,
                        output,
                        display: None,
                        diff: None,
                        diagram: None,
                        present: None,
                        widget: None,
                        images: Vec::new(),
                        app: None,
                    },
                });
            }
            self.est
                .calibrate(sent, resp.usage.input + resp.usage.cache_read);
            let (msg, recovered) = normalize(resp.message, self.recovers_text_calls());
            let bad_args = msg
                .tool_uses()
                .iter()
                .any(|(_, _, i)| i.get("_invalid_json").is_some());
            if let Some(why) =
                format_failure(resp.stop, recovered, bad_args, streamed.format_failed)
            {
                self.note_format_failure(why);
            }

            let reasoning: String = msg
                .content
                .iter()
                .filter_map(|b| match b {
                    Block::Thinking { text, .. } => Some(text.as_str()),
                    _ => None,
                })
                .collect();
            if !reasoning.is_empty() {
                self.complete_item(
                    streamed.reasoning,
                    ItemKind::Reasoning,
                    Item::Reasoning { text: reasoning },
                );
            }
            let answer = msg.text();
            let silent = answer.trim().is_empty();
            let nudge = (!nudged && !used_tools && resp.stop != Stop::Length)
                .then(|| self.file_nudge(&answer, &named))
                .flatten();
            // A step that continues nothing starts a new bubble.
            if !continuing {
                reply_text.clear();
            }
            if !answer.is_empty() {
                self.conv.chapters.replied(&answer);
                // A continued reply's item carries the whole answer, not just this part: the
                // client sets its text from this, and the bubble is the same one.
                reply_text.push_str(&answer);
                self.complete_item(
                    streamed.message.clone().or_else(|| reply_item.clone()),
                    ItemKind::Message,
                    Item::Message {
                        text: reply_text.clone(),
                    },
                );
            }

            let uses = msg.tool_uses();
            // More of a cut-off reply joins the message it continues (one bubble, one history
            // message, via the log's Extend); anything else starts its own. Its thinking stays
            // out of the join: a provider wants thinking first in an assistant message, and the
            // block already there is left exactly as it was.
            if continuing {
                let more: Vec<Block> = msg
                    .content
                    .into_iter()
                    .filter(|b| !matches!(b, Block::Thinking { .. }))
                    .collect();
                self.extend_last(more);
            } else {
                self.push_msg(msg);
            }
            // Safe point (the model's message closed and is in the log): an app update's
            // drain suspends the turn here, before any tool of this step runs, marking the
            // calls it never got to — never "[Request interrupted by user]".
            if drain_pending(&self.shared).await {
                let missing: Vec<Block> = uses
                    .iter()
                    .map(|(id, name, _)| Block::ToolResult {
                        id: id.clone(),
                        name: name.clone(),
                        content: "Interrupted by app update; will be re-run or resumed.".into(),
                        is_error: true,
                    })
                    .collect();
                if !missing.is_empty() {
                    self.extend_last(missing);
                }
                break EndReason::Suspended;
            }
            if let (true, Some(nudge)) = (uses.is_empty(), nudge) {
                nudged = true;
                self.notice(
                    Level::Info,
                    "the model asked for files it can read; reminded it to use its tools",
                );
                self.push_user(nudge);
                continue;
            }
            if uses.is_empty() {
                // An update's drain takes the turn here, finished answer and all.
                if drain_pending(&self.shared).await {
                    break EndReason::Suspended;
                }
                // Ran out of output room mid-reply (long thinking, usually): carry on rather
                // than end the turn, a few times, so long work doesn't stop on a token cap.
                if resp.stop == Stop::Length && continued < MAX_CONTINUES {
                    continued += 1;
                    self.notice(Level::Info, "reply hit the output limit; continuing");
                    // The reply goes on in the bubble it started (and the message it already
                    // is in the history). The id only exists when text streamed; a reply cut
                    // inside a tool call has nothing to append to.
                    reply_item = streamed.message.clone().or(reply_item.take());
                    continuing = reply_item.is_some();
                    // No text came back: the cut fell inside a tool call, which was dropped.
                    // "Continue" would only restart the same oversized call, so ask for smaller
                    // pieces instead.
                    steer = Some(if silent {
                        CUT_TOOL_CALL.into()
                    } else {
                        CONTINUE_REPLY.into()
                    });
                    continue;
                }
                break if resp.stop == Stop::Length {
                    EndReason::MaxTokens {
                        auto_continued: continued,
                    }
                } else {
                    EndReason::Complete
                };
            }

            used_tools = true;
            // A reply that acted is progress: the next cut-off gets a fresh set of continues.
            continued = 0;
            // Whatever came next starts its own bubble.
            reply_item = None;
            continuing = false;
            reply_text.clear();
            match self.run_tools(uses, &mut guard, streamed.early).await? {
                Batch::Continue => {}
                Batch::Denied => break EndReason::Denied,
                Batch::Looping => break EndReason::Looping,
                Batch::Waiting => break EndReason::Complete,
                Batch::Blocked(denial) => break EndReason::BlockedOnApproval { denial },
                Batch::Suspended => break EndReason::Suspended,
            }
            // Safe point (a tool call finished, its result recorded): an app update's drain
            // suspends the turn here.
            if drain_pending(&self.shared).await {
                break EndReason::Suspended;
            }
            // Stop landed mid-tool: the tool already recorded "Interrupted by user.", so end
            // the turn here instead of handing the result back to the model. The outer select
            // races this future against the token; whichever wins, the turn ends cancelled.
            if self.shared.cancel.lock().unwrap().is_cancelled() {
                return Err(Interrupted.into());
            }
        };
        // A suspended turn ends exactly here, before any warm-up (there's no next turn to
        // warm) and after everything the log needs: history, events, the fsync below.
        if reason == EndReason::Suspended {
            if let Some((id, _)) = self.shared.journal.live.lock().unwrap().take() {
                if let Some(dir) = &self.store {
                    let _ = std::fs::remove_file(session::live_path(dir, &id));
                }
            }
            self.active_turn = None;
            self.shared.panes.set_in_turn(false);
            self.flush_gists().await;
            self.end_turn(turn, reason);
            return Ok(());
        }
        // Prune now, while the user reads the reply, and warm the result: the next turn then
        // starts from a prefix that's already cached instead of prefilling all of it.
        if self.prune(context::PRUNE_AT) {
            self.rebased();
            self.warm(None);
        }
        self.active_turn = None;
        self.shared.panes.set_in_turn(false);
        self.flush_gists().await;
        self.end_turn(turn, reason);
        Ok(())
    }
}

/// Sent after a reply cut off at the output limit inside a tool call (no text came back, and
/// the half-written call can't run).
const CUT_TOOL_CALL: &str = "Your last reply hit the output limit partway through a tool call, so \
that call was dropped and nothing ran. Don't repeat it in one piece: split it into smaller calls. \
For a long file, Write the first part, then add the rest with Edit, a section at a time.";

/// Steers the call that continues a reply cut off at the output limit. Sent with that one
/// request only: the reply is one assistant message, so this never joins the history.
const CONTINUE_REPLY: &str = "Your reply was cut off at the output limit. Continue exactly where \
you stopped, with no preamble and no recap.";
