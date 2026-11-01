pub mod anthropic;
pub mod codex;
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
    /// The conversation this call continues, so the server keeps its prompt cached (sent as
    /// `prompt_cache_key`); only set for servers that take it.
    pub cache_key: Option<&'a str>,
}

/// Request fields a server takes beyond the standard API (see [`Provider::extensions`]).
#[derive(Debug, Clone, Copy, Default)]
pub struct Extensions {
    pub thinking_budget: bool,
    pub cache_key: bool,
    /// Prefills a request without answering ([`Provider::prefill`]).
    pub prefill: bool,
}

pub enum StreamEvent {
    Text(String),
    Thinking(String),
    /// A tool call started streaming (its arguments may take a while).
    ToolCall(String),
    /// A tool call's arguments are complete while the reply is still streaming: the `index`th
    /// call of this reply, with its input as the final response will have it, unless the reply
    /// goes wrong later. Lets the engine start read-only tools early.
    ToolReady {
        index: usize,
        name: String,
        input: Value,
    },
    /// More of a tool call's arguments (raw JSON text, in order), for previewing them while
    /// they stream. Providers that only see whole calls never send it.
    ToolArgs {
        name: String,
        chunk: String,
    },
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
    /// The edge's billing verdict for this refusal, when it said (its `x-frog-billing`
    /// response header). `None` from every other provider — then the body decides.
    pub billing: Option<Billing>,
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "HTTP {}: {}", self.status, self.body)
    }
}

impl std::error::Error for HttpError {}

impl HttpError {
    /// What a person would want to read: the provider's own `error.message` when its body is
    /// JSON (OpenAI's shape, which frog cloud uses), else the status alone.
    pub fn summary(&self) -> String {
        serde_json::from_str::<serde_json::Value>(&self.body)
            .ok()
            .and_then(|v| v["error"]["message"].as_str().map(str::to_string))
            .unwrap_or_else(|| format!("HTTP {}", self.status))
    }
}

/// The edge's billing verdict for a 402 (its `x-frog-billing` response header):
/// `credit: <micros>` = the wallet pays the next call at usage prices and the retry is
/// admitted; `allowance` = the refusal isn't admitted (nothing can pay).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Billing {
    /// The wallet pays for the next call at usage prices; `Some` is what's left when the
    /// edge said, `None` when it didn't (a bare `credit`, or the body's credit semantics).
    Credit { balance_micro: Option<u64> },
    /// Not admitted: the wallet is empty, or the edge wouldn't transition this refusal.
    Allowance,
}

impl Billing {
    /// From the edge's `x-frog-billing` header: `credit: 5000000` or a bare `credit`.
    pub fn from_header(v: &str) -> Option<Self> {
        let v = v.trim();
        let rest = v.strip_prefix("credit")?;
        Some(match rest.strip_prefix(':') {
            // `credit: 0` says the wallet is empty: not admitted.
            Some(n) if n.trim().parse::<u64>().is_ok_and(|b| b > 0) => {
                Self::Credit {
                    balance_micro: n.trim().parse().ok(),
                }
            }
            Some(_) => Self::Allowance,
            None => Self::Credit { balance_micro: None },
        })
    }

    /// The provider's error body decides when the header is missing (BYOK gateways, the edge
    /// before it ships the header). OpenAI's shape (`error.type` `insufficient_quota`): a
    /// refusal whose words say the session can keep going on credit is admitted; a bare
    /// limit is not.
    pub fn parse(body: &str) -> Option<Self> {
        let v = serde_json::from_str::<Value>(body).ok()?;
        let err = &v["error"];
        let ty = err["type"].as_str().unwrap_or_default();
        let code = err["code"]
            .as_i64()
            .or(err["code"].as_str().and_then(|c| c.parse().ok()));
        if !matches!(ty, "insufficient_quota") && code != Some(402) {
            return None;
        }
        let msg = err["message"].as_str().unwrap_or_default().to_lowercase();
        // "add credit to keep going at usage prices": the edge's own promise that the
        // wallet pays for the next call.
        (msg.contains("credit to keep going") || msg.contains("billing credit"))
            .then_some(Self::Credit { balance_micro: None })
    }
}

impl HttpError {
    /// A billing refusal (402, or a body the provider bills with): the transcript's typed
    /// billing path instead of a provider error dump.
    pub fn is_billing(&self) -> bool {
        self.status == 402 || self.billing.is_some()
    }

