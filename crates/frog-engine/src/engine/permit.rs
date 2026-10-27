//! Permissions: prompts, denials, the auto-mode judge and classifier.

use super::*;

impl Agent {
    /// [`Self::permit`], recording a [`ToolTiming`] with how long the user and the
    /// classifier took (the tool's own time is filled in once it runs).
    pub(super) async fn timed_permit(
        &mut self,
        item: &str,
        name: &str,
        arg: &str,
        input: &Value,
    ) -> Decision {
        let (user, classifier) = (self.timing.user_ms, self.timing.classifier_ms);
        let decision = self.permit(item, name, arg, input).await;
        let t = &self.timing;
        let timing = ToolTiming {
            id: item.to_string(),
            name: name.to_string(),
            ms: 0,
            early: false,
            user_ms: t.user_ms - user,
            classifier_ms: t.classifier_ms - classifier,
        };
        self.timing.tools.push(timing);
        decision
    }

    pub(super) async fn permit(
        &mut self,
        item: &str,
        name: &str,
        arg: &str,
        input: &Value,
    ) -> Decision {
        // A monitor's command is a shell command like any other; a bare timer runs nothing.
        let name = match name {
            crate::background::MONITOR
                if input["command"]
                    .as_str()
                    .is_some_and(|c| !c.trim().is_empty()) =>
            {
                "Bash"
            }
            crate::background::MONITOR => return Decision::Allow,
            n => n,
        };
        let kind = if crate::panes::is_read(name, input) {
            Kind::Read
        } else {
            tools::kind(name)
        };
        if kind == Kind::Read || self.mode == Mode::Yolo {
            return Decision::Allow;
        }
        let pane_action = input["action"].as_str().unwrap_or("");
        // `Terminal.run` is a shell command like any other, except that pane shells can't be
        // sandboxed (see `panes::shell_command`), so it asks the way an unsandboxed command
        // does. The other pane actions (typing into a shell, driving a page) ask on their own
        // terms.
        let terminal_run = name == crate::panes::TERMINAL && pane_action == "run";
        let pane = !terminal_run && matches!(name, crate::panes::TERMINAL | crate::panes::PREVIEW);
        // Web reads change nothing and show on their tool card, like reads — in every
        // mode (Cam's decision 2026-10-23): WebSearch always, WebFetch when the host is
        // a plain public domain (the fetch itself still re-checks every resolved IP
        // against private ranges, and a non-public host keeps asking as before). A
        // public-host GET sends nothing the request itself doesn't show.
        if kind == Kind::Net
            && (name == "WebSearch"
                || crate::tools::web::public_host(input["url"].as_str().unwrap_or("")))
        {
            self.decision(item, "rule", "allow", "read-only web call", 0);
            return Decision::Allow;
        }
        // MCP tools that only read (`list_*`, `get-*`, vcad's `inspect_*`, …) run without a
        // card in every mode: a manager in default mode stalled ten minutes on each one. Auto
        // mode keeps its slightly wider verb list on top.
        if name.starts_with("mcp__")
            && (crate::auto::mcp_read(name)
                || (self.mode == Mode::Auto && crate::auto::read_tool(name, input)))
        {
            self.decision(item, "rule", "allow", "read-only tool call", 0);
            return Decision::Allow;
        }
        // A write the user granted this server in `[mcp_trust]` (`planetscale = "write"`):
        // no card, but every one is on the record (engine log, a notice, the decision event).
        if let Some(server) = crate::auto::mcp_write(name).filter(|s| self.cfg.mcp_write_trusted(s))
        {
            let tool = crate::auto::mcp_parts(name).map_or(name, |(_, t)| t);
            let args = tools::truncate_middle(&input.to_string(), 400);
            let line = format!(
                "mcp_trust: ran {server} › {tool} without a card ([mcp_trust] {server} = \"write\"); args: {args}"
            );
            if self.cfg.log_calls {
                eprintln!("{line}");
            }
            self.notice(Level::Info, line);
            self.decision(
                item,
                "trust",
                "allow",
                &format!("write grant for {server}"),
                0,
            );
            return Decision::Allow;
        }
        let call = call_hash(name, input);
        if name == crate::folder::TOOL {
            return self.ask_folder(item, name, arg).await;
        }
        let mcp = name.starts_with("mcp__");
        let cmd = input["command"].as_str().unwrap_or("").trim();
        let prefix = cmd.split_whitespace().next().unwrap_or("").to_string();
        let leaves_sandbox = name == "Bash" && input["unsandboxed"].as_bool() == Some(true);
        // Layer 1, built-in rules, no model call. A command the parser proves
        // read-only (no writes, no subshells, no credential paths) runs without
        // asking in every mode, sandboxed or not: it can only read, and the
        // sandbox is a write fence, not the only thing standing between the agent
        // and `cat`.
        if name == "Bash"
            && !crate::shell::touches_credentials(cmd)
            && (bash_allowed(cmd, &self.cfg.allow_bash) || crate::shell::read_only(cmd))
        {
            self.decision(item, "rule", "allow", "read-only command", 0);
            return Decision::Allow;
        }
        // A sandboxed command can only write inside the project and can't read credentials,
        // so it runs without asking; leaving the sandbox always asks.
        if name == "Bash" && self.ctx.shell_sandbox.is_some() && !leaves_sandbox {
            self.decision(item, "sandbox", "allow", "sandboxed", 0);
            return Decision::Allow;
        }
        // A screenshot of a session-local file (the tool itself refuses anything outside the
        // workspace) or of localhost: a local capture and a localhost URL can only show the
        // session's own work. Anything else keeps asking. (Allow-by-default in every mode
        // would hand out the whole web; the chief's list scopes this to auto at minimum.)
        if name == "Screenshot" && self.mode == Mode::Auto && crate::auto::local_capture(input) {
            self.decision(
                item,
                "rule",
                "allow",
                "captures only the session's own work",
                0,
            );
            return Decision::Allow;
        }
        // A path prefix the user allowed for this program earlier this session.
        if name == "Bash"
            && !crate::shell::touches_credentials(cmd)
            && crate::approval::prefix_allows(cmd, &self.ctx.cwd, &self.prefix_allow)
        {
            self.decision(
                item,
                "session",
                "allow",
                "under a path prefix allowed this session",
                0,
            );
            return Decision::Allow;
        }
        // Provenance (auto mode): a routine build/test step (known build tools,
        // plain file ops, parser-proven reads; no interpreters, network or
        // substitutions) acting only on in-project paths or the session's own
        // scratch (paths it created, fresh dirs under the shared temp dir)
        // doesn't need the classifier or a prompt. Destructive programs there
        // need provenance; anything outside this scope still asks.
        if name == "Bash"
            && self.mode == Mode::Auto
            && !crate::shell::touches_credentials(cmd)
            && crate::auto::hard_rule(name, input, &self.ctx.root).is_none()
            && crate::approval::routine(cmd)
            && crate::approval::own_scope(cmd, &self.ctx.cwd, &self.ctx.root, &self.created)
        {
            self.decision(
                item,
                "provenance",
                "allow",
                "touches only the project or its own scratch",
                0,
            );
            return Decision::Allow;
        }
        let key = match kind {
            Kind::Edit => "edits".to_string(),
            Kind::Net => format!("web:{}", web_host(name, input)),
            _ if name == "Screenshot" => format!("visual:Screenshot:{}", capture_host(input)),
            _ if matches!(name, "Image" | "Compare") => format!("visual:{name}"),
            _ if mcp => format!("mcp:{name}"),
            _ if pane => format!("{}:{pane_action}", name.to_lowercase()),
            _ if leaves_sandbox => format!("bash-unsandboxed:{prefix}"),
            _ => format!("bash:{prefix}"),
        };
        // A Write/Edit into another checkout (the main repo when this session is in a worktree)
        // is outside the project whatever the mode: it asks, and is denied headless.
        let target = matches!(name, "Write" | "Edit")
            .then(|| input["file_path"].as_str().map(|p| self.ctx.resolve(p)))
            .flatten();
        let outside = target.as_ref().is_some_and(|p| self.ctx.outside(p));
        if let Some(path) = target.filter(|_| outside) {
            // Provenance (auto mode): writing into a path this session created,
            // or a fresh file in the shared temp dir, is the session's own
            // scratch — as in-project as its own checkout. Anything else
            // outside still asks (and is denied headless).
            if self.mode == Mode::Auto
                && crate::approval::path_in_own_scope(&path, &self.ctx.root, &self.created)
            {
                self.decision(
                    item,
                    "provenance",
                    "allow",
                    "writes only its own scratch",
                    0,
                );
                self.ctx.permitted.insert(path);
                return Decision::Allow;
            }
            if !self.can_ask {
                return Decision::Deny;
            }
            if let Some(d) = self.repeat_refusal(item, name, arg, call) {
                return d;
            }
            let id = new_id();
            let (tx, rx) = oneshot::channel();
            self.shared.pending.lock().unwrap().insert(id.clone(), tx);
            let preview = tools::fs::preview(name, input, &self.ctx);
            self.emit(Event::PermissionRequest {
                id: id.clone(),
                item: item.into(),
                name: name.into(),
                arg: arg.into(),
                always: String::new(),
                preview,
                reason: Some(format!(
                    "Writes outside this session's folder ({}).",
                    path.display()
                )),
                subagent: None,
                card: None,
            });
            let decision = rx.await.unwrap_or(Decision::Deny);
            self.emit(Event::PermissionResolved { id, decision });
            if decision != Decision::Deny {
                self.ctx.permitted.insert(path);
            } else {
                self.record_denial(call, "the user denied it".into());
            }
            return decision;
        }
        // Auto mode: a Write/Edit of the session's own scratch (a fresh path under the shared
        // temp dir, or one this session made) is as much its own as the project. `ctx.outside`
        // already counts temp dirs as scratch, so the hard rule's "outside the project" (which
        // knows only the project root) mustn't card it.
        if self.mode == Mode::Auto
            && matches!(name, "Write" | "Edit")
            && let Some(p) = input["file_path"].as_str()
            && crate::auto::hard_rule(name, input, &self.ctx.root).is_some()
            && crate::approval::path_in_own_scope(
                &crate::approval::normalize(&self.ctx.resolve(p)),
                &self.ctx.root,
                &self.created,
            )
        {
            self.decision(
                item,
                "provenance",
                "allow",
                "writes only its own scratch",
                0,
            );
            return Decision::Allow;
        }
        let auto = match kind {
            Kind::Edit => {
                self.mode == Mode::AcceptEdits
                    // Auto mode: edits inside the project are checkpointed and can be undone.
                    || (self.mode == Mode::Auto
                        && crate::auto::hard_rule(name, input, &self.ctx.root).is_none())
            }
            Kind::Net => false,
            _ if matches!(name, "Image" | "Screenshot" | "Compare")
                || mcp
                || leaves_sandbox
                || pane =>
            {
                false
            }
            // Read-only commands were allowed in layer 1 above; anything left
            // here is a write or unknown, which only auto mode's classifier may pass.
            _ => false,
        };
        if auto || self.session_allow.contains(&key) {
            self.decision(
                item,
                if self.session_allow.contains(&key) {
                    "session"
                } else {
                    "rule"
                },
                "allow",
                if self.session_allow.contains(&key) {
                    "allowed earlier this session"
                } else {
                    "mode allows it"
                },
                0,
            );
            return Decision::Allow;
        }
        let mut reason = leaves_sandbox.then(|| {
            "Runs outside the sandbox: it can change files anywhere and read your credentials."
                .to_string()
        });
        if terminal_run && self.ctx.shell_sandbox.is_some() {
            reason = Some(
                "Runs in a terminal pane, which isn't sandboxed: it can change files anywhere and read your credentials."
                    .to_string(),
            );
        }
        if self.mode == Mode::Auto {
            let sandbox = match (self.ctx.shell_sandbox.is_some(), leaves_sandbox) {
                (_, true) => crate::auto::Sandbox::Leaving,
                (true, false) => crate::auto::Sandbox::In,
                (false, false) => crate::auto::Sandbox::Off,
            };
            let started = Instant::now();
            let verdict = self.auto_judge(item, name, input, sandbox).await;
            let took = ms(started.elapsed());
            self.timing.classifier_ms += took;
            match verdict {
                Ok(()) => {
                    self.decision(
                        item,
                        "classifier",
                        "allow",
                        "the classifier approved it",
                        took,
                    );
                    return Decision::Allow;
                }
                Err(why) => {
                    let layer = if why == CLASSIFIER_DOWN_ASK {
                        "fallback"
                    } else {
                        "classifier"
                    };
                    self.decision(item, layer, "ask", &why, took);
                    reason = Some(format!(
                        "Auto mode asked because {}.",
                        why.trim_end_matches('.')
                    ))
                }
            }
        }
        if !self.can_ask {
            self.decision(item, "ask", "ask", "not interactive: denied", 0);
            return Decision::Deny;
        }
        if let Some(d) = self.repeat_refusal(item, name, arg, call) {
            return d;
        }
        let always = match kind {
            Kind::Edit => "allow all edits this session".to_string(),
            Kind::Net if name == "WebSearch" => {
                "always allow web searches this session".to_string()
            }
            Kind::Net => format!(
                "always allow fetching from {} this session",
                web_host(name, input)
            ),
            _ if name == "Image" => "always allow image generation this session".to_string(),
            _ if name == "Screenshot" => format!(
                "always allow screenshots of {} this session",
                capture_host(input)
            ),
            _ if name == "Compare" => "always allow visual comparisons this session".to_string(),
            _ if mcp => {
                let pretty = name
                    .strip_prefix("mcp__")
                    .unwrap_or(name)
                    .replacen("__", " › ", 1);
                format!("always allow {pretty} this session")
            }
            _ if name == crate::panes::TERMINAL && pane => {
                "always allow typing into terminal panes this session".to_string()
            }
            _ if pane => format!("always allow preview {pane_action} this session"),
            _ => String::new(), // shell commands: set from the card below
        };
        let timeout_secs = self.cfg.approval_timeout_secs;
        self.last_note = None;
        // Shell commands get a card, and no blanket "always allow `rm`": the only
        // session-wide choice is this program under the card's path prefix.
        let card = (name == "Bash").then(|| {
            // A command's own relative paths resolve where the shell runs (`ctx.cwd`,
            // which `cd` moves); "outside the project" is judged against the session's
            // checkout (`ctx.root`), which never moves.
            crate::approval::card(
                cmd,
                &self.ctx.cwd,
                &self.ctx.root,
                reason.as_deref().unwrap_or("no rule or verdict allowed it"),
                self.agent_reason(),
                &self.created,
                timeout_secs,
            )
        });
        let always = match card.as_ref().and_then(|c| c.prefix.as_ref()) {
            Some(p) => format!(
                "allow `{}` under {p} this session",
                crate::approval::program(cmd)
            ),
            None if card.is_some() => String::new(),
            None => always,
        };
        let id = new_id();
        let (tx, rx) = oneshot::channel();
        self.shared.pending.lock().unwrap().insert(id.clone(), tx);
        let preview = tools::fs::preview(name, input, &self.ctx);
        self.decision(
            item,
            "ask",
            "ask",
            reason.as_deref().unwrap_or("no rule or verdict allowed it"),
            0,
        );
        let card_prefix = card.as_ref().and_then(|c| c.prefix.clone());
        self.emit(Event::PermissionRequest {
            id: id.clone(),
            item: item.into(),
            name: name.into(),
            arg: arg.into(),
            always,
            preview,
            reason,
            subagent: None,
            card,
        });
        // The bus mirrors the card as one line with a link. IRC never approves: the click
        // happens in the app, on a link the bus can't forge (the id is frog's own).
        if let Some(bus) = self.irc() {
            bus.post_notice(
                crate::irc::NoticeKind::WaitingOnUser,
                &crate::irc::approval_notice(&self.conv.session_id, item, name),
            );
        }
        let asked = Instant::now();
        // Waiting has a limit: past it, frog takes the safe path (deny), says so in
        // the tool result, and the agent carries on with the rest of the task.
        let answer = if timeout_secs == 0 {
            Ok(rx.await)
        } else {
            tokio::time::timeout(Duration::from_secs(timeout_secs), rx).await
        };
        let decision = match answer {
            Ok(d) => d.unwrap_or(Decision::Deny),
            Err(_) => {
                self.shared.pending.lock().unwrap().remove(&id);
                let mins = (timeout_secs as f64 / 60.0).round() as u64;
                self.last_note = Some(format!(
                    "nobody answered within {} so frog took the safe path and skipped it; don't retry it, find another way or leave it for the user",
                    if mins >= 1 {
                        format!("{mins} min")
                    } else {
                        format!("{timeout_secs} s")
                    }
                ));
                self.notice(
                    Level::Warn,
                    format!("A permission prompt went unanswered for {timeout_secs}s; denied it and carried on."),
                );
                Decision::Deny
            }
        };
        self.timing.user_ms += ms(asked.elapsed());
        // A note only means something with a deny; with an allow it's dropped.
        let note = self.shared.notes.lock().unwrap().remove(&id);
        if let (Some(note), Decision::Deny) = (note, decision) {
            self.last_note = Some(format!("\"{note}\""));
        }
        if decision == Decision::Deny {
            let why = match &self.last_note {
                Some(n) => format!("denied: {n}"),
                None => "the user denied it".into(),
            };
            self.record_denial(call, why);
        }
        self.emit(Event::PermissionResolved { id, decision });
        match decision {
            Decision::AllowAlways | Decision::AllowPrefix if name == "Bash" => {
                if let Some(p) = card_prefix {
                    self.prefix_allow.push((
                        crate::approval::program(cmd),
                        crate::approval::normalize(Path::new(&p)),
                    ));
                }
                Decision::Allow
            }
            Decision::AllowAlways | Decision::AllowPrefix => {
                self.session_allow.insert(key);
                Decision::Allow
            }
            d => d,
        }
    }

