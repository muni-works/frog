//! A provider that replays canned responses, for engine tests.

use super::{Request, Response, StreamEvent};
use crate::message::Block;
use anyhow::{Result, anyhow};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub struct Client {
    pub responses: Mutex<VecDeque<Response>>,
    /// Each request as the server would see it: the system prompt, then the messages as JSON.
    pub sent: Arc<Mutex<Vec<String>>>,
    /// Stream each tool call's arguments as `StreamEvent::ToolReady`, then keep "decoding" for
    /// this long before the next block, as a model still writing its reply would.
    pub tool_args: Option<Duration>,
}

impl Client {
    pub fn new(responses: Vec<Response>) -> Self {
        Self {
            responses: Mutex::new(responses.into()),
            sent: Default::default(),
            tool_args: None,
        }
    }

    pub async fn complete(
        &self,
        req: &Request<'_>,
        on: &mut (dyn FnMut(StreamEvent) + Send),
    ) -> Result<Response> {
        self.sent.lock().unwrap().push(format!(
            "{}{}",
            req.system,
            serde_json::to_string(req.messages)?
        ));
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
