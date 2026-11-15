//! A pooled model (`node/<hash12>`): each call is placed on one of your paired nodes, or this
//! Mac's tang, and speaks OpenAI-compatible chat to it (docs/node-protocol.md §7). A node that
//! drops mid-call comes back as [`NodeFailed`]; the engine discards the partial and calls again,
//! and the next placement skips the node for 30 s.

use super::{HttpError, Request, Response, Stop, StreamEvent, openai};
use crate::config::Profile;
use crate::nodes::{Call, Placed, Pool, Sample, Step};
use crate::protocol::RanOn;
use anyhow::{Result, anyhow};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::time::Instant;

pub struct Client {
    pub pool: Arc<Pool>,
    /// The `weights_hash` prefix this model is.
    pub hash: String,
    /// The node the session is pinned to (`node/<hash>@<pin>`).
    pub pin: Option<String>,
    /// Where the last call that finished ran: placement prefers it next.
    last: Mutex<Option<Placed>>,
    anthropic: super::anthropic::Settings,
    extra: Option<serde_json::Value>,
    watch: Mutex<Option<tokio_util::sync::DropGuard>>,
}

/// A node stopped answering mid-call (transport error, 5xx, an unfinished stream, a stall).
/// The node is already marked down; `next` is where the call would go now, `None` when
/// nowhere can take it.
#[derive(Debug)]
pub struct NodeFailed {
    pub from: String,
    pub next: Option<String>,
    pub cause: String,
}

impl NodeFailed {
    /// The one notice: "mew stopped answering; finishing on this Mac".
    pub fn notice(&self) -> Option<String> {
        self.next
            .as_ref()
            .map(|to| format!("{} stopped answering; finishing on {to}", self.from))
    }
}

impl std::fmt::Display for NodeFailed {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match &self.next {
            Some(_) => write!(f, "{} stopped answering ({})", self.from, self.cause),
            None => write!(
                f,
                "{} stopped answering and no other node has this model right now",
                self.from
            ),
        }
    }
}

impl std::error::Error for NodeFailed {}

/// No node can take the call: one line, not retried.
#[derive(Debug)]
pub struct NoPlacement(pub String);

impl std::fmt::Display for NoPlacement {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for NoPlacement {}

/// The reply went quiet.
#[derive(Debug)]
struct Stalled(Duration);

impl std::fmt::Display for Stalled {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "no bytes for {}s", self.0.as_secs_f32())
    }
}

impl std::error::Error for Stalled {}

impl Client {
    pub fn new(pool: Arc<Pool>, model: &str, p: Option<&Profile>) -> Self {
        let (hash, pin) = crate::nodes::split_spec(model);
        Self {
            pool,
            hash: hash.to_lowercase(),
            pin: pin.map(String::from),
            last: Mutex::new(None),
            anthropic: p
                .map(|p| super::anthropic::Settings::from_profile(p, true))
                .unwrap_or_default(),
            extra: p.and_then(|p| p.extra.clone()),
            watch: Mutex::new(None),
        }
    }

    /// Where the last finished call ran.
    pub fn ran_on(&self) -> Option<RanOn> {
        self.last.lock().unwrap().as_ref().map(Placed::ran_on)
    }

    /// Place a call (`req` None: just somewhere that has the model).
    fn place(&self, req: Option<&Request<'_>>) -> Result<Placed, String> {
        let last = self
            .last
            .lock()
            .unwrap()
            .as_ref()
            .map(|p| p.node_id.clone());
        let call = Call {
            pin: self.pin.as_deref(),
            last: last.as_deref(),
            cache_key: req.and_then(|r| r.cache_key),
            prompt_tokens: req.map_or(0, prompt_tokens),
            prefix: req.and_then(prefix),
            step: req.map_or(Step::Answer, step),
            background: req.is_some_and(|r| r.background),
        };
        self.pool.schedule(&self.hash, &call)
    }

    fn openai(&self, at: &Placed, background: bool) -> openai::Client {
        openai::Client {
            http: self.pool.http.clone(),
            base: format!("{}/v1", at.base.trim_end_matches('/')),
            model: at.model.clone(),
            key: at.key.clone(),
            extra: self.extra.clone(),
            anthropic: self.anthropic.clone(),
            priority: Some(if background {
                "background"
            } else {
                "interactive"
            }),
        }
    }

