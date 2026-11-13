//! Calling the model: the request on the wire, retries and fallbacks.
//!
//! One retry policy for every call (docs/design/model-policy.md): a busy provider (429, 5xx, a
//! dropped stream) gets three retries at 1 s, 2 s and 4 s, with one notice in the transcript and
//! no card; a wrong key, an empty wallet or a model the gateway doesn't serve (401/402/404) gets
//! none, and the one line saying how to fix it goes up before the turn ends with the provider's
//! own error.

use super::*;
use crate::model_policy::{self, is_fail_fast};

/// The engine's own error for a hard billing refusal, so the turn's end is the typed
/// [`EndReason::BillingLimit`] — "out of credit", never a provider dump. The engine catches
/// it in the same place it catches everything else and classifies it straight through.
#[derive(Debug)]
pub(crate) struct BillingRefused {
    pub window: String,
    pub reason: String,
    pub balance_micro: Option<u64>,
}

impl std::fmt::Display for BillingRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "out of credit ({})", self.reason)
    }
}

impl std::error::Error for BillingRefused {}

/// What a billing refusal means, read off the [`HttpError`]: which window, the provider's
/// clean message, the remaining credit, and whether the next call was admitted at usage
/// prices.
struct BillingRefusal {
    window: &'static str,
    reason: String,
    balance_micro: Option<u64>,
    admitted: bool,
}

fn billing(e: &anyhow::Error) -> Option<BillingRefusal> {
    let h = e.downcast_ref::<HttpError>()?;
    if !h.is_billing() {
        return None;
    }
    Some(BillingRefusal {
        window: h.billing_window(),
        reason: h.summary(),
        balance_micro: h.billing_balance(),
        admitted: h.billing_admitted(),
    })
}