    /// What the agent said just before this call, for the approval card.
    pub(super) fn agent_reason(&self) -> Option<String> {
        let text = self
            .conv
            .messages
            .iter()
            .rev()
            .find(|m| m.role == Role::Assistant)?
            .text();
        let text = text.trim();
        (!text.is_empty()).then(|| tools::truncate_middle(text, 300))
    }

    /// Remember a card's deny: this turn's retries of the identical call don't ask again, and
    /// the session's count moves toward its breaker.
    pub(super) fn record_denial(&mut self, call: u64, why: String) {
        self.turn_denied.insert(call, why);
        *self.session_denied.entry(call).or_insert(0) += 1;
    }

    /// Just before a card would go up: never burn an approval window on a call already
    /// refused. Retried in the same turn, it's denied at once and the turn ends
    /// (`BlockedOnApproval`); denied `DENIED_LIMIT` times this session, it's denied at once
    /// with a notice and the agent carries on. `None`: ask as usual.
    pub(super) fn repeat_refusal(
        &mut self,
        item: &str,
        name: &str,
        arg: &str,
        call: u64,
    ) -> Option<Decision> {
        if let Some(denial) = self.turn_denied.get(&call).cloned() {
            self.decision(
                item,
                "repeat",
                "deny",
                &format!("already denied this turn: {denial}"),
                0,
            );
            self.notice(
                Level::Warn,
                format!(
                    "Blocked on approval: `{name} {arg}` was already denied this turn ({denial}). frog didn't ask again and ended the turn."
                ),
            );
            self.blocked = Some(denial);
            return Some(Decision::Deny);
        }
        if self.session_denied.get(&call).copied().unwrap_or(0) >= DENIED_LIMIT {
            let why = "this call was denied twice and won't ask again this session";
            self.decision(item, "breaker", "deny", why, 0);
            self.notice(Level::Warn, format!("`{name} {arg}`: {why}."));
            self.last_note = Some(format!(
                "{why}; don't retry it, find another way or leave it for the user"
            ));
            // A retry later this turn ends the turn instead of repeating this.
            self.turn_denied.insert(call, why.to_string());
            return Some(Decision::Deny);
        }
        None
    }

