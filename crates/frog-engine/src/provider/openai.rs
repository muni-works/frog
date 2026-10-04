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
    /// The context window the server is running with, if it says. Tries llama.cpp (`/props`),
    /// LM Studio (`/api/v0/models/{id}`), then vLLM (`/v1/models` `max_model_len`).
    pub async fn probe_context(&self) -> Option<u64> {
        let base = self.base.trim_end_matches('/');
        let root = base.trim_end_matches("/v1");
        let get = |url: String| async move {
            let mut rb = self.http.get(url);
            if let Some(k) = &self.key {
                rb = rb.bearer_auth(k);
            }
            let resp = rb.send().await.ok()?;
            if !resp.status().is_success() {
                return None;
            }
            resp.json::<Value>().await.ok()
        };
        if let Some(v) = get(format!("{root}/props")).await
            && let Some(n) = v["default_generation_settings"]["n_ctx"]
                .as_u64()
                .or(v["n_ctx"].as_u64())
        {
            return Some(n);
        }
        if let Some(v) = get(format!("{root}/api/v0/models/{}", self.model)).await
            && let Some(n) = v["loaded_context_length"]
                .as_u64()
                .or(v["max_context_length"].as_u64())
        {
            return Some(n);
        }
        let v = get(format!("{base}/models")).await?;
        v["data"]
            .as_array()?
            .iter()
            .find(|m| m["id"].as_str() == Some(self.model.as_str()))
            .and_then(|m| m["max_model_len"].as_u64())
    }

    /// OpenAI's own API (not a compatible server).
    pub fn is_openai(&self) -> bool {
        self.base.contains("api.openai.com")
    }

    /// Capabilities the server lists for this model in `/v1/models` (tang-llm and ollama's /v1
    /// say `vision`), if any.
    pub async fn capabilities(&self) -> Option<Vec<String>> {
        let url = format!("{}/models", self.base.trim_end_matches('/'));
        let mut rb = self.http.get(url);
        if let Some(k) = &self.key {
            rb = rb.bearer_auth(k);
        }
        let v: Value = rb.send().await.ok()?.json().await.ok()?;
        let models = v["data"].as_array()?;
        let m = models
            .iter()
            .find(|m| m["id"].as_str() == Some(self.model.as_str()))
            .or_else(|| (models.len() == 1).then(|| &models[0]))?;
        Some(
            m["capabilities"]
                .as_array()?
                .iter()
                .filter_map(|c| c.as_str().map(String::from))
                .collect(),
        )
    }

    fn body(&self, req: &Request) -> Value {
        let mut messages = vec![json!({ "role": "system", "content": req.system })];
        for m in req.messages {
            match m.role {
                Role::User => {
                    let (mut text, mut images) = (Vec::new(), Vec::new());
                    for b in &m.content {
                        match b {
                            Block::ToolResult { id, content, .. } => messages.push(
                                json!({ "role": "tool", "tool_call_id": id, "content": content }),
                            ),
                            Block::Text { text: t } => text.push(t.as_str()),
                            Block::Image { mime, data } => images.push(json!({
                                "type": "image_url",
                                "image_url": { "url": format!("data:{mime};base64,{data}") },
                            })),
                            _ => {}
                        }
                    }
                    if !images.is_empty() {
                        // Tool messages can't carry images, so they follow as a user message.
                        let mut parts = vec![
                            json!({ "type": "text", "text": if text.is_empty() { "(image)".to_string() } else { text.join("\n\n") } }),
                        ];
                        parts.extend(images);
                        messages.push(json!({ "role": "user", "content": parts }));
                    } else if !text.is_empty() {
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
        if let Some(schema) = req.format {
            body["response_format"] = json!({
                "type": "json_schema",
                "json_schema": { "name": "frog_action", "schema": schema },
            });
        }
        // Only the generation prompt changes, so the server's cached prefix still matches.
        // OpenAI's own API rejects unknown fields.
        if let Some(think) = req.think
            && !self.is_openai()
        {
            body["chat_template_kwargs"] = json!({ "enable_thinking": think });
        }
        if let Some(n) = req.think_budget
            && !self.is_openai()
        {
            body["thinking_budget"] = json!(n);
        }
        if let Some(k) = req.cache_key {
            body["prompt_cache_key"] = json!(k);
        }
        if let Some(extra) = &self.extra {
            deep_merge(&mut body, extra);
        }
        body
    }

    /// Have the server prefill `req` without answering (tang-llm's `/v1/prefill`), so the
    /// call that follows starts from a warm cache.
    pub fn prefill(&self, req: &Request<'_>) -> impl Future<Output = Result<()>> + Send + 'static {
        let url = format!("{}/prefill", self.base.trim_end_matches('/'));
        let mut body = self.body(req);
        if let Some(o) = body.as_object_mut() {
            o.remove("stream");
            o.remove("stream_options");
        }
        let mut rb = self.http.post(url).json(&body);
        if let Some(k) = &self.key {
            rb = rb.bearer_auth(k);
        }
        async move {
            rb.send().await?.error_for_status()?;
            Ok(())
        }
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
        // Calls whose arguments already parsed (`StreamEvent::ToolReady` went out).
        let mut ready: Vec<bool> = Vec::new();
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
                    ready.resize(idx + 1, false);
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
                // A JSON object can't grow once it closes, so arguments that parse are done.
                if !ready[idx]
                    && !c.1.is_empty()
                    && c.2.trim_end().ends_with('}')
                    && let Ok(input @ Value::Object(_)) = serde_json::from_str::<Value>(&c.2)
                {
                    ready[idx] = true;
                    let name = c.1.clone();
                    // Its place among the calls the response will keep (the named ones).
                    let index = calls[..idx].iter().filter(|c| !c.1.is_empty()).count();
                    on(StreamEvent::ToolReady { index, name, input });
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::Message;

    #[test]
    fn images_follow_tool_results_as_a_user_message() {
        let c = Client {
            http: reqwest::Client::new(),
            base: "http://localhost:1/v1".into(),
            model: "m".into(),
            key: None,
            extra: None,
        };
        let msgs = vec![Message {
            role: Role::User,
            content: vec![
                Block::ToolResult {
                    id: "t1".into(),
                    name: "look".into(),
                    content: "a window".into(),
                    is_error: false,
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
        let m = body["messages"].as_array().unwrap();
        assert_eq!(m[1]["role"], "tool");
        assert_eq!(m[2]["role"], "user");
        assert_eq!(
            m[2]["content"][1]["image_url"]["url"],
            "data:image/png;base64,AAAA"
        );
    }

    #[test]
    fn thinking_budget_is_a_top_level_field_but_not_for_openai() {
        let client = |base: &str| Client {
            http: reqwest::Client::new(),
            base: base.into(),
            model: "m".into(),
            key: None,
            extra: None,
        };
        let msgs = vec![Message::user("hi")];
        let req = |think_budget| Request {
            system: "s",
            messages: &msgs,
            tools: &[],
            max_tokens: None,
            format: None,
            think: None,
            think_budget,
            cache_key: None,
        };
        let tang = client("http://192.168.2.12:8420/v1");
        assert_eq!(tang.body(&req(Some(1024)))["thinking_budget"], 1024);
        assert!(tang.body(&req(None)).get("thinking_budget").is_none());
        let openai = client("https://api.openai.com/v1");
        assert!(
            openai
                .body(&req(Some(1024)))
                .get("thinking_budget")
                .is_none()
        );
    }

    #[test]
    fn cache_key_is_sent_as_prompt_cache_key() {
        let c = Client {
            http: reqwest::Client::new(),
            base: "http://127.0.0.1:8911/v1".into(),
            model: "m".into(),
            key: None,
            extra: None,
        };
        let msgs = vec![Message::user("hi")];
        let req = |cache_key| Request {
            system: "s",
            messages: &msgs,
            tools: &[],
            max_tokens: None,
            format: None,
            think: None,
            think_budget: None,
            cache_key,
        };
        assert_eq!(c.body(&req(Some("abc")))["prompt_cache_key"], "abc");
        assert!(c.body(&req(None)).get("prompt_cache_key").is_none());
    }

    #[test]
    fn thinking_switch_goes_in_template_kwargs_but_not_to_openai() {
        let client = |base: &str, extra: Option<Value>| Client {
            http: reqwest::Client::new(),
            base: base.into(),
            model: "m".into(),
            key: None,
            extra,
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
        let local = client("http://localhost:8911/v1", None);
        assert_eq!(
            local.body(&req(Some(false)))["chat_template_kwargs"]["enable_thinking"],
            false
        );
        assert!(local.body(&req(None)).get("chat_template_kwargs").is_none());
        let openai = client("https://api.openai.com/v1", None);
        assert!(
            openai
                .body(&req(Some(false)))
                .get("chat_template_kwargs")
                .is_none()
        );
        // The profile's own `extra` wins.
        let pinned = client(
            "http://localhost:8911/v1",
            Some(json!({ "chat_template_kwargs": { "enable_thinking": true } })),
        );
        assert_eq!(
            pinned.body(&req(Some(false)))["chat_template_kwargs"]["enable_thinking"],
            true
        );
    }
}
