//! Providers you connect: gateways and APIs from a preset list (OpenRouter, Vercel AI Gateway,
//! Anthropic, OpenAI), local servers (ollama, LM Studio), and your own servers (a GPU box on the
//! network running ollama, vLLM or llama.cpp). tang and Apple's on-device model are built in.
//!
//! Which providers are connected and which of their models are on lives in
//! `~/.config/frog/models.json`, which frog writes (the app's Settings edits it through frog).
//! API keys never go there: they're kept in the macOS Keychain (service `frog`, account = the
//! provider id), or come from the provider's usual environment variable.

use crate::config::{ProviderKind, config_dir};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

/// A provider frog knows how to reach without being told.
pub struct Preset {
    pub id: &'static str,
    pub name: &'static str,
    pub kind: ProviderKind,
    pub base_url: &'static str,
    /// Environment variables that hold its key, checked after the Keychain.
    pub key_env: &'static [&'static str],
    /// Where to get a key; empty for keyless local servers.
    pub key_url: &'static str,
    /// Runs on this machine (listed when it answers, no key needed).
    pub local: bool,
}

/// This Mac's own engine (the tang sidecar). `tang` is its old id.
pub const LOCAL: &str = "local";
/// frog cloud: frog's hosted models. `frog-api`, `frog`, `tang-cloud` and `zest` are old ids.
pub const CLOUD: &str = "cloud";
/// The only origin the Keychain's frog cloud key is ever sent to.
pub const CLOUD_ORIGIN: &str = "https://api.frog.toys";
/// Variables that point frog cloud somewhere else, first wins.
pub const CLOUD_BASE_ENV: &[&str] = &["FROG_BASE_URL", "TANG_CLOUD_BASE_URL", "TANG_BASE_URL"];

/// A provider id as frog writes it today: old ids become their new names.
pub fn canonical(id: &str) -> &str {
    match id {
        "tang" => LOCAL,
        "frog-api" | "frog" | "tang-cloud" | "zest" => CLOUD,
        other => other,
    }
}

/// Short names for the models this Mac's engine ships with.
pub const LOCAL_MODELS: &[(&str, &str)] = &[
    ("qwen3-4b", "mlx-community/Qwen3-4B-4bit"),
    ("qwen3-32b", "mlx-community/Qwen3-32B-4bit"),
];

/// A `local/` model's checkpoint: a short name's repo, or the name itself.
pub fn local_repo(model: &str) -> &str {
    LOCAL_MODELS
        .iter()
        .find(|(short, _)| *short == model)
        .map_or(model, |(_, repo)| repo)
}

/// A spec as frog writes it today: new provider ids, short names for bundled local models.
/// Inputs in old forms keep working; this is what gets stored.
pub fn normalize(spec: &str) -> String {
    let Some((prov, model)) = spec.split_once('/') else {
        return spec.to_string();
    };
    let prov = canonical(prov);
    if prov == LOCAL
        && let Some((short, _)) = LOCAL_MODELS.iter().find(|(_, repo)| *repo == model)
    {
        return format!("{LOCAL}/{short}");
    }
    format!("{prov}/{model}")
}

/// Ids no server you add can take: the built-ins and every old name for them.
pub const RESERVED: &[&str] = &[
    LOCAL,
    CLOUD,
    "tang",
    "frog-api",
    "frog",
    "tang-cloud",
    "zest",
    "apple",
    "claude",
    "llamacpp",
    "mlx",
    "vllm",
];

/// Where a provider sits in every list: This Mac, then your servers, then frog cloud, then
/// other clouds. Lower comes first.
pub fn rank(id: &str) -> u8 {
    let id = canonical(id);
    match preset(id) {
        Some(p) if p.local => 0,
        Some(_) if id == CLOUD => 2,
        Some(_) => 3,
        // Not a preset: a server you added.
        None => 1,
    }
}

