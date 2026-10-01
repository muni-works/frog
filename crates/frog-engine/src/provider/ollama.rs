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
    /// Whether the model takes images (ollama lists a `vision` capability).
    pub async fn supports_vision(&self) -> Option<bool> {
        let caps = self.show().await?;
        let caps = caps["capabilities"].as_array()?;
        Some(caps.iter().any(|c| c.as_str() == Some("vision")))
    }

    async fn show(&self) -> Option<Value> {
        let url = format!("{}/api/show", self.base.trim_end_matches('/'));
        let resp = self
            .http
            .post(url)
            .json(&json!({ "model": self.model }))
            .send()
            .await
            .ok()?;
        resp.json().await.ok()
    }

    /// `details.parameter_size`, like "3.1B" or "270M".
    pub async fn params_b(&self) -> Option<f64> {
        let v = self.show().await?;
        let size = v["details"]["parameter_size"]
            .as_str()?
            .trim()
            .to_uppercase();
        let (num, scale) = match size.strip_suffix('B') {
            Some(n) => (n, 1.0),
            None => (size.strip_suffix('M')?, 0.001),
        };
        num.parse::<f64>().ok().map(|n| n * scale)
    }

    /// The model's maximum context length, from `/api/show`.
    pub async fn probe_context(&self) -> Option<u64> {
        self.show().await?["model_info"]
            .as_object()?
            .iter()
            .find(|(k, _)| k.ends_with(".context_length"))
            .and_then(|(_, v)| v.as_u64())
    }

    fn body(&self, req: &Request) -> Value {
        let mut messages = vec![json!({ "role": "system", "content": req.system })];
        for m in req.messages {
            match m.role {
                Role::User => {
                    let (mut text, mut images) = (Vec::new(), Vec::new());
                    for b in &m.content {
                        match b {
                            Block::ToolResult { name, content, .. } => messages.push(
                                json!({ "role": "tool", "tool_name": name, "content": content }),
                            ),
                            Block::Text { text: t } => text.push(t.as_str()),
                            Block::Image { data, .. } => images.push(data.as_str()),
                            _ => {}
                        }
                    }
                    if !text.is_empty() || !images.is_empty() {
                        let mut msg = json!({ "role": "user", "content": text.join("\n\n") });
                        if !images.is_empty() {
                            msg["images"] = json!(images);
                        }
                        messages.push(msg);
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
        if let Some(schema) = req.format {
            body["format"] = schema.clone();
        }
        if let Some(think) = req.think {
            body["think"] = json!(think);
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::Message;

    #[test]
    fn images_ride_on_a_user_message() {
        let c = Client {
            http: reqwest::Client::new(),
            base: "http://localhost:1".into(),
            model: "m".into(),
            num_ctx: 4096,
            extra: None,
        };
        let msgs = vec![Message {
            role: Role::User,
            content: vec![
                Block::Text {
                    text: "what's this?".into(),
                },
                Block::Image {
                    mime: "image/png".into(),
                    data: "AAAA".into(),
                },
            ],
        }];
        let req = Request {
            system: "s",
            messages: &msgs,
            tools: &[],
            max_tokens: None,
            format: None,
            think: None,
            think_budget: None,
            cache_key: None,
        };
        let body = c.body(&req);
        let m = &body["messages"][1];
        assert_eq!(m["content"], "what's this?");
        assert_eq!(m["images"][0], "AAAA");
    }

    #[test]
    fn thinking_switch_is_the_think_flag() {
        let c = Client {
            http: reqwest::Client::new(),
            base: "http://localhost:1".into(),
            model: "m".into(),
            num_ctx: 4096,
            extra: None,
        };
        let msgs = vec![Message::user("hi")];
        let req = |think| Request {
            system: "s",
            messages: &msgs,
            tools: &[],
            max_tokens: None,
            format: None,
            think,
            think_budget: None,
            cache_key: None,
        };
        assert_eq!(c.body(&req(Some(false)))["think"], false);
        assert!(c.body(&req(None)).get("think").is_none());
    }
}
