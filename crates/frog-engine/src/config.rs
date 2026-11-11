use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use schemars::JsonSchema;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ProviderKind {
    Openai,
    Anthropic,
    Ollama,
    Codex,
    /// A pooled model on your paired nodes (`node/<weights_hash first 12>`).
    Node,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Default, JsonSchema)]
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
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Default, JsonSchema)]
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

/// How an Anthropic model thinks (`thinking` on the Messages API). Unset picks per model:
/// adaptive for `claude-opus-*` that support it, nothing otherwise.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum AnthropicThinking {
    /// `{type: "adaptive"}`: the model decides when and how much to think (Opus 4.6+).
    Adaptive,
    /// `{type: "enabled", budget_tokens}`: a fixed budget. Older models only; newer ones
    /// reject it, so they get adaptive instead.
    Enabled,
    /// Send no `thinking` parameter.
    Off,
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
    /// A small model with the same tokenizer that drafts tokens for the sidecar to verify
    /// (e.g. `mlx-community/Qwen3-0.6B-4bit` for Qwen3-32B): ~1.4x on CUDA, ~1.15x on Metal.
    #[serde(default)]
    pub draft_model: Option<String>,
    /// Whether the model takes images. Probed when unset (ollama reports it; Anthropic and
    /// OpenAI's own models do).
    #[serde(default)]
    pub vision: Option<bool>,
    /// Overrides the global `thinking` for this model.
    #[serde(default)]
    pub thinking: Option<Thinking>,
    /// Overrides the global `thinking_budget` for this model.
    #[serde(default)]
    pub thinking_budget: Option<u32>,
    /// Anthropic `thinking` mode (see [`AnthropicThinking`]).
    #[serde(default)]
    pub anthropic_thinking: Option<AnthropicThinking>,
    /// `budget_tokens` for `anthropic_thinking = "enabled"` (default 16000, at least 1024).
    #[serde(default)]
    pub anthropic_budget: Option<u32>,
    /// `thinking.display`: "summarized" (default, so thinking streams) or "omitted".
    #[serde(default)]
    pub thinking_display: Option<String>,
    /// Anthropic `output_config.effort`: low, medium, high, xhigh or max. Defaults to "high"
    /// on `claude-opus-*` (the API's own default for Opus 5.5 is medium).
    #[serde(default)]
    pub effort: Option<String>,
    /// Prompt-cache lifetime: "5m" or "1h". Unset: the system prompt and tools get 1h on
    /// Anthropic's API (5m through a gateway), the conversation 5m.
    #[serde(default)]
    pub cache_ttl: Option<String>,
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
            draft_model: None,
            vision: None,
            thinking: None,
            thinking_budget: None,
            anthropic_thinking: None,
            anthropic_budget: None,
            thinking_display: None,
            effort: None,
            cache_ttl: None,
        }
    }

    pub fn context_window(&self) -> u64 {
        self.context_window.unwrap_or_else(|| {
            let known = (self.provider != ProviderKind::Ollama && self.sidecar.is_none())
                .then(|| crate::provider::anthropic::known_limits(&self.model))
                .flatten();
            match (known, self.provider) {
                (Some((ctx, _)), _) => ctx,
                (None, ProviderKind::Anthropic) => 200_000,
                _ => 32_768,
            }
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

fn default_subagent_steps() -> u32 {
    100
}

fn default_approval_timeout() -> u64 {
    600
}

fn default_background_tasks() -> usize {
    4
}

fn default_true() -> bool {
    true
}

fn default_thinking_budget() -> u32 {
    crate::thinking::DEFAULT_BUDGET
}

#[derive(Clone, Debug, Deserialize)]
pub struct Config {
    /// Optional screenshot service; defaults to bundled frog-apple WebKit.
    #[serde(default)]
    pub screenshot_endpoint: Option<String>,
    /// Vision judge profile; defaults to the session model when it supports vision.
    #[serde(default)]
    pub compare_model: Option<String>,
    /// Explicit image generation backend; disabled when unset.
    #[serde(default)]
    pub image: crate::tools::image::Settings,
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
    /// Most reasoning tokens per call where the model thinks (twice this on a turn's first
    /// call); 0 is unlimited. Only sent to servers that take it (tang-llm). A profile's
    /// `thinking_budget` overrides it.
    #[serde(default = "default_thinking_budget")]
    pub thinking_budget: u32,
    /// Also load ~/.claude/CLAUDE.md and CLAUDE.md files as instructions.
    #[serde(default = "default_true")]
    pub load_claude_md: bool,
    /// MCP servers (`[mcp_servers.<name>]`: `command`/`args`/`env`, or `url`/`headers`). A
    /// project's `.mcp.json` adds more.
    #[serde(default)]
    pub mcp_servers: BTreeMap<String, crate::mcp::ServerConfig>,
    /// Let the agent see and drive macOS apps (the bundled `frog-desktop` MCP server).
    #[serde(default)]
    pub computer_use: bool,
    /// Read Claude Code's MCP servers too. Not a config.toml key: `load` fills it from the
    /// choice recorded by `--use-claude-mcp` (see `imports`).
    #[serde(skip)]
    pub claude_mcp: bool,
    /// See only the project: none of the user's own instructions (FROG.md, ~/.claude/CLAUDE.md),
    /// skills or MCP servers. Not a config.toml key: `frog-bench` sets it so a run measures the
    /// harness and the model, not whoever's machine it ran on.
    #[serde(skip)]
    pub hermetic: bool,
    /// Measure each turn's energy (`--energy`, which the Mac app passes when "Show energy use"
    /// is on). Off by default: it keeps a thread reading the power sensor.
    #[serde(skip)]
    pub energy: bool,
    /// Log each model call's timing to stderr (the Mac app's engine log): sent, still waiting,
    /// done or failed. `--serve` turns it on; the TUI draws on the terminal and leaves it off.
    #[serde(skip)]
    pub log_calls: bool,
    /// Run shell commands in a sandbox (writes only in the project, credentials hidden), so
    /// they run without asking. Set false to have every command ask instead.
    #[serde(default = "default_true")]
    pub sandbox_shell: bool,
    /// Opt-in holes in that sandbox (`[sandbox]`), for tools like `gh` that need a credential.
    /// Empty by default: nothing widens unless configured.
    #[serde(default)]
    pub sandbox: SandboxConfig,
    /// `[egress]`: the hosts sandboxed commands may reach, and which sessions enforce it
    /// (agent-started ones by default). See `egress`.
    #[serde(default)]
    pub egress: crate::egress::EgressConfig,
    /// This session was started by an agent (`--worker`, which the app passes for
    /// `StartSession`; kept in the session log so a resume stays one). Not a config.toml key.
    #[serde(skip)]
    pub worker: bool,
    /// Set on a subagent's config by its parent: the parent's egress state, so the subagent's
    /// commands obey the same list and grants and its hits surface in the parent's
    /// transcript. Not a config.toml key.
    #[serde(skip)]
    pub egress_parent: Option<std::sync::Arc<crate::egress::Egress>>,
    /// Start read-only tool calls (Read, Grep, Glob, public web reads, read-only shell
    /// commands) as soon as their arguments arrive, while the model is still writing the rest
    /// of its reply, and run a reply's leading reads side by side. Results, history and events
    /// are the same as without it; only the waiting overlaps.
    #[serde(default = "default_true")]
    pub early_tools: bool,
    /// The model auto mode's classifier uses (a profile or provider/model). Default:
    /// Apple's on-device model where it exists, else frog cloud's small model
    /// (`cloud/deepseek-v4.1-flash`, or `cloud/qwen3-coder-next` when the gateway lists it); the
    /// session's model is the last classifier, then the built-in rules.
    #[serde(default)]
    pub auto_classifier: Option<String>,
    /// A second classifier model, tried when `auto_classifier` can't answer (unreachable,
    /// timed out, an HTTP error). Unset: the session's own model judges, then frog's
    /// built-in rules decide alone.
    #[serde(default)]
    pub auto_classifier_fallback: Option<String>,
    /// Seconds a permission prompt waits for an answer before frog takes the safe path
    /// (denies the call, tells the agent, and carries on). 0 waits forever.
    #[serde(default = "default_approval_timeout")]
    pub approval_timeout_secs: u64,
    /// The model that writes shell-command gists for tool rows (a profile or
    /// provider/model). Default: Apple's on-device model, else frog cloud's small
    /// model (`cloud/deepseek-v4.1-flash`, or `cloud/qwen3-coder-next` when the gateway lists it).
    /// With neither usable, rows show the elided command.
    #[serde(default)]
    pub gist_model: Option<String>,
    /// The model `Task` subagents use (a profile or provider/model) unless a call names one.
    /// Default: the session's model. One that can't be resolved or isn't allowed here falls
    /// back to the session's model.
    #[serde(default)]
    pub subagent_model: Option<String>,
    /// Steps a subagent may take before it has to report.
    #[serde(default = "default_subagent_steps")]
    pub subagent_max_steps: u32,
    /// Background subagents (`Task` with `background: true`) that may run at once.
    #[serde(default = "default_background_tasks")]
    pub background_tasks: usize,
    /// Set on a write-mode subagent's own config by its parent: it gets the edit and shell
    /// tools. Not a config.toml key.
    #[serde(skip)]
    pub subagent_write: bool,
    /// The WebSearch backend: "searxng", "brave", "exa", "tavily" or "frog". Unset: a configured
    /// `searxng_url`, else a search key in the environment, else Frog Cloud's search when
    /// connected, else no WebSearch.
    #[serde(default)]
    pub web_search: Option<String>,
    /// Your SearXNG instance, e.g. `http://localhost:8888`.
    #[serde(default)]
    pub searxng_url: Option<String>,
    /// Let WebFetch reach localhost and private networks (off: public addresses only).
    #[serde(default)]
    pub web_allow_private: bool,
    /// The IRC agent bus (docs/design/agent-bus-irc.md). Off until the frog cloud Bus DO
    /// deploys; a client that sees `enabled` declares `SetClientCaps { irc }`. The URL is the
    /// bus WebSocket; `channel` is the team channel this Mac's sessions post to.
    #[serde(default)]
    pub irc: IrcConfig,
    /// `[mcp_trust]`: MCP servers granted a tier beyond plain reads (`planetscale = "write"`).
    /// A write grant lets that server's write tools (see `auto::mcp_write`) run without a card,
    /// each one logged and shown as a notice. Empty by default: no server is ever trusted
    /// unless configured; read-only tools never card anyway.
    #[serde(default)]
    pub mcp_trust: BTreeMap<String, McpTrust>,
    /// `[delegation]`: where a flagged call goes after the second classifier pass
    /// still says ask (docs/design/delegation.md). `chief` names the session(s)
    /// that decide calls in `chief_classes`; everything else — and the fixed
    /// never-delegable set, always — cards the user. Absent: today's behavior.
    #[serde(default)]
    pub delegation: Delegation,
    /// `[memory]`: `compiled = "auto" | "on" | "off"` (see `compiled_memory`).
    #[serde(default)]
    pub memory: crate::compiled_memory::Settings,
}

/// `[delegation]`: who a still-flagged call is offered to before the user.
#[derive(Clone, Debug, Deserialize, Default)]
pub struct Delegation {
    /// The delegating approver, the chief of staff: a session name or id the
    /// client resolves like `SendMessage`'s `to`. Empty: no delegation.
    #[serde(default)]
    pub chief: Vec<String>,
    /// The grant classes the chief may decide (the delegation.md vocabulary).
    /// Anything not here — and the fixed never-delegable set — cards the user.
    #[serde(default)]
    pub chief_classes: Vec<String>,
    /// Seconds the chief has to answer before the card falls back to the user.
    #[serde(default = "default_chief_timeout")]
    pub chief_timeout_secs: u64,
    /// One approvals roll-up notice per day, at most (`rollup`; `digest` is the
    /// older name).
    #[serde(default = "default_true", alias = "rollup")]
    pub digest: bool,
}

fn default_chief_timeout() -> u64 {
    300
}

impl Delegation {
    /// Whether `class` is in the chief's grant list. A name outside the
    /// vocabulary never grants (a typo can't widen the list silently).
    pub fn grants(&self, class: &str) -> bool {
        grant::ALL.contains(&class) && self.chief_classes.iter().any(|c| c == class)
    }

    /// Classes in `chief_classes` outside the vocabulary: ignored, warned about
    /// once at startup.
    pub fn unknown_classes(&self) -> Vec<&str> {
        self.chief_classes
            .iter()
            .map(String::as_str)
            .filter(|c| !grant::ALL.contains(c))
            .collect()
    }
}

/// The grant-class vocabulary (docs/design/delegation.md). Shapes of harm, not
/// tool names; the classifier's context and the config share these strings.
pub mod grant {
    /// A remote shell into ephemeral infra this session spun up.
    pub const SSH_SCRATCH: &str = "ssh-scratch";
    /// Creates or bills compute the org pays for.
    pub const POD_SPEND: &str = "pod-spend";
    /// Writes inside the project or the session's own scratch.
    pub const OWN_SCOPE_WRITES: &str = "own-scope-writes";
    /// Deletes inside the session's own scratch only.
    pub const SCRATCH_DELETES: &str = "scratch-deletes";
    /// Sends the session's own data out to a first-party endpoint.
    pub const NETWORK_READ_WRITES: &str = "network-read-writes";
    /// MCP writes on a server already granted in `[mcp_trust]`.
    pub const MCP_WRITE_GRANTED: &str = "mcp-write-granted";
    /// Long multi-step commands whose segments are individually ordinary.
    pub const LONG_COMMANDS: &str = "long-commands";
    /// Widens the session's egress fence: `allow_hosts` beyond the session's list, or a
    /// command leaving the sandbox the list is enforced in (the yolo/unsandboxed cards).
    pub const EGRESS: &str = "egress-widen";

    /// Every class the vocabulary defines, for config validation.
    pub const ALL: &[&str] = &[
        SSH_SCRATCH,
        POD_SPEND,
        OWN_SCOPE_WRITES,
        SCRATCH_DELETES,
        NETWORK_READ_WRITES,
        MCP_WRITE_GRANTED,
        LONG_COMMANDS,
        EGRESS,
    ];
}

/// How far a `[mcp_trust]` grant goes for one MCP server.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum McpTrust {
    /// Reads only: the same as no grant (read-only tools never card).
    Read,
    /// Its write tools run without a card, each logged.
    Write,
}

impl Config {
    /// Whether `server` has a write grant in `[mcp_trust]`.
    pub fn mcp_write_trusted(&self, server: &str) -> bool {
        self.mcp_trust.get(server) == Some(&McpTrust::Write)
    }
}

/// `[irc]`: the agent bus. Off by default — flipping it on is the deploy switch.
#[derive(Clone, Debug, Deserialize)]
pub struct IrcConfig {
    /// Turn the bus on. Off until the DO deploys; everything else here is inert without it.
    #[serde(default)]
    pub enabled: bool,
    /// The bus WebSocket. Default: frog cloud's Bus Durable Object.
    #[serde(default = "irc_url")]
    pub url: String,
    /// The team channel for this project's sessions (`#frog`, `#chief`, …).
    #[serde(default)]
    pub channel: Option<String>,
    /// The SASL account name this Mac's sessions authenticate as. The token itself is NEVER
    /// config: it's looked up by this name in the keychain (or `FROG_IRC_TOKEN`), and never
    /// logged.
    #[serde(default)]
    pub account: Option<String>,
}

impl Default for IrcConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            url: irc_url(),
            channel: None,
            account: None,
        }
    }
}

