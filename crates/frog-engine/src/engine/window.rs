//! What goes into a model call: system prompt and harness, repo map, summaries, thinking, the context window and fitting the history into it.

use super::*;

impl Agent {
    /// Recompute tier, tool mode and system prompt from the profile and capabilities.
    pub(super) fn apply_harness(&mut self) {
        self.harness.apply(&self.profile);
        let base = if self.chat {
            prompt::chat_prompt(&self.cfg, &self.profile.model)
        } else {
            prompt::system_prompt(&self.root, &self.cfg, &self.profile.model)
        };
        let rules = crate::rules::prompt_section(
            &self.rules,
            crate::rules::prompt_budget(self.harness.tier),
        );
        self.system = format!("{base}{rules}{}", harness::guidance(self.harness.tier));
        if !self.subagent && self.shared.sessions.enabled() {
            self.system.push_str(crate::tools::sessions::PROMPT);
        } else if !self.subagent && !self.chat {
            self.system.push_str(crate::tools::sessions::LOCAL_PROMPT);
        }
        if !self.subagent && self.irc().is_some() {
            self.system.push_str(crate::irc::PROMPT);
            self.system.push_str(crate::irc::APPROVAL_PROMPT);
        }
        if !self.chat && !self.subagent {
            self.system
                .push_str(prompt::panes_prompt(self.shared.panes.client()));
        }
        if !self.plain_chat() {
            self.system.push_str(&self.mcp.prompt());
        }
        if self.subagent {
            self.system.push_str(if self.cfg.subagent_write {
                crate::subagent::WRITE_PROMPT
            } else {
                crate::subagent::PROMPT
            });
        }
        // No Skill tool in a small window (see `sync_specs`), so no catalog either.
        if !self.small_window() {
            self.system.push_str(&crate::skills::catalog(&self.skills));
        }
        let (index, omitted) = crate::memory::index(&self.notes, self.harness.tier, self.window);
        self.system.push_str(&index);
        self.notes_omitted = omitted;
        if self.has_recall() {
            self.system
                .push_str("\nRecall searches your notes and past sessions in this project.\n");
        }
        // The store's contents never go in the prompt (that's the point): only how to reach it.
        if self.compiled.is_some() {
            self.system.push_str(crate::compiled_memory::PROMPT);
        }
        // Last, since it's the one part that changes between turns.
        self.system.push_str(&self.repo_map.text);
    }

    /// Whether `Recall` is offered: there's a project with notes and summaries to search.
    pub(super) fn has_recall(&self) -> bool {
        !self.chat
            && self
                .memory
                .as_ref()
                .is_some_and(|m| m.sessions_dir().is_some())
    }

    /// Notes and this project's session summaries, for `Recall`.
    pub(super) fn recall_sources(&self) -> Vec<crate::summary::Stored> {
        self.memory
            .as_ref()
            .and_then(|m| m.sessions_dir())
            .map(|d| crate::summary::load(&d))
            .unwrap_or_default()
    }

    /// Rebuild the repo map for small and mid-size models if files changed (or `mentioned`
    /// names a source file it doesn't show). Only called between turns, so the prompt prefix
    /// holds while a turn runs.
    pub(super) fn refresh_repo_map(&mut self, mentioned: &[String]) {
        self.poll_repo_map();
        if self.chat || self.subagent || self.memory.is_none() {
            return;
        }
        let budget = match crate::repomap::budget(self.harness.tier) {
            // A small window gets the top of the map only.
            b if self.small_window() => b.min(Self::SMALL_REPO_MAP),
            b => b,
        };
        if budget == 0 {
            if !self.repo_map.text.is_empty() {
                self.repo_map = Default::default();
                self.map_logged = false;
                self.log_map();
            }
            return;
        }
        // The initial build was scheduled from `Agent::new`; if it has completed, keep it.
        // Rebuilds after edits are scheduled by `rebased`, where the system prompt is rebuilt.
        if !self.repo_map.text.is_empty() {
            return;
        }
        if self.map_building {
            return;
        }
        let cache = self
            .memory
            .as_ref()
            .and_then(|m| m.project_file(crate::repomap::CACHE_FILE));
        let root = self.root.clone();
        let cache = cache.clone();
        let mentioned = mentioned.to_vec();
        let edited = self.conv.edited.clone();
        let tx = self.map_build_tx.clone();
        self.map_building = true;
        std::thread::spawn(move || {
            let Some(root) = crate::checkpoint::repo_root(&root) else {
                let _ = tx.send((crate::repomap::Map::default(), false));
                return;
            };
            let home = dirs::home_dir().and_then(|p| p.canonicalize().ok());
            let canonical = root.canonicalize().unwrap_or_else(|_| root.clone());
            if canonical == Path::new("/") || home.as_deref() == Some(canonical.as_path()) {
                let _ = tx.send((crate::repomap::Map::default(), false));
                return;
            }
            let seeds = crate::repomap::Seeds {
                mentioned: &mentioned,
                edited: &edited,
            };
            let result = crate::repomap::build_bounded(
                &root,
                cache.as_deref(),
                &seeds,
                budget,
                20_000,
                Some(Duration::from_secs(2)),
            );
            let _ = tx.send(result);
        });
    }