pub const PRESETS: &[Preset] = &[
    // This Mac: frog's own engine (tang-llm), started on demand on its own port.
    Preset {
        id: LOCAL,
        name: "This Mac",
        kind: ProviderKind::Openai,
        base_url: "http://127.0.0.1:8911/v1",
        key_env: &[],
        key_url: "",
        local: true,
    },
    // frog cloud: hosted Qwen3-Coder-Next, powered by tang (OpenAI-compatible).
    // FROG_BASE_URL (or the old TANG_CLOUD_BASE_URL, TANG_BASE_URL) overrides it.
    Preset {
        id: CLOUD,
        name: "frog cloud",
        kind: ProviderKind::Openai,
        base_url: "https://api.frog.toys/v1",
        key_env: &[
            "FROG_API_KEY",
            "TANG_CLOUD_API_KEY",
            "TANG_API_KEY",
            "ZEST_API_KEY",
        ],
        key_url: "https://api.frog.toys/beta",
        local: false,
    },
    Preset {
        id: "openrouter",
        name: "OpenRouter",
        kind: ProviderKind::Openai,
        base_url: "https://openrouter.ai/api/v1",
        key_env: &["OPENROUTER_API_KEY"],
        key_url: "https://openrouter.ai/settings/keys",
        local: false,
    },
    Preset {
        id: "vercel",
        name: "Vercel AI Gateway",
        kind: ProviderKind::Openai,
        base_url: "https://ai-gateway.vercel.sh/v1",
        key_env: &["AI_GATEWAY_API_KEY", "VERCEL_AI_GATEWAY_API_KEY"],
        key_url: "https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai%2Fapi-keys",
        local: false,
    },
    // Cloudflare AI Gateway: its REST API serves Workers AI models (cloudflare/@cf/zai-org/glm-5.3)
    // and third-party ones on unified billing (cloudflare/anthropic/claude-opus-5.5), one token
    // for all. The account id lives in the URL, so the base URL is built at request time
    // from CLOUDFLARE_ACCOUNT_ID (cf_base_url).
    Preset {
        id: "cloudflare",
        name: "Cloudflare AI Gateway",
        kind: ProviderKind::Openai,
        base_url: "", // resolved per-request via cf_base_url_from
        key_env: &["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_API_KEY"],
        key_url: "https://dash.cloudflare.com/profile/api-tokens",
        local: false,
    },
    Preset {
        id: "anthropic",
        name: "Anthropic",
        kind: ProviderKind::Anthropic,
        base_url: "https://api.anthropic.com",
        key_env: &["ANTHROPIC_API_KEY"],
        key_url: "https://console.anthropic.com/settings/keys",
        local: false,
    },
    Preset {
        id: "openai",
        name: "OpenAI",
        kind: ProviderKind::Openai,
        base_url: "https://api.openai.com/v1",
        key_env: &["OPENAI_API_KEY"],
        key_url: "https://platform.openai.com/api-keys",
        local: false,
    },
    Preset {
        id: "ollama",
        name: "Ollama",
        kind: ProviderKind::Ollama,
        base_url: "http://localhost:11434",
        key_env: &[],
        key_url: "",
        local: true,
    },
    Preset {
        id: "lmstudio",
        name: "LM Studio",
        kind: ProviderKind::Openai,
        base_url: "http://localhost:1234/v1",
        key_env: &[],
        key_url: "",
        local: true,
    },
];

pub fn preset(id: &str) -> Option<&'static Preset> {
    let id = canonical(id);
    PRESETS.iter().find(|p| p.id == id)
}

/// Cloudflare AI Gateway's base URL, OpenAI-compatible, with the account id in the URL.
/// `None` until `CLOUDFLARE_ACCOUNT_ID` is set: it can't be a static `Preset::base_url`.
pub fn cf_base_url_from(env: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    let id = env("CLOUDFLARE_ACCOUNT_ID")?;
    Some(format!(
        "https://api.cloudflare.com/client/v4/accounts/{id}/ai/v1"
    ))
}

