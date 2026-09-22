//! Ollama's native /api/chat. Used over /v1 because it lets us set num_ctx
//! (ollama's default context is tiny and silently truncates prompts).

use super::{Request, Response, Stop, StreamEvent, assistant_message, deep_merge, sse};
use crate::message::{Block, Role, Usage};
use anyhow::{Result, bail};
use serde_json::{Value, json};

pub struct Client {
    pub http: reqwest::Client,
    pub base: String,
    pub model: String,
    pub num_ctx: u64,
    pub extra: Option<Value>,
}

impl Client {
    fn body(&self, req: &Request) -> Value {
        let mut messages = vec![json!({ "role": "system", "content": req.system })];
        for m in req.messages {
            match m.role {
                Role::User => {
                    let mut text = Vec::new();
                    for b in &m.content {
                        match b {
                            Block::ToolResult { name, content, .. } => messages.push(
                                json!({ "role": "tool", "tool_name": name, "content": content }),
                            ),
                            Block::Text { text: t } => text.push(t.as_str()),
                            _ => {}
                        }
                    }
                    if !text.is_empty() {
                        messages.push(json!({ "role": "user", "content": text.join("\n\n") }));
                    }
                }
                Role::Assistant => {
                    let calls: Vec<Value> = m
                        .tool_uses()
                        .into_iter()
                        .map(|(_, name, input)| json!({ "function": { "name": name, "arguments": input } }))
                        .collect();
                    let mut msg = json!({ "role": "assistant", "content": m.text() });
                    if !calls.is_empty() {
                        msg["tool_calls"] = json!(calls);
                    }
                    messages.push(msg);
                }
            }
        }
        let mut body = json!({
            "model": self.model,
            "messages": messages,
            "stream": true,
            "options": { "num_ctx": self.num_ctx },
        });
        if let Some(n) = req.max_tokens {
            body["options"]["num_predict"] = json!(n);
        }
        if !req.tools.is_empty() {
            body["tools"] = req
                .tools
                .iter()
                .map(|t| json!({ "type": "function", "function": { "name": t.name, "description": t.description, "parameters": t.schema } }))
                .collect();
        }
        if let Some(extra) = &self.extra {
            deep_merge(&mut body, extra);
        }
        body
    }

    pub async fn complete(
        &self,
        req: &Request<'_>,
        on: &mut (dyn FnMut(StreamEvent) + Send),
    ) -> Result<Response> {
        let url = format!("{}/api/chat", self.base.trim_end_matches('/'));
        let resp = self
            .http
            .post(url)
            .json(&self.body(req))
            .send()
            .await
            .map_err(|e| {
                if e.is_connect() {
                    // Keep the reqwest error in the chain so the engine can classify it.
                    anyhow::Error::from(e).context(format!(
                        "can't reach ollama at {} — is it running? (`ollama serve`)",
                        self.base
                    ))
                } else {
                    e.into()
                }
            })?;
        let resp = sse::check(resp).await?;

        let mut text = String::new();
        let mut thinking = String::new();
        let mut calls = Vec::new();
        let mut usage = Usage::default();
        let mut stop = None;
        sse::for_each_line(resp, |line| {
            if line.trim().is_empty() {
                return Ok(());
            }
            let v: Value = serde_json::from_str(line)?;
            if let Some(err) = v["error"].as_str() {
                bail!("ollama: {err}");
            }
            let m = &v["message"];
            if let Some(s) = m["thinking"].as_str().filter(|s| !s.is_empty()) {
                thinking.push_str(s);
                on(StreamEvent::Thinking(s.into()));
            }
            if let Some(s) = m["content"].as_str().filter(|s| !s.is_empty()) {
                text.push_str(s);
                on(StreamEvent::Text(s.into()));
            }
            for tc in m["tool_calls"].as_array().into_iter().flatten() {
                let name = tc["function"]["name"].as_str().unwrap_or("").to_string();
                on(StreamEvent::ToolCall(name.clone()));
                let args = match &tc["function"]["arguments"] {
                    Value::String(s) => super::parse_args(s),
                    v => v.clone(),
                };
                calls.push((tc["id"].as_str().unwrap_or("").to_string(), name, args));
            }
            if v["done"].as_bool() == Some(true) {
                stop = Some(Stop::from_reason(
                    v["done_reason"].as_str().unwrap_or("stop"),
                ));
                usage.input = v["prompt_eval_count"].as_u64().unwrap_or(0);
                usage.output = v["eval_count"].as_u64().unwrap_or(0);
            }
            Ok(())
        })
        .await?;

        Ok(Response {
            message: assistant_message(thinking, None, text, calls),
            usage,
            stop: stop.unwrap_or(Stop::Incomplete),
        })
    }
}
