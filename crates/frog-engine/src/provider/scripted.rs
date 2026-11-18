//! A provider that replays canned responses, for engine tests.

use super::{HttpError, Request, Response, StreamError, StreamEvent};
use crate::message::Block;
use anyhow::{Result, anyhow};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// One scripted model call that goes wrong. `partial` blocks stream first (as a reply that
/// began and then broke off) unless it's empty, then the call fails.
#[derive(Clone)]
pub enum Fail {
    /// An error event inside a healthy (2xx) stream, as gateways send when their upstream
    /// stumbles.
    Stream { partial: Vec<Block>, message: String },
    /// A non-2xx answer, before anything streams.
    Http { status: u16, body: String },
    /// A busy answer that says how long to wait (its `retry-after`, in seconds).
    Busy { status: u16, body: String, retry_after: u64 },
    /// The edge's billing refusal: a 402 with its `x-frog-billing` header, as frog cloud
    /// sends it.
    Billing {
        status: u16,
        body: String,
        /// The `x-frog-billing` header's value (`credit: <micros>`), when the edge said.
        billing: Option<String>,
    },
    /// A call that never answers: the stream stalls before its first byte and stays that way
    /// (a dead upstream with the socket still open). For the quiet-child tests.
    Stall,
    /// A call that hangs `secs` and then fails as a timed-out stream would: a real stall,
    /// which the retry policy retries.
    Hang { secs: u64 },
    /// A bug: the call panics, taking the engine's work loop with it. For the dead-child tests.
    Panic,
    /// `text` streams, then nothing for `secs`, then the call goes on with the next scripted
    /// response: a stream that stalls mid-reply and recovers. For the quiet-call tests.
    Pause { text: String, secs: u64 },
}

impl Fail {
    /// A stream that dies with nothing streamed yet.
    pub fn before(message: &str) -> Self {
        Self::Stream {
            partial: Vec::new(),
            message: message.into(),
        }
    }

    /// A stream that fails after `text` has streamed.
    pub fn partial(text: &str, message: &str) -> Self {
        Self::Stream {
            partial: vec![Block::Text { text: text.into() }],
            message: message.into(),
        }
    }

    /// A 4xx/5xx answer, as a request that never got anywhere.
    pub fn http(status: u16, body: &str) -> Self {
        Self::Http {
            status,
            body: body.into(),
        }
    }

    /// frog cloud's billing refusal: a 402 with the edge's `x-frog-billing` header.
    pub fn billing(body: &str, header: Option<&str>) -> Self {
        Self::Billing {
            status: 402,
            body: body.into(),
            billing: header.map(Into::into),
        }
    }
}

pub struct Client {
    pub responses: Mutex<VecDeque<Response>>,
    /// Each request as the server would see it: the system prompt, the tools' names, then the
    /// messages as JSON.
    pub sent: Arc<Mutex<Vec<String>>>,
    /// Each request's fixed part in full: the system prompt, then every tool's name,
    /// description and schema in the order sent. For prompt-size and cache-prefix tests.
    pub fixed: Arc<Mutex<Vec<(String, Vec<(String, String, String)>)>>>,
    /// Stream each tool call's arguments as `StreamEvent::ToolReady`, then keep "decoding" for
    /// this long before the next block, as a model still writing its reply would.
    pub tool_args: Option<Duration>,
    /// Calls that fail (see [`Fail`]), consumed before `responses`.
    pub fails: Mutex<VecDeque<Fail>>,
    /// When each attempt started, for asserting a backoff sequence (paused-clock tests).
    pub attempts: std::sync::Arc<Mutex<Vec<tokio::time::Instant>>>,
    /// When set (a `(enabled, release)` pair), every call pends here after its request was
    /// recorded but before its reply streams — a slow provider, so a test can land an
    /// interrupt mid-call deterministically. (A `Notify` permit set before the waiter
    /// registers would be lost, so the gate is flags the call polls until the test flips it.)
    pub hold: Option<Arc<(std::sync::atomic::AtomicBool, std::sync::atomic::AtomicBool)>>,
    /// The client another Frog Cloud model answers with, when the engine falls back to one
    /// (taken once; without it a scripted session never falls back).
    pub fallback: Mutex<Option<Box<Client>>>,
    /// The model's context window, in bytes of the request as `sent` records it: a longer
    /// request is refused with frog cloud's 413 `context_length_exceeded`, as a real server
    /// refuses a prompt its window can't hold. Refused requests don't consume the script.
    pub window: Option<usize>,
    /// When set, the server prefills (tang-llm's `/v1/prefill`) and takes a conversation key:
    /// each warm-up lands here, as `sent` records calls, once it reaches the server.
    pub prefills: Option<Arc<Mutex<Vec<Prefilled>>>>,
    /// While set and false, a warm-up pends before it reaches the server (`prefills`), as a
    /// long prefill still running would; flipping it to true lets every held one through.
    pub prefill_gate: Option<Arc<std::sync::atomic::AtomicBool>>,
}