/// Cloudflare AI Gateway's base URL, once `CLOUDFLARE_ACCOUNT_ID` is set.
pub fn cf_base_url() -> Option<String> {
    cf_base_url_from(&env_var)
}

/// Cloudflare's models frog suggests: Workers AI's own, and Claude through the gateway.
/// (id, name, context)
pub const CF_MODELS: &[(&str, &str, u64)] = &[
    ("@cf/zai-org/glm-5.3", "GLM 5.3", 1_048_576),
    ("@cf/deepseek-ai/deepseek-v4.1-flash-1017", "DeepSeek V4.1 Flash", 1_048_576),
    ("anthropic/claude-opus-5.5", "Claude Opus 5.5", 200_000),
];

/// frog cloud's base URL, from the first non-empty override, else the preset's.
pub fn cloud_base_url_from(env: &dyn Fn(&str) -> Option<String>) -> String {
    CLOUD_BASE_ENV
        .iter()
        .find_map(|v| env(v))
        .unwrap_or_else(|| preset(CLOUD).unwrap().base_url.to_string())
}

pub fn cloud_base_url() -> String {
    cloud_base_url_from(&env_var)
}

/// Whether a URL is on frog cloud's own origin (scheme, host and port all match).
pub fn on_cloud_origin(url: &str) -> bool {
    url.strip_prefix(CLOUD_ORIGIN)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
}

fn env_var(v: &str) -> Option<String> {
    std::env::var(v).ok().filter(|k| !k.is_empty())
}

/// A server you added: another machine's ollama, or any OpenAI-compatible endpoint.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Custom {
    pub name: String,
    pub kind: ProviderKind,
    pub base_url: String,
}

/// frog's own record of your providers and models (`models.json`).
#[derive(Debug, Default, Serialize, Deserialize)]
pub struct State {
    #[serde(default)]
    pub custom: BTreeMap<String, Custom>,
    /// Remote models shown in the picker, as `provider/model` specs. Local models (ollama,
    /// tang, Apple, your own servers) are always shown.
    #[serde(default)]
    pub enabled: BTreeSet<String>,
}

fn state_path() -> PathBuf {
    config_dir().join("models.json")
}

