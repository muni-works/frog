//! The project a session works in: its MCP servers, tool specs, and moving to another folder.

use super::*;

impl Agent {
    /// Connect the configured MCP servers (config.toml and the project's `.mcp.json`) and add
    /// their tools. Failures and quarantined tools become notices; nothing here is fatal.
    /// Start connecting the project's MCP servers in the background, so the prompt (and the
    /// first turn) doesn't wait on them; [`Self::poll_mcp`] installs them once they're up.
    ///
    /// This runs on every session open and every folder move, so it must never interrupt:
    /// a server that wants an OAuth sign-in is reported as `needs_auth` and left alone. Only
    /// [`Agent::sign_in_mcp`], from an explicit request, opens a browser.
    pub(super) fn connect_mcp(&mut self) {
        self.mcp_pending = None;
        self.mcp_tx = None;
        if self.subagent {
            return;
        }
        let servers = crate::mcp::configured(&self.cfg, &self.root);
        if servers.is_empty() {
            return;
        }
        // Mark that MCP servers are configured, so McpTools is offered even before they connect
        self.mcp.expect_servers();
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let emit = {
            let journal = self.shared.journal.clone();
            move |event: Event| journal.emit(event)
        };
        let host = crate::mcp::Host::new(emit, self.rich && self.can_ask, &self.root);
        self.mcp_connecting = servers.keys().cloned().collect();
        for (name, cfg) in servers {
            let tx = tx.clone();
            let host = host.clone();
            tokio::spawn(async move {
                let delta = crate::mcp::Hub::connect_delta(host, name.clone(), cfg).await;
                let _ = tx.send(delta);
            });
        }
        // Kept, not dropped: the queue's sender outlives this loop so a sign-in's reconnect
        // can join it later (see `sign_in_mcp`).
        self.mcp_tx = Some(tx);
        self.mcp_pending = Some(rx);
        // Configuring a server is not the same as having its tools: say which are configured
        // (and which want a sign-in) from the start, before any of them answers.
        self.emit_mcp_servers();
    }

    /// A person asked to sign in to `server` — Settings → MCP → Sign in, or the transcript's
    /// card ([`Op::McpSignIn`]). `decline` records a refusal instead.
    ///
    /// The sign-in itself runs in the background: the browser can sit open for minutes, and
    /// the engine must stay responsive (the user may never finish, or may close the tab). The
    /// outcome arrives as [`Event::McpSignedIn`] or [`Event::McpSignedOut`]; on success the
    /// reconnect goes through the ordinary pending queue and installs as soon as it lands.
    pub(super) fn sign_in_mcp(&mut self, server: String, decline: bool) {
        if self.subagent {
            return;
        }
        let Some(cfg) = crate::mcp::configured(&self.cfg, &self.root).remove(&server) else {
            self.notice(
                Level::Warn,
                format!("`{server}` isn't a configured MCP server, so there is nothing to sign in to"),
            );
            return;
        };
        let key = crate::mcp::auth_key(&server, &cfg);
        if decline {
            // If it can't be recorded, say so: a refusal that quietly fails to stick comes
            // back next session, which is the whole complaint this change fixes.
            if let Err(e) = crate::mcp::refuse_sign_in(&key) {
                self.notice(
                    Level::Warn,
                    format!("couldn't remember declining `{server}`'s sign-in ({e}); it will ask again next session"),
                );
            }
            self.emit(Event::McpSignedOut {
                server,
                error: None,
            });
            self.emit_mcp_servers();
            return;
        }
        // Asked for on purpose, so no longer remembered as refused.
        crate::mcp::forget_refusal(&key);
        // The reconnect reports through the queue the engine polls, so its tools install as
        // soon as it lands — between turns, or mid-turn at the next step (a mid-turn merge
        // waits for the step after it, since tools change the prompt's cached prefix).
        let tx = match &self.mcp_tx {
            Some(tx) => tx.clone(),
            None => {
                let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
                self.mcp_tx = Some(tx.clone());
                self.mcp_pending = Some(rx);
                tx
            }
        };
        // The live hub, so the reconnected server joins this session rather than a fresh one.
        let host = self.mcp.host().clone();
        let journal = self.shared.journal.clone();
        tokio::spawn(async move {
            match crate::mcp::sign_in(&server, &cfg, None, crate::mcp_oauth::system_browser()).await {
                Ok(_) => {
                    let delta = crate::mcp::Hub::connect_delta(host, server.clone(), cfg).await;
                    let tools = delta
                        .1
                        .status()
                        .into_iter()
                        .find(|s| s.name == server)
                        .map(|s| s.tools)
                        .unwrap_or_default();
                    let _ = tx.send(delta);
                    journal.emit(Event::McpSignedIn { server, tools });
                }
                Err(e) => journal.emit(Event::McpSignedOut {
                    server,
                    error: Some(format!("{e:#}")),
                }),
            }
        });
    }

