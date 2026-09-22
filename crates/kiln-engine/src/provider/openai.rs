//! OpenAI-compatible chat completions: llama.cpp, LM Studio, vLLM, MLX, ollama's /v1, OpenAI itself.

use super::{Request, Response, Stop, StreamEvent, assistant_message, deep_merge, parse_args, sse};
use crate::message::{Block, Role, Usage};
use anyhow::{Result, bail};
use serde_json::{Value, json};

pub struct Client {
    pub http: reqwest::Client,
    pub base: String,
    pub model: String,
    pub key: Option<String>,
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
                            Block::ToolResult { id, content, .. } => messages.push(
                                json!({ "role": "tool", "tool_call_id": id, "content": content }),
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
                        .map(|(id, name, input)| {
                            json!({ "id": id, "type": "function", "function": { "name": name, "arguments": input.to_string() } })
                        })
                        .collect();
                    let text = m.text();
                    let mut msg = json!({ "role": "assistant", "content": if text.is_empty() { Value::Null } else { json!(text) } });
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
            "stream_options": { "include_usage": true },
        });
        if let Some(n) = req.max_tokens {
            body["max_tokens"] = json!(n);
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
        let url = format!("{}/chat/completions", self.base.trim_end_matches('/'));
        let mut rb = self.http.post(url).json(&self.body(req));
        if let Some(k) = &self.key {
            rb = rb.bearer_auth(k);
        }
        let resp = sse::check(rb.send().await?).await?;

        let mut text = String::new();
        let mut thinking = String::new();
        let mut calls: Vec<(String, String, String)> = Vec::new();
        let mut usage = Usage::default();
        let mut stop = None;

        sse::for_each_line(resp, |line| {
            let Some(data) = line.strip_prefix("data:").map(str::trim) else {
                return Ok(());
            };
            if data.is_empty() || data == "[DONE]" {
                return Ok(());
            }
            let v: Value = serde_json::from_str(data)?;
            if let Some(err) = v.get("error") {
                bail!("server error: {err}");
            }
            if let Some(u) = v.get("usage").filter(|u| u.is_object()) {
                let cached = u["prompt_tokens_details"]["cached_tokens"]
                    .as_u64()
                    .unwrap_or(0);
                usage.input = u["prompt_tokens"]
                    .as_u64()
                    .unwrap_or(0)
                    .saturating_sub(cached);
                usage.cache_read = cached;
                usage.output = u["completion_tokens"].as_u64().unwrap_or(0);
            }
            if let Some(r) = v["choices"][0]["finish_reason"].as_str() {
                stop = Some(Stop::from_reason(r));
            }
            let Some(delta) = v["choices"].get(0).map(|c| &c["delta"]) else {
                return Ok(());
            };
            // llama.cpp/deepseek use reasoning_content; vLLM/ollama/LM Studio use reasoning.
            for key in ["reasoning_content", "reasoning"] {
                if let Some(s) = delta[key].as_str().filter(|s| !s.is_empty()) {
                    thinking.push_str(s);
                    on(StreamEvent::Thinking(s.into()));
                    break;
                }
            }
            if let Some(s) = delta["content"].as_str().filter(|s| !s.is_empty()) {
                text.push_str(s);
                on(StreamEvent::Text(s.into()));
            }
            for tc in delta["tool_calls"].as_array().into_iter().flatten() {
                let idx = tc["index"]
                    .as_u64()
                    .map(|i| i as usize)
                    .unwrap_or(calls.len());
                if calls.len() <= idx {
                    calls.resize_with(idx + 1, Default::default);
                }
                let c = &mut calls[idx];
                if let Some(id) = tc["id"].as_str().filter(|s| !s.is_empty()) {
                    c.0 = id.into();
                }
                if let Some(n) = tc["function"]["name"].as_str().filter(|s| !s.is_empty())
                    && c.1.is_empty()
                {
                    c.1 = n.into();
                    on(StreamEvent::ToolCall(n.into()));
                }
                match &tc["function"]["arguments"] {
                    Value::String(a) => c.2.push_str(a),
                    // Some servers send arguments as an object instead of a string.
                    obj @ Value::Object(_) => c.2 = obj.to_string(),
                    _ => {}
                }
            }
            Ok(())
        })
        .await?;

        let calls = calls
            .into_iter()
            .filter(|c| !c.1.is_empty())
            .map(|(id, name, args)| (id, name, parse_args(&args)))
            .collect();
        Ok(Response {
            message: assistant_message(thinking, None, text, calls),
            usage,
            stop: stop.unwrap_or(Stop::Incomplete),
        })
    }
}
