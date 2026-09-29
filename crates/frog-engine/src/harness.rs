//! Fitting the harness to the model.
//!
//! The same model's results swing 40–139x in tokens and up to 30 points in score across
//! harnesses (arXiv 2607.22585, 2608.08654, 2609.17394), so frog measures what each model can
//! actually do (a few small probe requests, cached per model) and picks the tool-call mode and
//! prompt guidance to match.

use crate::config::{Profile, ProviderKind, ToolMode, data_dir};
use crate::message::Message;
use crate::prompt::{self, Action};
use crate::provider::{Provider, Request, Response, ToolSpec};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Tier {
    Strong,
    Medium,
    Weak,
}

/// What a model demonstrably does, from [`probe`].
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Caps {
    /// Calls a tool correctly through the API's native tool calling.
    pub native_tools: bool,
    /// Writes a parseable `<tool_call>` block when tools are described in the prompt.
    pub text_tools: bool,
    /// The server enforces a JSON schema and the model fills it with a correct call.
    pub json_mode: bool,
    /// Answers directly when no tool is needed, instead of calling one anyway.
    pub abstains: bool,
    /// Emits reasoning ("thinking") before answering. Constraining these models to a JSON
    /// schema suppresses the reasoning and hurt them in the bench (qwen3:4b: native 5/6, json 2/6).
    #[serde(default)]
    pub thinks: bool,
    /// A thinking model that answers directly when asked not to think (hybrid Qwen3 does;
    /// reasoning-only models like Qwen3-2507-Thinking reason anyway, into the answer). `None`
    /// until probed.
    #[serde(default)]
    pub think_off: Option<bool>,
    /// Parameter count in billions, when the server says.
    pub params_b: Option<f64>,
    /// Unix milliseconds.
    pub probed: i64,
}

fn cache_path() -> PathBuf {
    data_dir().join("models.json")
}

/// Cache key: provider, endpoint, and model.
pub fn key(p: &Profile) -> String {
    format!(
        "{:?}|{}|{}",
        p.provider,
        p.base_url.as_deref().unwrap_or(""),
        p.model
    )
    .to_lowercase()
}

fn read_cache() -> BTreeMap<String, Caps> {
    std::fs::read(cache_path())
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

pub fn cached(p: &Profile) -> Option<Caps> {
    read_cache().remove(&key(p))
}

pub fn save(p: &Profile, caps: &Caps) {
    let mut all = read_cache();
    all.insert(key(p), caps.clone());
    let _ = std::fs::create_dir_all(data_dir());
    if let Ok(bytes) = serde_json::to_vec_pretty(&all) {
        let tmp = cache_path().with_extension("json.tmp");
        if std::fs::write(&tmp, bytes).is_ok() {
            let _ = std::fs::rename(tmp, cache_path());
        }
    }
}

/// A model that runs in someone's data center: a hosted API, or one reached through a cloud
/// gateway (OpenRouter, Vercel AI Gateway). Its window and output limits are the API's, and its
/// energy can only be estimated. A server of your own isn't one: its window is real.
pub fn is_cloud(p: &Profile) -> bool {
    let url = p.base_url.as_deref().map(|u| u.trim_end_matches('/'));
    is_hosted(p)
        || crate::providers::PRESETS
            .iter()
            .any(|pre| !pre.local && url == Some(pre.base_url.trim_end_matches('/')))
}

/// Hosted frontier APIs don't need probing.
pub fn is_hosted(p: &Profile) -> bool {
    p.provider == ProviderKind::Anthropic
        || (p.provider == ProviderKind::Openai && p.base_url.is_none())
}

pub fn tier(p: &Profile, caps: Option<&Caps>) -> Tier {
    if is_hosted(p) {
        return Tier::Strong;
    }
    let Some(c) = caps else { return Tier::Medium };
    match c.params_b {
        Some(b) if b >= 30.0 && c.native_tools => Tier::Strong,
        // Small reasoning models that handle native tools punch above their size
        // (qwen3:4b: 5/6 in the bench).
        Some(b) if b >= 10.0 || (c.thinks && c.native_tools) => Tier::Medium,
        Some(_) => Tier::Weak,
        None if c.native_tools && c.abstains => Tier::Medium,
        None => Tier::Weak,
    }
}

/// Resolve `auto` into a concrete mode. An explicit mode in the profile always wins.
pub fn choose_mode(p: &Profile, caps: Option<&Caps>, tier: Tier) -> ToolMode {
    if p.tool_mode != ToolMode::Auto {
        return p.tool_mode;
    }
    let Some(c) = caps else {
        return ToolMode::Native;
    };
    // Grammar-constrained output helps small models most (arXiv 2609.23742), but not ones
    // that reason first.
    if tier == Tier::Weak && c.json_mode && !c.thinks {
        return ToolMode::Json;
    }
    if c.native_tools {
        ToolMode::Native
    } else if c.text_tools {
        ToolMode::Text
    } else if c.json_mode {
        ToolMode::Json
    } else {
        // Nothing passed. Text mode can't be rejected by the server (native tools can: ollama
        // 400s for models without tool support), and at worst the model just answers.
        ToolMode::Text
    }
}

/// Extra system-prompt guidance by tier. Planning helps weaker models (arXiv 2609.20804).
pub fn guidance(tier: Tier) -> &'static str {
    match tier {
        Tier::Strong => "",
        Tier::Medium => {
            "\n# Working style\n- For anything beyond a one-step change, write a short plan with TodoWrite first.\n"
        }
        Tier::Weak => {
            "\n# Working style\n\
- Work in small steps: make one tool call, look at the result, then decide the next step.\n\
- Before changing code, write a short plan with TodoWrite.\n\
- Read a file right before editing it. Copy old_string exactly from the Read output, without the line-number prefix.\n\
- If a tool call fails, read the error and fix the call. Don't repeat an identical call.\n"
        }
    }
}

