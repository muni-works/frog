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
        let kind = if crate::panes::is_read(name, input)
            || (name == crate::compiled_memory::TOOL && crate::compiled_memory::is_read(input))
        {
            Kind::Read
        } else {
            tools::kind(name)
        };
        // A command that would widen an enforced egress allow-list (hosts beyond it, or
        // leaving the sandbox it's enforced in) is a human's call in every mode but yolo.
        // `Some(hosts)`: the hosts it asks for.
        let egress_ask = self.egress_ask(name, input);
        // Yolo never asks (Cam, 2026-11-02): the call runs, and the transcript gets one quiet
        // line where every other mode would card. The hosts the agent named are its
        // declaration; they're granted for the session, and the proxy still blocks anything it
        // didn't declare, so the exfil tripwire keeps working. Headless (`can_ask = false`)
        // keeps its path below: it can't ask, so it denies.
        if self.mode == Mode::Yolo && self.can_ask && egress_ask.is_some() {
            self.yolo_widen_egress(
                item,
                name,
                input["command"].as_str().unwrap_or(""),
                &egress_ask.unwrap_or_default(),
                input["unsandboxed"].as_bool() == Some(true),
            );
            return Decision::Allow;
        }
        if (kind == Kind::Read || self.mode == Mode::Yolo) && egress_ask.is_none() {
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
        // mode (Cam's decision 2026-10-23): WebSearch, and WebFetch when the host is a
        // plain public domain (the fetch itself still re-checks every resolved IP against
        // private ranges, and a non-public host keeps asking as before). Only plain ones,
        // though: a long query, path segment or search term could carry what the agent
        // read out past the sandbox, so those go on to the classifier or a card.
        if kind == Kind::Net && crate::tools::web::plain_read(name, input) {
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
            && egress_ask.is_none()
            && !crate::shell::touches_credentials(cmd)
            && (bash_allowed(cmd, &self.cfg.allow_bash) || crate::shell::read_only(cmd))
        {
            self.decision(item, "rule", "allow", "read-only command", 0);
            return Decision::Allow;
        }
        // A sandboxed command can only write inside the project and can't read credentials,
        // so it runs without asking; leaving the sandbox always asks.
        if name == "Bash"
            && self.ctx.shell_sandbox.is_some()
            && !leaves_sandbox
            && egress_ask.is_none()
        {
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
            && egress_ask.is_none()
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
            && egress_ask.is_none()
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
        if egress_ask.is_none() && (auto || self.session_allow.contains(&key)) {
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
        match &egress_ask {
            Some(hosts) if !hosts.is_empty() => {
                reason = Some(format!(
                    "Reaches {}, which isn't on this session's network allow-list.",
                    hosts.join(", ")
                ))
            }
            Some(_) => {
                reason = Some(
                    "Runs outside the sandbox and past this session's network allow-list: it can reach any host, change files anywhere and read your credentials."
                        .to_string(),
                )
            }
            None => {}
        }
        if self.mode == Mode::Auto && egress_ask.is_none() {
            let sandbox = match (self.ctx.shell_sandbox.is_some(), leaves_sandbox) {
                (_, true) => crate::auto::Sandbox::Leaving,
                (true, false) => crate::auto::Sandbox::In,
                (false, false) => crate::auto::Sandbox::Off,
            };
            let started = Instant::now();
            let verdict = self.auto_judge(item, name, arg, input, sandbox).await;
            let took = ms(started.elapsed());
            self.timing.classifier_ms += took;
            match verdict {
                Ok((layer, why)) => {
                    self.digest.count(match layer {
                        "classifier" => crate::digest::Which::AutoAllowed,
                        _ => crate::digest::Which::SecondPass,
                    });
                    self.decision(item, layer, "allow", &why, took);
                    return Decision::Allow;
                }
                Err((layer, why)) => {
                    self.decision(item, layer, "ask", &why, took);
                    reason = Some(format!(
                        "Auto mode asked because {}.",
                        why.trim_end_matches('.')
                    ));
                    // Still flagged after the second pass: the chief decides what
                    // the user shouldn't have to, when its grant list covers the
                    // class (docs/design/delegation.md). Only a `second-pass` flag
                    // may route: `never-delegable`, a classifier outage and a hard
                    // rule with no classifier always card the user.
                    let routed = if layer == "second-pass" {
                        self.delegate_flagged(
                            item,
                            name,
                            arg,
                            input,
                            reason.clone().unwrap_or_default(),
                        )
                        .await
                    } else {
                        Chief::NoRoute
                    };
                    match routed {
                        Chief::Decided(decision) => return decision,
                        // Counted as a chief fallback already; it cards like any other.
                        Chief::Fallback => {}
                        Chief::NoRoute => self.digest.count(if layer == "never-delegable" {
                            crate::digest::Which::NeverDelegable
                        } else {
                            crate::digest::Which::Blocked
                        }),
                    }
                    self.daily_digest_notice();
                }
            }
        }
        // An egress ask (hosts beyond the session's allow-list, or leaving the sandbox
        // it's enforced in) doesn't go through the classifier — its harm is fixed, not a
        // judgment call — so the chief route lives here instead. Egress widening is a
        // delegable class (docs/design/delegation.md): a chief `[delegation]` grants, the
        // chief decides; without one, the card goes up exactly as before. A never-delegable
        // call never routes, whatever it also asks: `auto_judge` (which checks `hard_class`)
        // is skipped for an egress ask, so the check is repeated here and the card wins.
        if let Some(hosts) = &egress_ask
            && self.mode == Mode::Auto
            && self.can_ask
        {
            if let Some(why) = crate::delegation::hard_class(
                name,
                input,
                &self.ctx.cwd,
                &self.ctx.root,
                &self.created,
            ) {
                let why = format!("it {why} (never delegated)");
                self.decision(item, "never-delegable", "ask", &why, 0);
                self.digest.count(crate::digest::Which::NeverDelegable);
                reason = Some(why);
            } else {
                let reason = match hosts.len() {
                    0 => "It would run outside the sandbox, past the session's network allow-list."
                        .to_string(),
                    _ => format!(
                        "It would reach {}, which isn't on this session's network allow-list.",
                        hosts.join(", ")
                    ),
                };
                match self.delegate_flagged(item, name, arg, input, reason).await {
                    Chief::Decided(decision) => {
                        // The same grant an answered card makes: these hosts for the run,
                        // or for the rest of the session.
                        if let (Some(egress), true) = (&self.ctx.egress, !hosts.is_empty()) {
                            match &decision {
                                Decision::Allow => egress.grant_once(cmd, hosts.clone()),
                                Decision::AllowAlways | Decision::AllowPrefix => {
                                    egress.grant(hosts);
                                    self.notice(
                                        Level::Info,
                                        format!(
                                            "Network allow-list: {} allowed for the rest of this session.",
                                            hosts.join(", ")
                                        ),
                                    );
                                }
                                Decision::Deny => {}
                            }
                        }
                        return decision;
                    }
                    // Counted and audited (delegated:chief fell back) already; it cards.
                    Chief::Fallback => {}
                    // No chief, class not granted, or not interactive: the card, as before.
                    Chief::NoRoute => self.digest.count(crate::digest::Which::Blocked),
                }
            }
        }
        if !self.can_ask {
            self.decision(
                item,
                if egress_ask.is_some() {
                    "egress"
                } else {
                    "ask"
                },
                "ask",
                "not interactive: denied",
                0,
            );
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
        // An egress card's standing choice is the hosts, never a program under a prefix.
        let card = card.map(|mut c| {
            if let Some(hosts) = &egress_ask {
                c.prefix = None;
                c.risk = if hosts.is_empty() {
                    "Past the allow-list nothing stops a command from sending this project, or anything it can read, to any host.".into()
                } else {
                    format!("{} would receive whatever the command sends: an unknown host is how code and secrets leave.", hosts.join(", "))
                };
            }
            c
        });
        let always = match &egress_ask {
            Some(hosts) if !hosts.is_empty() => {
                format!("always allow {} this session", hosts.join(", "))
            }
            _ => always,
        };
        let always = match card.as_ref().and_then(|c| c.prefix.as_ref()) {
            Some(p) => format!(
                "allow `{}` under {p} this session",
                crate::approval::program(cmd)
            ),
            None if card.is_some() && egress_ask.is_none() => String::new(),
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
        // The grant: these hosts for this one run, or for the rest of the session.
        if let (Some(hosts), Some(egress)) = (&egress_ask, &self.ctx.egress)
            && !hosts.is_empty()
        {
            match decision {
                Decision::Allow => egress.grant_once(cmd, hosts.clone()),
                Decision::AllowAlways | Decision::AllowPrefix => {
                    egress.grant(hosts);
                    self.notice(
                        Level::Info,
                        format!(
                            "Network allow-list: {} allowed for the rest of this session.",
                            hosts.join(", ")
                        ),
                    );
                }
                Decision::Deny => {}
            }
        }
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

    /// Yolo ran a call that widened the egress fence: grant the hosts it declared for the
    /// session and put the fact in the transcript as one quiet line, never a card. Yolo is
    /// "act without asking", not "act silently": the row is the whole point. `hosts` is
    /// [`Self::egress_ask`]'s answer — the hosts it named, empty when it only left the
    /// sandbox (`leaves`, past which no list applies).
    fn yolo_widen_egress(
        &mut self,
        item: &str,
        name: &str,
        command: &str,
        hosts: &[String],
        leaves: bool,
    ) {
        if !hosts.is_empty() && let Some(egress) = &self.ctx.egress {
            egress.grant(hosts);
        }
        let head = crate::egress::head(command);
        // Past the sandbox no list applies, so `hosts` is empty there: the sandbox line is the
        // whole fact, and naming hosts "allowed" would be a lie (nothing fences them).
        let line = match (leaves, hosts.is_empty()) {
            (true, _) => format!(
                "yolo: `{head}` ran outside the sandbox; it can change files anywhere and read your credentials."
            ),
            (false, _) => format!(
                "yolo: `{head}` reaches {}, now allowed this session.",
                hosts.join(", ")
            ),
        };
        if self.cfg.log_calls {
            eprintln!("{line}");
        }
        self.notice(Level::Info, line);
        self.decision(item, "yolo", "allow", "yolo: widened egress without asking", 0);
        self.emit(Event::EgressWidened {
            item: item.to_string(),
            tool: name.to_string(),
            command: head,
            hosts: hosts.to_vec(),
            sandbox_left: leaves,
        });
    }

    /// Whether a shell command would widen an enforced egress allow-list: `Some(hosts)` when
    /// its `allow_hosts` names hosts the session doesn't allow yet, `Some([])` when it asks to
    /// leave the sandbox the list is enforced in, `None` otherwise.
    fn egress_ask(&self, name: &str, input: &Value) -> Option<Vec<String>> {
        let egress = self.ctx.egress.as_ref().filter(|e| e.enforced())?;
        if name != "Bash" || (self.ctx.shell_sandbox.is_none() && self.ctx.sandbox.is_none()) {
            return None;
        }
        let asked: Vec<String> = input["allow_hosts"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|h| h.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        let missing = egress.missing(&asked);
        // `--sandbox` (strict) ignores `unsandboxed`, so only the everyday sandbox can be left.
        let leaves = input["unsandboxed"].as_bool() == Some(true)
            && self.ctx.sandbox.is_none()
            && self.ctx.shell_sandbox.is_some();
        match (missing.is_empty(), leaves) {
            (true, false) => None,
            // Outside the sandbox no list applies: that's the question, whatever hosts it named.
            (_, true) => Some(Vec::new()),
            (false, false) => Some(missing),
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
        // A session starts on a model its gateway lists right now, or not at all
        // (docs/design/model-policy.md): the check is here, once, so a model that dropped out
        // of the gateway's list never becomes a session that dies on its first call.
        if name == sessions::START
            && let Some(spec) = input["model"].as_str().filter(|s| !s.trim().is_empty())
        {
            crate::model_policy::check_spawn_spec(&self.cfg, spec)
                .await
                .map_err(|e| anyhow::anyhow!("{e:#}"))?;
        }
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

    /// Auto mode (docs/design/delegation.md): never-delegable classes, hard rules, the
    /// classifier (then `auto_classifier_fallback`, then the built-in rules alone), then the
    /// context-rich second pass over a flag. `Ok((layer, why))` runs the call;
    /// `Err((layer, why))` says why the user should decide. The caller records either.
    pub(super) async fn auto_judge(
        &mut self,
        item: &str,
        name: &str,
        arg: &str,
        input: &Value,
        sandbox: crate::auto::Sandbox,
    ) -> std::result::Result<(&'static str, String), (&'static str, String)> {
        // Hard classes override every allow and always reach the user: no classifier,
        // no second pass, no chief.
        if let Some(why) =
            crate::delegation::hard_class(name, input, &self.ctx.cwd, &self.ctx.root, &self.created)
        {
            return Err(("never-delegable", format!("it {why} (never delegated)")));
        }
        let preview = tools::fs::preview(name, input, &self.ctx);
        let action = crate::auto::describe(name, input, preview.as_ref(), sandbox);
        // A hard rule is a flag without asking the first pass: it goes straight to the
        // second, which can only clear it with context (rm and ssh are always
        // double-checked, never single-checked). With no classifier it cards.
        if let Some(why) = crate::auto::hard_rule(name, input, &self.ctx.root) {
            if self.classifier.is_none()
                && let Ok(c) = crate::auto::Classifier::new(&self.cfg, &self.ctx.root)
            {
                self.classifier = Some(c);
            }
            if self.classifier.is_none() {
                return Err(("classifier", format!("it {why}")));
            }
            return self
                .second_pass(item, name, arg, input, &action, format!("it {why}"))
                .await;
        }
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
                Ok(("classifier", "the classifier approved it".into()))
            }
            // The first pass flagged it: the flag is usually missing context, and
            // context is cheap. (The first pass never names Cam; it's a flag too.)
            Some(crate::auto::Verdict::Ask(why)) | Some(crate::auto::Verdict::Cam(why)) => {
                self.second_pass(
                    item,
                    name,
                    arg,
                    input,
                    &action,
                    format!("the classifier said: {why}"),
                )
                .await
            }
            Some(crate::auto::Verdict::Failed(why)) => Err(("classifier", why)),
            // Nothing could judge: the built-in rules decide alone. A down classifier never
            // cards a call by itself; only a call no rule can prove harmless asks. A worker on
            // a BYOK model is the exception (docs/design/model-policy.md): it may not quietly
            // degrade to rules, so the call stops and says how to fix the provider instead.
            None => match crate::auto::rules_fallback(name, input) {
                Some(_) if !self.rules_may_decide_for_a_worker() => Err((
                    "classifier",
                    format!(
                        "the classifier is down ({}) and a worker can't run on rules alone with a BYOK model; {}",
                        self.classifier_down
                            .as_ref()
                            .map_or("no classifier answered", |(_, why)| why.as_str()),
                        crate::model_policy::connect_line(&self.profile_name)
                    ),
                )),
                Some(rule) => {
                    self.emit(Event::AutoApproved {
                        item: item.to_string(),
                        reason: format!("{rule}; the classifier is down, rules decided"),
                    });
                    Ok((
                        "fallback",
                        format!("{rule}; the classifier is down, rules decided"),
                    ))
                }
                None => Err(("fallback", CLASSIFIER_DOWN_ASK.into())),
            },
        }
    }

    /// Whether the built-in rules may decide alone for this session
    /// (docs/design/model-policy.md): yes for an interactive session (a human is there to be
    /// asked when a rule can't prove the call harmless), and for a worker on the platform's
    /// own models — but a worker running on BYOK fails with the provider's fix instead of
    /// quietly degrading to rules, because nobody is watching that key.
    fn rules_may_decide_for_a_worker(&self) -> bool {
        !self.cfg.worker
            || crate::model_policy::tier(&self.profile_name, &self.profile)
                != crate::model_policy::Tier::Byok
    }

    /// The second, context-rich classifier pass over a flagged call: the session's
    /// brief, recent actions, who owns the targets, what the user asked for. It can
    /// only upgrade the flag (to an allow with a reason, audited) or confirm it; a
    /// `cam` answer or any failure keeps the card. `flag` is why it was flagged.
    pub(super) async fn second_pass(
        &mut self,
        item: &str,
        name: &str,
        arg: &str,
        input: &Value,
        action: &str,
        flag: String,
    ) -> std::result::Result<(&'static str, String), (&'static str, String)> {
        let ctx = crate::auto::Context {
            brief: self.agent_reason(),
            actions: self.history_tail(),
            ownership: self.ownership_lines(name, input),
            need: self.conv.inputs.clone(),
        };
        let verdict = match self.classifier.as_mut() {
            Some(c) => c.rejudge(action, &ctx).await,
            None => crate::auto::Verdict::Failed("the classifier is unavailable".into()),
        };
        match verdict {
            crate::auto::Verdict::Allow(why) => {
                self.notice(
                    Level::Info,
                    format!("second pass: `{name} {arg}` allowed with context ({why})"),
                );
                self.emit(Event::AutoApproved {
                    item: item.to_string(),
                    reason: format!("second pass: {why}"),
                });
                Ok(("second-pass", why))
            }
            crate::auto::Verdict::Ask(why) => {
                Err(("second-pass", format!("{flag}; with context: {why}")))
            }
            crate::auto::Verdict::Cam(why) => Err((
                "never-delegable",
                format!("{flag}; with context: {why} (never delegated)"),
            )),
            // Fail closed: the flag stands, the card goes up. Layer `fallback`, not
            // `second-pass`: an outage is never a delegation route, so this always
            // reaches the user (docs/design/delegation.md).
            crate::auto::Verdict::Failed(why) => Err((
                "fallback",
                format!("{flag}; the second pass couldn't finish ({why})"),
            )),
        }
    }

    /// A call still flagged after the second pass: offer it to the chief before
    /// it cards the user (docs/design/delegation.md). `Decided` when the chief
    /// answered; `Fallback` when it was asked but couldn't decide (counted and
    /// audited here); `NoRoute` when there's no chief route (no chief configured,
    /// the class isn't granted). The chief answers over the session wire
    /// (`SessionRequest` `DelegateApproval` → the broker → the chief's
    /// `ResolveDelegated` → `SessionReply`); a client that doesn't know
    /// `DelegateApproval` errors or never answers, and the card falls back.
    pub(super) async fn delegate_flagged(
        &mut self,
        item: &str,
        name: &str,
        arg: &str,
        input: &Value,
        reason: String,
    ) -> Chief {
        let chiefs = self.cfg.delegation.chief.clone();
        let Some(chief) = chiefs.first().cloned() else {
            return Chief::NoRoute;
        };
        // Egress asks (the yolo/unsandboxed/allow_hosts cards) have their own shape:
        // widening the fence, classified by what the call asks, not by the command's
        // paths. `soft_egress` is checked before `soft_class`, which knows nothing
        // about hosts.
        let hosts = self.egress_ask(name, input);
        let class = match &hosts {
            Some(hosts) => crate::delegation::soft_egress(hosts),
            None => crate::delegation::soft_class(
                name,
                input,
                &self.ctx.cwd,
                &self.ctx.root,
                &self.created,
                &self.cfg,
            ),
        };
        let Some(class) = class else {
            return Chief::NoRoute;
        };
        if !self.cfg.delegation.grants(class) {
            return Chief::NoRoute;
        }
        if !self.shared.sessions.enabled() {
            return self.chief_fallback(item, "no session broker to reach the chief");
        }
        let (id, rx) = self.shared.sessions.open();
        let request = serde_json::json!({
            "chief": chief,
            "chiefs": chiefs,
            "approval_id": id,
            "tool": name,
            "arg": arg,
            "class": class,
            "reason": reason,
            "agent_says": self.agent_reason(),
            "timeout_secs": self.cfg.delegation.chief_timeout_secs,
        });
        self.notice(
            Level::Info,
            format!("delegated:chief: asking {chief} about `{name} {arg}` ({class})"),
        );
        self.emit(Event::SessionRequest {
            id: id.clone(),
            item: item.into(),
            tool: "DelegateApproval".into(),
            input: request,
        });
        let timeout = self.cfg.delegation.chief_timeout_secs;
        let waited = Instant::now();
        // `rx` resolves to `Result<Value, String>` (the chief's reply or the
        // broker's error); the wait itself can time out or be dropped.
        let answer = if timeout == 0 {
            Ok(rx.await)
        } else {
            tokio::time::timeout(Duration::from_secs(timeout), rx).await
        };
        self.timing.user_ms += ms(waited.elapsed());
        let reply = match answer {
            Ok(Ok(Ok(r))) => r,
            Ok(Ok(Err(e))) => return self.chief_fallback(item, &format!("{chief}: {e}")),
            Ok(Err(_)) => return self.chief_fallback(item, "the broker went away"),
            Err(_) => {
                return self.chief_fallback(item, &format!("{chief} didn't answer in {timeout}s"));
            }
        };
        let Some((allowed, note)) = crate::delegation::parse_reply(&reply) else {
            return self.chief_fallback(item, &format!("{chief}'s answer was unreadable"));
        };
        let note = note.map(|n| format!(" ({n})")).unwrap_or_default();
        if allowed {
            self.digest.count(crate::digest::Which::DelegatedChief);
            let why = format!("{chief} approved it{note} [{class}]");
            self.notice(
                Level::Info,
                format!("delegated:chief: `{name} {arg}` — approved by {chief}{note}"),
            );
            self.decision(item, "delegated", "allow", &why, 0);
            Chief::Decided(Decision::Allow)
        } else {
            self.digest.count(crate::digest::Which::Blocked);
            let why = format!("{chief} declined it{note} [{class}]");
            self.notice(
                Level::Warn,
                format!("delegated:chief: `{name} {arg}` — declined by {chief}{note}"),
            );
            self.decision(item, "delegated", "deny", &why, 0);
            self.record_denial(call_hash(name, input), format!("the chief declined: {why}"));
            self.last_note = Some(why);
            Chief::Decided(Decision::Deny)
        }
    }

    /// The chief couldn't take a delegated call: count it, audit it, card the user.
    pub(super) fn chief_fallback(&mut self, item: &str, why: &str) -> Chief {
        self.digest.count(crate::digest::Which::ChiefFallback);
        self.notice(
            Level::Warn,
            format!("delegated:chief: fell back to the user ({why})"),
        );
        self.decision(
            item,
            "delegated",
            "ask",
            &format!("delegation fell back to the user: {why}"),
            0,
        );
        Chief::Fallback
    }

    /// The day's single digest notice, at the first card after midnight.
    pub(super) fn daily_digest_notice(&mut self) {
        if !self.cfg.delegation.digest {
            return;
        }
        if !self.digest.needs_daily_notice() {
            return;
        }
        // Once per session per day, and once per day across the sessions
        // sharing this store: the first card after midnight carries it.
        self.digest.mark_noticed();
        let day = self.digest.day();
        if crate::digest::claim_daily(self.store.as_deref(), &day) {
            let summary = self.digest.summary();
            self.notice(Level::Info, summary);
        }
    }

    /// The session's last few steps, short, for the second pass's context: what the
    /// agent said and which tools it ran, oldest first.
    pub(super) fn history_tail(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for m in self
            .conv
            .messages
            .iter()
            .rev()
            .filter(|m| m.role == Role::Assistant)
        {
            for b in m.content.iter().rev() {
                let line = match b {
                    Block::Text { text } if !text.trim().is_empty() => {
                        format!("said: {}", text.trim())
                    }
                    Block::ToolUse { name, input, .. } => {
                        let what = input["command"]
                            .as_str()
                            .or(input["file_path"].as_str())
                            .map(String::from)
                            .unwrap_or_else(|| input.to_string());
                        format!("ran {name}: {what}")
                    }
                    _ => continue,
                };
                out.push(tools::truncate_middle(&line, 200));
            }
            if out.len() >= 6 {
                break;
            }
        }
        out.truncate(6);
        out.reverse();
        out
    }

    /// Who owns what this call touches, one line per path, for the second pass.
    pub(super) fn ownership_lines(&self, name: &str, input: &Value) -> Vec<String> {
        let cmd = input["command"].as_str().unwrap_or("");
        let paths: Vec<PathBuf> = if name == "Bash" && !cmd.is_empty() {
            crate::approval::paths(cmd, &self.ctx.cwd)
        } else if let Some(p) = input["file_path"].as_str() {
            vec![crate::approval::normalize(&self.ctx.resolve(p))]
        } else if let Some(p) = input["url"].as_str().filter(|_| name == "Screenshot") {
            vec![crate::approval::normalize(&self.ctx.resolve(p))]
        } else {
            Vec::new()
        };
        let root = crate::approval::normalize(&self.ctx.root);
        let temp = crate::approval::normalize(&std::env::temp_dir());
        let mut out: Vec<String> = paths
            .into_iter()
            // A remote `host:path` operand is a host, below, not a local path.
            .filter(|p| !p.to_string_lossy().contains(':'))
            .map(|p| {
                let note = if p.starts_with(&root) {
                    "in this session's project"
                } else if crate::approval::created_here(&p, &self.created) {
                    "created by this session"
                } else if p.starts_with(&temp)
                    || p.starts_with("/private/tmp")
                    || p.starts_with("/tmp")
                {
                    if p.exists() {
                        "under the shared temp dir (may predate this session)"
                    } else {
                        "fresh scratch under the shared temp dir"
                    }
                } else {
                    "outside the project and not created by this session"
                };
                format!("{} — {}", p.display(), note)
            })
            .collect();
        // Remote shells: is the host something this session brought up or already used?
        if name == "Bash" {
            for host in remote_hosts(cmd) {
                let note = if self.seen_in_session(&host) {
                    "remote host seen earlier in this session (it created or used it)"
                } else {
                    "remote host not seen earlier in this session (foreign)"
                };
                out.push(format!("{host} — {note}"));
            }
        }
        out
    }

    /// Whether `needle` appears in an earlier tool call or result this session (a pod
    /// it created, a host it printed). Only the session's own history counts.
    pub(super) fn seen_in_session(&self, needle: &str) -> bool {
        // The newest assistant message is the call being judged; it doesn't count.
        let upto = self
            .conv
            .messages
            .iter()
            .rposition(|m| m.role == Role::Assistant)
            .unwrap_or(self.conv.messages.len());
        self.conv.messages[..upto].iter().any(|m| {
            m.content.iter().any(|b| match b {
                Block::ToolResult { content, .. } => content.contains(needle),
                Block::ToolUse { input, .. } => input.to_string().contains(needle),
                _ => false,
            })
        })
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
                // The fallback is `auto_classifier_fallback` and nothing else
                // (docs/design/model-policy.md): the session's own model is never a judge,
                // so a dead BYOK key can't take auto mode down with it, and a cloud session
                // doesn't get a judge that moves with it.
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