    /// Record how one permission check was decided, so the ask rate can be
    /// measured from session logs. Not shown as a notice; a durable event.
    pub(super) fn decision(&self, item: &str, layer: &str, outcome: &str, reason: &str, ms: u64) {
        self.emit(Event::PermissionDecision {
            item: item.to_string(),
            layer: layer.to_string(),
            outcome: outcome.to_string(),
            reason: reason.to_string(),
            ms,
        });
    }

    /// `ListSessions`, `SendMessage`, `StartSession`: the client carries them out.
    pub(super) async fn session_tool(
        &mut self,
        item: &str,
        name: &str,
        input: &Value,
    ) -> Result<tools::Output> {
        use crate::tools::sessions;
        sessions::validate(name, input)?;
        let (id, rx) = self.shared.sessions.open();
        self.emit(Event::SessionRequest {
            id,
            item: item.into(),
            tool: name.into(),
            input: input.clone(),
        });
        let reply = rx
            .await
            .unwrap_or_else(|_| Err("the app didn't answer".into()));
        Ok(tools::Output {
            content: sessions::result(reply)?,
            ..Default::default()
        })
    }

    /// `Ask`: show the question and wait for the answer.
    pub(super) async fn ask_user(&mut self, item: &str, input: &Value) -> Result<tools::Output> {
        let q = crate::ask::parse(input)?;
        let id = new_id();
        let (tx, rx) = oneshot::channel();
        self.shared.questions.lock().unwrap().insert(id.clone(), tx);
        self.emit(Event::Question {
            id: id.clone(),
            item: item.into(),
            question: q.question.clone(),
            options: q.options.clone(),
            multi: q.multi,
            allow_other: q.allow_other,
        });
        // An interrupt drops this whole turn; the loop around it resolves what's still open.
        let asked = Instant::now();
        let answer = rx.await.unwrap_or_default();
        self.timing.user_ms += ms(asked.elapsed());
        self.emit(Event::QuestionResolved {
            id,
            answer: answer.clone(),
        });
        let text = crate::ask::result(&q, &answer);
        Ok(tools::Output {
            display: Some(text.trim_start_matches("The user ").to_string()),
            content: text,
            ..Default::default()
        })
    }