const PROBE_SYSTEM: &str = "You are a coding assistant. Use tools when the task needs them.";
const PROBE_READ: &str = "Read the file probe.txt with the Read tool.";
const PROBE_MATH: &str = "What is 17 + 25? Reply with just the number. Do not use any tools.";

fn reads_probe(name: &str, args: &serde_json::Value) -> bool {
    name == "Read"
        && args["file_path"]
            .as_str()
            .is_some_and(|p| p.contains("probe.txt"))
}

async fn ask(
    provider: &Provider,
    system: &str,
    user: &str,
    tools: &[ToolSpec],
    format: Option<&Value>,
) -> anyhow::Result<Response> {
    let msgs = vec![Message::user(user)];
    let req = Request {
        system,
        messages: &msgs,
        tools,
        max_tokens: Some(2048),
        format,
        think: None,
        think_budget: None,
    };
    let mut ignore = |_| {};
    let call = provider.complete(&req, &mut ignore);
    tokio::time::timeout(Duration::from_secs(120), call)
        .await
        .map_err(|_| anyhow::anyhow!("probe request timed out"))?
}

/// Run the capability probes. The first (plain text, no tools) doubles as a reachability check:
/// if it fails, the model can't be profiled and nothing should be cached. After that, an error
/// just means the feature isn't supported (e.g. a 400 for `tools` or `format`).
pub async fn probe(provider: &Provider, specs: &[ToolSpec]) -> anyhow::Result<Caps> {
    let text_system = format!("{PROBE_SYSTEM}{}", prompt::text_tools_prompt(specs));
    let r = ask(provider, &text_system, PROBE_READ, &[], None).await?;
    let text_tools = prompt::extract_tool_calls(&r.message.text())
        .is_some_and(|(_, calls)| calls.iter().any(|(n, a)| reads_probe(n, a)));

    let native = ask(provider, PROBE_SYSTEM, PROBE_READ, specs, None)
        .await
        .ok();
    let native_tools = native.as_ref().is_some_and(|r| {
        r.message
            .tool_uses()
            .iter()
            .any(|(_, n, a)| reads_probe(n, a))
    });
    let thinks = [&r, native.as_ref().unwrap_or(&r)].iter().any(|resp| {
        resp.message
            .content
            .iter()
            .any(|b| matches!(b, crate::message::Block::Thinking { text, .. } if !text.trim().is_empty()))
    });

    let abstains = ask(provider, PROBE_SYSTEM, PROBE_MATH, specs, None)
        .await
        .is_ok_and(|r| r.message.tool_uses().is_empty() && r.message.text().contains("42"));

    let json_system = format!("{PROBE_SYSTEM}{}", prompt::json_tools_prompt(specs));
    let schema = prompt::json_schema(specs);
    let json_mode = ask(provider, &json_system, PROBE_READ, &[], Some(&schema))
        .await
        .is_ok_and(|r| {
            matches!(prompt::parse_action(&r.message.text()),
                Some((_, Action::Tool { name, args })) if reads_probe(&name, &args))
        });

    let think_off = if thinks {
        Some(probe_think_off(provider).await)
    } else {
        None
    };

    Ok(Caps {
        native_tools,
        text_tools,
        json_mode,
        abstains,
        thinks,
        think_off,
        params_b: provider.params_b().await,
        probed: chrono::Utc::now().timestamp_millis(),
    })
}