impl State {
    pub fn load() -> Self {
        let mut s: Self = std::fs::read(state_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        // One-time migration: specs saved under old provider ids get their new names.
        if s.migrate() {
            let _ = s.save();
        }
        s
    }

    /// Rewrite `enabled` specs to today's names; true when anything changed.
    pub fn migrate(&mut self) -> bool {
        let new: BTreeSet<String> = self.enabled.iter().map(|e| normalize(e)).collect();
        let changed = new != self.enabled;
        self.enabled = new;
        changed
    }

    pub fn save(&self) -> Result<()> {
        let path = state_path();
        std::fs::create_dir_all(path.parent().unwrap())?;
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(tmp, path)?;
        Ok(())
    }
}

/// A provider as clients see it.
#[derive(Debug, Serialize)]
pub struct ProviderInfo {
    pub id: String,
    pub name: String,
    pub kind: ProviderKind,
    pub base_url: String,
    pub local: bool,
    /// Added by you (can be removed).
    pub custom: bool,
    /// Where its key comes from: "keychain", "env", or none.
    pub key: Option<&'static str>,
    pub key_url: String,
    /// Has what it needs: a key, or (local and custom) nothing.
    pub connected: bool,
    /// Its place in every list, lower first: 0 This Mac, 1 your servers, 2 frog cloud,
    /// 3 other clouds.
    pub rank: u8,
    /// Built in and always listed: can't be removed (frog cloud).
    pub pinned: bool,
}

/// Every provider, in rank order: This Mac, your servers, frog cloud, other clouds.
pub fn list(state: &State) -> Vec<ProviderInfo> {
    let presets = PRESETS.iter().map(|p| {
        let key = key_source(p.id);
        // Cloudflare's base URL has the account id in it: empty until CLOUDFLARE_ACCOUNT_ID
        // is set, and it needs that id (with the key) to count as connected.
        let cf = p.id == "cloudflare";
        let base_url = if p.id == CLOUD {
            cloud_base_url()
        } else if cf {
            cf_base_url().unwrap_or_default()
        } else {
            p.base_url.into()
        };
        let connected = match p.id {
            LOCAL => crate::sidecar::available("tang"),
            _ if cf => key.is_some() && !base_url.is_empty(),
            _ => p.local || key.is_some(),
        };
        ProviderInfo {
            id: p.id.into(),
            name: p.name.into(),
            kind: p.kind,
            base_url,
            local: p.local,
            custom: false,
            key,
            key_url: p.key_url.into(),
            connected,
            rank: rank(p.id),
            pinned: p.id == CLOUD,
        }
    });
    let custom = state.custom.iter().map(|(id, c)| ProviderInfo {
        id: id.clone(),
        name: c.name.clone(),
        kind: c.kind,
        base_url: c.base_url.clone(),
        local: true,
        custom: true,
        key: key_source(id),
        key_url: String::new(),
        connected: true,
        rank: rank(id),
        pinned: false,
    });
    let mut out: Vec<ProviderInfo> = presets.chain(custom).collect();
    // Stable: presets keep their order within a rank, servers stay alphabetical.
    out.sort_by_key(|p| p.rank);
    out
}

/// The one place a provider's key comes from, and where it was found: "env" (its usual
/// variable) or "keychain" (set in frog). The environment wins. frog cloud's Keychain key goes
/// only to frog cloud's own origin: with its base URL pointed elsewhere, only an env key is
/// used. Web search services (`brave`, `exa`, `tavily`) keep their keys the same way.
pub fn key_from(
    id: &str,
    env: &dyn Fn(&str) -> Option<String>,
    keychain: &dyn Fn(&str) -> Option<String>,
) -> Option<(&'static str, String)> {
    let id = canonical(id);
    let from_env = match preset(id) {
        Some(p) => p.key_env.iter().find_map(|v| env(v)),
        None => crate::tools::websearch::KEYED
            .iter()
            .find(|(k, _)| *k == id)
            .and_then(|(_, v)| env(v)),
    };
    if let Some(k) = from_env {
        return Some(("env", k));
    }
    if id == CLOUD && !on_cloud_origin(&cloud_base_url_from(env)) {
        return None;
    }
    keychain(id).map(|k| ("keychain", k))
}

/// Where a provider's key comes from, if it has one frog would use.
pub fn key_source(id: &str) -> Option<&'static str> {
    key_from(id, &env_var, &keychain_get).map(|(s, _)| s)
}

/// A provider's key, as [`key_from`] finds it.
pub fn key(id: &str) -> Option<String> {
    key_from(id, &env_var, &keychain_get).map(|(_, k)| k)
}

/// The Keychain, with the one-time move of frog cloud's key from its old account
/// (`frog-api`) to `cloud`.
fn keychain_get(id: &str) -> Option<String> {
    let id = canonical(id);
    keychain::get(id).or_else(|| {
        if id != CLOUD {
            return None;
        }
        let old = keychain::get("frog-api")?;
        let _ = keychain::set(CLOUD, &old);
        Some(old)
    })
}

/// What `frog account` shows: frog cloud's key and where requests go. Local only: no network.
#[derive(Debug, Serialize, PartialEq)]
pub struct Account {
    pub connected: bool,
    /// "env" or "keychain"; none when logged out.
    pub key_source: Option<&'static str>,
    /// The variable the key came from, for an env key.
    pub key_env: Option<&'static str>,
    /// A saved Keychain key that isn't used because the environment's wins.
    pub keychain_ignored: bool,
    pub base_url: String,
    /// The base URL is frog cloud's own: a Keychain key may go there.
    pub pinned: bool,
    /// A Keychain key exists but is withheld, because the base URL points elsewhere.
    pub keychain_withheld: bool,
    pub key_url: &'static str,
}