    /// Whether the next call was admitted at usage prices: the edge's header when it said,
    /// else the body's credit semantics.
    pub fn billing_admitted(&self) -> bool {
        match self.billing {
            Some(b) => matches!(b, Billing::Credit { .. }),
            None => Billing::parse(&self.body).is_some_and(|b| matches!(b, Billing::Credit { .. })),
        }
    }

    /// The remaining credit when the edge said, in millionths of a dollar.
    pub fn billing_balance(&self) -> Option<u64> {
        match self.billing {
            Some(Billing::Credit { balance_micro }) => balance_micro,
            _ => None,
        }
    }

    /// Which allowance this refusal names, from the provider's own words: the 5-hour window,
    /// the weekly one, or the wallet itself.
    pub fn billing_window(&self) -> &'static str {
        let msg = serde_json::from_str::<Value>(&self.body)
            .ok()
            .and_then(|v| v["error"]["message"].as_str().map(str::to_string))
            .unwrap_or_else(|| self.body.clone());
        let msg = msg.to_lowercase();
        if msg.contains("5-hour") || msg.contains("5 hour") {
            "5h"
        } else if msg.contains("week") {
            "weekly"
        } else {
            "credit"
        }
    }
}

/// An error event inside an otherwise-accepted (2xx) response stream: OpenAI-compatible
/// gateways and Anthropic send these mid-stream when their upstream stumbles — the stream
/// ends before the terminal chunk, the upstream is overloaded or timed out. The call may
/// already have streamed partial text, so the engine drops what it showed and retries.
#[derive(Debug)]
pub struct StreamError {
    pub message: String,
}

impl std::fmt::Display for StreamError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "server error mid-stream: {}", self.message)
    }
}

impl std::error::Error for StreamError {}

impl HttpError {
    /// A "your request exceeds the model's context window" rejection: OpenAI-style and
    /// Anthropic wording, and the variants Vercel's AI Gateway fans a gateway 400 out to.
    /// `true` for the same class of error reported by any of its providers.
    pub fn context_overflow(&self) -> bool {
        if !matches!(self.status, 400 | 413) {
            return false;
        }
        let b = self.body.to_lowercase();
        [
            "maximum context length",
            "context window",
            "context length",
            "input too long",
            "prompt is too long",
            "prompt too long",
            "exceeds the maximum allowed input length",
            "exceeds max length",
            "longer than the model's context",
            "longer than the context length",
            "reduce the length of the input",
            "reduce the length of the messages",
            "reduce the input",
            "too large for this model",
            "input_length_exceeded",
            "request too large",
        ]
        .iter()
        .any(|m| b.contains(m))
    }
}

pub enum Provider {
    OpenAi(openai::Client),
    Anthropic(anthropic::Client),
    Ollama(ollama::Client),
    Codex(codex::Client),
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
            ProviderKind::Codex => Self::Codex(codex::Client::new(
                std::env::current_dir()?,
                p.model.clone(),
            )),
            ProviderKind::Openai => Self::OpenAi(openai::Client {
                http,
                base: p
                    .base_url
                    .clone()
                    .unwrap_or_else(|| "https://api.openai.com/v1".into()),
                model: p.model.clone(),
                key,
                extra,
                anthropic: anthropic::Settings::from_profile(p, true),
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
                settings: anthropic::Settings::from_profile(p, false),
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

    pub fn with_cwd(mut self, cwd: &std::path::Path) -> Self {
        if let Self::Codex(c) = &mut self {
            c.cwd = cwd.to_path_buf();
        }
        self
    }

    /// The server's compiled-memory endpoints, for an OpenAI-compatible server that may
    /// have them (not OpenAI's own API).
    pub fn memory_remote(&self) -> Option<crate::compiled_memory::Remote> {
        match self {
            Self::OpenAi(c) if !c.is_openai() => Some(crate::compiled_memory::Remote::new(
                c.http.clone(),
                &c.base,
                c.key.clone(),
            )),
            _ => None,
        }
    }

    pub fn take_codex_items(&self) -> Vec<(String, String, serde_json::Value)> {
        match self {
            Self::Codex(c) => c.take_items(),
            _ => Vec::new(),
        }
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
            Self::Codex(_) => Some(false),
            Self::OpenAi(c) => tokio::time::timeout(Duration::from_secs(3), c.capabilities())
                .await
                .ok()
                .flatten()
                .map(|caps| caps.iter().any(|c| c == "vision")),
            #[cfg(test)]
            Self::Scripted(_) => None,
        }
    }

    /// Prefill `req` on servers that can ([`Extensions::prefill`]); the future owns what it
    /// needs, so it can run in the background.
    pub fn prefill(
        &self,
        req: &Request,
    ) -> Option<impl std::future::Future<Output = Result<()>> + Send + 'static> {
        match self {
            Self::OpenAi(c) => Some(c.prefill(req)),
            _ => None,
        }
    }

