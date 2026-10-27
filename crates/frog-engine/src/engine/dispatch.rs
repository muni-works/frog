//! Running tools: one call, a reply's batch, subagents and background jobs.

use super::*;

impl Agent {
    /// `Task`: run a subagent and return its report (its steps stream as live output), or,
    /// with `background`, start it and return its id. A write-mode subagent works in this
    /// session's mode and sandbox, and its permission prompts come to the user through ours.
    pub(super) async fn run_task(&mut self, id: &str, input: &Value) -> Result<tools::Output> {
        if self.subagent {
            anyhow::bail!("subagents can't start subagents");
        }
        let write = match input["mode"].as_str().unwrap_or("read") {
            "read" | "" => false,
            "write" => true,
            m => anyhow::bail!("unknown mode `{m}`: use read or write"),
        };
        let (profile_name, profile, fallback) = crate::subagent::profile(
            &self.cfg,
            &self.root,
            input["model"].as_str(),
            (&self.profile_name, &self.profile),
        );
        if let Some(why) = fallback {
            self.notice(Level::Warn, why);
        }
        let mut cfg = self.cfg.clone();
        cfg.subagent_write = write;
        let opts = Options {
            cfg,
            profile_name,
            profile,
            cwd: self.root.clone(),
            // Never more than the parent may do: its mode, and only it can ask the user.
            mode: if write { self.mode } else { Mode::Default },
            can_ask: write && self.can_ask,
            resume: None,
            store: None,
            sandbox: !write || self.ctx.sandbox.is_some(),
            rich: false,
            subagent: true,
            chat: false,
        };
        if tools::bool_arg(input, "background") {
            let max = self.cfg.background_tasks.max(1);
            return crate::background::start_task(&self.shared.bg, opts, input, max);
        }
        let stop = CancellationToken::new();
        self.shared
            .subagents
            .lock()
            .unwrap()
            .insert(id.to_string(), stop.clone());
        let forward = crate::background::forward(self.shared.bg.clone(), id.to_string(), false);
        // A drain cascades to a live subagent: it suspends its own turn (its engine ends it
        // `Suspended`), and the parent's drain deadline bounds its wait.
        let cascade = {
            let d = self.shared.draining.lock().unwrap();
            d.as_ref()
                .filter(|s| !s.acked)
                .map(|s| (s.deadline, stop.clone()))
        };
        if let Some((deadline, token)) = cascade {
            tokio::spawn(async move {
                let left = deadline.saturating_sub(now_ms());
                if left > 0 {
                    tokio::time::sleep(Duration::from_millis(left as u64)).await;
                }
                token.cancel();
            });
        }
        let out = crate::subagent::run(opts, input, stop, forward).await;
        self.shared.subagents.lock().unwrap().remove(id);
        out
    }

    /// Where background jobs write their output: next to the session log.
    pub(super) fn jobs_dir(&self) -> PathBuf {
        match &self.store {
            Some(dir) => dir.join(format!("{}.jobs", self.conv.session_id)),
            None => std::env::temp_dir().join(format!("frog-jobs-{}", self.conv.session_id)),
        }
    }

    /// A long bare wait ([`crate::auto::long_wait`]) run as a background job (the same path as
    /// `Bash { run_in_background }`, already permitted): the tool returns at once, telling the
    /// model what happened, and the job's `<job-done>` wake brings the output when it ends.
    pub(super) fn background_wait(&self, input: &Value, secs: u64) -> Result<tools::Output> {
        let started =
            crate::background::start_job(&self.shared.bg, input, &self.ctx, &self.jobs_dir())?;
        let id = started
            .content
            .split_whitespace()
            .find(|w| w.starts_with("job-"))
            .map(|w| w.trim_end_matches([',', '.']).to_string())
            .unwrap_or_else(|| "a background job".into());
        self.notice(
            Level::Warn,
            format!("a {secs}s sleep moved to background job {id}; the turn goes on"),
        );
        Ok(tools::Output::text(format!(
            "That wait is now a background job ({id}, {secs}s); continuing. Don't sleep to wait: do other work now or end your turn; the <job-done id={id}> wake, with the output of the commands after the sleep, starts your next turn.\n\n{}",
            started.content
        )))
    }