    /// `UseFolder` hands the conversation a folder's files and shell, so the user decides,
    /// every time: no auto mode, no "always".
    pub(super) async fn ask_folder(&mut self, item: &str, name: &str, arg: &str) -> Decision {
        if !self.can_ask {
            return Decision::Deny;
        }
        let id = new_id();
        let (tx, rx) = oneshot::channel();
        self.shared.pending.lock().unwrap().insert(id.clone(), tx);
        self.emit(Event::PermissionRequest {
            id: id.clone(),
            item: item.into(),
            name: name.into(),
            arg: arg.into(),
            always: String::new(),
            preview: None,
            reason: Some(
                "Frog will be able to read and edit files in this folder and run commands there."
                    .into(),
            ),
            subagent: None,
            card: None,
        });
        let asked = Instant::now();
        let decision = match rx.await.unwrap_or(Decision::Deny) {
            Decision::AllowAlways | Decision::AllowPrefix => Decision::Allow,
            d => d,
        };
        self.timing.user_ms += ms(asked.elapsed());
        self.emit(Event::PermissionResolved { id, decision });
        decision
    }

    /// Auto mode: hard rules, then the classifier, then `auto_classifier_fallback`, then the
    /// built-in rules alone. `Ok` runs the call (and records why); `Err` says why the user
    /// should decide.
    pub(super) async fn auto_judge(
        &mut self,
        item: &str,
        name: &str,
        input: &Value,
        sandbox: crate::auto::Sandbox,
    ) -> std::result::Result<(), String> {
        if let Some(why) = crate::auto::hard_rule(name, input, &self.ctx.root) {
            return Err(format!("it {why}"));
        }
        let preview = tools::fs::preview(name, input, &self.ctx);
        let action = crate::auto::describe(name, input, preview.as_ref(), sandbox);
        let verdict = match self.classifier_verdict(false, &action).await {
            Ok(v) => {
                self.classifier_back();
                Some(v)
            }
            Err(down) => match self.classifier_verdict(true, &action).await {
                Ok(v) => {
                    let model = self
                        .classifier_fallback
                        .as_ref()
                        .map(|c| c.profile_name.clone())
                        .unwrap_or_default();
                    self.classifier_degraded(&format!("the fallback classifier ({model})"), &down);
                    Some(v)
                }
                Err(_) => {
                    self.classifier_degraded("frog's built-in rules", &down);
                    None
                }
            },
        };
        match verdict {
            Some(crate::auto::Verdict::Allow(reason)) => {
                self.emit(Event::AutoApproved {
                    item: item.to_string(),
                    reason,
                });
                Ok(())
            }
            Some(crate::auto::Verdict::Ask(reason)) => {
                Err(format!("the classifier said: {reason}"))
            }
            Some(crate::auto::Verdict::Failed(why)) => Err(why),
            // Nothing could judge: the built-in rules decide alone. A down classifier never
            // cards a call by itself; only a call no rule can prove harmless asks.
            None => match crate::auto::rules_fallback(name, input) {
                Some(rule) => {
                    self.emit(Event::AutoApproved {
                        item: item.to_string(),
                        reason: format!("{rule}; the classifier is down, rules decided"),
                    });
                    Ok(())
                }
                None => Err(CLASSIFIER_DOWN_ASK.into()),
            },
        }
    }