fn irc_url() -> String {
    "wss://api.frog.toys/bus".into()
}

/// `[sandbox]`: what the Bash sandbox may read and write beyond its defaults. Reads widen only
/// from the credential list; writes are fully opt-in. The environment isn't filtered (commands
/// inherit frog's), so there's no `pass_env`.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct SandboxConfig {
    /// Paths (`~/` allowed) a sandboxed command may read even though they're credentials,
    /// e.g. `~/.config/gh`. Agent sessions that need `ssh` to user hosts set
    /// `allow_read = ["~/.ssh/known_hosts"]` (read-only; keys stay unreadable; the no-sudo and
    /// no-writes-outside-scratch rules still bind). `~` is expanded when the sandbox is built,
    /// not when the config is parsed.
    #[serde(default)]
    pub allow_read: Vec<String>,
    /// Paths (`~/` allowed) a sandboxed command may write in addition to the project, temp
    /// dirs and toolchain caches — e.g. a shared build dir or sibling agent worktrees:
    /// `~/Developer/.shared-target`. Opt-in: the default is nothing extra.
    #[serde(default)]
    pub allow_write: Vec<String>,
    /// macOS: let commands read the login Keychain (`~/Library/Keychains`), so `gh` and
    /// credential helpers that keep their token there work. Every sandboxed command can then
    /// read any Keychain item that doesn't prompt.
    #[serde(default)]
    pub allow_keychain: bool,
    /// Outbound network policy. Unset (default): open. `"dev"`: only GitHub, crates.io, npm
    /// and Swift package hosts (via a local proxy). macOS only; Linux stays open.
    #[serde(default)]
    pub network: Option<String>,
    /// Let sandboxed git reads reach GitHub over https instead of ssh: a per-command config
    /// overlay turns `git@github.com:` into `https://github.com/` and uses `gh` as the
    /// credential helper, so fetch/ls-remote/pull work without exposing `~/.ssh`. Applies only
    /// to read subcommands with no `push` in the command. Default off: the alternative that
    /// needs no gh is `allow_read = ["~/.ssh"]` (read-only, but keys become readable).
    #[serde(default)]
    pub git_https: bool,
}

