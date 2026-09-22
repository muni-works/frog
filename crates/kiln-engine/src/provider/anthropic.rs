//! Anthropic Messages API with streaming and prompt caching.

use super::{Request, Response, Stop, StreamEvent, deep_merge, parse_args, sse};
use crate::message::{Block, Message, Role, Usage};
use anyhow::{Result, bail};
use serde_json::{Value, json};

pub struct Client {
    pub http: reqwest::Client,
    pub base: String,
    pub model: String,
    pub key: String,
    pub extra: Option<Value>,
}

fn block_json(b: &Block) -> Option<Value> {
    Some(match b {
        Block::Text { text } if text.trim().is_empty() => return None,
        Block::Text { text } => json!({ "type": "text", "text": text }),
        // Thinking from other providers has no signature and can't be replayed.
        Block::Thinking {
            text,
            signature: Some(sig),
        } => json!({ "type": "thinking", "thinking": text, "signature": sig }),
        Block::Thinking { .. } => return None,
        Block::ToolUse { id, name, input } => {
            json!({ "type": "tool_use", "id": id, "name": name, "input": input })
        }
        Block::ToolResult {
            id,
            content,
            is_error,
            ..
        } => {
            json!({ "type": "tool_result", "tool_use_id": id, "content": content, "is_error": is_error })
        }
    })
}

enum Partial {
    Text(String),
    Thinking(String, String),
    Tool(String, String, String),
    Other,
}

impl Client {
    fn body(&self, req: &Request) -> Value {
        let mut messages: Vec<Value> = req
            .messages
            .iter()
            .map(|m: &Message| {
                let role = match m.role {
                    Role::User => "user",
                    Role::Assistant => "assistant",
                };
                json!({ "role": role, "content": m.content.iter().filter_map(block_json).collect::<Vec<_>>() })
            })
            .filter(|m| m["content"].as_array().is_some_and(|c| !c.is_empty()))
            .collect();
        // Cache everything up to the latest message.
        if let Some(last) = messages
            .last_mut()
            .and_then(|m| m["content"].as_array_mut())
            .and_then(|c| c.last_mut())
        {
            last["cache_control"] = json!({ "type": "ephemeral" });
        }
        let mut tools: Vec<Value> = req
            .tools
            .iter()
            .map(|t| json!({ "name": t.name, "description": t.description, "input_schema": t.schema }))
            .collect();
        if let Some(t) = tools.last_mut() {
            t["cache_control"] = json!({ "type": "ephemeral" });
        }
        let mut body = json!({
            "model": self.model,
            "max_tokens": req.max_tokens.unwrap_or(32_000),
            "system": [{ "type": "text", "text": req.system, "cache_control": { "type": "ephemeral" } }],
            "messages": messages,
            "stream": true,
        });
        if !tools.is_empty() {
            body["tools"] = json!(tools);
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
        let resp = self
            .http
            .post(format!("{}/v1/messages", self.base.trim_end_matches('/')))
            .header("x-api-key", &self.key)
            .header("anthropic-version", "2023-06-01")
            .json(&self.body(req))
            .send()
            .await?;
        let resp = sse::check(resp).await?;

        let mut parts: Vec<Partial> = Vec::new();
        let mut usage = Usage::default();
        let mut stop = None;
        sse::for_each_line(resp, |line| {
            let Some(data) = line.strip_prefix("data:").map(str::trim) else {
                return Ok(());
            };
            if data.is_empty() {
                return Ok(());
            }
            let v: Value = serde_json::from_str(data)?;
            match v["type"].as_str().unwrap_or("") {
                "message_start" => {
                    let u = &v["message"]["usage"];
                    usage.input = u["input_tokens"].as_u64().unwrap_or(0)
                        + u["cache_creation_input_tokens"].as_u64().unwrap_or(0);
                    usage.cache_read = u["cache_read_input_tokens"].as_u64().unwrap_or(0);
                }
                "content_block_start" => {
                    let b = &v["content_block"];
                    parts.push(match b["type"].as_str().unwrap_or("") {
                        "text" => Partial::Text(String::new()),
                        "thinking" => Partial::Thinking(String::new(), String::new()),
                        "tool_use" => {
                            let name = b["name"].as_str().unwrap_or("").to_string();
                            on(StreamEvent::ToolCall(name.clone()));
                            Partial::Tool(
                                b["id"].as_str().unwrap_or("").into(),
                                name,
                                String::new(),
                            )
                        }
                        _ => Partial::Other,
                    });
                }
                "content_block_delta" => {
                    let d = &v["delta"];
                    let s = |k: &str| d[k].as_str().unwrap_or("").to_string();
                    match (parts.last_mut(), d["type"].as_str().unwrap_or("")) {
                        (Some(Partial::Text(t)), "text_delta") => {
                            t.push_str(&s("text"));
                            on(StreamEvent::Text(s("text")));
                        }
                        (Some(Partial::Thinking(t, _)), "thinking_delta") => {
                            t.push_str(&s("thinking"));
                            on(StreamEvent::Thinking(s("thinking")));
                        }
                        (Some(Partial::Thinking(_, sig)), "signature_delta") => {
                            sig.push_str(&s("signature"))
                        }
                        (Some(Partial::Tool(_, _, args)), "input_json_delta") => {
                            args.push_str(&s("partial_json"))
                        }
                        _ => {}
                    }
                }
                "message_delta" => {
                    if let Some(r) = v["delta"]["stop_reason"].as_str() {
                        stop = Some(Stop::from_reason(r));
                    }
                    usage.output = v["usage"]["output_tokens"].as_u64().unwrap_or(usage.output)
                }
                "error" => bail!("anthropic error: {}", v["error"]),
                _ => {}
            }
            Ok(())
        })
        .await?;

        let content = parts
            .into_iter()
            .filter_map(|p| match p {
                Partial::Text(text) if !text.is_empty() => Some(Block::Text { text }),
                Partial::Thinking(text, sig) => Some(Block::Thinking {
                    text,
                    signature: Some(sig),
                }),
                Partial::Tool(id, name, args) => Some(Block::ToolUse {
                    id,
                    name,
                    input: parse_args(&args),
                }),
                _ => None,
            })
            .collect();
        Ok(Response {
            message: Message {
                role: Role::Assistant,
                content,
            },
            usage,
            stop: stop.unwrap_or(Stop::Incomplete),
        })
    }
}