    /// Install the background MCP connection if it has finished.
    pub(super) fn poll_mcp(&mut self) {
        for (_name, delta) in std::mem::take(&mut self.mcp_ready_queue) {
            self.merge_mcp(delta);
        }
        loop {
            let result = self.mcp_pending.as_mut().and_then(|rx| rx.try_recv().ok());
            let Some((_name, delta)) = result else { break };
            self.mcp_ready_queue.push((_name, delta));
        }
    }

    /// Get the next configured server to connect; the loop returns immediately for a closed queue.
    pub(super) async fn mcp_ready(&mut self) -> Option<(String, crate::mcp::Hub)> {
        match &mut self.mcp_pending {
            Some(rx) => rx.recv().await,
            None => std::future::pending().await,
        }
    }

    pub(super) fn merge_mcp(&mut self, delta: crate::mcp::Hub) {
        let status = delta.status();
        let failed = status
            .iter()
            .filter_map(|st| st.error.clone().map(|e| (st.name.clone(), e)))
            .collect::<Vec<_>>();
        for st in &status {
            self.mcp_connecting.remove(&st.name);
        }
        self.mcp.merge(delta);
        if let Some(line) = crate::mcp::unavailable_summary(&failed) {
            self.notice(Level::Info, line);
        }
        *self.shared.mcp.lock().unwrap() = Some(self.mcp.clone());
        self.sync_specs();
        self.apply_harness();
        self.emit_mcp_servers();
    }

    /// Tell the client how every configured server is doing, the whole list. Sent when the
    /// servers are configured, whenever a connect finishes and whenever a sign-in changes one,
    /// so a server that is configured but not offering tools is always visible somewhere —
    /// the failure mode of "built, tested, never switched on" is a tool list that quietly
    /// lacks what a person set up.
    pub(super) fn emit_mcp_servers(&mut self) {
        if self.subagent {
            return;
        }
        let servers = self.mcp.status();
        if servers.is_empty() && !self.mcp.expected() {
            return;
        }
        // Still connecting: they're configured, so they get a row even before they answer.
        let mut reports: Vec<_> = servers
            .iter()
            .map(crate::protocol::McpServerReport::from)
            .collect();
        let connected: Vec<&str> = servers.iter().map(|s| s.name.as_str()).collect();
        for name in self.mcp_connecting.clone() {
            if !connected.contains(&name.as_str()) {
                reports.push(crate::protocol::McpServerReport {
                    name,
                    connected: false,
                    needs_auth: false,
                    declined: false,
                    error: None,
                    tools: Vec::new(),
                });
            }
        }
        reports.sort_by(|a, b| a.name.cmp(&b.name));
        self.emit(Event::McpServers { servers: reports });
    }

    /// Below this window (tokens), the prompt keeps to what a small model can hold: no
    /// subagents, no MCP instructions or schemas until loaded, skills by name only.
    pub(super) const COMPACT_WINDOW: u64 = 16_384;
    /// Characters of repo map a small window gets.
    pub(super) const SMALL_REPO_MAP: usize = 1_200;

    pub(super) fn small_window(&self) -> bool {
        self.window < Self::COMPACT_WINDOW
    }

    /// A chat (no project) with a small model: no tools, so nothing to describe for them.
    pub(super) fn plain_chat(&self) -> bool {
        self.chat && self.small_window() && !self.subagent
    }