impl Account {
    pub fn read() -> Self {
        Self::from(&env_var, &keychain_get)
    }

    pub fn from(
        env: &dyn Fn(&str) -> Option<String>,
        keychain: &dyn Fn(&str) -> Option<String>,
    ) -> Self {
        let p = preset(CLOUD).unwrap();
        let base_url = cloud_base_url_from(env);
        let pinned = on_cloud_origin(&base_url);
        let found = key_from(CLOUD, env, keychain).map(|(s, _)| s);
        let saved = keychain(CLOUD).is_some();
        Account {
            connected: found.is_some(),
            key_source: found,
            key_env: (found == Some("env"))
                .then(|| p.key_env.iter().copied().find(|v| env(v).is_some()))
                .flatten(),
            keychain_ignored: found == Some("env") && saved,
            base_url,
            pinned,
            keychain_withheld: found != Some("keychain") && !pinned && saved,
            key_url: p.key_url,
        }
    }

    pub fn render(&self) -> String {
        if !self.connected {
            let mut s = format!(
                "frog cloud: not connected: set FROG_API_KEY or add a key in the app; get one at {}\n",
                self.key_url
            );
            if self.keychain_withheld {
                s.push_str(&format!(
                    "  your saved key is only sent to {CLOUD_ORIGIN}, and the base URL is {}\n",
                    self.base_url
                ));
            }
            return s;
        }
        let source = match (self.key_source, self.key_env) {
            (Some("env"), Some(v)) => v.to_string(),
            (Some("env"), None) => "environment".into(),
            _ => "Keychain".into(),
        };
        let mut s = format!("frog cloud: connected\n  key       {source}\n");
        if self.keychain_ignored {
            s.push_str(
                "            (using the environment's key; your saved key is ignored here)\n",
            );
        }
        s.push_str(&format!("  base url  {}\n", self.base_url));
        let pin = if self.pinned {
            format!("yes: a saved key only goes to {CLOUD_ORIGIN}")
        } else {
            "no: base URL overridden, only an env key is sent".to_string()
        };
        s.push_str(&format!("  pinned    {pin}\n"));
        s
    }
}

/// Store a key (empty removes it).
pub fn set_key(id: &str, key: &str) -> Result<()> {
    let id = canonical(id);
    let key = key.trim();
    if key.is_empty() {
        return keychain::delete(id);
    }
    keychain::set(id, key)
}

/// A paired node's key (docs/node-protocol.md §7): Keychain account `node:<node_id>`, which
/// the Mac app writes when pairing finishes.
pub fn node_key(node_id: &str) -> Option<String> {
    keychain::get(&format!("node:{node_id}"))
}

/// MCP OAuth's Keychain accounts (`mcp-oauth:<server>`), through the same module so
/// `FROG_KEYCHAIN=off` and the cache behave the same.
pub(crate) fn keychain_mcp_get(id: &str) -> Option<String> {
    keychain::get(id)
}

pub(crate) fn keychain_mcp_set(id: &str, value: &str) -> Result<()> {
    keychain::set(id, value)
}

pub(crate) fn keychain_mcp_delete(id: &str) {
    let _ = keychain::delete(id);
}

/// A provider id for a server you add: lowercase letters, digits and dashes, not a preset's.
pub fn add_custom(state: &mut State, id: &str, custom: Custom) -> Result<()> {
    let ok = !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
    if !ok {
        bail!("a provider id is lowercase letters, digits and dashes (like `gpu`)");
    }
    if preset(id).is_some() || RESERVED.contains(&id) {
        bail!("`{id}` is taken by a built-in provider");
    }
    if !custom.base_url.starts_with("http://") && !custom.base_url.starts_with("https://") {
        bail!("the server's URL starts with http:// or https://");
    }
    state.custom.insert(id.to_string(), custom);
    Ok(())
}