    /// What the server takes beyond the standard API: a per-request reasoning cap, and a
    /// conversation key for its KV cache. OpenAI keys its prompt cache by
    /// `prompt_cache_key`; tang-llm lists both among the model's capabilities. Bounded by a
    /// short timeout.
    pub async fn extensions(&self) -> Extensions {
        match self {
            Self::OpenAi(c) if c.is_openai() => Extensions {
                cache_key: true,
                ..Extensions::default()
            },
            Self::OpenAi(c) => {
                let caps = tokio::time::timeout(Duration::from_secs(3), c.capabilities())
                    .await
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                let has = |name: &str| caps.iter().any(|c| c == name);
                Extensions {
                    thinking_budget: has("thinking_budget"),
                    cache_key: c.is_frog_api() || has("prompt_cache_key"),
                    prefill: has("prefill"),
                }
            }
            _ => Extensions::default(),
        }
    }

    /// The context window the server reports, if it does. Bounded by a short timeout.
    /// frog cloud, at its own address or wherever FROG_BASE_URL points.
    pub fn is_frog_api(&self) -> bool {
        matches!(self, Self::OpenAi(c) if c.is_frog_api())
    }

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
            Self::Codex(c) => c.complete(req, on).await,
            #[cfg(test)]
            Self::Scripted(c) => c.complete(req, on).await,
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

#[cfg(test)]
mod http_error_tests {
    use super::{Billing, HttpError};

    #[test]
    fn summary_is_the_providers_own_message() {
        let e = HttpError {
            status: 429,
            body: r#"{"error":{"message":"bull is busy right now","type":"rate_limit_error"}}"#.into(),
            billing: None,
        };
        assert_eq!(e.summary(), "bull is busy right now");
        let plain = HttpError { status: 502, body: "<html>bad gateway</html>".into(), billing: None };
        assert_eq!(plain.summary(), "HTTP 502");
    }

    #[test]
    fn the_edge_header_decides_the_admit_and_the_balance() {
        let admitted = |v: &str| {
            HttpError {
                status: 402,
                body: "{}".into(),
                billing: Billing::from_header(v),
            }
        };
        let yes = admitted("credit: 4200000");
        assert!(yes.billing_admitted());
        assert_eq!(yes.billing_balance(), Some(4_200_000));
        assert_eq!(yes.billing_window(), "credit");
        // A bare `credit`: admitted, no balance to show.
        let bare = admitted("credit");
        assert!(bare.billing_admitted());
        assert_eq!(bare.billing_balance(), None);
        // `credit: 0`: the wallet is empty — the edge won't bill a refusal to nothing.
        let zero = admitted("credit: 0");
        assert!(!zero.billing_admitted());
        // A non-credit header (or none): the body decides.
        assert!(!admitted("allowance").billing_admitted());
        assert!(!HttpError { status: 402, body: "{}".into(), billing: None }.billing_admitted());
    }

    #[test]
    fn the_body_admits_when_it_says_credit_semantics() {
        let with = |body: &str| HttpError { status: 402, body: body.into(), billing: None };
        // frog cloud's 5-hour window: credit semantics, admitted.
        let five = with(
            r#"{"error":{"message":"5-hour plan limit reached; add credit to keep going at usage prices","type":"insufficient_quota","code":402}}"#,
        );
        assert!(five.billing_admitted());
        assert_eq!(five.billing_window(), "5h");
        assert_eq!(five.summary(), "5-hour plan limit reached; add credit to keep going at usage prices");
        // A bare wallet-empty refusal: not admitted, but still billing (typed, not a dump).
        let empty = with(r#"{"error":{"message":"Insufficient credits","type":"insufficient_credits"}}"#);
        assert!(!empty.billing_admitted());
        assert!(empty.is_billing());
        // A busy provider isn't billing, even with the same shape on another status.
        let busy = HttpError {
            status: 429,
            body: r#"{"error":{"message":"bull is busy"}}"#.into(),
            billing: None,
        };
        assert!(!busy.is_billing());
    }
}