impl Default for Config {
    fn default() -> Self {
        toml::from_str("").expect("empty config parses")
    }
}

pub fn config_dir() -> PathBuf {
    dirs::home_dir().unwrap_or_default().join(".config/frog")
}

pub fn data_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join(".local/share/frog")
}

/// frog's own engine on this machine: needs nothing else installed.
pub const LOCAL_DEFAULT: &str = "local/qwen3-4b";

impl Config {
    pub fn load() -> Result<Self> {
        let path = config_dir().join("config.toml");
        let mut cfg: Self = if path.exists() {
            let text = std::fs::read_to_string(&path)?;
            toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))?
        } else {
            Self::default()
        };
        cfg.claude_mcp = crate::imports::claude_mcp_on();
        // Old provider ids in `default_model` get today's names (in memory; the file is yours).
        cfg.default_model = cfg.default_model.map(|m| crate::providers::normalize(&m));
        Ok(cfg)
    }

    /// Explicit configuration: a missing file is an error, and user MCP imports are not loaded.
    pub fn load_from(path: &std::path::Path) -> Result<Self> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))
    }

    /// Resolve a profile name or a `provider/model` spec.
    pub fn resolve(&self, spec: Option<&str>) -> Result<(String, Profile)> {
        let spec = spec
            .map(String::from)
            .or_else(|| std::env::var("FROG_MODEL").ok())
            .or_else(|| self.default_model.clone())
            // frog's own engine first: it needs nothing else installed.
            .unwrap_or_else(|| LOCAL_DEFAULT.into());
        if let Some(p) = self.models.get(&spec) {
            return Ok((spec, p.clone()));
        }
        // Old provider ids (`tang/`, `frog-api/`, ...) and bare model names get today's spec.
        let spec = match bare(&spec) {
            Some(full) => full,
            None => crate::providers::normalize(&spec),
        };
        let (prov, model) = spec.split_once('/').ok_or_else(|| {
            anyhow!("unknown model `{spec}`: use a profile from config.toml or provider/model (local/, cloud/, codex/, ollama/, apple/, openai/, lmstudio/, llamacpp/, anthropic/)")
        })?;
        let mut p = match prov {
            "ollama" => Profile::new(ProviderKind::Ollama, model),
            "openai" => Profile::new(ProviderKind::Openai, model),
            "anthropic" | "claude" => Profile::new(ProviderKind::Anthropic, model),
            "lmstudio" => Profile::new(ProviderKind::Openai, model),
            "llamacpp" | "mlx" | "vllm" => Profile::new(ProviderKind::Openai, model),
            "local" => {
                let repo = crate::providers::local_repo(model);
                let mut p = Profile::new(ProviderKind::Openai, repo);
                p.sidecar = Some(repo.to_string());
                p
            }
            // Apple's on-device model has no native tool calling; guided JSON is exact.
            "apple" => {
                let mut p = Profile::new(ProviderKind::Openai, crate::sidecar::APPLE);
                p.sidecar = Some(crate::sidecar::APPLE.into());
                p.tool_mode = ToolMode::Json;
                // The on-device model's whole window; the sidecar doesn't report it.
                p.context_window = Some(8_192);
                p
            }
            "openrouter" | "vercel" | "cloud" | "cloudflare" => {
                Profile::new(ProviderKind::Openai, model)
            }
            // Your paired nodes (docs/node-protocol.md §7): placed per call, keys from the Keychain.
            "node" => Profile::new(ProviderKind::Node, model),
            "codex" => {
                let mut p = Profile::new(ProviderKind::Codex, model);
                if let Some((_, context)) = crate::provider::codex::models()
                    .iter()
                    .find(|(m, _)| *m == model)
                {
                    p.context_window = Some(*context);
                }
                p
            }
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
            "cloud" => Some(crate::providers::cloud_base_url()),
            "cloudflare" => crate::providers::cf_base_url(),
            "local" | "apple" => p.sidecar.as_deref().map(crate::sidecar::base_url),
            "openrouter" | "vercel" => {
                crate::providers::preset(prov).map(|x| x.base_url.to_string())
            }
            _ => None,
        };
        // Cloudflare's base URL has the account id in it: without one, requests would go
        // nowhere useful, so say so instead of silently failing later.
        if prov == "cloudflare" && p.base_url.is_none() {
            bail!("cloudflare needs CLOUDFLARE_ACCOUNT_ID set (it's part of the URL)");
        }
        // Keys set in frog (the Keychain) or the provider's own variable.
        // OpenAI's key goes only to OpenAI itself, never to an OPENAI_BASE_URL elsewhere.
        // frog cloud's saved key is pinned the same way, inside `providers::key`.
        let elsewhere = prov == "openai" && p.base_url.is_some();
        if matches!(
            prov,
            "openrouter" | "vercel" | "cloud" | "cloudflare" | "anthropic" | "claude"
            | "openai"
        ) && !elsewhere
        {
            let id = if prov == "claude" { "anthropic" } else { prov };
            p.api_key = crate::providers::key(id);
        }
        Ok((spec.clone(), with_catalog(p, &spec)))
    }
}