    /// The context window the node reports for this model.
    pub async fn probe_context(&self) -> Option<u64> {
        self.pool.ensure_fresh().await;
        self.pool.model(&self.hash)?.context_window
    }

    pub async fn capabilities(&self) -> Option<Vec<String>> {
        self.pool.ensure_fresh().await;
        let at = self.place(None).ok()?;
        self.openai(&at, false).capabilities().await
    }

    pub async fn complete(
        &self,
        req: &Request<'_>,
        on: &mut (dyn FnMut(StreamEvent) + Send),
    ) -> Result<Response> {
        {
            let mut w = self.watch.lock().unwrap();
            if w.is_none() {
                *w = Some(self.pool.watch());
            }
        }
        self.pool.ensure_fresh().await;
        let mut at = self.place(Some(req)).map_err(NoPlacement)?;
        if let Some(model) = at.start.take() {
            // The best (or only) place is this Mac's tang, which isn't running: start it.
            if let Err(e) = self.pool.start_local(&model).await {
                self.pool.mark_down(crate::nodes::LOCAL_ID);
                return Err(NoPlacement(format!("couldn't start this Mac's tang: {e:#}")).into());
            }
            at = self.place(Some(req)).map_err(NoPlacement)?;
            if at.start.is_some() {
                self.pool.mark_down(crate::nodes::LOCAL_ID);
                return Err(NoPlacement(
                    "this Mac's tang started but doesn't serve this model".into(),
                )
                .into());
            }
        }
        let _flight = self.pool.begin(&at, req.background);
        let client = self.openai(&at, req.background);
        let timing = self.pool.timing.clone();
        // The last byte's time (None before the first), read by the stall watch.
        let last = Arc::new(Mutex::new(None::<Instant>));
        let heard = last.clone();
        let first = Arc::new(Mutex::new(None::<Instant>));
        let first_heard = first.clone();
        let started = Instant::now();
        let r = {
            let mut forward = |e: StreamEvent| {
                let now = Instant::now();
                *heard.lock().unwrap() = Some(now);
                first_heard.lock().unwrap().get_or_insert(now);
                on(e)
            };
            let call = client.complete(req, &mut forward);
            let watch = async {
                loop {
                    tokio::time::sleep(Duration::from_millis(100).min(timing.stall / 4)).await;
                    let quiet = match *last.lock().unwrap() {
                        Some(t) => (t.elapsed() > timing.stall).then_some(timing.stall),
                        None => {
                            (started.elapsed() > timing.first_byte).then_some(timing.first_byte)
                        }
                    };
                    if let Some(d) = quiet {
                        return d;
                    }
                }
            };
            tokio::select! {
                r = call => r,
                d = watch => Err(Stalled(d).into()),
            }
        };
        let failed = |cause: String| -> anyhow::Error {
            self.pool.mark_down(&at.node_id);
            // The next call must not prefer the node that just failed.
            let mut last = self.last.lock().unwrap();
            if last.as_ref().is_some_and(|p| p.node_id == at.node_id) {
                *last = None;
            }
            drop(last);
            let next = self.place(Some(req)).ok().map(|p| p.label().to_string());
            anyhow!(NodeFailed {
                from: at.label().to_string(),
                next,
                cause,
            })
        };
        match r {
            Ok(resp) if resp.stop == Stop::Incomplete => {
                Err(failed("the reply ended before it finished".into()))
            }
            Ok(mut resp) => {
                let first = *first.lock().unwrap();
                self.pool.observe(
                    &at,
                    if req.background {
                        Step::Background
                    } else {
                        step(req)
                    },
                    Sample {
                        prefilled: resp.usage.input,
                        output: resp.usage.output,
                        first_byte: first.map(|t| t - started),
                        total: started.elapsed(),
                        prefix: prefix(req).map(|(h, _)| h),
                    },
                );
                resp.usage.ran_on = Some(at.ran_on());
                *self.last.lock().unwrap() = Some(at);
                Ok(resp)
            }
            Err(e) if node_gone(&e) => Err(failed(format!("{e:#}"))),
            Err(e) => Err(e),
        }
    }
}

/// The prompt's size in tokens, roughly (four characters each), for the finish estimate.
fn prompt_tokens(req: &Request<'_>) -> u64 {
    let msgs = serde_json::to_string(req.messages).map_or(0, |s| s.len());
    let tools: usize = req
        .tools
        .iter()
        .map(|t| t.name.len() + t.description.len() + t.schema.to_string().len())
        .sum();
    ((req.system.len() + msgs + tools) / 4) as u64
}