    /// Built-in tools plus whatever MCP tools are live (and, with many, loaded).
    pub(super) fn sync_specs(&mut self) {
        self.mcp.set_compact(self.small_window());
        let mut specs = tools::specs();
        if self.profile.provider == ProviderKind::Codex {
            specs.clear();
            self.specs = specs;
            return;
        }
        if self.ctx.web.search.is_some() {
            specs.push(tools::websearch::spec());
        }
        if self.chat {
            // No project to work in: only the tools that don't touch files or run commands.
            specs.retain(|s| matches!(&*s.name, "Visualize" | "VisualGuide" | "Image" | "WebFetch" | "WebSearch"));
            specs.push(crate::folder::spec());
        }
        // Terminal panes are engine-owned, so every client gets them; previews need a client
        // that hosts them. Subagents only get to look.
        if !self.chat {
            specs.push(crate::panes::terminal_spec(self.subagent));
            if self.shared.panes.client() {
                specs.push(crate::panes::preview_spec(self.subagent));
            }
        }
        if self.subagent {
            // A write-mode subagent also edits and runs commands (asking as the parent would).
            let write = self.cfg.subagent_write;
            specs.retain(|s| {
                tools::kind(&s.name) == Kind::Read
                    || matches!(&*s.name, crate::panes::TERMINAL | crate::panes::PREVIEW)
                    || (write && matches!(&*s.name, "Bash" | "Write" | "Edit"))
            });
        } else {
            if !self.small_window() {
                specs.push(crate::subagent::spec());
            }
            if !self.chat {
                specs.extend(crate::background::specs());
                specs.push(crate::title::spec());
                specs.push(crate::next::spec());
            }
            if !self.skills.is_empty() {
                specs.push(crate::skills::spec());
            }
            if !self.chat {
                specs.push(crate::folder::spec());
            }
            specs.push(crate::present::spec(self.harness.tier == Tier::Weak));
            if self.can_ask && self.shared.client_ask.load(Ordering::Relaxed) {
                specs.push(crate::ask::spec());
            }
            if self.shared.sessions.enabled() {
                specs.extend(crate::tools::sessions::specs());
            } else if !self.chat {
                // No client hosts sessions: the engine owns the children (see `kids`).
                specs.extend(
                    crate::tools::sessions::specs()
                        .into_iter()
                        .filter(|s| crate::kids::handles(&s.name)),
                );
            }
            // The bus tool, only when the client declared the bus (never to subagents: a
            // subagent's parent carries the channel).
            if self.irc().is_some() {
                specs.push(crate::irc::spec());
            }
        }
        if self.has_recall() {
            specs.push(crate::recall::spec());
        }
        if self.compiled.is_some() {
            specs.push(crate::compiled_memory::spec());
        }
        // MCP tools last: servers that connect late (or tools loaded on demand) then only
        // append to the list, and the prefix before them stays cached.
        if !self.subagent {
            specs.extend(self.mcp.specs());
        }
        // A small model chatting just talks: offered any tool, it calls one on every turn
        // (Apple's on-device model drew diagrams of "hello"). With none, it can only answer.
        if self.plain_chat() {
            specs.clear();
        } else if self.small_window() && !self.subagent {
            // In a project, a small window holds the core tools and little else: the rest
            // (diagrams, the code map, docs, recall, skills, the plan) cost more room than
            // they're worth at 8k. Visual tools and panes stay: the user can ask for
            // generation or a capture/compare loop even with a compact local model.
            specs.retain(|s| {
                matches!(
                    &*s.name,
                    "Bash"
                        | "Read"
                        | "Write"
                        | "Edit"
                        | "Glob"
                        | "Grep"
                        | "Image"
                        | "Screenshot"
                        | "Compare"
                ) || matches!(&*s.name, crate::panes::TERMINAL | crate::panes::PREVIEW)
                    || &*s.name == crate::mcp::SEARCH_TOOL
                    || &*s.name == crate::folder::TOOL
                    || &*s.name == crate::ask::TOOL
            });
        }
        self.specs = specs;
    }