/// Why a provider can't be removed, if it can't: frog cloud is built in.
pub fn removable(id: &str) -> Result<()> {
    let c = canonical(id);
    if c == CLOUD {
        bail!(
            "frog cloud is built in and can't be removed; to disconnect it, unset FROG_API_KEY or clear its key: `printf '' | frog --set-key cloud`"
        );
    }
    if preset(c).is_some() || RESERVED.contains(&c) {
        bail!("`{id}` is built in; only servers you added can be removed");
    }
    Ok(())
}

/// The Keychain, through `/usr/bin/security`. The same tool writes and reads the item, so it
/// stays readable across frog rebuilds without prompts; keys go in on stdin, never argv.
mod keychain {
    use super::*;
    use std::io::Write;
    use std::process::{Command, Stdio};
    use std::sync::Mutex;

    const SERVICE: &str = "frog";
    static CACHE: Mutex<BTreeMap<String, Option<String>>> = Mutex::new(BTreeMap::new());

    pub fn get(id: &str) -> Option<String> {
        if let Some(hit) = CACHE.lock().unwrap().get(id) {
            return hit.clone();
        }
        // FROG_KEYCHAIN=off: never read the Keychain (tests, sandboxes).
        if !cfg!(target_os = "macos") || std::env::var("FROG_KEYCHAIN").is_ok_and(|v| v == "off") {
            return None;
        }
        let find = |service: &str| {
            Command::new("/usr/bin/security")
                .args(["find-generic-password", "-s", service, "-a", id, "-w"])
                .stderr(Stdio::null())
                .output()
                .ok()
                .filter(|o| o.status.success())
                .and_then(|o| String::from_utf8(o.stdout).ok())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        };
        let out = find(SERVICE);
        CACHE.lock().unwrap().insert(id.to_string(), out.clone());
        out
    }

    pub fn set(id: &str, key: &str) -> Result<()> {
        if !cfg!(target_os = "macos") {
            bail!(
                "storing keys needs the macOS Keychain; set the provider's environment variable instead"
            );
        }
        // `security -i` reads commands from stdin; a key with quotes or whitespace can't be
        // quoted safely there, and no real API key has them.
        if key
            .chars()
            .any(|c| c.is_whitespace() || c == '"' || c == '\\')
        {
            bail!("that doesn't look like an API key");
        }
        let mut child = Command::new("/usr/bin/security")
            .arg("-i")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .context("couldn't run security")?;
        let line = format!(
            "add-generic-password -U -s {SERVICE} -a \"{id}\" -l \"frog: {id}\" -w \"{key}\"\n"
        );
        child.stdin.take().unwrap().write_all(line.as_bytes())?;
        let out = child.wait_with_output()?;
        let err = String::from_utf8_lossy(&out.stderr);
        if !out.status.success() || err.contains("error") {
            bail!("couldn't save the key to the Keychain: {}", err.trim());
        }
        CACHE
            .lock()
            .unwrap()
            .insert(id.to_string(), Some(key.to_string()));
        Ok(())
    }

    /// Tests: pretend the Keychain holds `key` for `id` (None: holds nothing).
    #[cfg(test)]
    pub fn seed(id: &str, key: Option<&str>) {
        CACHE
            .lock()
            .unwrap()
            .insert(id.to_string(), key.map(String::from));
    }

