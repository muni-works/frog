use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ProviderKind {
    Openai,
    Anthropic,
    Ollama,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum ToolMode {
    /// Pick per model from its capability profile (see `harness.rs`).
    #[default]
    Auto,
    /// Use the API's native tool calling.
    Native,
    /// Describe tools in the system prompt and parse `<tool_call>` blocks from text.
    /// For models/servers with broken or missing native tool support.
    Text,
    /// Grammar-constrained JSON: every response is one tool call or an answer, enforced by
    /// the server (ollama `format`, OpenAI-compatible `response_format`). For small models.
    Json,
}

/// When a reasoning model thinks before answering (see `thinking.rs`).
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum Thinking {
    /// Think where it pays (planning, after errors, after reading); answer directly on routine
    /// follow-ups. Only for models that can switch thinking off.
    #[default]
    Auto,
    /// Leave the model's default (a reasoning model thinks on every call).
    Always,
    /// Ask the model not to think on any call.
    Never,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Profile {
    pub provider: ProviderKind,
    pub model: String,
    pub base_url: Option<String>,
    pub api_key: Option<String>,
    pub api_key_env: Option<String>,
    pub context_window: Option<u64>,
    pub max_tokens: Option<u32>,
    #[serde(default)]
    pub tool_mode: ToolMode,
    /// Merged into the request body verbatim (e.g. `think = true`, `temperature = 0.2`).
    pub extra: Option<Value>,
    /// Serve this model (a Hugging Face repo id or a directory) with the bundled tang-llm
    /// sidecar, started on demand. Implies an OpenAI-compatible provider on its port.
    #[serde(default)]
    pub sidecar: Option<String>,
    /// Whether the model takes images. Probed when unset (ollama reports it; Anthropic and
    /// OpenAI's own models do).
    #[serde(default)]
    pub vision: Option<bool>,
    /// Overrides the global `thinking` for this model.
    #[serde(default)]
    pub thinking: Option<Thinking>,
}

impl Profile {
    pub fn new(provider: ProviderKind, model: &str) -> Self {
        Self {
            provider,
            model: model.to_string(),
            base_url: None,
            api_key: None,
            api_key_env: None,
            context_window: None,
            max_tokens: None,
            tool_mode: ToolMode::Auto,
            extra: None,
            sidecar: None,
            vision: None,
            thinking: None,
        }
    }

    pub fn context_window(&self) -> u64 {
        self.context_window.unwrap_or(match self.provider {
            ProviderKind::Anthropic => 200_000,
            _ => 32_768,
        })
    }

    pub fn api_key(&self) -> Option<String> {
        if let Some(k) = &self.api_key {
            return Some(k.clone());
        }
        if let Some(var) = &self.api_key_env {
            return std::env::var(var).ok();
        }
        match self.provider {
            ProviderKind::Anthropic => std::env::var("ANTHROPIC_API_KEY").ok(),
            // Only send OPENAI_API_KEY to OpenAI itself, never to arbitrary base URLs.
            ProviderKind::Openai if self.base_url.is_none() => std::env::var("OPENAI_API_KEY").ok(),
            _ => None,
        }
    }
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Deserialize)]
pub struct Config {
    pub default_model: Option<String>,
    #[serde(default)]
    pub models: BTreeMap<String, Profile>,
    /// Extra bash command prefixes that run without asking (e.g. "cargo check").
    #[serde(default)]
    pub allow_bash: Vec<String>,
    #[serde(default = "default_true")]
    pub show_thinking: bool,
    /// When reasoning models think: "auto" (default), "always" or "never". A profile's
    /// `thinking` overrides it.
    #[serde(default)]
    pub thinking: Thinking,
    /// Also load ~/.claude/CLAUDE.md and CLAUDE.md files as instructions.
    #[serde(default = "default_true")]
    pub load_claude_md: bool,
    /// MCP servers (`[mcp_servers.<name>]`: `command`/`args`/`env`, or `url`/`headers`). A
    /// project's `.mcp.json` adds more.
    #[serde(default)]
    pub mcp_servers: BTreeMap<String, crate::mcp::ServerConfig>,
    /// Let the agent see and drive macOS apps (the bundled `kiln-desktop` MCP server).
    #[serde(default)]
    pub computer_use: bool,
    /// Run shell commands in a sandbox (writes only in the project, credentials hidden), so
    /// they run without asking. Set false to have every command ask instead.
    #[serde(default = "default_true")]
    pub sandbox_shell: bool,
    /// The model auto mode's classifier uses (a profile or provider/model). Default: Apple's
    /// on-device model when available, else the session's model.
    #[serde(default)]
    pub auto_classifier: Option<String>,
    /// The WebSearch backend: "searxng", "brave", "exa" or "tavily". Unset: a configured
    /// `searxng_url`, else a search key in the environment, else no WebSearch.
    #[serde(default)]
    pub web_search: Option<String>,
    /// Your SearXNG instance, e.g. `http://localhost:8888`.
    #[serde(default)]
    pub searxng_url: Option<String>,
    /// Let WebFetch reach localhost and private networks (off: public addresses only).
    #[serde(default)]
    pub web_allow_private: bool,
}

impl Default for Config {
    fn default() -> Self {
        toml::from_str("").expect("empty config parses")
    }
}

pub fn config_dir() -> PathBuf {
    dirs::home_dir().unwrap_or_default().join(".config/kiln")
}

pub fn data_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join(".local/share/kiln")
}