/// One warm-up as the server saw it.
#[derive(Clone, Debug, PartialEq)]
pub struct Prefilled {
    /// The conversation key (`prompt_cache_key`) it warms.
    pub key: Option<String>,
    /// The request, rendered as [`Client::sent`] renders calls.
    pub request: String,
}

/// A request as the server would see it: the system prompt, the tools' names, then the
/// messages as JSON.
fn render(req: &Request<'_>) -> Result<String> {
    let tools: String = req
        .tools
        .iter()
        .map(|t| format!("<tool {}>", t.name))
        .collect();
    Ok(format!(
        "{}{tools}{}",
        req.system,
        serde_json::to_string(req.messages)?
    ))
}

impl Client {
    pub fn new(responses: Vec<Response>) -> Self {
        Self {
            responses: Mutex::new(responses.into()),
            sent: Default::default(),
            fixed: Default::default(),
            tool_args: None,
            fails: Default::default(),
            attempts: Default::default(),
            hold: None,
            fallback: Default::default(),
            window: None,
            prefills: None,
            prefill_gate: None,
        }
    }

    /// A server that prefills: warm-ups are recorded in the returned list.
    pub fn with_prefill(mut self) -> (Self, Arc<Mutex<Vec<Prefilled>>>) {
        let prefills = Arc::new(Mutex::new(Vec::new()));
        self.prefills = Some(prefills.clone());
        (self, prefills)
    }