/// The prompt's stable head: the system prompt up to the per-session environment
/// (`prompt::ENV_HEADER`, which the engine moves out for pooled models) plus the tools, the same
/// for every session on the repo whatever its worktree. Its hash and estimated tokens, for
/// placing a new session where the head is already in KV.
fn prefix(req: &Request<'_>) -> Option<(u64, u64)> {
    use std::hash::{Hash, Hasher};
    let end = req
        .system
        .find(crate::prompt::ENV_HEADER)
        .unwrap_or(req.system.len());
    let head = &req.system[..end];
    let mut h = std::collections::hash_map::DefaultHasher::new();
    head.hash(&mut h);
    let mut chars = head.len();
    for t in req.tools {
        t.name.hash(&mut h);
        t.description.hash(&mut h);
        t.schema.to_string().hash(&mut h);
        chars += t.name.len() + t.description.len() + t.schema.to_string().len();
    }
    (chars >= 1024).then(|| (h.finish(), (chars / 4) as u64))
}

/// What a call is likely to write: after tool results, usually the next tool call.
fn step(req: &Request<'_>) -> Step {
    let after_tools = req.messages.last().is_some_and(|m| {
        m.content
            .iter()
            .any(|b| matches!(b, crate::message::Block::ToolResult { .. }))
    });
    if after_tools {
        Step::Tool
    } else {
        Step::Answer
    }
}

