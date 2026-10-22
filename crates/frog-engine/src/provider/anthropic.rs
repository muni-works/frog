//! Anthropic Messages API with streaming and prompt caching.

use super::{Request, Response, Stop, StreamError, StreamEvent, deep_merge, parse_args, sse};
use crate::config::{AnthropicThinking, Profile, Thinking};
use crate::message::{Block, Message, Role, Usage};
use anyhow::{Result, bail};
use serde_json::{Value, json};

pub struct Client {
    pub http: reqwest::Client,
    pub base: String,
    pub model: String,
    pub key: String,
    pub extra: Option<Value>,
    pub settings: Settings,
}

/// Per-profile request options (see the matching `Profile` fields).
#[derive(Clone, Debug, Default)]
pub struct Settings {
    pub thinking: Option<AnthropicThinking>,
    pub budget: Option<u32>,
    pub display: Option<String>,
    pub effort: Option<String>,
    pub cache_ttl: Option<String>,
    /// The profile asked for `thinking = "never"`: honoured only where the API allows
    /// thinking off. Frog's per-call `auto` switch is deliberately not forwarded: changing
    /// `thinking` between calls invalidates the cached conversation.
    pub never: bool,
    /// Reached through a gateway: no 1h cache TTL unless the profile asks for it.
    pub gateway: bool,
}

impl Settings {
    pub fn from_profile(p: &Profile, gateway: bool) -> Self {
        Self {
            thinking: p.anthropic_thinking,
            budget: p.anthropic_budget,
            display: p.thinking_display.clone(),
            effort: p.effort.clone(),
            cache_ttl: p.cache_ttl.clone(),
            never: p.thinking == Some(Thinking::Never),
            gateway,
        }
    }
}

/// `anthropic/claude-opus-5.5` and `claude-opus-5-5` both become `claude-opus-5-5`.
fn norm(model: &str) -> String {
    model
        .rsplit('/')
        .next()
        .unwrap_or(model)
        .to_ascii_lowercase()
        .replace('.', "-")
}

fn is(m: &str, prefixes: &[&str]) -> bool {
    prefixes.iter().any(|p| m.starts_with(p))
}

/// Takes `thinking: {type: "adaptive"}` (Opus 4.6+, Sonnet 4.6+, the 5 family).
fn adaptive(m: &str) -> bool {
    is(
        m,
        &[
            "claude-opus-4-6",
            "claude-opus-4-7",
            "claude-opus-4-8",
            "claude-opus-5",
            "claude-sonnet-4-6",
            "claude-sonnet-5",
            "claude-haiku-5",
            "claude-fable",
            "claude-mythos",
        ],
    )
}

/// Rejects `thinking.budget_tokens` and sampling parameters with a 400.
fn adaptive_only(m: &str) -> bool {
    adaptive(m) && !is(m, &["claude-opus-4-6", "claude-sonnet-4-6"])
}

/// Where leaving `thinking` out turns it off (elsewhere it runs adaptive or is required).
fn omit_is_off(m: &str) -> bool {
    is(
        m,
        &[
            "claude-opus-4-6",
            "claude-opus-4-7",
            "claude-opus-4-8",
            "claude-sonnet-4-6",
        ],
    )
}

fn takes_effort(m: &str) -> bool {
    adaptive(m) || m.starts_with("claude-opus-4-5")
}

/// Context window and max output tokens of a Claude model, from Anthropic's models overview
/// (platform.claude.com/docs/en/about-claude/models/overview). `None` for other models.
pub fn known_limits(model: &str) -> Option<(u64, u32)> {
    let m = norm(model);
    if adaptive(&m) {
        return Some((1_000_000, 128_000));
    }
    if is(
        &m,
        &["claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-4-5"],
    ) {
        return Some((200_000, 64_000));
    }
    m.starts_with("claude-").then_some((200_000, 32_000))
}

/// `max_tokens` when the caller sets none: room for thinking plus a long answer, without
/// claiming a model's whole 128k output cap.
fn default_max_tokens(model: &str) -> u32 {
    known_limits(model).map_or(32_000, |(_, out)| out.min(64_000))
}

fn cache_control(ttl: Option<&str>) -> Value {
    match ttl {
        Some("1h") => json!({ "type": "ephemeral", "ttl": "1h" }),
        _ => json!({ "type": "ephemeral" }),
    }
}

/// Mark the last block of `msg` that can carry a breakpoint (thinking blocks can't).
fn mark(msg: &mut Value, cc: Value) {
    let Some(blocks) = msg["content"].as_array_mut() else {
        return;
    };
    if let Some(b) = blocks
        .iter_mut()
        .rev()
        .find(|b| !matches!(b["type"].as_str(), Some("thinking" | "redacted_thinking")))
    {
        b["cache_control"] = cc;
    }
}

