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
    /// Also load ~/.claude/CLAUDE.md and CLAUDE.md files as instructions.
    #[serde(default = "default_true")]
    pub load_claude_md: bool,
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
            anyhow!("unknown model `{spec}`: use a profile from config.toml or provider/model (ollama/, openai/, lmstudio/, llamacpp/, anthropic/)")
        })?;
        let mut p = match prov {
            "ollama" => Profile::new(ProviderKind::Ollama, model),
            "openai" => Profile::new(ProviderKind::Openai, model),
            "anthropic" | "claude" => Profile::new(ProviderKind::Anthropic, model),
            "lmstudio" => Profile::new(ProviderKind::Openai, model),
            "llamacpp" | "mlx" | "vllm" => Profile::new(ProviderKind::Openai, model),
            _ => bail!("unknown provider `{prov}`"),
        };
        p.base_url = match prov {
            "lmstudio" => Some("http://localhost:1234/v1".into()),
            "llamacpp" => Some("http://localhost:8080/v1".into()),
            "mlx" => Some("http://localhost:8080/v1".into()),
            "vllm" => Some("http://localhost:8000/v1".into()),
            "openai" => std::env::var("OPENAI_BASE_URL").ok(),
            _ => None,
        };
        Ok((spec, p))
    }
}