    /// Run a tool, streaming its live output as ephemeral `Output` deltas on item `id`.
    pub(super) async fn run_tool(
        &mut self,
        id: &str,
        name: &str,
        input: &Value,
    ) -> Result<tools::Output> {
        // A working directory that was deleted out from under the session (a worktree cleaned
        // up, a temp folder gone) would fail every command with "No such file or directory".
        // Fall back to the session root and say so.
        if !self.ctx.cwd.is_dir() {
            let gone = std::mem::take(&mut self.ctx.cwd);
            self.ctx.cwd = self.root.clone();
            self.ctx.read_files.clear();
            // The sandbox roots pointed into the deleted folder too; the session root confines
            // what's left, if it still sandboxes at all.
            if self.ctx.sandbox.as_ref().is_some_and(|p| !p.is_dir()) {
                self.ctx.sandbox = Some(self.root.clone());
            }
            if self.ctx.shell_sandbox.as_ref().is_some_and(|p| !p.is_dir()) {
                self.ctx.shell_sandbox = Some(self.root.clone());
            }
            self.notice(
                Level::Warn,
                format!(
                    "The working directory {} is gone; continuing in the session root {}.",
                    gone.display(),
                    self.root.display()
                ),
            );
        }
        if name == crate::skills::TOOL {
            return crate::skills::run(&self.skills, &mut self.conv.skills_loaded, input);
        }
        if name == crate::recall::TOOL && self.has_recall() {
            let sessions = self.recall_sources();
            let sources = crate::recall::Sources {
                notes: &self.notes,
                sessions: &sessions,
            };
            return crate::recall::run(&sources, input, self.harness.tier);
        }
        if name == crate::subagent::TOOL {
            return self.run_task(id, input).await;
        }
        // The sleep guard: a long bare wait would hold the turn (and every event and message
        // behind it) for minutes, so it runs as a background job and the turn goes on.
        if name == "Bash"
            && !self.subagent
            && !tools::bool_arg(input, "run_in_background")
            && let Some(secs) = crate::auto::long_wait(input["command"].as_str().unwrap_or(""))
        {
            return self.background_wait(input, secs);
        }
        if crate::background::handles(name)
            || (name == "Bash" && tools::bool_arg(input, "run_in_background"))
        {
            if self.subagent {
                anyhow::bail!(
                    "background work isn't available to subagents; run it in the foreground"
                );
            }
            if name == "Bash" {
                return crate::background::start_job(
                    &self.shared.bg,
                    input,
                    &self.ctx,
                    &self.jobs_dir(),
                );
            }
            return crate::background::run(&self.shared.bg, name, input, &self.ctx);
        }
        if name == crate::ask::TOOL {
            return self.ask_user(id, input).await;
        }
        if crate::tools::sessions::is_tool(name) && !self.subagent {
            return self.session_tool(id, name, input).await;
        }
        if name == crate::irc::TOOL && !self.subagent {
            let Some(bus) = self.irc() else {
                anyhow::bail!("the IRC bus isn't enabled for this conversation");
            };
            return crate::irc::run(&bus, input);
        }
        if name == crate::present::TOOL {
            return crate::present::run(input, &self.ctx.root, self.harness.tier == Tier::Weak);
        }
        if name == crate::folder::TOOL && !self.subagent {
            return self.use_folder(input).await;
        }
        if name == crate::title::TOOL {
            let title = crate::title::parse(input)?;
            self.set_title(title.clone());
            return Ok(tools::Output::text(format!("Session titled \"{title}\".")));
        }
        if name == crate::panes::TERMINAL {
            return self.shared.panes.terminal(input, self.subagent).await;
        }
        if name == crate::panes::PREVIEW {
            return self.shared.panes.preview(input, self.subagent).await;
        }
        if self.mcp.handles(name) {
            let hub = self.mcp.clone();
            let out = hub.call(id, name, input).await;
            // Record loaded tools if McpTools was called
            if name == crate::mcp::SEARCH_TOOL {
                if out.is_ok() {
                    let loaded = hub.loaded();
                    if !loaded.is_empty() {
                        self.record(crate::session::Record::LoadedTools { tools: loaded });
                    }
                }
            }
            return out;
        }
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        self.ctx.progress = Some(tx);
        let (preview_tx, mut preview_rx) = mpsc::unbounded_channel();
        self.ctx.preview = Some(preview_tx);
        // The tool holds `ctx` mutably, so deltas go out through a detached emitter.
        let emit = {
            let (journal, id) = (self.shared.journal.clone(), id.to_string());
            move |text: String| {
                journal.emit(Event::ItemDelta {
                    id: id.clone(),
                    delta: Delta::Output { text },
                });
            }
        };
        let cwd_before = self.ctx.cwd.clone();
        let mut out = {
            // Stop cancels a long tool in flight (Bash kills its process group), not just
            // between tools: watch the turn's token alongside the tool future.
            self.ctx.cancel = Some(self.shared.cancel.lock().unwrap().clone());
            let run = tools::run(name, input, &mut self.ctx);
            tokio::pin!(run);
            loop {
                tokio::select! {
                    out = &mut run => break out,
                    Some(chunk) = rx.recv() => emit(chunk),
                    Some(delta) = preview_rx.recv() => { self.shared.journal.emit(Event::ItemDelta { id: id.to_string(), delta }); },
                }
            }
        };
        self.ctx.cancel = None;
        while let Ok(chunk) = rx.try_recv() {
            emit(chunk);
        }
        while let Ok(delta) = preview_rx.try_recv() {
            self.shared.journal.emit(Event::ItemDelta {
                id: id.to_string(),
                delta,
            });
        }
        self.ctx.progress = None;
        self.ctx.preview = None;
        // Cancelled mid-run: the result reads as an interrupt, not an error, and the turn ends
        // cleanly right after (run_tools' remaining calls skip, the caller sees Interrupted).
        if out.is_err() && self.shared.cancel.lock().unwrap().is_cancelled() {
            out = Ok(tools::Output {
                content: "Interrupted by user.".into(),
                ..Default::default()
            });
        }
        // A `cd` that stuck: say where the shell works now, durably (SessionStatus on a dead
        // session reads it from the log).
        // (Compared canonically: the shell reports `pwd -P`, so `/var` comes back as
        // `/private/var` without having moved.)
        let canon = |p: &PathBuf| p.canonicalize().unwrap_or_else(|_| p.clone());
        if self.ctx.cwd != cwd_before && canon(&self.ctx.cwd) != canon(&cwd_before) {
            self.shared.journal.emit(Event::ShellCwd {
                cwd: self.ctx.cwd.clone(),
            });
        }
        out
    }