fn block_json(b: &Block) -> Option<Value> {
    Some(match b {
        Block::Text { text } if text.trim().is_empty() => return None,
        Block::Text { text } => json!({ "type": "text", "text": text }),
        // Thinking from other providers has no signature and can't be replayed.
        Block::Thinking {
            text,
            signature: Some(sig),
        } if !sig.is_empty() => json!({ "type": "thinking", "thinking": text, "signature": sig }),
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
        Block::Image { mime, data } => {
            json!({ "type": "image", "source": { "type": "base64", "media_type": mime, "data": data } })
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
        // Breakpoints (the API allows 4): tools and system (stable, longest TTL first), the
        // last message (moving), and the message before the previous reply, which is where
        // the previous request put its moving one, so a long tool loop never falls outside
        // the 20-block lookback.
        let s = &self.settings;
        let stable_ttl = s.cache_ttl.as_deref().or((!s.gateway).then_some("1h"));
        let moving_ttl = s.cache_ttl.as_deref();
        let n = messages.len();
        if n >= 3 {
            mark(&mut messages[n - 3], cache_control(moving_ttl));
        }
        if let Some(last) = messages.last_mut() {
            mark(last, cache_control(moving_ttl));
        }
        let mut tools: Vec<Value> = req
            .tools
            .iter()
            .map(|t| json!({ "name": t.name, "description": t.description, "input_schema": t.schema }))
            .collect();
        if let Some(t) = tools.last_mut() {
            t["cache_control"] = cache_control(stable_ttl);
        }
        let max_tokens = req
            .max_tokens
            .unwrap_or_else(|| default_max_tokens(&self.model));
        let mut body = json!({
            "model": self.model,
            "max_tokens": max_tokens,
            "messages": messages,
            "stream": true,
        });
        if !req.system.trim().is_empty() {
            body["system"] = json!([{ "type": "text", "text": req.system, "cache_control": cache_control(stable_ttl) }]);
        }
        let (thinking, effort) = self.reasoning(max_tokens);
        if let Some(t) = thinking {
            body["thinking"] = t;
        }
        if let Some(e) = effort {
            body["output_config"] = json!({ "effort": e });
        }
        if !tools.is_empty() {
            body["tools"] = json!(tools);
        }
        if let Some(extra) = &self.extra {
            deep_merge(&mut body, extra);
        }
        body
    }

    /// The `thinking` parameter and `output_config.effort` for this model and profile.
    fn reasoning(&self, max_tokens: u32) -> (Option<Value>, Option<String>) {
        let s = &self.settings;
        let m = norm(&self.model);
        let mode = s.thinking.or_else(|| {
            (m.starts_with("claude-opus-") && adaptive(&m)).then_some(AnthropicThinking::Adaptive)
        });
        // Where the API lets thinking be off, `thinking = "never"` turns it off.
        let off = mode == Some(AnthropicThinking::Off)
            || (s.never && s.thinking.is_none() && omit_is_off(&m));
        let Some(mode) = mode.filter(|_| !off) else {
            return (None, None);
        };
        let thinking = match mode {
            AnthropicThinking::Enabled if !adaptive_only(&m) => {
                let budget = s.budget.unwrap_or(16_000).max(1024);
                json!({ "type": "enabled", "budget_tokens": budget.min(max_tokens.saturating_sub(1)) })
            }
            _ if adaptive(&m) => json!({
                "type": "adaptive",
                "display": s.display.as_deref().unwrap_or("summarized"),
            }),
            // An older model asked for adaptive: nothing it understands.
            _ => return (None, None),
        };
        let effort = takes_effort(&m)
            .then(|| {
                s.effort
                    .clone()
                    .or_else(|| m.starts_with("claude-opus-").then(|| "high".into()))
            })
            .flatten();
        (Some(thinking), effort)
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
                        (Some(Partial::Tool(_, name, args)), "input_json_delta") => {
                            let chunk = s("partial_json");
                            args.push_str(&chunk);
                            on(StreamEvent::ToolArgs {
                                name: name.clone(),
                                chunk,
                            });
                        }
                        _ => {}
                    }
                }
                "content_block_stop" => {
                    if let Some(Partial::Tool(_, name, args)) = parts.last() {
                        let index = parts
                            .iter()
                            .filter(|p| matches!(p, Partial::Tool(..)))
                            .count()
                            - 1;
                        on(StreamEvent::ToolReady {
                            index,
                            name: name.clone(),
                            input: parse_args(args),
                        });
                    }
                }
                "message_delta" => {
                    if let Some(r) = v["delta"]["stop_reason"].as_str() {
                        stop = Some(Stop::from_reason(r));
                    }
                    let u = &v["usage"];
                    usage.output = u["output_tokens"].as_u64().unwrap_or(usage.output);
                    // Some gateways (Vercel) report input and cache counts only here.
                    if let Some(i) = u["input_tokens"].as_u64().filter(|&i| i > 0) {
                        usage.input = i + u["cache_creation_input_tokens"].as_u64().unwrap_or(0);
                    }
                    if let Some(c) = u["cache_read_input_tokens"].as_u64().filter(|&c| c > 0) {
                        usage.cache_read = c;
                    }
                }
                "error" => bail!(StreamError {
                    message: v["error"].to_string()
                }),
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
                    signature: Some(sig).filter(|s| !s.is_empty()),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn client(model: &str, settings: Settings) -> Client {
        Client {
            http: reqwest::Client::new(),
            base: "http://localhost:1".into(),
            model: model.into(),
            key: "k".into(),
            extra: None,
            settings,
        }
    }

    fn msg(role: Role, content: Vec<Block>) -> Message {
        Message { role, content }
    }

    fn text(role: Role, t: &str) -> Message {
        msg(role, vec![Block::Text { text: t.into() }])
    }

    fn body(c: &Client, messages: &[Message]) -> Value {
        let tools = [super::super::ToolSpec {
            name: "Bash".into(),
            description: "run".into(),
            schema: json!({ "type": "object" }),
        }];
        c.body(&Request {
            system: "sys",
            messages,
            tools: &tools,
            max_tokens: None,
            format: None,
            think: Some(false),
            think_budget: None,
            cache_key: None,
        })
    }

    fn convo() -> Vec<Message> {
        vec![
            text(Role::User, "a"),
            text(Role::Assistant, "b"),
            text(Role::User, "c"),
            text(Role::Assistant, "d"),
            text(Role::User, "e"),
        ]
    }

    fn count_breakpoints(v: &Value) -> usize {
        match v {
            Value::Object(o) => {
                o.contains_key("cache_control") as usize
                    + o.values().map(count_breakpoints).sum::<usize>()
            }
            Value::Array(a) => a.iter().map(count_breakpoints).sum(),
            _ => 0,
        }
    }

    #[test]
    fn opus_thinks_adaptively_with_effort_by_default() {
        for model in [
            "claude-opus-5-5",
            "anthropic/claude-opus-5.5",
            "claude-opus-4-6",
        ] {
            let b = body(&client(model, Settings::default()), &convo());
            assert_eq!(b["thinking"]["type"], "adaptive", "{model}");
            assert_eq!(b["thinking"]["display"], "summarized");
            assert_eq!(b["output_config"]["effort"], "high");
            assert!(b["thinking"].get("budget_tokens").is_none());
        }
        // Not opus, or too old for adaptive: nothing is added.
        for model in ["claude-sonnet-5-5", "claude-opus-4-5", "claude-haiku-4-5"] {
            let b = body(&client(model, Settings::default()), &convo());
            assert!(b.get("thinking").is_none(), "{model}");
            assert!(b.get("output_config").is_none(), "{model}");
        }
    }

    #[test]
    fn profile_controls_thinking_and_effort() {
        let s = Settings {
            effort: Some("xhigh".into()),
            display: Some("omitted".into()),
            ..Default::default()
        };
        let b = body(&client("claude-opus-5-5", s), &convo());
        assert_eq!(b["output_config"]["effort"], "xhigh");
        assert_eq!(b["thinking"]["display"], "omitted");

        // budget_tokens is a 400 on Opus 5.5, so "enabled" becomes adaptive there...
        let s = Settings {
            thinking: Some(AnthropicThinking::Enabled),
            budget: Some(8000),
            ..Default::default()
        };
        let b = body(&client("claude-opus-5-5", s.clone()), &convo());
        assert_eq!(b["thinking"]["type"], "adaptive");
        // ...and a real budget on a model that takes one.
        let b = body(&client("claude-sonnet-4-5", s), &convo());
        assert_eq!(b["thinking"]["type"], "enabled");
        assert_eq!(b["thinking"]["budget_tokens"], 8000);
        assert!(b.get("output_config").is_none());

        let off = Settings {
            thinking: Some(AnthropicThinking::Off),
            ..Default::default()
        };
        let b = body(&client("claude-opus-5-5", off), &convo());
        assert!(b.get("thinking").is_none() && b.get("output_config").is_none());
    }

    #[test]
    fn thinking_never_only_where_the_api_allows_off() {
        let never = Settings {
            never: true,
            ..Default::default()
        };
        // Opus 5.5 can't switch thinking off, so `never` and the per-call switch are ignored.
        let b = body(&client("claude-opus-5-5", never.clone()), &convo());
        assert_eq!(b["thinking"]["type"], "adaptive");
        let b = body(&client("claude-opus-4-8", never), &convo());
        assert!(b.get("thinking").is_none());
    }

    #[test]
    fn extra_still_wins() {
        let mut c = client("claude-opus-5-5", Settings::default());
        c.extra = Some(json!({ "output_config": { "effort": "max" } }));
        assert_eq!(body(&c, &convo())["output_config"]["effort"], "max");
    }

    #[test]
    fn cache_breakpoints_stable_then_moving_within_the_limit() {
        let b = body(&client("claude-opus-5-5", Settings::default()), &convo());
        assert_eq!(count_breakpoints(&b), 4);
        let one_hour = json!({ "type": "ephemeral", "ttl": "1h" });
        let five_min = json!({ "type": "ephemeral" });
        assert_eq!(b["tools"][0]["cache_control"], one_hour);
        assert_eq!(b["system"][0]["cache_control"], one_hour);
        // The last message and the one before the previous reply, never the in-between ones.
        let m = b["messages"].as_array().unwrap();
        for (i, want) in [(0, false), (1, false), (2, true), (3, false), (4, true)] {
            assert_eq!(
                m[i]["content"][0].get("cache_control").is_some(),
                want,
                "{i}"
            );
        }
        assert_eq!(m[4]["content"][0]["cache_control"], five_min);

        // A short conversation has just the last message.
        let b = body(
            &client("claude-opus-5-5", Settings::default()),
            &convo()[..1],
        );
        assert_eq!(count_breakpoints(&b), 3);
    }

    #[test]
    fn gateway_defaults_to_the_short_ttl_and_the_profile_can_choose() {
        let gw = Settings {
            gateway: true,
            ..Default::default()
        };
        let b = body(&client("anthropic/claude-opus-5.5", gw.clone()), &convo());
        assert!(b["system"][0]["cache_control"].get("ttl").is_none());
        let all = Settings {
            cache_ttl: Some("1h".into()),
            ..gw
        };
        let b = body(&client("anthropic/claude-opus-5.5", all), &convo());
        assert_eq!(b["messages"][4]["content"][0]["cache_control"]["ttl"], "1h");
    }

    #[test]
    fn breakpoints_skip_thinking_blocks_and_thinking_round_trips() {
        let history = vec![
            text(Role::User, "go"),
            msg(
                Role::Assistant,
                vec![
                    Block::Thinking {
                        text: "hm".into(),
                        signature: Some("sig".into()),
                    },
                    Block::ToolUse {
                        id: "t".into(),
                        name: "Bash".into(),
                        input: json!({}),
                    },
                ],
            ),
            msg(
                Role::User,
                vec![Block::ToolResult {
                    id: "t".into(),
                    name: "Bash".into(),
                    content: "ok".into(),
                    is_error: false,
                }],
            ),
        ];
        let b = body(&client("claude-opus-5-5", Settings::default()), &history);
        let a = &b["messages"][1]["content"];
        assert_eq!(a[0]["type"], "thinking");
        assert_eq!(a[0]["signature"], "sig");
        assert!(a[0].get("cache_control").is_none());
        // Foreign or unsigned thinking is dropped rather than rejected by the API.
        assert!(
            block_json(&Block::Thinking {
                text: "x".into(),
                signature: Some(String::new())
            })
            .is_none()
        );
    }

    #[test]
    fn limits_and_default_max_tokens_come_from_the_model_table() {
        assert_eq!(known_limits("claude-opus-5-5"), Some((1_000_000, 128_000)));
        assert_eq!(
            known_limits("anthropic/claude-opus-5.5"),
            Some((1_000_000, 128_000))
        );
        assert_eq!(known_limits("claude-haiku-4-5"), Some((200_000, 64_000)));
        assert_eq!(known_limits("qwen3-8b"), None);
        let b = body(&client("claude-opus-5-5", Settings::default()), &convo());
        assert_eq!(b["max_tokens"], 64_000);
        let b = body(&client("claude-opus-4-1", Settings::default()), &convo());
        assert_eq!(b["max_tokens"], 32_000);
        let p = Profile::new(
            crate::config::ProviderKind::Openai,
            "anthropic/claude-opus-5.5",
        );
        assert_eq!(p.context_window(), 1_000_000);
    }
}