/// Whether the model honors "don't think": asked a one-number question with thinking off, a
/// model that can switch answers in a few tokens with no reasoning. One that can't reasons
/// anyway (ollama then puts it in the answer), or the server rejects the switch.
pub async fn probe_think_off(provider: &Provider) -> bool {
    let msgs = vec![Message::user(PROBE_MATH)];
    let req = Request {
        system: PROBE_SYSTEM,
        messages: &msgs,
        tools: &[],
        max_tokens: Some(256),
        format: None,
        think: Some(false),
        think_budget: None,
    };
    let mut ignore = |_| {};
    let call = provider.complete(&req, &mut ignore);
    let Ok(Ok(r)) = tokio::time::timeout(Duration::from_secs(60), call).await else {
        return false;
    };
    answered_directly(&r)
}

fn answered_directly(r: &Response) -> bool {
    let reasoned = r.message.content.iter().any(
        |b| matches!(b, crate::message::Block::Thinking { text, .. } if !text.trim().is_empty()),
    );
    let text = r.message.text();
    !reasoned && text.contains("42") && text.trim().len() <= 40
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gateways_are_cloud_and_your_own_servers_are_not() {
        let cfg = crate::config::Config::default();
        let cloud = |spec: &str| is_cloud(&cfg.resolve(Some(spec)).unwrap().1);
        assert!(cloud("anthropic/claude-sonnet-5"));
        assert!(cloud("vercel/anthropic/claude-opus-5.5-fast"));
        assert!(cloud("openrouter/qwen/qwen3-coder"));
        assert!(!cloud("ollama/qwen3:4b"));
        assert!(!cloud("lmstudio/qwen3-coder-30b"));
        assert!(!cloud("tang/mlx-community/Qwen3-4B-4bit"));
        let mut mine = Profile::new(ProviderKind::Openai, "qwen3");
        mine.base_url = Some("http://mew.local:8000/v1".into());
        assert!(!is_cloud(&mine));
    }

    fn local(model: &str) -> Profile {
        Profile::new(ProviderKind::Ollama, model)
    }

    fn caps(native: bool, json: bool, params: Option<f64>) -> Caps {
        Caps {
            native_tools: native,
            text_tools: true,
            json_mode: json,
            abstains: true,
            thinks: false,
            think_off: None,
            params_b: params,
            probed: 0,
        }
    }

    #[test]
    fn small_models_with_grammar_get_json_mode() {
        let p = local("qwen2.5:3b");
        let c = caps(true, true, Some(3.1));
        let t = tier(&p, Some(&c));
        assert_eq!(t, Tier::Weak);
        assert_eq!(choose_mode(&p, Some(&c), t), ToolMode::Json);
    }

    #[test]
    fn big_models_with_working_tools_stay_native() {
        let p = local("qwen3-coder:30b");
        let c = caps(true, true, Some(30.5));
        let t = tier(&p, Some(&c));
        assert_eq!(t, Tier::Strong);
        assert_eq!(choose_mode(&p, Some(&c), t), ToolMode::Native);
    }

    #[test]
    fn thinking_models_are_not_forced_into_json() {
        let p = local("qwen3:4b");
        let mut c = caps(true, true, Some(4.0));
        c.thinks = true;
        assert_eq!(
            choose_mode(&p, Some(&c), tier(&p, Some(&c))),
            ToolMode::Native
        );
    }

    #[test]
    fn broken_native_tools_fall_back_to_text() {
        let p = local("some-model");
        let c = caps(false, false, Some(14.0));
        assert_eq!(choose_mode(&p, Some(&c), Tier::Medium), ToolMode::Text);
    }

    #[test]
    fn explicit_mode_wins() {
        let mut p = local("qwen2.5:3b");
        p.tool_mode = ToolMode::Native;
        assert_eq!(
            choose_mode(&p, Some(&caps(true, true, Some(3.0))), Tier::Weak),
            ToolMode::Native
        );
    }

    #[test]
    fn think_off_means_a_short_direct_answer() {
        use crate::message::Block;
        use crate::provider::Stop;
        let reply = |content: Vec<Block>| Response {
            message: Message {
                role: crate::message::Role::Assistant,
                content,
            },
            usage: Default::default(),
            stop: Stop::End,
        };
        let text = |t: &str| Block::Text { text: t.into() };
        assert!(answered_directly(&reply(vec![text("42")])));
        // Reasoning-only models keep reasoning: in a thinking block, or in the answer.
        assert!(!answered_directly(&reply(vec![
            Block::Thinking {
                text: "17 plus 25…".into(),
                signature: None,
            },
            text("42"),
        ])));
        assert!(!answered_directly(&reply(vec![text(
            "Okay, the user wants 17 + 25. Let me add: 10 + 20 is 30, 7 + 5 is 12, so 42."
        )])));
    }

    #[test]
    fn hosted_models_are_strong_without_probing() {
        let p = Profile::new(ProviderKind::Anthropic, "claude-sonnet-5");
        assert_eq!(tier(&p, None), Tier::Strong);
    }
}