    /// Run one batch of tool calls. Returns true if the user denied one.    /// Whether the model may call `name` now: it's in the tool list this step was offered, or
    /// it's a connected MCP server's tool (with many, only some are listed up front and the
    /// rest load on demand; that saves context, it isn't a permission).
    pub(super) fn offers(&self, name: &str) -> bool {
        self.specs.iter().any(|s| s.name == name)
            || (name.starts_with("mcp__") && self.mcp.handles(name))
    }

    /// A context to run `name` in on the side (while its reply is still streaming, or beside
    /// the reply's other reads), if it may: a call that changes nothing and that the permission
    /// layers never ask about ([`crate::auto::parallel_read`]), which this step offers. Its own
    /// context, so nothing it records reaches `self.ctx` unless its result is used.
    pub(super) fn early_ctx(&self, name: &str, input: &Value) -> Option<Ctx> {
        let ok = crate::auto::parallel_read(name, input)
            && self.offers(name)
            && !self.mcp.handles(name)
            && input.get("_invalid_json").is_none()
            // A working directory deleted out from under the session: `run_tool` falls back
            // to the root and says so, which a call run on the side can't.
            && self.ctx.cwd.is_dir();
        ok.then(|| Ctx {
            root: self.ctx.root.clone(),
            cwd: self.ctx.cwd.clone(),
            read_files: HashMap::new(),
            todos: Vec::new(),
            sandbox: self.ctx.sandbox.clone(),
            shell_sandbox: self.ctx.shell_sandbox.clone(),
            sandbox_extra: self.ctx.sandbox_extra.clone(),
            permitted: self.ctx.permitted.clone(),
            progress: None,
            preview: None,
            cancel: None,
            web: self.ctx.web.clone(),
            image: self.ctx.image.clone(),
            screenshot_endpoint: self.ctx.screenshot_endpoint.clone(),
            judge: self.ctx.judge.clone(),
        })
    }

