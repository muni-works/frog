//! A provider that replays canned responses, for engine tests.

use super::{Request, Response, StreamEvent};
use crate::message::Block;
use anyhow::{Result, anyhow};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

pub struct Client {
    pub responses: Mutex<VecDeque<Response>>,
    /// Each request as the server would see it: the system prompt, then the messages as JSON.
    pub sent: Arc<Mutex<Vec<String>>>,
}

impl Client {
    pub fn new(responses: Vec<Response>) -> Self {
        Self {
            responses: Mutex::new(responses.into()),
            sent: Default::default(),
        }
    }

    pub fn complete(
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
        for b in &r.message.content {
            match b {
                Block::Thinking { text, .. } => on(StreamEvent::Thinking(text.clone())),
                Block::Text { text } => on(StreamEvent::Text(text.clone())),
                Block::ToolUse { name, .. } => on(StreamEvent::ToolCall(name.clone())),
                Block::ToolResult { .. } | Block::Image { .. } => {}
            }
        }
        Ok(r)
    }
}