    /// One classifier's verdict (`fallback`: `auto_classifier_fallback`'s), started on first
    /// use. `Err` says why it couldn't answer: it isn't configured, wouldn't start, failed, or
    /// failed less than `CLASSIFIER_RETRY` ago (skipped, so a stopped server costs one
    /// timeout, not one per call). Never `Ok(Verdict::Failed)`.
    pub(super) async fn classifier_verdict(
        &mut self,
        fallback: bool,
        action: &str,
    ) -> std::result::Result<crate::auto::Verdict, String> {
        let down = if fallback {
            &self.classifier_fallback_down
        } else {
            &self.classifier_down
        };
        if let Some((at, why)) = down
            && at.elapsed() < CLASSIFIER_RETRY
        {
            return Err(why.clone());
        }
        let started = if fallback {
            self.classifier_fallback.is_some()
        } else {
            self.classifier.is_some()
        };
        if !started {
            let built = if fallback {
                match crate::auto::Classifier::fallback(&self.cfg, &self.ctx.root) {
                    Some(b) => b,
                    None => return Err("no fallback classifier is configured".into()),
                }
            } else {
                crate::auto::Classifier::new(&self.cfg, &self.ctx.root)
            };
            match built {
                Ok(c) if fallback => self.classifier_fallback = Some(c),
                Ok(c) => self.classifier = Some(c),
                Err(e) => {
                    return Err(
                        self.classifier_failed(fallback, format!("it couldn't start ({e:#})"))
                    );
                }
            }
        }
        let slot = if fallback {
            &self.classifier_fallback
        } else {
            &self.classifier
        };
        let model = slot
            .as_ref()
            .map(|c| c.profile_name.clone())
            .unwrap_or_default();
        self.emit(Event::Progress {
            label: format!("checking with auto mode ({model})"),
            completed: None,
            total: None,
        });
        let inputs = self.conv.inputs.clone();
        let slot = if fallback {
            &mut self.classifier_fallback
        } else {
            &mut self.classifier
        };
        let Some(classifier) = slot.as_mut() else {
            return Err("it isn't running".into());
        };
        match classifier.judge(&inputs, action).await {
            crate::auto::Verdict::Failed(why) => Err(self.classifier_failed(fallback, why)),
            v => {
                if fallback {
                    self.classifier_fallback_down = None;
                }
                Ok(v)
            }
        }
    }