/// Most node failovers in one call: each takes a node out, so this only bounds a pool that
/// keeps coming back between attempts.
const MAX_FAILOVERS: u32 = 4;

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
        // A switch is a start for this session's purposes: the model has to be one its gateway
        // lists now, or the next call is the 404 this check exists to prevent
        // (docs/design/model-policy.md).
        crate::model_policy::check_spawn(&name, &profile)
            .await
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

    pub(super) async fn call(
        &self,
        label: &str,
        messages: &[Message],
        quiet: bool,
        offer_tools: bool,
        think: Option<bool>,
        think_budget: Option<u32>,
        // The message item this call's reply belongs to, when it continues one already
        // streaming (`Streamed::message` is seeded with it, so its text joins that item).
        message: Option<String>,
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
            // Subagents and compaction run beside the conversation: background on a node.
            background: self.subagent || label == "compacting",
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
        // One billing line per turn, however many calls: the transition to credit is one
        // fact, not one per step.
        let mut billing_line = false;
        let mut failovers = 0;
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
                message: message.clone(),
                extends,
                reusable,
                ..Default::default()
            };
            let sent = Instant::now();
            // A call in flight: `Status.waiting` reports it, so a session waiting on a slow
            // or dead model says so instead of looking merely busy. Published, because the
            // client learns state from events and this is the only moment the wait begins.
            *self.call_started.lock().unwrap() = Some((sent, attempt + 1, None));
            self.emit_status();
            // The engine log: what was sent, and a note while nothing has come back, so a
            // slow provider or a hang shows up while it's happening, not just after.
            let heard = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let watchdog = self.cfg.log_calls.then(|| {                eprintln!(
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
                    // The answer is in, JSON-mode or not: this call isn't waiting any more.
                    // Cleared here as well as below, because this arm returns early.
                    *self.call_started.lock().unwrap() = None;
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
                Ok(resp) => {
                    // The answer is in: this call is no longer waiting on the model.
                    *self.call_started.lock().unwrap() = None;
                    return Ok((resp, streamed));
                }
                // A billing refusal is a state transition, not an error: "transition to
                // credits, but make it obvious". One typed, informational line names the
                // window and the credit balance; the provider's raw JSON never goes up. When
                // the edge admitted the next call at usage prices (`x-frog-billing: credit`,
                // or the body reads like credit semantics), the step continues past the
                // fail-fast wall — once; a second refusal (the credit spent or the admit
                // withdrawn) ends the turn below. A hard refusal (nothing admitted it) ends
                // the turn with the typed billing reason, never a provider error.
                Err(e) if billing(&e).is_some() => {
                    let billing = billing(&e).unwrap();
                    let ids: Vec<String> = streamed
                        .message
                        .iter()
                        .chain(streamed.reasoning.iter())
                        .cloned()
                        .collect();
                    if !ids.is_empty() {
                        self.emit(Event::ItemsDiscarded { ids });
                    }
                    if !billing.admitted {
                        *self.call_started.lock().unwrap() = None;
                        return Err(BillingRefused {
                            window: billing.window.to_string(),
                            reason: billing.reason,
                            balance_micro: billing.balance_micro,
                        }
                        .into());
                    }
                    if !billing_line {
                        billing_line = true;
                        self.emit(Event::BillingLimit {
                            window: billing.window.to_string(),
                            reason: billing.reason.clone(),
                            balance_micro: billing.balance_micro,
                        });
                    }
                    // One credit-billed attempt after the refusal: a second 402 means the
                    // admit didn't hold (or the credit ran out), and the turn ends with the
                    // honest typed reason instead of spinning.
                    if attempt > 0 {
                        *self.call_started.lock().unwrap() = None;
                        return Err(BillingRefused {
                            window: billing.window.to_string(),
                            reason: billing.reason,
                            balance_micro: billing.balance_micro,
                        }
                        .into());
                    }
                    attempt += 1;
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
                // A paired node stopped answering (docs/node-protocol.md §7): its partial goes,
                // it's out of placement for 30 s, and the same call runs again at once on the
                // next placement with one notice. Each failure takes a node out, so with every
                // node down the call ends with one line (`next` is None), never a loop.
                Err(e)
                    if e
                        .downcast_ref::<crate::provider::node::NodeFailed>()
                        .and_then(|f| f.notice())
                        .is_some()
                        && failovers < MAX_FAILOVERS =>
                {
                    failovers += 1;
                    let ids: Vec<String> = streamed
                        .message
                        .iter()
                        .chain(streamed.reasoning.iter())
                        .cloned()
                        .collect();
                    if !ids.is_empty() {
                        self.emit(Event::ItemsDiscarded { ids });
                    }
                    let line = e
                        .downcast_ref::<crate::provider::node::NodeFailed>()
                        .and_then(|f| f.notice())
                        .unwrap_or_default();
                    self.notice(Level::Warn, line);
                }
                // A wrong key, an empty wallet or a model the gateway doesn't serve is the
                // first answer, not a hiccup: no retry spends the rest of the budget on it. The
                // one line saying how to fix it goes up here, and the turn ends with the
                // provider's own error underneath (docs/design/model-policy.md).
                Err(e) if is_fail_fast(&e) => {
                    let ids: Vec<String> = streamed
                        .message
                        .iter()
                        .chain(streamed.reasoning.iter())
                        .cloned()
                        .collect();
                    if !ids.is_empty() {
                        self.emit(Event::ItemsDiscarded { ids });
                    }
                    if let Some(fix) = model_policy::fix_for(&self.profile_name, &e) {
                        self.notice(Level::Warn, fix);
                    }
                    return Err(e);
                }
                // A busy or briefly unreachable provider is retried before the turn
                // stops: one 503, dropped connection or mid-stream gateway error shouldn't end
                // a long task. When the broken attempt had already streamed a partial reply,
                // its items are discarded and the step runs again from scratch. Three retries
                // at 1 s, 2 s and 4 s, and ONE line for the whole storm.
                Err(e)
                    if attempt < model_policy::MAX_RETRIES
                        && (retryable(&e)
                            || e.chain()
                                .filter_map(|c| c.downcast_ref::<reqwest::Error>())
                                .any(|r| r.is_connect())) =>
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
                    // One notice total, on the first retry: a storm is one line, not one per
                    // attempt and not a card.
                    if attempt == 1 {
                        let why = e
                            .downcast_ref::<HttpError>()
                            .map(HttpError::summary)
                            .unwrap_or_else(|| format!("{e:#}"));
                        self.notice(
                            Level::Info,
                            format!(
                                "{why} — retrying (up to {} times)",
                                model_policy::MAX_RETRIES
                            ),
                        );
                    }
                    // A busy provider may say how long to wait; keep it for the status line
                    // and wait that long instead of our own backoff when it's longer.
                    let asked = e
                        .downcast_ref::<HttpError>()
                        .and_then(|h| h.retry_after)
                        .map(|d| d.as_secs());
                    let wait = model_policy::retry_wait(attempt).max(
                        asked
                            .map(Duration::from_secs)
                            .unwrap_or(Duration::ZERO),
                    );
                    if asked.is_some() {
                        *self.call_started.lock().unwrap() = Some((Instant::now(), attempt + 1, asked));
                        self.emit_status();
                    }
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
                    *self.call_started.lock().unwrap() = None;
                    return Err(e);
                }
            }
        }
    }
}