    /// The result of a call that started early, as running it now would give, and how long
    /// it ran before `now` (time the turn didn't wait for it).
    pub(super) async fn finish_early(
        &mut self,
        call: crate::early::Call,
        now: Instant,
    ) -> Option<(Result<tools::Output>, Duration)> {
        let ran = call.finish().await?;
        // What it read counts as read, as if it had run now.
        self.ctx.read_files.extend(ran.read_files);
        let overlap = ran.done.min(now).saturating_duration_since(ran.started);
        Some((ran.out, overlap))
    }

    pub(super) async fn run_tools(
        &mut self,
        uses: Vec<(String, String, Value)>,
        guard: &mut LoopGuard,
        mut early: crate::early::Early,
    ) -> Result<Batch> {
        // Results accumulate in place so an interrupt keeps what already ran.
        self.push_msg(Message {
            role: Role::User,
            content: Vec::new(),
        });
        let mut denied = false;
        let mut blocked: Option<String> = None;
        let mut looping = false;
        let mut replan: Option<String> = None;
        let uses_len = uses.len();
        // Parallel reads: the reply's leading run of calls that change nothing all start now,
        // side by side (those its stream already started keep running), and the loop below
        // takes their results in order. The first call that could change something closes the
        // run, so it and everything after it run one at a time, after every read before it.
        if self.cfg.early_tools {
            for (index, (_, name, input)) in uses.iter().enumerate() {
                let ctx = self.early_ctx(name, input);
                early.ready(index, name.clone(), input.clone(), ctx);
            }
        }
        for index in 0..uses_len {
            // Safe point between tool calls (the previous call's result is recorded): an
            // update's drain records the rest of the batch as interrupted-by-update and
            // suspends the turn here, before anything more runs.
            if drain_pending(&self.shared).await {
                self.mark_suspended(&uses, index);
                return Ok(Batch::Suspended);
            }
            let (id, name, input) = uses[index].clone();
            // Taken for every call, so a mismatch drops all the early runs after it.
            let started_early = early.take(index, &name, &input);
            let key = format!("{name}\u{0}{input}");
            let count = guard.counts.entry(key.clone()).or_insert(0);
            // Reading a pane again is polling, not looping: what's there changes.
            if !crate::panes::is_read(&name, &input) {
                *count += 1;
            }
            let seen = *count;
            let (_, arg) = tools::label(&name, &input, &self.ctx);
            if seen <= 1 {
                guard.stale_replans = 0;
            }
            guard.note_recent(format!("{name} {arg}"));
            // The 3rd and 5th identical call ask the model to re-plan; the last stops the turn.
            if seen == LOOP_REPLAN || seen == LOOP_STOP - 1 {
                guard.stale_replans += 1;
                replan = Some(guard.replan(&format!("{name} {arg}"), seen));
            }
            if seen >= LOOP_STOP || guard.stale_replans >= LOOP_STALE_REPLANS {
                looping = true;
            }
            let replay = if seen >= LOOP_NUDGE && !looping {
                guard
                    .last
                    .get(&key)
                    .map(|r| format!("{r}\n{}", repeat_nudge(&name, &input, r, seen)))
            } else {
                None
            };
            let mut executed = false;
            self.emit(Event::ItemStarted {
                id: id.clone(),
                kind: ItemKind::ToolCall {
                    name: name.clone(),
                    arg: arg.clone(),
                },
            });

            let text = |outcome, content: String, display: Option<&str>| {
                (
                    outcome,
                    tools::Output {
                        content,
                        display: display.map(String::from),
                        ..Default::default()
                    },
                )
            };
            let (outcome, out) = if looping {
                let msg = format!(
                    "Not run: repeated calls (this one made {seen} times). Stopping the turn; the work so far is kept."
                );
                text(
                    ToolOutcome::Error,
                    msg,
                    Some("refused: repeated identical call"),
                )
            } else if let Some(content) = replay {
                text(
                    ToolOutcome::Ok,
                    content,
                    Some("repeated call: earlier result reused"),
                )
            } else if seen >= LOOP_REPLAN {
                let msg = format!(
                    "Not run: this exact call already ran {} times this turn with the same result. \
Don't repeat it. Change the arguments or try a different approach.",
                    seen - 1
                );
                text(
                    ToolOutcome::Error,
                    msg,
                    Some("refused: repeated identical call"),
                )
            } else if blocked.is_some() {
                text(
                    ToolOutcome::Skipped,
                    "Skipped: the turn ended on a call that was already denied.".to_string(),
                    None,
                )
            } else if denied {
                text(
                    ToolOutcome::Skipped,
                    "Skipped: an earlier tool call was rejected.".to_string(),
                    None,
                )
            } else if !self.offers(&name) {
                // Only what this step offered runs: a chat has no Bash however it's asked for.
                text(
                    ToolOutcome::Error,
                    format!(
                        "There's no `{name}` tool in this conversation. Use only the tools you were given."
                    ),
                    Some("refused: not an available tool"),
                )
            } else if let Decision::Deny = self.timed_permit(&id, &name, &arg, &input).await {
                if let Some(denial) = self.blocked.clone() {
                    // A retry of a call already denied this turn: no second card. The turn
                    // ends with the denial, so whoever wakes the agent next sees why.
                    self.last_note = None;
                    blocked = Some(denial.clone());
                    text(
                        ToolOutcome::Denied,
                        format!(
                            "Not run: this exact call was already denied this turn ({denial}). frog didn't ask again and ended the turn. Don't retry it: find another way, or leave it for the user."
                        ),
                        None,
                    )
                } else {
                    // A deny with a note (the user's, or frog's own when the prompt timed
                    // out) is direction, not a stop: the agent adjusts and carries on.
                    let (msg, stop) = match self.last_note.take() {
                    Some(note) => (
                        format!("Not run: the call was denied with this note: {note}\nAdjust your approach accordingly and continue with the rest of the task."),
                        false,
                    ),
                    None if self.can_ask => (
                        "The user rejected this tool call. Stop and wait for their instructions.".to_string(),
                        true,
                    ),
                    None => (
                        "Not permitted in non-interactive mode (run with --yolo to allow).".to_string(),
                        false,
                    ),
                };
                    denied = stop;
                    text(ToolOutcome::Denied, msg, None)
                }
            } else {
                let started = Instant::now();
                self.snapshot(&name, &input);
                // Provenance: which paths this call is about to bring into being.
                let before: Vec<PathBuf> = match &*name {
                    "Bash" => crate::approval::missing(
                        input["command"].as_str().unwrap_or(""),
                        &self.ctx.cwd,
                    ),
                    "Write" => input["file_path"]
                        .as_str()
                        .map(|p| crate::approval::normalize(&self.ctx.resolve(p)))
                        .filter(|p| !p.exists())
                        .into_iter()
                        .collect(),
                    _ => Vec::new(),
                };
                let ran = match started_early {
                    Some(call) => self.finish_early(call, started).await,
                    None => None,
                };
                let early = ran.as_ref().map(|(_, overlap)| ms(*overlap));
                // A drain past its deadline kills the tool in flight (the same token
                // `Interrupt` uses) and records it interrupted-by-update.
                let r = match ran {
                    Some((r, _)) => r,
                    None => {
                        // A tool in flight gets the rest of the drain deadline; past it, the
                        // tool is killed (dropping its future kills its process group) and
                        // recorded interrupted-by-update, here and for the rest of the batch.
                        let deadline = drain_deadline(self.shared.clone());
                        tokio::select! {
                            r = self.run_tool(&id, &name, &input) => r,
                            _ = deadline => {
                                self.mark_suspended(&uses, index);
                                return Ok(Batch::Suspended);
                            }
                        }
                    }
                };
                self.created
                    .extend(before.into_iter().filter(|p| p.exists()));
                let took = ms(started.elapsed());
                self.timing.tool_ms += took;
                self.timing.early_ms += early.unwrap_or(0);
                if let Some(t) = self.timing.tools.last_mut() {
                    t.ms = took;
                    t.early = early.is_some();
                }
                executed = true;
                match r {
                    Ok(o) => (ToolOutcome::Ok, o),
                    Err(e) => text(ToolOutcome::Error, format!("Error: {e:#}"), None),
                }
            };
            let mut out = out;
            // Captured before the item's parts move into its event: a shell command queued
            // for a gist when it finished (see the queue after `ItemCompleted`).
            let (is_bash, item_id, command, out_head) = if name == "Bash" {
                (
                    true,
                    id.clone(),
                    input["command"].as_str().unwrap_or("").to_string(),
                    out.content.chars().take(400).collect(),
                )
            } else {
                (false, String::new(), String::new(), String::new())
            };
            // One result can't blow the window (and being the most recent, it would never be
            // pruned): clip anything larger than MAX_RESULT_SHARE of the window.
            let result_cap = self.result_cap();
            if out.content.len() > result_cap {
                out.content = crate::tools::truncate_middle(&out.content, result_cap);
                out.content.push_str(&format!(
                    "\n\n[frog] Output capped at {} of the model's {}-token window; ask more narrowly or read a range.",
                    result_cap, self.window
                ));
            }
            if outcome == ToolOutcome::Ok {
                if executed && replayable(&name) {
                    guard.last.insert(key.clone(), out.content.clone());
                }
                // The world changed, so earlier results and repeat counts no longer apply.
                if matches!(&*name, "Edit" | "Write") {
                    guard.last.clear();
                    guard.counts.clear();
                    guard.stale_replans = 0;
                } else if name == "Bash" {
                    guard.last.clear();
                }
            }
            // A repeat that had to run fresh still gets the nudge.
            if executed && seen == LOOP_NUDGE && outcome == ToolOutcome::Ok {
                let n = repeat_nudge(&name, &input, &out.content, seen);
                out.content = format!("{}\n{n}", out.content);
            }
            let output = out.content;
            // Rules scoped to the file just read or edited go in front of its result, the
            // first time this session.
            let rules = match (&*name, outcome == ToolOutcome::Ok) {
                ("Read" | "Edit" | "Write", true) => input["file_path"]
                    .as_str()
                    .map(|p| self.ctx.resolve(p))
                    .map(|p| self.rules_for(&p))
                    .unwrap_or_default(),
                _ => String::new(),
            };
            if let Some(d) = &out.diff
                && let Some(rel) = self.rel(Path::new(&d.path))
                && !self.conv.edited.contains(&rel)
            {
                self.conv.edited.push(rel);
            }

            self.extend_last(vec![Block::ToolResult {
                id: id.clone(),
                name: name.clone(),
                content: format!("{rules}{output}"),
                is_error: outcome != ToolOutcome::Ok,
            }]);
            // Images a tool returned (a render, a screenshot) go to the model too, after the
            // results; `prepare_images` decides per request whether it gets to see them.
            let seen: Vec<Block> = out
                .images
                .iter()
                .take(2)
                .map(|i| Block::Image {
                    mime: i.mime.clone(),
                    data: i.data.clone(),
                })
                .collect();
            if !seen.is_empty() {
                self.extend_last(seen);
            }
            self.emit(Event::ItemCompleted {
                id,
                item: Item::ToolCall {
                    name,
                    arg,
                    input,
                    outcome,
                    output,
                    display: out.display,
                    diff: out.diff,
                    diagram: out.diagram,
                    present: out.present,
                    images: out.images,
                    app: out.app,
                },
            });
            // Queue a gist for a finished shell command, written when the turn ends in one
            // batched side-model call (see `flush_gists`). Skipped calls (not run) don't
            // need one; the elided command tells that story.
            if is_bash && outcome == ToolOutcome::Ok && executed {
                self.pending_gists.push((item_id, command, out_head));
            }
        }
        if looping {
            let why = format!(
                "[frog] Turn stopped: the same tool call repeated {LOOP_STOP} times, or {LOOP_STALE_REPLANS} \
re-plans passed with no new call. Everything done so far is kept; give a different instruction to continue."
            );
            self.notice(Level::Warn, why.clone());
            self.extend_last(vec![Block::Text { text: why }]);
        } else if let Some(r) = replan {
            self.extend_last(vec![Block::Text { text: r }]);
        }
        Ok(if let Some(denial) = blocked {
            Batch::Blocked(denial)
        } else if denied {
            Batch::Denied
        } else if looping {
            Batch::Looping
        } else {
            Batch::Continue
        })
    }