/// A bare model name (`glm-5.3-flash`, `qwen3-4b`) as a full spec, when exactly one provider frog
/// knows offers it. No network: bundled local names and frog cloud's last-fetched list.
fn bare(spec: &str) -> Option<String> {
    if spec.contains('/') {
        return None;
    }
    let mut hits: Vec<String> = crate::providers::LOCAL_MODELS
        .iter()
        .filter(|(short, _)| *short == spec)
        .map(|(short, _)| format!("local/{short}"))
        .chain(
            crate::catalog::cloud_models()
                .into_iter()
                .filter(|m| m.id == spec)
                .map(|m| m.spec),
        )
        .collect();
    hits.dedup();
    (hits.len() == 1).then(|| hits.remove(0))
}

/// What the catalog knows about a model (context size, images), unless the profile says.
fn with_catalog(mut p: Profile, spec: &str) -> Profile {
    if let Some(m) = crate::catalog::cached(spec) {
        p.context_window = p.context_window.or(m.context);
        p.vision = p.vision.or(Some(m.vision()));
    }
    p
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_irc_bus_is_off_until_config_turns_it_on() {
        let cfg = Config::default();
        assert!(!cfg.irc.enabled, "off by default until the DO deploys");
        assert_eq!(cfg.irc.url, "wss://api.frog.toys/bus");
        let text = r##"
            [irc]
            enabled = true
            channel = "#frog"
            account = "cam-mac"
            url = "wss://example.invalid/bus"
        "##;
        let cfg: Config = toml::from_str(text).unwrap();
        assert!(cfg.irc.enabled);
        assert_eq!(cfg.irc.channel.as_deref(), Some("#frog"));
        assert_eq!(cfg.irc.account.as_deref(), Some("cam-mac"));
        assert_eq!(cfg.irc.url, "wss://example.invalid/bus");
    }

    #[test]
    fn sandbox_allow_read_parses_with_tildes_intact() {
        // `~` is expanded when the sandbox is built (bash.rs `expand_home`), not here.
        let cfg: Config = toml::from_str(
            r#"
            [sandbox]
            allow_read = ["~/.ssh/known_hosts"]
        "#,
        )
        .unwrap();
        assert_eq!(cfg.sandbox.allow_read, ["~/.ssh/known_hosts"]);
    }

    #[test]
    fn mcp_trust_is_empty_by_default_and_grants_only_what_it_names() {
        assert!(Config::default().mcp_trust.is_empty());
        assert!(!Config::default().mcp_write_trusted("planetscale"));
        let cfg: Config = toml::from_str(
            r#"
            [mcp_trust]
            planetscale = "write"
            runpod = "read"
        "#,
        )
        .unwrap();
        assert!(cfg.mcp_write_trusted("planetscale"));
        assert!(!cfg.mcp_write_trusted("runpod"));
        assert!(!cfg.mcp_write_trusted("vcad"));
        assert!(toml::from_str::<Config>("[mcp_trust]\nx = \"admin\"").is_err());
    }

    #[test]
    fn resolves_new_ids_aliases_and_bare_names() {
        let cfg = Config::default();
        let (spec, p) = cfg.resolve(Some("local/qwen3-4b")).unwrap();
        assert_eq!(spec, "local/qwen3-4b");
        assert_eq!(p.sidecar.as_deref(), Some("mlx-community/Qwen3-4B-4bit"));
        let (spec, _) = cfg
            .resolve(Some("tang/mlx-community/Qwen3-32B-4bit"))
            .unwrap();
        assert_eq!(spec, "local/qwen3-32b");
        let (spec, p) = cfg
            .resolve(Some("local/mlx-community/Qwen3-32B-4bit"))
            .unwrap();
        assert_eq!(spec, "local/qwen3-32b");
        assert_eq!(p.model, "mlx-community/Qwen3-32B-4bit");
        for old in ["frog-api", "frog", "tang-cloud", "zest", "cloud"] {
            let (spec, p) = cfg
                .resolve(Some(&format!("{old}/qwen3-coder-next")))
                .unwrap();
            assert_eq!(spec, "cloud/qwen3-coder-next");
            assert!(p.base_url.is_some());
        }
        // frog cloud's old ids (Cam's own config still says `cloud/bull`) read as today's.
        for (old, new) in [("cloud/bull", "cloud/deepseek-v4.1-flash"), ("cloud/tree", "cloud/glm-5.3-flash")] {
            let (spec, p) = cfg.resolve(Some(old)).unwrap();
            assert_eq!(spec, new);
            assert_eq!(p.model, &new[6..]);
        }
        let cfg2: Config = toml::from_str("default_model = \"cloud/tree\"").unwrap();
        assert_eq!(cfg2.resolve(None).unwrap().0, "cloud/glm-5.3-flash");
        // A bare name frog cloud lists resolves to it.
        let tree = "cloud/tree-bare-test";
        crate::catalog::TEST_CACHE
            .lock()
            .unwrap()
            .get_or_insert_with(Default::default)
            .insert(
                tree.into(),
                crate::catalog::Model {
                    spec: tree.into(),
                    provider: "cloud".into(),
                    id: "tree-bare-test".into(),
                    ..Default::default()
                },
            );
        let (spec, _) = cfg.resolve(Some("tree-bare-test")).unwrap();
        if let Some(c) = crate::catalog::TEST_CACHE.lock().unwrap().as_mut() {
            c.remove(tree);
        }
        assert_eq!(spec, tree);
        let (spec, _) = cfg.resolve(Some("qwen3-4b")).unwrap();
        assert_eq!(spec, "local/qwen3-4b");
        let (spec, p) = cfg.resolve(Some("codex/default")).unwrap();
        assert_eq!(spec, "codex/default");
        assert_eq!(p.provider, ProviderKind::Codex);
        let e = cfg.resolve(Some("nope")).unwrap_err().to_string();
        assert!(e.contains("local/, cloud/, codex/"), "{e}");
    }
}

