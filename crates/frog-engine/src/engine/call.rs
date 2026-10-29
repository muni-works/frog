//! Calling the model: the request on the wire, retries and fallbacks.

use super::*;

impl Agent {
    /// One model request. Streams item events (unless `quiet`) and retries transient errors
    /// that happen before anything streamed. Without `offer_tools` the model can only answer:
    /// in `json` mode a summary request that offers tools gets a tool call back, not a summary.
    pub(super) async fn set_model(&mut self, spec: &str) -> Result<()> {
        let (name, profile) = self
            .cfg
            .resolve(Some(spec))
            .map_err(|e| ConfigError(format!("{e:#}")))?;
        if profile.provider == ProviderKind::Codex {
            crate::provider::codex::check_available()
                .await
                .map_err(|e| ConfigError(format!("{e:#}")))?;
        }
        crate::policy::check(&self.root, &name, &profile)
            .map_err(|e| ConfigError(format!("{e:#}")))?;
        self.provider = Provider::new(&profile)
            .map_err(|e| ConfigError(format!("{e:#}")))?
            .with_cwd(&self.root);
        self.profile_name = name;
        self.profile = profile;
        if self.cfg.compare_model.is_none() {
            self.ctx.judge = Some(self.profile.clone());
        }
        self.shared.journal.header.lock().unwrap().1 = self.profile_name.clone();
        // A new model starts on its own harness: what the old one fell back to doesn't carry.
        self.harness = harness::Harness::for_profile(&self.profile);
        self.model_ready = false;
        self.apply_harness();
        self.resolve_window().await;
        self.note_text_mode_from_probe();
        self.emit(Event::ModelChanged {
            model: self.profile_name.clone(),
        });
        Ok(())
    }

    /// frog cloud is unreachable (offline) or out of capacity, credit or hours (503, 402, 502):
    /// carry on with a local model instead of failing the turn. `FROG_FALLBACK_MODEL` picks
    /// which.
    /// How many times to retry a failed call: frog cloud gets longer (busy, or a tunnel blip).
    pub(super) fn retry_budget(&self, _e: &anyhow::Error) -> u32 {
        let cloud = self
            .profile_name
            .split_once('/')
            .is_some_and(|(p, _)| crate::providers::canonical(p) == crate::providers::CLOUD);
        if cloud { 6 } else { 3 }
    }

    pub(super) fn cloud_fallback(&self, e: &anyhow::Error) -> Option<String> {
        let prov = self.profile_name.split_once('/')?.0;
        if crate::providers::canonical(prov) != crate::providers::CLOUD {
            return None;
        }
        let offline = e
            .chain()
            .filter_map(|c| c.downcast_ref::<reqwest::Error>())
            .any(|r| r.is_connect());
        let unavailable = e
            .downcast_ref::<HttpError>()
            .is_some_and(|h| matches!(h.status, 402 | 502 | 503));
        if !offline && !unavailable {
            return None;
        }
        Some(
            std::env::var("FROG_FALLBACK_MODEL")
                .ok()
                .filter(|m| !m.is_empty())
                .map(|m| crate::providers::normalize(&m))
                .unwrap_or_else(|| crate::config::LOCAL_DEFAULT.into()),
        )
        // Only to a local model that's actually there: a fallback to nothing just fails later.
        .filter(|m| !m.starts_with("local/") || local_server_up())
    }