    /// Every call in the batch from `from` on never ran (an update's drain stopped it):
    /// record each as interrupted-by-update in the batch's results message, so the history
    /// is whole and `repair()` has nothing dangling on resume.
    pub(super) fn mark_suspended(&mut self, uses: &[(String, String, Value)], from: usize) {
        let missing: Vec<Block> = uses[from..]
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
        self.sync_log();
    }

    /// What a model call sends for `messages` in the current tool mode.
    pub(super) fn wire(&self, messages: &[Message], specs: &[ToolSpec]) -> Wire {
        let with_images = self.prepare_images(messages);
        let prepared = with_images.as_deref().unwrap_or(messages);
        match self.harness.tool_mode {
            ToolMode::Text => Wire {
                system: format!("{}{}", self.system, prompt::text_tools_prompt(specs)),
                messages: Some(prompt::to_text_mode(prepared)),
                native_tools: false,
                format: None,
            },
            ToolMode::Json => Wire {
                system: format!("{}{}", self.system, prompt::json_tools_prompt(specs)),
                messages: Some(prompt::to_json_mode(prepared)),
                native_tools: false,
                format: Some(prompt::json_schema(specs)),
            },
            ToolMode::Native | ToolMode::Auto => Wire {
                system: self.system.clone(),
                messages: with_images,
                native_tools: true,
                format: None,
            },
        }
    }

    /// Images as the model should get them: the last few as images for a model that can see,
    /// the rest (and all of them, for one that can't) as a short note. `None` when there are
    /// no images to change.
    pub(super) fn prepare_images(&self, messages: &[Message]) -> Option<Vec<Message>> {
        const KEEP: usize = 3;
        let total = messages
            .iter()
            .flat_map(|m| &m.content)
            .filter(|b| matches!(b, Block::Image { .. }))
            .count();
        let keep = if self.vision { KEEP } else { 0 };
        if total <= keep {
            return None;
        }
        let mut seen = 0;
        let out = messages
            .iter()
            .map(|m| Message {
                role: m.role,
                content: m
                    .content
                    .iter()
                    .map(|b| match b {
                        Block::Image { mime, .. } => {
                            seen += 1;
                            if seen > total - keep {
                                b.clone()
                            } else if self.vision {
                                Block::Text {
                                    text: format!("[earlier {mime} image omitted to save context]"),
                                }
                            } else {
                                Block::Text {
                                    text: format!(
                                        "[{mime} image attached; this model can't see images]"
                                    ),
                                }
                            }
                        }
                        other => other.clone(),
                    })
                    .collect(),
            })
            .collect();
        Some(out)
    }
}