    pub(super) fn poll_repo_map(&mut self) {
        let Ok((map, capped)) = self.map_build_rx.lock().unwrap().try_recv() else {
            return;
        };
        self.map_building = false;
        if capped {
            self.notice(Level::Info, "repo map limited to 20,000 files or 2 seconds");
        }
        if map.text != self.repo_map.text {
            self.map_logged = false;
        }
        self.repo_map = map;
        self.log_map();
    }

    /// Log the repo map if the session log doesn't hold it yet. Only into a log that exists: a
    /// conversation opened and never used shouldn't get one just for its map.
    pub(super) fn log_map(&mut self) {
        if self.map_logged || self.store.is_none() || !self.shared.journal.has_log() {
            return;
        }
        self.record(Record::RepoMap {
            map: self.repo_map.clone(),
        });
        self.map_logged = true;
    }

    /// `path` relative to the project root, for rules and the repo map.
    pub(super) fn rel(&self, path: &Path) -> Option<String> {
        let p = if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.root.join(path)
        };
        p.strip_prefix(&self.root)
            .ok()
            .map(|r| r.to_string_lossy().into_owned())
    }

    /// The scoped rules `path` matches that haven't been shown this session, as a block.
    pub(super) fn rules_for(&mut self, path: &Path) -> String {
        let Some(rel) = self.rel(path) else {
            return String::new();
        };
        let due = crate::rules::due(&self.rules, &rel, &mut self.conv.rules_seen);
        crate::rules::block(&due, &rel, crate::rules::inject_budget(self.harness.tier))
    }

    /// Write or update this session's summary from its log. No model call.
    pub(super) fn write_summary(&self) {
        let Some(summary) = self.build_summary() else {
            return;
        };
        let Some(out) = self.memory.as_ref().and_then(|m| m.sessions_dir()) else {
            return;
        };
        if let Err(e) = crate::summary::write(&out, &summary) {
            self.notice(
                Level::Warn,
                format!("couldn't write the session summary: {e:#}"),
            );
        }
    }

    /// This session's structured summary (the #53 fields: files with +/−, turns with their
    /// requests/outcomes, tests run), built from the log without a model call. None when
    /// there's nothing to summarize (no store, no log, no events).
    pub(super) fn build_summary(&self) -> Option<crate::summary::Summary> {
        let dir = self.store.as_ref()?;
        if !self.shared.journal.has_log() {
            return None;
        }
        let loaded = session::load(dir, &self.conv.session_id).ok()?;
        if loaded.events.is_empty() {
            return None;
        }
        Some(crate::summary::build(&loaded.header, &loaded.events, None))
    }

    /// `/remember`, `/forget`, `/memory` and `/recall`: answered with a notice, no model call.
    /// Returns false if `text` isn't one of them.
    pub(super) fn memory_command(&mut self, text: &str) -> bool {
        if self.subagent || !crate::memory::is_command(text) {
            return false;
        }
        let Some(store) = &self.memory else {
            self.notice(
                Level::Warn,
                "memory isn't available without a session store",
            );
            return true;
        };
        if let Some(query) = crate::memory::recall_query(text) {
            let sessions = self.recall_sources();
            let sources = crate::recall::Sources {
                notes: &self.notes,
                sessions: &sessions,
            };
            let reply = crate::recall::command(&sources, query, self.harness.tier);
            self.notice(Level::Info, reply);
            return true;
        }
        let Some(reply) = crate::memory::command(store, &self.notes, text, self.notes_omitted)
        else {
            return false;
        };
        if reply.changed {
            self.notes = store.load();
            self.apply_harness();
        }
        self.notice(reply.level, reply.message);
        true
    }

    /// The `thinking` setting in effect: the profile's, else the global one.
    pub(super) fn thinking_mode(&self) -> Thinking {
        self.profile.thinking.unwrap_or(self.cfg.thinking)
    }

    /// The thinking switch for the next call, given whether [`thinking::wanted`] it.
    pub(super) fn think_switch(&self, want: bool) -> Option<bool> {
        let can_switch = match &self.harness.caps {
            // Nothing to switch off.
            Some(c) if !c.thinks => return None,
            Some(c) => c.think_off,
            None => None,
        };
        thinking::switch(self.thinking_mode(), can_switch, want)
    }

    /// The reasoning-token cap for the next call, given its thinking switch: only for servers
    /// that take one, and only where the model thinks.
    pub(super) fn think_budget(&self, think: Option<bool>) -> Option<u32> {
        if !self.budget_ok || self.thinking_mode() == Thinking::Never {
            return None;
        }
        let base = self
            .profile
            .thinking_budget
            .unwrap_or(self.cfg.thinking_budget);
        thinking::budget(base, think, &self.conv.messages)
    }

    /// Measure the model again when its cached probe is older than `harness::PROBE_TTL_MS`,
    /// once per session, before the turn's first call. An old finding (native tools broken, say)
    /// would otherwise decide the tool mode forever. Only under `auto`, which is what reads it,
    /// and never for a model whose native tools are known.
    pub(super) async fn reprobe_if_stale(&mut self) {
        if self.harness.reprobed
            || !harness::reprobe_due(&self.profile, self.harness.caps.as_ref(), now_ms())
        {
            return;
        }
        self.harness.reprobed = true;
        // The full tool set, as `frog probe` measures: the probe asks for a Read, which a
        // chat's trimmed specs don't have.
        let specs = tools::specs();
        let probed = harness::probe(&self.provider, &specs, |label, completed, total| {
            self.emit(Event::Progress {
                label: label.into(),
                completed: Some(completed),
                total: Some(total),
            })
        })
        .await;
        match probed {
            Ok(caps) => {
                if self.store.is_some() {
                    harness::save(&self.profile, &caps);
                }
                self.harness.caps = Some(caps);
            }
            Err(e) => self.notice(
                Level::Warn,
                format!(
                    "{}'s capability profile is out of date and re-checking it failed ({e:#}); using the old one",
                    self.profile.model
                ),
            ),
        }
    }

    /// Whether `<tool_call>` text in a reply is a call: always in text mode, and under native
    /// only for models that may slip into it (Qwen/Hermes templates on some servers). A model
    /// known to call tools natively that writes one is quoting the format, not calling.
    pub(super) fn recovers_text_calls(&self) -> bool {
        self.harness.recovers_text_calls(&self.profile)
    }

    /// The model botched the tool-call format (text calls under native, invalid JSON args, or
    /// JSON mode not honored). Under `auto`, two strikes moves to text mode for this session
    /// only: the finding is never written to the capability cache (see `harness::save`), and a
    /// model whose native tools are known to work never moves.
    pub(super) fn note_format_failure(&mut self, why: &str) {
        let Some(from) = self.harness.note_format_failure(&self.profile, why) else {
            return;
        };
        // never persist the downgrade to the capability cache
        let from = format!("{from:?}").to_lowercase();
        self.warn_text_mode(format!(
            "{from} tool calls failed twice ({why}); switching this session to text tool calls. \
Not saved: the next session starts on {from} again"
        ));
    }

    /// Say so whenever a session runs on text tool calls it didn't ask for, naming the model and
    /// why: in the transcript, and in the engine log (stderr), so a demoted model can't go
    /// unnoticed.
    pub(super) fn warn_text_mode(&self, why: String) {
        let message = format!("{} ({}): {why}", self.profile_name, self.profile.model);
        eprintln!("frog: text tool calls: {message}");
        self.notice(Level::Warn, message);
    }

    /// At session start or a model switch: a cached probe that put `auto` on text tool calls.
    pub(super) fn note_text_mode_from_probe(&self) {
        if self.profile.tool_mode != ToolMode::Auto || self.harness.tool_mode != ToolMode::Text {
            return;
        }
        let when = self
            .harness
            .caps
            .as_ref()
            .filter(|c| c.probed > 0)
            .and_then(|c| chrono::DateTime::from_timestamp_millis(c.probed))
            .map(|t| format!(" on {}", t.format("%Y-%m-%d")))
            .unwrap_or_default();
        self.warn_text_mode(format!(
            "using text tool calls: its capability probe{when} found native tool calls not working. \
`frog --probe -m <model>` measures again"
        ));
    }

    /// Settle the context window: configured value, bounded by what the server reports.
    /// Ollama allocates memory per `num_ctx`, so an unconfigured window stays at 32k.
    pub(super) async fn resolve_window(&mut self) {
        if let Some(model) = self.profile.sidecar.clone() {
            if !crate::sidecar::is_serving(&model).await {
                self.emit(Event::Progress {
                    label: format!("loading {model}"),
                    completed: None,
                    total: None,
                });
            }
            if let Err(e) = crate::sidecar::ensure(&self.profile).await {
                self.notice(Level::Warn, format!("{e:#}"));
            }
        }
        self.vision = match self.profile.vision {
            Some(v) => v,
            None => self.provider.supports_vision().await.unwrap_or(false),
        };
        let ext = self.provider.extensions().await;
        self.budget_ok = ext.thinking_budget;
        self.cache_key_ok = ext.cache_key;
        self.prefill_ok = ext.prefill;
        let configured = self.profile.context_window;
        let probed = self.provider.probe_context().await;
        // frog cloud's catalog entry is only a fallback: the server says what it runs.
        let cloud = self.provider.is_frog_api();
        self.window = match (configured, probed) {
            (Some(_), Some(p)) if cloud => p,
            (Some(c), Some(p)) if p < c => {
                self.notice(
                    Level::Warn,
                    format!("context_window is {c} but the server supports {p}; using {p}"),
                );
                p
            }
            (Some(c), _) => c,
            (None, Some(p)) if self.profile.provider == ProviderKind::Ollama => p.min(32_768),
            (None, Some(p)) => p,
            // Neither the config nor the server said: the catalog may still know the model's
            // real limit, which beats the per-provider default.
            (None, None) => crate::catalog::cached(&self.profile_name)
                .and_then(|m| m.context)
                .unwrap_or_else(|| self.profile.context_window()),
        };
        // Once per session: where the window came from, so a wrong one is traceable. `configured`
        // here means the catalog or the profile said it, not the server. Benchmarks (hermetic)
        // don't care.
        if !self.cfg.hermetic {
            let source = match (probed, configured) {
                (Some(_), _) => "server",
                (None, Some(_)) => "catalog",
                (None, None) => "default",
            };
            self.notice(
                Level::Info,
                format!(
                    "context window: {} tokens (from {source}); auto-compacting past {}",
                    self.window,
                    (self.window as f64 * context::HARD_LIMIT) as u64
                ),
            );
        }
        self.provider.set_context_window(self.window);
        // The tools, repo map and prompt were built before the window was known; a small one
        // trims them.
        if self.small_window() && self.repo_map.text.len() > Self::SMALL_REPO_MAP {
            self.repo_map = Default::default();
            self.refresh_repo_map(&[]);
        }
        self.start_compiled_memory().await;
        self.sync_specs();
        self.apply_harness();
        self.warm(None);
    }

    /// Compiled memory for this model, if its server keeps it (`compiled_memory`): ends the
    /// previous model's first, so a model switch saves what it held.
    pub(super) async fn start_compiled_memory(&mut self) {
        self.finish_compiled_memory().await;
        let setting = self.cfg.memory.compiled;
        if self.subagent || self.cfg.hermetic || setting == crate::compiled_memory::Compiled::Off {
            return;
        }
        let (Some(remote), Some(store)) = (self.provider.memory_remote(), self.memory.as_ref())
        else {
            if setting == crate::compiled_memory::Compiled::On {
                self.notice(
                    Level::Warn,
                    "[memory] compiled = \"on\", but this model's provider has no compiled memory.",
                );
            }
            return;
        };
        let blob = crate::compiled_memory::blob_path(store);
        let key = self.conv.session_id.clone();
        match crate::compiled_memory::Session::start(setting, remote, &key, blob).await {
            Ok(Some(s)) => {
                self.notice(
                    Level::Info,
                    format!("compiled memory: on ({})", s.blob().display()),
                );
                self.compiled = Some(s);
            }
            Ok(None) => {}
            Err(e) => self.notice(Level::Warn, format!("{e:#}")),
        }
    }

    /// Save compiled memory and end the server's session for it.
    pub(super) async fn finish_compiled_memory(&mut self) {
        if let Some(m) = self.compiled.take()
            && let Some(n) = m.finish().await
        {
            self.notice(Level::Warn, n);
        }
    }

    /// Have the server prefill this conversation as it stands (it was just opened or shown,
    /// or the model changed), plus `draft` as the next message when the user is typing one,
    /// so the next turn starts warm instead of re-reading everything. In the background, one
    /// at a time: newer drafts replace a queued one. A failure only costs the head start.
    pub(super) fn warm(&self, draft: Option<&str>) {
        if !self.prefill_ok
            || !self.cache_key_ok
            || (self.conv.messages.is_empty() && draft.is_none())
        {
            return;
        }
        let mut messages = self.conv.messages.clone();
        if let Some(draft) = draft {
            // As `turn` will send it: shell output waiting to go along, then the words.
            let mut text = self.conv.pending.join("\n");
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(draft);
            match messages.last_mut() {
                Some(m) if m.role == Role::User => m.content.push(Block::Text { text }),
                _ => messages.push(Message::user(text)),
            }
        }
        let wire = self.wire(&messages, &self.specs);
        let req = Request {
            system: &wire.system,
            messages: wire.messages(&messages),
            tools: if wire.native_tools { &self.specs } else { &[] },
            max_tokens: None,
            format: wire.format.as_ref(),
            think: None,
            think_budget: None,
            cache_key: Some(&self.conv.session_id),
            background: true,
        };
        let Some(prefill) = self.provider.prefill(&req) else {
            return;
        };
        *self.sent.lock().unwrap() = flatten(req.system, req.tools, req.messages);
        let prefill: Warming = Box::pin(prefill);
        let mut w = self.warming.lock().unwrap();
        if w.0 {
            w.1 = Some(prefill);
            return;
        }
        w.0 = true;
        drop(w);
        let warming = self.warming.clone();
        let log = self.cfg.log_calls;
        tokio::spawn(async move {
            let mut next = Some(prefill);
            while let Some(prefill) = next {
                let started = Instant::now();
                match prefill.await {
                    Ok(()) if log => {
                        eprintln!("warmed in {:.1}s", started.elapsed().as_secs_f64())
                    }
                    Err(e) if log => eprintln!("warming failed: {e:#}"),
                    _ => {}
                }
                let mut w = warming.lock().unwrap();
                next = w.1.take();
                w.0 = next.is_some();
            }
        });
    }

    pub(super) fn fixed_chars(&self) -> usize {
        fixed_chars(&self.system, &self.specs)
    }

    pub(super) fn estimate(&self) -> u64 {
        self.est
            .tokens(self.fixed_chars() + context::history_chars(&self.conv.messages))
    }

    /// The most chars one tool result may carry: [`context::MAX_RESULT_SHARE`] of the window,
    /// in chars via the estimator.
    pub(super) fn result_cap(&self) -> usize {
        self.est
            .chars((self.window as f64 * context::MAX_RESULT_SHARE) as u64)
            .max(MIN_RESULT_CAP)
    }

    /// Stage 1: prune stale and old tool output (no LLM), once the prompt passes `start` of the
    /// window. Stage 2: summarize again when new messages fill the window. The hard limit
    /// ([`context::HARD_LIMIT`]) bypasses the once-per-new-messages hysteresis: past it, the next
    /// call is one oversized tool result away from a provider 400, so compact regardless.
    pub(super) async fn fit_context(
        &mut self,
        compacted: &mut Option<usize>,
        start: f64,
    ) -> Result<()> {
        let pruned = self.prune(start);
        let hard = (self.window as f64 * context::HARD_LIMIT) as u64;
        if self.estimate() > hard
            || ((self.estimate() as f64) > self.window as f64 * context::COMPACT_AT
                && compacted.is_none_or(|len| self.conv.messages.len() > len))
        {
            self.notice(
                Level::Warn,
                if self.estimate() > hard {
                    "context is nearly at the provider's limit; summarizing…"
                } else {
                    "context is still nearly full after pruning; summarizing…"
                },
            );
            if let Err(e) = self.compact(None).await {
                // Same story as the overflow path above: one line to the transcript (the
                // client renders the event as a rescue line), the raw failure to the log.
                eprintln!("compaction failed: {e:#}");
                self.emit(Event::CompactionFailed {
                    detail: format!("{e:#}"),
                });
                anyhow::bail!("compaction failed; the history can't fit the context window");
            }
            *compacted = Some(self.conv.messages.len());
        } else if pruned {
            self.rebased();
        }
        Ok(())
    }

    /// Prune down to PRUNE_TO once the prompt passes `start` of the window, logging each
    /// replacement. Whether anything was pruned.
    pub(super) fn prune(&mut self, start: f64) -> bool {
        let window = self.window as f64;
        let before = self.estimate();
        if (before as f64) < window * start {
            return false;
        }
        let target = self.est.chars((window * context::PRUNE_TO) as u64);
        let plan = context::plan_prune(
            &self.conv.messages,
            target.saturating_sub(self.fixed_chars()),
        );
        if plan.is_empty() {
            return false;
        }
        for (id, content) in &plan {
            self.record(Record::Replace {
                id: id.clone(),
                content: content.clone(),
            });
            context::apply(&mut self.conv.messages, id, content);
        }
        self.emit(Event::ContextPruned {
            results: plan.len(),
            tokens_before: before,
            tokens_after: self.estimate(),
        });
        true
    }

    /// The history was just rewritten, so the cached prefix is gone anyway: the one time to
    /// bring the repo map (and with it the system prompt) up to date for free.
    pub(super) fn rebased(&mut self) {
        self.repo_map = Default::default();
        self.map_logged = false;
        self.refresh_repo_map(&[]);
        self.apply_harness();
    }

    /// Pin the working tree before the turn touches anything (git repos, persisted sessions only).
    pub(super) fn checkpoint(&self, turn: u64) {
        if self.store.is_none() {
            return;
        }
        let Some(root) = crate::checkpoint::repo_root(&self.root) else {
            return;
        };
        match crate::checkpoint::snapshot(&root, &format!("{}/{turn}", self.conv.session_id)) {
            Ok(commit) => self.record(Record::Checkpoint { turn, root, commit }),
            Err(e) => self.notice(
                Level::Warn,
                format!("couldn't checkpoint the working tree: {e:#}"),
            ),
        }
        // A picture of the preview to go with it, if there is one (doesn't hold the turn up).
        if let Some(dir) = &self.store {
            self.shared
                .panes
                .checkpoint(&self.conv.session_id, turn, dir);
        }
    }

    /// Before an Edit/Write, log the file's current content so the turn can be rewound.
    pub(super) fn snapshot(&self, name: &str, input: &Value) {
        if !matches!(name, "Edit" | "Write") {
            return;
        }
        let Some(p) = input["file_path"].as_str() else {
            return;
        };
        let path = self.ctx.resolve(p);
        let before = match std::fs::metadata(&path) {
            Ok(m) if m.len() > 4_000_000 => return,
            Ok(_) => match std::fs::read_to_string(&path) {
                Ok(s) => Some(s),
                Err(_) => return,
            },
            Err(_) => None,
        };
        self.record(Record::Snapshot {
            turn: self.conv.turn,
            path,
            before,
        });
    }
}