    pub fn delete(id: &str) -> Result<()> {
        if cfg!(target_os = "macos") {
            let _ = Command::new("/usr/bin/security")
                .args(["delete-generic-password", "-s", SERVICE, "-a", id])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
        CACHE.lock().unwrap().insert(id.to_string(), None);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn custom_ids_are_checked() {
        let mut s = State::default();
        let box3090 = Custom {
            name: "3090".into(),
            kind: ProviderKind::Ollama,
            base_url: "http://gpu:11434".into(),
        };
        assert!(add_custom(&mut s, "gpu", box3090.clone()).is_ok());
        assert!(add_custom(&mut s, "openrouter", box3090.clone()).is_err());
        assert!(add_custom(&mut s, "Bad Id", box3090.clone()).is_err());
        let bad_url = Custom {
            base_url: "gpu:11434".into(),
            ..box3090
        };
        assert!(add_custom(&mut s, "other", bad_url).is_err());
        assert_eq!(s.custom.len(), 1);
    }

    fn env_of(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |v| {
            pairs
                .iter()
                .find(|(k, _)| *k == v)
                .map(|(_, x)| x.to_string())
        }
    }

    #[test]
    fn old_ids_and_short_names_normalize() {
        assert_eq!(
            normalize("tang/mlx-community/Qwen3-4B-4bit"),
            "local/qwen3-4b"
        );
        assert_eq!(
            normalize("tang/mlx-community/Qwen3-32B-4bit"),
            "local/qwen3-32b"
        );
        assert_eq!(normalize("tang/some/other"), "local/some/other");
        for old in ["frog-api", "frog", "tang-cloud", "zest"] {
            assert_eq!(
                normalize(&format!("{old}/qwen3-coder-next")),
                "cloud/qwen3-coder-next"
            );
        }
        assert_eq!(
            normalize("anthropic/claude-sonnet-5"),
            "anthropic/claude-sonnet-5"
        );
        assert_eq!(local_repo("qwen3-32b"), "mlx-community/Qwen3-32B-4bit");
        assert_eq!(preset("frog-api").unwrap().id, CLOUD);
    }

    #[test]
    fn migrate_rewrites_enabled_specs() {
        let mut s = State::default();
        s.enabled.insert("frog-api/qwen3-coder-next".into());
        s.enabled.insert("anthropic/claude-sonnet-5".into());
        assert!(s.migrate());
        assert!(s.enabled.contains("cloud/qwen3-coder-next"));
        assert!(!s.migrate());
    }

    #[test]
    fn rank_orders_mac_servers_cloud_others() {
        let mut s = State::default();
        let gpu = Custom {
            name: "gpu".into(),
            kind: ProviderKind::Ollama,
            base_url: "http://gpu:11434".into(),
        };
        add_custom(&mut s, "gpu", gpu).unwrap();
        let ids: Vec<String> = list(&s).into_iter().map(|p| p.id).collect();
        let at = |id: &str| ids.iter().position(|x| x == id).unwrap();
        assert_eq!(ids[0], LOCAL);
        assert!(at("ollama") < at("gpu") && at("lmstudio") < at("gpu"));
        assert_eq!(at(CLOUD), at("gpu") + 1);
        assert!(at(CLOUD) < at("openrouter") && at(CLOUD) < at("anthropic"));
        let infos = list(&s);
        let cloud = infos.iter().find(|p| p.id == CLOUD).unwrap();
        assert!(cloud.pinned && cloud.rank == 2);
        assert!(infos.iter().filter(|p| p.pinned).count() == 1);
    }

    #[test]
    fn env_key_beats_keychain() {
        keychain::seed("anthropic", Some("kc-anthropic"));
        let kc = |id: &str| keychain::get(id);
        let env = env_of(&[("FROG_API_KEY", "env-cloud")]);
        let both = |id: &str| {
            if id == CLOUD {
                Some("kc-cloud".to_string())
            } else {
                None
            }
        };
        assert_eq!(
            key_from("cloud", &env, &both),
            Some(("env", "env-cloud".into()))
        );
        assert_eq!(
            key_from("frog-api", &env, &both),
            Some(("env", "env-cloud".into()))
        );
        let none = env_of(&[]);
        assert_eq!(
            key_from("cloud", &none, &both),
            Some(("keychain", "kc-cloud".into()))
        );
        assert_eq!(
            key_from("anthropic", &none, &kc),
            Some(("keychain", "kc-anthropic".into()))
        );
        let anth = env_of(&[("ANTHROPIC_API_KEY", "env-a")]);
        assert_eq!(
            key_from("anthropic", &anth, &kc),
            Some(("env", "env-a".into()))
        );
    }

    #[test]
    fn keychain_cloud_key_is_pinned_to_its_host() {
        let kc = |id: &str| (id == CLOUD).then(|| "kc".to_string());
        let elsewhere = env_of(&[("FROG_BASE_URL", "https://evil.example/v1")]);
        assert_eq!(key_from(CLOUD, &elsewhere, &kc), None);
        let lookalike = env_of(&[("FROG_BASE_URL", "https://api.frog.toys.evil.example/v1")]);
        assert_eq!(key_from(CLOUD, &lookalike, &kc), None);
        let own = env_of(&[("FROG_BASE_URL", "https://api.frog.toys/v2")]);
        assert_eq!(key_from(CLOUD, &own, &kc), Some(("keychain", "kc".into())));
        let with_env = env_of(&[
            ("FROG_BASE_URL", "http://localhost:9999/v1"),
            ("FROG_API_KEY", "e"),
        ]);
        assert_eq!(key_from(CLOUD, &with_env, &kc), Some(("env", "e".into())));
    }

    #[test]
    fn cloud_cannot_be_removed() {
        for id in ["cloud", "frog-api", "frog", "tang-cloud", "zest"] {
            let e = removable(id).unwrap_err().to_string();
            assert!(e.contains("can't be removed"), "{e}");
        }
        assert!(removable("local").is_err());
        assert!(removable("gpu").is_ok());
    }

    #[test]
    fn built_in_ids_and_aliases_are_reserved() {
        let c = Custom {
            name: "x".into(),
            kind: ProviderKind::Openai,
            base_url: "http://x:1/v1".into(),
        };
        let mut s = State::default();
        for id in [
            "local",
            "cloud",
            "tang",
            "frog-api",
            "frog",
            "tang-cloud",
            "zest",
        ] {
            let e = add_custom(&mut s, id, c.clone()).unwrap_err().to_string();
            assert!(e.contains("taken"), "{id}: {e}");
        }
        assert!(s.custom.is_empty());
    }

    #[test]
    fn cf_base_url_needs_the_account_id() {
        let set = env_of(&[("CLOUDFLARE_ACCOUNT_ID", "abc123")]);
        assert_eq!(
            cf_base_url_from(&set).unwrap(),
            "https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1"
        );
        let empty = env_of(&[]);
        assert_eq!(cf_base_url_from(&empty), None);
        // The preset exists but has no static base URL: it's built per-request.
        let p = preset("cloudflare").unwrap();
        assert_eq!(p.base_url, "");
        assert!(p.key_env.contains(&"CLOUDFLARE_API_TOKEN"));
    }

    #[test]
    fn cf_model_specs_round_trip() {
        for (id, _, _) in CF_MODELS {
            let spec = format!("cloudflare/{id}");
            assert_eq!(normalize(&spec), spec);
            let (prov, model) = spec.split_once('/').unwrap();
            assert_eq!(preset(prov).unwrap().id, "cloudflare");
            assert_eq!(model, *id);
        }
    }

    #[test]
    fn account_text() {
        let kc_none = |_: &str| None;
        let out = env_of(&[]);
        let a = Account::from(&out, &kc_none);
        assert!(!a.connected);
        assert_eq!(
            a.render(),
            "frog cloud: not connected: set FROG_API_KEY or add a key in the app; get one at https://api.frog.toys/beta\n"
        );
        let kc = |id: &str| (id == CLOUD).then(|| "k".to_string());
        let env = env_of(&[("FROG_API_KEY", "e")]);
        let a = Account::from(&env, &kc);
        assert_eq!(
            a.render(),
            "frog cloud: connected\n  key       FROG_API_KEY\n            (using the environment's key; your saved key is ignored here)\n  base url  https://api.frog.toys/v1\n  pinned    yes: a saved key only goes to https://api.frog.toys\n"
        );
        let moved = env_of(&[("FROG_BASE_URL", "http://localhost:1/v1")]);
        let a = Account::from(&moved, &kc);
        assert!(!a.connected && a.keychain_withheld && !a.pinned);
    }
}
