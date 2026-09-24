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

#[derive(Clone, Debug)]
pub struct ToolSpec {
    /// Owned so tools discovered at runtime (MCP servers) fit alongside the built-ins.
    pub name: std::borrow::Cow<'static, str>,
    pub description: std::borrow::Cow<'static, str>,
    pub schema: Value,
}

pub struct Request<'a> {
    pub system: &'a str,
    pub messages: &'a [Message],
    pub tools: &'a [ToolSpec],
    pub max_tokens: Option<u32>,
    /// JSON schema the whole response must match (grammar-constrained decoding).
    pub format: Option<&'a Value>,
    /// Turn the model's reasoning on or off for this call; `None` leaves its default. Sent as
    /// ollama's `think` and as `chat_template_kwargs.enable_thinking` to OpenAI-compatible
    /// servers (tang-llm, vLLM, llama.cpp, SGLang), never to OpenAI's own API. A profile's
    /// `extra` still wins.
    pub think: Option<bool>,
    /// Most reasoning tokens before the server closes the thinking block and makes the model
    /// answer. Sent as `thinking_budget` to OpenAI-compatible servers other than OpenAI's own;
    /// only set for servers that list the `thinking_budget` capability (tang-llm).
    pub think_budget: Option<u32>,
}

pub enum StreamEvent {
    Text(String),
    Thinking(String),
    /// A tool call started streaming (its arguments may take a while).
    ToolCall(String),
}

#[derive(Clone)]
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

    /// Whether the model takes images: ollama says so, Anthropic's always do, and OpenAI's own
    /// API models do. Unknown (`None`) for other OpenAI-compatible servers.
    pub async fn supports_vision(&self) -> Option<bool> {
        match self {
            Self::Ollama(c) => tokio::time::timeout(Duration::from_secs(3), c.supports_vision())
                .await
                .ok()
                .flatten(),
            Self::Anthropic(_) => Some(true),
            Self::OpenAi(c) if c.is_openai() => Some(true),
            Self::OpenAi(c) => tokio::time::timeout(Duration::from_secs(3), c.capabilities())
                .await
                .ok()
                .flatten()
                .map(|caps| caps.iter().any(|c| c == "vision")),
            #[cfg(test)]
            Self::Scripted(_) => None,
        }
    }

    /// Whether the server caps reasoning per request (tang-llm lists `thinking_budget` among
    /// the model's capabilities). Bounded by a short timeout.
    pub async fn supports_thinking_budget(&self) -> bool {
        match self {
            Self::OpenAi(c) if !c.is_openai() => {
                tokio::time::timeout(Duration::from_secs(3), c.capabilities())
                    .await
                    .ok()
                    .flatten()
                    .is_some_and(|caps| caps.iter().any(|c| c == "thinking_budget"))
            }
            _ => false,
        }
    }

    /// The context window the server reports, if it does. Bounded by a short timeout.
    pub async fn probe_context(&self) -> Option<u64> {
        let probe = async {
            match self {
                Self::Ollama(c) => c.probe_context().await,
                Self::OpenAi(c) => c.probe_context().await,
                _ => None,
            }
        };
        tokio::time::timeout(Duration::from_secs(3), probe)
            .await
            .ok()
            .flatten()
    }

    /// Model size in billions of parameters, if the server reports it (ollama only).
    pub async fn params_b(&self) -> Option<f64> {
        match self {
            Self::Ollama(c) => c.params_b().await,
            _ => None,
        }
    }

    /// Ollama allocates the window per request (`num_ctx`), so it has to be told.
    pub fn set_context_window(&mut self, n: u64) {
        if let Self::Ollama(c) = self {
            c.num_ctx = n;
        }
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