/// A node that died, not a request it refused: transport, 5xx, an error mid-stream, a stall.
fn node_gone(e: &anyhow::Error) -> bool {
    if let Some(h) = e.downcast_ref::<HttpError>() {
        return h.status >= 500;
    }
    e.is::<Stalled>()
        || e.is::<super::StreamError>()
        || e.chain()
            .any(|c| c.downcast_ref::<reqwest::Error>().is_some())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::{Block, Message, Role};
    use crate::nodes::fake::{Chat, paired, quick, spawn};

    const Q4: &str = "aa11bb22cc33dd44";

    async fn call(c: &Client) -> (Result<Response>, String) {
        call_as(c, false).await
    }

    async fn call_as(c: &Client, background: bool) -> (Result<Response>, String) {
        let messages = vec![Message {
            role: Role::User,
            content: vec![Block::Text { text: "hi".into() }],
        }];
        let req = Request {
            system: "",
            messages: &messages,
            tools: &[],
            max_tokens: Some(16),
            format: None,
            think: None,
            think_budget: None,
            cache_key: None,
            background,
        };
        let mut seen = String::new();
        let r = c
            .complete(&req, &mut |e| {
                if let StreamEvent::Text(t) = e {
                    seen.push_str(&t)
                }
            })
            .await;
        (r, seen)
    }

    #[tokio::test]
    async fn a_dead_node_fails_over_and_the_next_call_runs_elsewhere() {
        let dead = spawn("fa", 900, vec![("org/Qwen3-4B", Q4, true)], Chat::Fail).await;
        let mac = spawn(
            "fb",
            1,
            vec![("org/Qwen3-4B", Q4, true)],
            Chat::Reply("hello"),
        )
        .await;
        let pool = crate::nodes::Pool::fixed(
            vec![paired("mew", "fa", &dead)],
            Some(mac.base.clone()),
            quick(),
        );
        let c = Client::new(pool, "aa11bb22cc33", None);
        let (r, _) = call(&c).await;
        let f = r.err().unwrap();
        let f = f.downcast_ref::<NodeFailed>().expect("a node failure");
        assert_eq!(
            f.notice().unwrap(),
            "mew stopped answering; finishing on this Mac"
        );
        let (r, text) = call(&c).await;
        let resp = r.unwrap();
        assert_eq!(text, "hello");
        assert_eq!(resp.usage.ran_on.unwrap().name, "this Mac");
        assert_eq!(c.ran_on().unwrap().local, true);
        assert_eq!((dead.chats(), mac.chats()), (1, 1));
    }

    #[tokio::test]
    async fn a_stall_mid_stream_is_a_node_failure() {
        let quiet = spawn(
            "fa",
            900,
            vec![("org/Qwen3-4B", Q4, true)],
            Chat::Stall("half a rep"),
        )
        .await;
        let pool = crate::nodes::Pool::fixed(vec![paired("mew", "fa", &quiet)], None, quick());
        let c = Client::new(pool, "aa11bb22cc33", None);
        let (r, text) = call(&c).await;
        assert_eq!(text, "half a rep");
        let e = r.err().unwrap();
        let f = e.downcast_ref::<NodeFailed>().expect("a node failure");
        // Nowhere else has it: no notice, one line, and the next call doesn't go back.
        assert!(f.notice().is_none());
        assert_eq!(
            e.to_string(),
            "mew stopped answering and no other node has this model right now"
        );
        let (r, _) = call(&c).await;
        assert!(r.err().unwrap().downcast_ref::<NoPlacement>().is_some());
        assert_eq!(quiet.chats(), 1);
    }

    #[tokio::test]
    async fn calls_say_their_priority() {
        let node = spawn(
            "fa",
            900,
            vec![("org/Qwen3-4B", Q4, true)],
            Chat::Reply("hi"),
        )
        .await;
        let pool = crate::nodes::Pool::fixed(vec![paired("mew", "fa", &node)], None, quick());
        let c = Client::new(pool, "aa11bb22cc33", None);
        assert!(call_as(&c, false).await.0.is_ok());
        assert!(call_as(&c, true).await.0.is_ok());
        assert_eq!(
            *node.priorities.lock().unwrap(),
            vec!["interactive".to_string(), "background".to_string()]
        );
    }

    /// A pool whose local tang isn't running yet, and starts (as a fake) on demand.
    fn startable(
        paired: Vec<crate::nodes::Paired>,
    ) -> (
        Arc<crate::nodes::Pool>,
        Arc<std::sync::atomic::AtomicUsize>,
        Arc<Mutex<Option<crate::nodes::fake::Fake>>>,
    ) {
        let addr = crate::nodes::fake::reserve();
        let starts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let up = Arc::new(Mutex::new(None));
        let (count, keep) = (starts.clone(), up.clone());
        let start = crate::nodes::LocalStart {
            catalog: Box::new(|| vec![(Q4.to_string(), "org/Qwen3-4B".to_string())]),
            start: Box::new(move |model| {
                let (count, keep) = (count.clone(), keep.clone());
                Box::pin(async move {
                    assert_eq!(model, "org/Qwen3-4B");
                    count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    let f = crate::nodes::fake::spawn_at(
                        addr,
                        "fc",
                        vec![("org/Qwen3-4B", Q4, true)],
                        Chat::Reply("from the mac"),
                    )
                    .await;
                    *keep.lock().unwrap() = Some(f);
                    Ok(())
                })
            }),
        };
        let pool =
            crate::nodes::Pool::fixed_with_start(paired, format!("http://{addr}"), quick(), start);
        (pool, starts, up)
    }

    #[tokio::test]
    async fn an_unstarted_local_tang_is_started_when_it_is_the_only_place() {
        let (pool, starts, _up) = startable(vec![]);
        let c = Client::new(pool, "aa11bb22cc33", None);
        let (r, text) = call(&c).await;
        let resp = r.unwrap();
        assert_eq!(text, "from the mac");
        assert!(resp.usage.ran_on.unwrap().local);
        // Running now: the next call doesn't start it again.
        assert!(call(&c).await.0.is_ok());
        assert_eq!(starts.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn failover_starts_this_macs_tang() {
        let dead = spawn("fa", 900, vec![("org/Qwen3-4B", Q4, true)], Chat::Fail).await;
        let (pool, starts, _up) = startable(vec![paired("mew", "fa", &dead)]);
        let c = Client::new(pool, "aa11bb22cc33", None);
        let (r, _) = call(&c).await;
        let e = r.err().unwrap();
        let f = e.downcast_ref::<NodeFailed>().expect("a node failure");
        assert_eq!(
            f.notice().unwrap(),
            "mew stopped answering; finishing on this Mac"
        );
        // Not started for a node that answered: only when this Mac is where the call goes.
        assert_eq!(starts.load(std::sync::atomic::Ordering::SeqCst), 0);
        let (r, text) = call(&c).await;
        assert_eq!(text, "from the mac");
        assert!(r.unwrap().usage.ran_on.unwrap().local);
        assert_eq!(starts.load(std::sync::atomic::Ordering::SeqCst), 1);
    }
}
