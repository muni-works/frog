//! A provider that replays canned responses, for engine tests.

use super::{Response, StreamEvent};
use crate::message::Block;
use anyhow::{Result, anyhow};
use std::collections::VecDeque;
use std::sync::Mutex;

pub struct Client {
    pub responses: Mutex<VecDeque<Response>>,
}

impl Client {
    pub fn new(responses: Vec<Response>) -> Self {
        Self {
            responses: Mutex::new(responses.into()),
        }
    }

    pub fn complete(&self, on: &mut (dyn FnMut(StreamEvent) + Send)) -> Result<Response> {
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
                Block::ToolResult { .. } => {}
            }
        }
        Ok(r)
    }
}
