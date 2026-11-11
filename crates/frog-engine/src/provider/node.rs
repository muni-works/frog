//! A pooled model (`node/<hash12>`): each call is placed on one of your paired nodes, or this
//! Mac's tang, and speaks OpenAI-compatible chat to it (docs/node-protocol.md §7). A node that
//! drops mid-call comes back as [`NodeFailed`]; the engine discards the partial and calls again,
//! and the next placement skips the node for 30 s.

use super::{HttpError, Request, Response, Stop, StreamEvent, openai};
use crate::config::Profile;
use crate::nodes::{Placed, Pool};
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

    fn pins(&self) -> Vec<String> {
        self.pin
            .iter()
            .cloned()
            .chain(
                self.last
                    .lock()
                    .unwrap()
                    .as_ref()
                    .map(|p| p.node_id.clone()),
            )
            .collect()
    }

    fn place(&self) -> Result<Placed, String> {
        let pins = self.pins();
        let pins: Vec<&str> = pins.iter().map(String::as_str).collect();
        self.pool.place(&self.hash, &pins)
    }

    fn openai(&self, at: &Placed) -> openai::Client {
        openai::Client {
            http: self.pool.http.clone(),
            base: format!("{}/v1", at.base.trim_end_matches('/')),
            model: at.model.clone(),
            key: at.key.clone(),
            extra: self.extra.clone(),
            anthropic: self.anthropic.clone(),
        }
    }

    /// The context window the node reports for this model.
    pub async fn probe_context(&self) -> Option<u64> {
        self.pool.ensure_fresh().await;
        self.pool.model(&self.hash)?.context_window
    }

    pub async fn capabilities(&self) -> Option<Vec<String>> {
        self.pool.ensure_fresh().await;
        let at = self.place().ok()?;
        self.openai(&at).capabilities().await
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
        let at = self.place().map_err(NoPlacement)?;
        let client = self.openai(&at);
        let timing = self.pool.timing.clone();
        // The last byte's time (None before the first), read by the stall watch.
        let last = Arc::new(Mutex::new(None::<Instant>));
        let heard = last.clone();
        let started = Instant::now();
        let r = {
            let mut forward = |e: StreamEvent| {
                *heard.lock().unwrap() = Some(Instant::now());
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
            let next = self.place().ok().map(|p| p.label().to_string());
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
                resp.usage.ran_on = Some(at.ran_on());
                *self.last.lock().unwrap() = Some(at);
                Ok(resp)
            }
            Err(e) if node_gone(&e) => Err(failed(format!("{e:#}"))),
            Err(e) => Err(e),
        }
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
}
