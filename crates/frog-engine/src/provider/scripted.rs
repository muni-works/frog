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
}

pub struct Client {
    pub responses: Mutex<VecDeque<Response>>,
    /// Each request as the server would see it: the system prompt, the tools' names, then the
    /// messages as JSON.
    pub sent: Arc<Mutex<Vec<String>>>,
    /// Stream each tool call's arguments as `StreamEvent::ToolReady`, then keep "decoding" for
    /// this long before the next block, as a model still writing its reply would.
    pub tool_args: Option<Duration>,
    /// Calls that fail (see [`Fail`]), consumed before `responses`.
    pub fails: Mutex<VecDeque<Fail>>,
}

impl Client {
    pub fn new(responses: Vec<Response>) -> Self {
        Self {
            responses: Mutex::new(responses.into()),
            sent: Default::default(),
            tool_args: None,
            fails: Default::default(),
        }
    }

    pub async fn complete(
        &self,
        req: &Request<'_>,
        on: &mut (dyn FnMut(StreamEvent) + Send),
    ) -> Result<Response> {
        let tools: String = req
            .tools
            .iter()
            .map(|t| format!("<tool {}>", t.name))
            .collect();
        self.sent.lock().unwrap().push(format!(
            "{}{tools}{}",
            req.system,
            serde_json::to_string(req.messages)?
        ));
        if let Some(fail) = self.fails.lock().unwrap().pop_front() {
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
                    return Err(HttpError { status, body }.into());
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