    /// Prefill `req` (only on a client [`with_prefill`](Self::with_prefill)): recorded when it
    /// reaches the server, after the gate if one is set.
    pub fn prefill(
        &self,
        req: &Request<'_>,
    ) -> impl std::future::Future<Output = Result<()>> + Send + 'static {
        let rendered = render(req);
        let key = req.cache_key.map(String::from);
        let prefills = self.prefills.clone();
        let gate = self.prefill_gate.clone();
        async move {
            if let Some(gate) = gate {
                while !gate.load(std::sync::atomic::Ordering::SeqCst) {
                    tokio::time::sleep(Duration::from_millis(2)).await;
                }
            }
            let request = rendered?;
            if let Some(p) = prefills {
                p.lock().unwrap().push(Prefilled { key, request });
            }
            Ok(())
        }
    }

    pub async fn complete(
        &self,
        req: &Request<'_>,
        on: &mut (dyn FnMut(StreamEvent) + Send),
    ) -> Result<Response> {
        self.attempts.lock().unwrap().push(tokio::time::Instant::now());
        self.fixed.lock().unwrap().push((
            req.system.to_string(),
            req.tools
                .iter()
                .map(|t| {
                    (
                        t.name.to_string(),
                        t.description.to_string(),
                        t.schema.to_string(),
                    )
                })
                .collect(),
        ));
        let request = render(req)?;
        let len = request.len();
        self.sent.lock().unwrap().push(request);
        if let Some(window) = self.window
            && len > window
        {
            return Err(HttpError {
                status: 413,
                body: format!(
                    "{{\"error\":{{\"message\":\"context_length_exceeded: this request is at least \
                     {len} bytes and the model's context window is {window}; shorten or compact the \
                     conversation\",\"type\":\"invalid_request_error\",\"code\":413}}}}"
                ),
                billing: None,
                retry_after: None,
            }
            .into());
        }
        // The request is in: the call is mid-flight now. Hold here if asked, until the test
        // releases it, so an op racing the turn (a Shutdown, an interrupt) lands mid-call.
        if let Some(gate) = &self.hold {
            let (enabled, release) = (&gate.0, &gate.1);
            while enabled.load(std::sync::atomic::Ordering::SeqCst)
                && !release.load(std::sync::atomic::Ordering::SeqCst)
            {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        }
        let fail = self.fails.lock().unwrap().pop_front();
        if let Some(fail) = fail {
            match fail {
                Fail::Stream { partial, message } => {
                    for b in &partial {
                        if let Block::Text { text } = b {
                            on(StreamEvent::Text(text.clone()));
                        }
                    }
                    return Err(StreamError { message }.into());
                }
                Fail::Http { status, body } => {
                    return Err(HttpError { status, body, billing: None, retry_after: None }.into());
                }
                Fail::Busy { status, body, retry_after } => {
                    return Err(HttpError {
                        status,
                        body,
                        billing: None,
                        retry_after: Some(Duration::from_secs(retry_after)),
                    }
                    .into());
                }
                Fail::Billing { status, body, billing } => {
                    return Err(HttpError {
                        status,
                        body,
                        billing: billing
                            .as_deref()
                            .and_then(super::Billing::from_header),
                        retry_after: None,
                    }
                    .into());
                }
                Fail::Stall => std::future::pending::<()>().await,
                Fail::Hang { secs } => {
                    tokio::time::sleep(Duration::from_secs(secs)).await;
                    return Err(StreamError {
                        message: "operation timed out".into(),
                    }
                    .into());
                }
                Fail::Panic => panic!("scripted provider panic (a test's injected bug)"),
                Fail::Pause { text, secs } => {
                    on(StreamEvent::Text(text));
                    tokio::time::sleep(Duration::from_secs(secs)).await;
                }
            }
        }
        let r = self
            .responses
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| anyhow!("script exhausted"))?;
        let mut index = 0;
        for b in &r.message.content {
            match b {
                Block::Thinking { text, .. } => on(StreamEvent::Thinking(text.clone())),
                // Text-mode calls stream as text: a pause after each one closes.
                Block::Text { text } if self.tool_args.is_some() => {
                    for piece in text.split_inclusive("</tool_call>") {
                        on(StreamEvent::Text(piece.to_string()));
                        if let Some(wait) = self.tool_args
                            && piece.ends_with("</tool_call>")
                        {
                            tokio::time::sleep(wait).await;
                        }
                    }
                }
                Block::Text { text } => on(StreamEvent::Text(text.clone())),
                Block::ToolUse { name, input, .. } => {
                    on(StreamEvent::ToolCall(name.clone()));
                    // Arguments arrive in pieces, as from a real server.
                    let args = input.to_string();
                    let mut rest = args.as_str();
                    while !rest.is_empty() {
                        let mut cut = rest.len().min(16);
                        while !rest.is_char_boundary(cut) {
                            cut += 1;
                        }
                        let (chunk, tail) = rest.split_at(cut);
                        on(StreamEvent::ToolArgs {
                            name: name.clone(),
                            chunk: chunk.into(),
                        });
                        rest = tail;
                    }
                    if let Some(wait) = self.tool_args {
                        on(StreamEvent::ToolReady {
                            index,
                            name: name.clone(),
                            input: input.clone(),
                        });
                        index += 1;
                        tokio::time::sleep(wait).await;
                    }
                }
                Block::ToolResult { .. } | Block::Image { .. } => {}
            }
        }
        Ok(r)
    }
}