    pub(super) async fn call(
        &self,
        label: &str,
        messages: &[Message],
        quiet: bool,
        offer_tools: bool,
        think: Option<bool>,
        think_budget: Option<u32>,
    ) -> Result<(Response, Streamed)> {
        let json_mode = self.harness.tool_mode == ToolMode::Json;
        // A JSON-mode reply is one object whose action comes last, so it's done by the time
        // its call is: nothing to gain.
        let early_tools = self.cfg.early_tools && offer_tools && !quiet && !json_mode;
        // `<tool_call>` text from a model that calls natively is prose: nothing to start early.
        let early_text = early_tools && self.recovers_text_calls();
        let specs = if offer_tools && self.profile.provider != ProviderKind::Codex {
            &self.specs[..]
        } else {
            &[][..]
        };
        let wire = self.wire(messages, specs);
        let (system, messages, format) =
            (&wire.system, wire.messages(messages), wire.format.as_ref());
        let tools = if wire.native_tools { specs } else { &[][..] };
        let prompt = self
            .est
            .tokens(fixed_chars(&system, tools) + context::history_chars(messages));
        // A local server fills whatever's left of the window unless told otherwise, and
        // overflows it; hosted APIs have their own output limits.
        let max_tokens = if crate::harness::is_cloud(&self.profile) {
            // Ask for room explicitly: left unset, some gateways apply a small default that long
            // thinking (GLM at high effort) exhausts before any answer or tool call.
            self.profile.max_tokens.or(Some(CLOUD_MAX_OUTPUT))
        } else {
            Some(context::reply_budget(
                self.window,
                prompt,
                self.profile.max_tokens,
            ))
        };
        let call = NEXT_CALL.fetch_add(1, Ordering::Relaxed) + 1;
        let req = Request {
            system: &system,
            messages,
            tools,
            max_tokens,
            format,
            think,
            think_budget,
            cache_key: self.cache_key_ok.then_some(self.conv.session_id.as_str()),
        };
        let (extends, reusable) = {
            let flat = flatten(&system, tools, messages);
            // `FROG_DUMP_PREFIX=dir`: every request as the cache sees it, to diff when one
            // stops extending the last.
            if let Some(dir) = std::env::var_os("FROG_DUMP_PREFIX") {
                let dir = PathBuf::from(dir);
                let _ = std::fs::create_dir_all(&dir)
                    .and_then(|_| std::fs::write(dir.join(format!("{call:04}.txt")), &flat));
            }
            let mut sent = self.sent.lock().unwrap();
            let r = reuse(&sent, &flat);
            *sent = flat;
            r
        };
        let mut attempt = 0;
        loop {
            self.emit(Event::Progress {
                label: label.into(),
                completed: None,
                total: None,
            });
            let mut started = false;
            let mut streamed = Streamed {
                no_think: think == Some(false),
                think_budget,
                extends,
                reusable,
                ..Default::default()
            };
            let sent = Instant::now();
            // The engine log: what was sent, and a note while nothing has come back, so a
            // slow provider or a hang shows up while it's happening, not just after.
            let heard = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let watchdog = self.cfg.log_calls.then(|| {
                eprintln!(
                    "call {call} {label} → {} · ~{prompt} tokens in · {} tools{}{}",
                    self.profile_name,
                    specs.len(),
                    max_tokens
                        .map(|n| format!(" · reply up to {n}"))
                        .unwrap_or_default(),
                    if attempt > 0 {
                        format!(" · attempt {}", attempt + 1)
                    } else {
                        String::new()
                    },
                );
                let heard = heard.clone();
                tokio::spawn(async move {
                    let mut waited = 0;
                    for step in [30, 30, 60, 120, 240] {
                        tokio::time::sleep(Duration::from_secs(step)).await;
                        waited += step;
                        if heard.load(Ordering::Relaxed) {
                            return;
                        }
                        eprintln!(
                            "call {call}: nothing back after {}",
                            secs(Duration::from_secs(waited))
                        );
                    }
                })
            });
            // When the first event arrived, and the first that wasn't reasoning.
            let (mut first, mut answer) = (None::<Instant>, None::<Instant>);
            let mut filter = TagFilter::default();
            let mut presenting = None::<crate::present::Stream>;
            let (cwd, weak) = (self.ctx.root.clone(), self.harness.tier == Tier::Weak);
            let text = |streamed: &mut Streamed, text: String| {
                let id = streamed.message.get_or_insert_with(|| {
                    let id = new_id();
                    self.emit(Event::ItemStarted {
                        id: id.clone(),
                        kind: ItemKind::Message,
                    });
                    id
                });
                self.emit(Event::ItemDelta {
                    id: id.clone(),
                    delta: Delta::Text { text },
                });
            };
            let r = self
                .provider
                .complete(&req, &mut |e| {
                    started = true;
                    heard.store(true, Ordering::Relaxed);
                    let now = Instant::now();
                    first.get_or_insert(now);
                    if !matches!(e, StreamEvent::Thinking(_)) {
                        answer.get_or_insert(now);
                    }
                    if quiet {
                        return;
                    }
                    match e {
                        StreamEvent::Thinking(text) => {
                            let id = streamed.reasoning.get_or_insert_with(|| {
                                let id = new_id();
                                self.emit(Event::ItemStarted {
                                    id: id.clone(),
                                    kind: ItemKind::Reasoning,
                                });
                                id
                            });
                            self.emit(Event::ItemDelta {
                                id: id.clone(),
                                delta: Delta::Reasoning { text },
                            });
                        }
                        StreamEvent::ToolCall(name) => {
                            presenting = (name == crate::present::TOOL).then(Default::default);
                            self.emit(Event::Progress {
                                label: format!("{name}…"),
                                completed: None,
                                total: None,
                            })
                        }
                        StreamEvent::ToolArgs { name, chunk } => {
                            if name == crate::present::TOOL
                                && let Some(p) =
                                    presenting.as_mut().and_then(|s| s.push(&chunk, &cwd, weak))
                            {
                                self.emit(Event::PresentPreview {
                                    present: Box::new(p),
                                });
                            }
                        }
                        StreamEvent::ToolReady { index, name, input } => {
                            if early_tools {
                                let ctx = self.early_ctx(&name, &input);
                                streamed.early.ready(index, name, input, ctx);
                            }
                        }
                        // JSON-mode output is raw JSON; the parsed answer is shown when complete.
                        StreamEvent::Text(_) if json_mode => {}
                        StreamEvent::Text(s) => {
                            if early_text {
                                streamed.early.text(&s, |n, i| self.early_ctx(n, i));
                            }
                            let was_inside = filter.inside;
                            let visible = filter.push(&s);
                            if !visible.is_empty() {
                                text(&mut streamed, visible);
                            }
                            if filter.inside && !was_inside {
                                self.emit(Event::Progress {
                                    label: "tool call…".into(),
                                    completed: None,
                                    total: None,
                                });
                            }
                        }
                    }
                })
                .await;
            let rest = filter.finish();
            if !quiet && !rest.is_empty() {
                text(&mut streamed, rest);
            }
            let done = Instant::now();
            if let Some(w) = watchdog {
                w.abort();
                match &r {
                    Ok(resp) => eprintln!(
                        "call {call} done in {} · first token {} · {} in, {} out · {:?}",
                        secs(done - sent),
                        first
                            .map(|f| secs(f - sent))
                            .unwrap_or_else(|| "none".into()),
                        resp.usage.input + resp.usage.cache_read,
                        resp.usage.output,
                        resp.stop,
                    ),
                    Err(e) => eprintln!("call {call} failed after {}: {e:#}", secs(done - sent)),
                }
            }
            let first = first.unwrap_or(done);
            streamed.ttft = first - sent;
            streamed.decode = done - first;
            streamed.think = answer.unwrap_or(done) - first;
            // A stream that ended without the server saying it was done is the same mid-stream
            // failure as a gateway error event; retried the same way, partials and all.
            let r = match r {
                Ok(resp) if resp.stop == Stop::Incomplete => Err(IncompleteStream.into()),
                other => other,
            };
            match r {
                // Unparseable JSON-mode output is kept as a plain answer and counted as a failure.
                Ok(resp) if json_mode => {
                    return Ok(match from_json_mode(resp.clone()) {
                        Some(resp) => (resp, streamed),
                        None => (
                            resp,
                            Streamed {
                                format_failed: true,
                                ..streamed
                            },
                        ),
                    });
                }
                Ok(resp) => return Ok((resp, streamed)),
                // A busy or briefly unreachable provider is retried before anything falls
                // back: one 503, dropped connection or mid-stream gateway error shouldn't end
                // a long task. When the broken attempt had already streamed a partial reply,
                // its items are discarded and the step runs again from scratch.
                Err(e)
                    if attempt < self.retry_budget(&e)
                        && (retryable(&e) || self.cloud_fallback(&e).is_some()) =>
                {
                    attempt += 1;
                    let ids: Vec<String> = streamed
                        .message
                        .iter()
                        .chain(streamed.reasoning.iter())
                        .cloned()
                        .collect();
                    if !ids.is_empty() {
                        self.emit(Event::ItemsDiscarded { ids });
                    }
                    let wait = Duration::from_secs((1u64 << attempt.min(5)).min(20));
                    let budget = self.retry_budget(&e);
                    self.notice(
                        Level::Warn,
                        format!(
                            "{e:#} — retrying in {}s ({attempt}/{budget})",
                            wait.as_secs()
                        ),
                    );
                    tokio::time::sleep(wait).await;
                }
                Err(e) => {
                    // The last attempt (or one that isn't retryable) may leave a streamed
                    // partial dangling: drop it, as the retry arm does.
                    let ids: Vec<String> = streamed
                        .message
                        .iter()
                        .chain(streamed.reasoning.iter())
                        .cloned()
                        .collect();
                    if !ids.is_empty() {
                        self.emit(Event::ItemsDiscarded { ids });
                    }
                    return Err(e);
                }
            }
        }
    }
}