    /// `UseFolder` (already approved): move the conversation into `path` and re-derive what
    /// depends on the folder, as `Agent::new` does. The tools and prompt switch on the next
    /// model call, so the turn carries on there.
    pub(super) async fn use_folder(&mut self, input: &Value) -> Result<tools::Output> {
        let base = if self.chat {
            dirs::home_dir().unwrap_or_else(|| self.root.clone())
        } else {
            self.root.clone()
        };
        let root = crate::folder::resolve(input["path"].as_str().unwrap_or(""), &base)?;
        if !self.chat
            && root
                == self
                    .root
                    .canonicalize()
                    .unwrap_or_else(|_| self.root.clone())
        {
            return Ok(tools::Output::text(format!(
                "Already working in {}.",
                root.display()
            )));
        }
        // A folder that keeps its code on this Mac can't take a cloud model.
        crate::policy::check(&root, &self.profile_name, &self.profile)?;
        // One engine per linked worktree holds wherever the conversation goes: take the new
        // tree's lock (or fail, naming its owner) before anything moves, and let the old go.
        let same_tree = crate::worktree::linked(&root) == crate::worktree::linked(&self.root);
        if !self.subagent && self.store.is_some() && !same_tree {
            let lock =
                crate::worktree::acquire(&root, &self.conv.session_id, Duration::from_secs(5))?;
            self.worktree_lock = lock.map(|mut l| {
                l.set_owner(&self.conv.session_id);
                l
            });
        }
        // The session file moves with it: its header says which folder it belongs to.
        if let Some(dir) = self.store.clone() {
            let header = Header {
                version: session::VERSION,
                id: self.conv.session_id.clone(),
                cwd: root.clone(),
                model: self.profile_name.clone(),
                created: now_ms(),
                forked_from: None,
                worker: self.cfg.worker,
                parent: self.cfg.parent_session.clone(),
            };
            self.shared.journal.header.lock().unwrap().0 = root.clone();
            let mut log = self.shared.journal.log.lock().unwrap();
            if let Some(l) = log.as_mut() {
                let created = session::load(&dir, &self.conv.session_id)
                    .map(|l| l.header)
                    .ok();
                let header = Header {
                    created: created.as_ref().map_or(header.created, |h| h.created),
                    parent: created.as_ref().and_then(|h| h.parent.clone()).or(header.parent),
                    forked_from: created.and_then(|h| h.forked_from),
                    ..header
                };
                l.rewrite_header(&dir, &header)?;
            }
        }
        self.chat = false;
        self.root = root.clone();
        let web = self.ctx.web.clone();
        let todos = std::mem::take(&mut self.ctx.todos);
        let sandbox = self.ctx.sandbox.is_some();
        self.ctx = Ctx::new(root.clone());
        self.ctx.web = web;
        self.ctx.image = self.cfg.image.clone();
        self.ctx.screenshot_endpoint = self.cfg.screenshot_endpoint.clone();
        self.ctx.judge = Some(match &self.cfg.compare_model {
            Some(model) => self.cfg.resolve(Some(model))?.1,
            None => self.profile.clone(),
        });
        self.ctx.todos = todos;
        if sandbox {
            self.ctx.sandbox = Some(root.clone());
        }
        if self.cfg.sandbox_shell && tools::bash::available() {
            self.ctx.shell_sandbox = Some(root.clone());
        }
        // The new folder's `[sandbox]` holes and egress policy (its own egress.toml entry).
        self.ctx.sandbox_extra = self.cfg.sandbox.clone();
        self.ctx.egress = crate::egress::for_session(&self.cfg, &root);
        if let Some(e) = &self.ctx.egress {
            e.set_session(&self.conv.session_id);
        }
        self.rules = crate::rules::discover(&root);
        self.conv.rules_seen.clear();
        self.skills = crate::skills::discover(&root);
        self.conv.skills_loaded.clear();
        if let Some(store) = &self.store {
            let memory = crate::memory::Store::new(&memory_root(store), Some(root.as_path()));
            self.notes = memory.load();
            self.memory = Some(memory);
        }
        // Approvals and the auto-mode judge were for the old folder.
        self.session_allow.clear();
        self.classifier = None;
        self.repo_map = Default::default();
        self.conv.edited.clear();
        self.refresh_repo_map(&[]);
        // MCP servers are configured per project. Ones that connected for the old folder but
        // weren't merged yet go too, or the next turn would pick them up here.
        self.mcp.shutdown();
        for (_, hub) in std::mem::take(&mut self.mcp_ready_queue) {
            hub.shutdown();
        }
        self.mcp = crate::mcp::Hub::empty();
        *self.shared.mcp.lock().unwrap() = None;
        self.connect_mcp();
        self.sync_specs();
        self.apply_harness();
        self.emit(Event::FolderChanged { cwd: root.clone() });
        self.emit_status();
        Ok(tools::Output::text(format!(
            "This conversation now works in {}. You can read and edit files there and run shell commands.",
            root.display()
        )))
    }
}