#[cfg(test)]
mod delegation_tests {
    use super::*;

    #[test]
    fn delegation_is_off_until_config_turns_it_on() {
        let cfg = Config::default();
        assert!(cfg.delegation.chief.is_empty());
        assert!(!cfg.delegation.grants("pod-spend"));
        let text = r##"
            [delegation]
            chief = ["chief of staff"]
            chief_classes = ["pod-spend", "ssh-scratch", "not-a-class"]
            chief_timeout_secs = 60
            digest = false
        "##;
        let cfg: Config = toml::from_str(text).unwrap();
        assert_eq!(cfg.delegation.chief, vec!["chief of staff"]);
        assert!(cfg.delegation.grants("pod-spend"));
        assert!(cfg.delegation.grants("ssh-scratch"));
        assert!(!cfg.delegation.grants("scratch-deletes"), "not granted");
        assert!(!cfg.delegation.grants("not-a-class"), "unknown classes never grant");
        assert!(!cfg.delegation.grants("egress-widen"), "not in this list");
        assert_eq!(cfg.delegation.unknown_classes(), vec!["not-a-class"]);
        assert_eq!(cfg.delegation.chief_timeout_secs, 60);
        assert!(!cfg.delegation.digest);
        // Egress widening is in the vocabulary, so it grants when named.
        let cfg: Config =
            toml::from_str("[delegation]\nchief = [\"x\"]\nchief_classes = [\"egress-widen\"]")
                .unwrap();
        assert!(cfg.delegation.grants("egress-widen"));
        assert!(cfg.delegation.unknown_classes().is_empty());
        // Defaults: 300s, digest on.
        let cfg: Config = toml::from_str("[delegation]\nchief = [\"x\"]").unwrap();
        assert_eq!(cfg.delegation.chief_timeout_secs, 300);
        assert!(cfg.delegation.digest);
        // The spec's key name.
        let cfg: Config = toml::from_str("[delegation]\nrollup = false").unwrap();
        assert!(!cfg.delegation.digest);
    }

    #[test]
    fn every_vocabulary_class_is_a_known_string() {
        // The config's grant check keys off these strings; a typo here would
        // silently never grant.
        for c in crate::config::grant::ALL {
            assert!(c.chars().all(|ch| ch.is_ascii_lowercase() || ch == '-'), "{c}");
        }
    }
}
