pub mod anthropic;
pub mod ollama;
pub mod openai;
#[cfg(test)]
pub mod scripted;
mod sse;

use crate::config::{Profile, ProviderKind};
use crate::message::{Block, Message, Usage};
use anyhow::Result;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

pub struct ToolSpec {
    pub name: &'static str,
    pub description: &'static str,
    pub schema: Value,
}

pub struct Request<'a> {
    pub system: &'a str,
    pub messages: &'a [Message],
    pub tools: &'a [ToolSpec],
    pub max_tokens: Option<u32>,
}

pub enum StreamEvent {
    Text(String),
    Thinking(String),
    /// A tool call started streaming (its arguments may take a while).
    ToolCall(String),
}

pub struct Response {
    pub message: Message,
    pub usage: Usage,
    pub stop: Stop,
}

/// Why the model stopped. `Incomplete` means the stream ended without the server saying it was done.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stop {
    End,
    ToolUse,
    Length,
    Incomplete,
}

impl Stop {
    pub fn from_reason(s: &str) -> Self {
        match s {
            "length" | "max_tokens" => Self::Length,
            "tool_calls" | "tool_use" | "function_call" => Self::ToolUse,
            _ => Self::End,
        }
    }
}

/// A non-2xx response from a provider.
#[derive(Debug)]
pub struct HttpError {
    pub status: u16,
    pub body: String,
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "HTTP {}: {}", self.status, self.body)
    }
}

impl std::error::Error for HttpError {}

pub enum Provider {
    OpenAi(openai::Client),
    Anthropic(anthropic::Client),
    Ollama(ollama::Client),
    #[cfg(test)]
    Scripted(scripted::Client),
}

impl Provider {
    pub fn new(p: &Profile) -> Result<Self> {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .build()?;
        let key = p.api_key();
        let extra = p.extra.clone();
        Ok(match p.provider {
            ProviderKind::Openai => Self::OpenAi(openai::Client {
                http,
                base: p
                    .base_url
                    .clone()
                    .unwrap_or_else(|| "https://api.openai.com/v1".into()),
                model: p.model.clone(),
                key,
                extra,
            }),
            ProviderKind::Anthropic => Self::Anthropic(anthropic::Client {
                http,
                base: p
                    .base_url
                    .clone()
                    .unwrap_or_else(|| "https://api.anthropic.com".into()),
                model: p.model.clone(),
                key: key.ok_or_else(|| anyhow::anyhow!("ANTHROPIC_API_KEY not set"))?,
                extra,
            }),
            ProviderKind::Ollama => Self::Ollama(ollama::Client {
                http,
                base: p.base_url.clone().unwrap_or_else(|| {
                    std::env::var("OLLAMA_HOST")
                        .map(|h| {
                            if h.starts_with("http") {
                                h
                            } else {
                                format!("http://{h}")
                            }
                        })
                        .unwrap_or_else(|_| "http://localhost:11434".into())
                }),
                model: p.model.clone(),
                num_ctx: p.context_window(),
                extra,
            }),
        })
    }

    pub async fn complete(
        &self,
        req: &Request<'_>,
        on: &mut (dyn FnMut(StreamEvent) + Send),
    ) -> Result<Response> {
        match self {
            Self::OpenAi(c) => c.complete(req, on).await,
            Self::Anthropic(c) => c.complete(req, on).await,
            Self::Ollama(c) => c.complete(req, on).await,
            #[cfg(test)]
            Self::Scripted(c) => c.complete(on),
        }
    }
}

pub fn new_id() -> String {
    static N: AtomicU64 = AtomicU64::new(0);
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("call_{t:x}{}", N.fetch_add(1, Ordering::Relaxed))
}

/// Tool arguments from a model can be garbage; keep it so the tool can report back.
pub fn parse_args(s: &str) -> Value {
    if s.trim().is_empty() {
        return json!({});
    }
    serde_json::from_str(s).unwrap_or_else(|_| json!({ "_invalid_json": s }))
}

pub fn assistant_message(
    thinking: String,
    signature: Option<String>,
    text: String,
    calls: Vec<(String, String, Value)>,
) -> Message {
    let mut content = Vec::new();
    if !thinking.is_empty() {
        content.push(Block::Thinking {
            text: thinking,
            signature,
        });
    }
    if !text.is_empty() {
        content.push(Block::Text { text });
    }
    for (id, name, input) in calls {
        let id = if id.is_empty() { new_id() } else { id };
        content.push(Block::ToolUse { id, name, input });
    }
    Message {
        role: crate::message::Role::Assistant,
        content,
    }
}

pub fn deep_merge(a: &mut Value, b: &Value) {
    match (a, b) {
        (Value::Object(a), Value::Object(b)) => {
            for (k, v) in b {
                deep_merge(a.entry(k.clone()).or_insert(Value::Null), v);
            }
        }
        (a, b) => *a = b.clone(),
    }
}