impl Config {
    pub fn load() -> Result<Self> {
        let path = config_dir().join("config.toml");
        if !path.exists() {
            return Ok(Self::default());
        }
        let text = std::fs::read_to_string(&path)?;
        toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))
    }

    /// Resolve a profile name or a `provider/model` spec.
    pub fn resolve(&self, spec: Option<&str>) -> Result<(String, Profile)> {
        let spec = spec
            .map(String::from)
            .or_else(|| std::env::var("KILN_MODEL").ok())
            .or_else(|| self.default_model.clone())
            .unwrap_or_else(|| "ollama/qwen3:4b".into());
        if let Some(p) = self.models.get(&spec) {
            return Ok((spec, p.clone()));
        }
        let (prov, model) = spec.split_once('/').ok_or_else(|| {
            anyhow!("unknown model `{spec}`: use a profile from config.toml or provider/model (ollama/, tang/, apple/, openai/, lmstudio/, llamacpp/, anthropic/)")
        })?;
        let mut p = match prov {
            "ollama" => Profile::new(ProviderKind::Ollama, model),
            "openai" => Profile::new(ProviderKind::Openai, model),
            "anthropic" | "claude" => Profile::new(ProviderKind::Anthropic, model),
            "lmstudio" => Profile::new(ProviderKind::Openai, model),
            "llamacpp" | "mlx" | "vllm" => Profile::new(ProviderKind::Openai, model),
            "tang" => {
                let mut p = Profile::new(ProviderKind::Openai, model);
                p.sidecar = Some(model.to_string());
                p
            }
            // Apple's on-device model has no native tool calling; guided JSON is exact.
            "apple" => {
                let mut p = Profile::new(ProviderKind::Openai, crate::sidecar::APPLE);
                p.sidecar = Some(crate::sidecar::APPLE.into());
                p.tool_mode = ToolMode::Json;
                p
            }
            "openrouter" | "vercel" => Profile::new(ProviderKind::Openai, model),
            _ => match crate::providers::State::load().custom.remove(prov) {
                // A server you added: another machine's ollama, or any OpenAI-compatible one.
                Some(c) => {
                    let mut p = Profile::new(c.kind, model);
                    p.base_url = Some(c.base_url);
                    p.api_key = crate::providers::key(prov);
                    return Ok((spec.clone(), with_catalog(p, &spec)));
                }
                None => bail!("unknown provider `{prov}`"),
            },
        };
        p.base_url = match prov {
            "lmstudio" => Some("http://localhost:1234/v1".into()),
            "llamacpp" => Some("http://localhost:8080/v1".into()),
            "mlx" => Some("http://localhost:8080/v1".into()),
            "vllm" => Some("http://localhost:8000/v1".into()),
            "openai" => std::env::var("OPENAI_BASE_URL").ok(),
            "tang" | "apple" => p.sidecar.as_deref().map(crate::sidecar::base_url),
            "openrouter" | "vercel" => {
                crate::providers::preset(prov).map(|x| x.base_url.to_string())
            }
            _ => None,
        };
        // Keys set in kiln (the Keychain) or the provider's own variable.
        // OpenAI's key goes only to OpenAI itself, never to an OPENAI_BASE_URL elsewhere.
        let elsewhere = prov == "openai" && p.base_url.is_some();
        if matches!(
            prov,
            "openrouter" | "vercel" | "anthropic" | "claude" | "openai"
        ) && !elsewhere
        {
            let id = if prov == "claude" { "anthropic" } else { prov };
            p.api_key = crate::providers::key(id);
        }
        Ok((spec.clone(), with_catalog(p, &spec)))
    }
}

/// What the catalog knows about a model (context size, images), unless the profile says.
fn with_catalog(mut p: Profile, spec: &str) -> Profile {
    if let Some(m) = crate::catalog::cached(spec) {
        p.context_window = p.context_window.or(m.context);
        p.vision = p.vision.or(Some(m.vision()));
    }
    p
}