    /// A classifier couldn't answer: skip it until `CLASSIFIER_RETRY` passes. Returns `why`.
    pub(super) fn classifier_failed(&mut self, fallback: bool, why: String) -> String {
        let down = Some((Instant::now(), why.clone()));
        if fallback {
            self.classifier_fallback_down = down;
        } else {
            self.classifier_down = down;
        }
        why
    }

    /// The classifier is down and `using` judges instead: the status carries one line that
    /// says so while it lasts, and a notice says it once per session for each fallback,
    /// never once per call.
    pub(super) fn classifier_degraded(&mut self, using: &str, why: &str) {
        let primary = self
            .classifier
            .as_ref()
            .map(|c| c.profile_name.clone())
            .unwrap_or_else(|| crate::auto::Classifier::primary_spec(&self.cfg));
        let why = why.trim_start_matches("it ").trim_end_matches('.');
        let line = format!("classifier {primary} is down ({why}); {using} decide");
        let changed = self.classifier_degraded.as_deref() != Some(line.as_str());
        self.classifier_degraded = Some(line);
        if self.classifier_told.insert(using.to_string()) {
            let rest = if using.starts_with("frog's") {
                "reads and the session's own work still run without asking; only calls no rule covers ask"
            } else {
                "it judges each call until the classifier is back"
            };
            self.notice(
                Level::Warn,
                format!(
                    "auto mode's classifier ({primary}) is down ({why}); using {using}: {rest}."
                ),
            );
        }
        if changed {
            self.emit_status();
        }
    }

    /// The classifier answered: it's back, and the status drops the degraded line.
    pub(super) fn classifier_back(&mut self) {
        self.classifier_down = None;
        if self.classifier_degraded.take().is_some() {
            self.emit_status();
        }
    }
}
