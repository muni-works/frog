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

pub const PRESETS: &[Preset] = &[
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
    PRESETS.iter().find(|p| p.id == id)
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
        std::fs::read(state_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
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
}

/// Every provider: presets, then yours.
pub fn list(state: &State) -> Vec<ProviderInfo> {
    let presets = PRESETS.iter().map(|p| {
        let key = key_source(p.id);
        ProviderInfo {
            id: p.id.into(),
            name: p.name.into(),
            kind: p.kind,
            base_url: p.base_url.into(),
            local: p.local,
            custom: false,
            key,
            key_url: p.key_url.into(),
            connected: p.local || key.is_some(),
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
    });
    presets.chain(custom).collect()
}

/// Where a provider's key would come from, without reading it.
fn key_source(id: &str) -> Option<&'static str> {
    if preset(id).is_some_and(|p| {
        p.key_env
            .iter()
            .any(|v| std::env::var(v).is_ok_and(|k| !k.is_empty()))
    }) {
        return Some("env");
    }
    keychain::get(id).map(|_| "keychain")
}

/// A provider's key: the Keychain first (what you set in frog), then its environment variable.
/// Web search services (`brave`, `exa`, `tavily`) keep their keys the same way.
pub fn key(id: &str) -> Option<String> {
    let env = |v: &str| std::env::var(v).ok().filter(|k| !k.is_empty());
    keychain::get(id).or_else(|| match preset(id) {
        Some(p) => p.key_env.iter().find_map(|v| env(v)),
        None => crate::tools::websearch::KEYED
            .iter()
            .find(|(k, _)| *k == id)
            .and_then(|(_, v)| env(v)),
    })
}

/// Store a key (empty removes it).
pub fn set_key(id: &str, key: &str) -> Result<()> {
    let key = key.trim();
    if key.is_empty() {
        return keychain::delete(id);
    }
    keychain::set(id, key)
}

/// A provider id for a server you add: lowercase letters, digits and dashes, not a preset's.
pub fn add_custom(state: &mut State, id: &str, custom: Custom) -> Result<()> {
    let ok = !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
    if !ok {
        bail!("a provider id is lowercase letters, digits and dashes (like `gpu-box`)");
    }
    if preset(id).is_some()
        || matches!(
            id,
            "tang" | "apple" | "claude" | "llamacpp" | "mlx" | "vllm"
        )
    {
        bail!("`{id}` is taken by a built-in provider");
    }
    if !custom.base_url.starts_with("http://") && !custom.base_url.starts_with("https://") {
        bail!("the server's URL starts with http:// or https://");
    }
    state.custom.insert(id.to_string(), custom);
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
    /// Keys saved before the rename; read once and copied over.
    const LEGACY: &str = "kiln";
    static CACHE: Mutex<BTreeMap<String, Option<String>>> = Mutex::new(BTreeMap::new());

    pub fn get(id: &str) -> Option<String> {
        if !cfg!(target_os = "macos") {
            return None;
        }
        if let Some(hit) = CACHE.lock().unwrap().get(id) {
            return hit.clone();
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
        let out = find(SERVICE).or_else(|| {
            // Saved under kiln's name: copy it to frog's.
            let key = find(LEGACY)?;
            let _ = set(id, &key);
            Some(key)
        });
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
            base_url: "http://gpu-box:11434".into(),
        };
        assert!(add_custom(&mut s, "gpu-box", box3090.clone()).is_ok());
        assert!(add_custom(&mut s, "openrouter", box3090.clone()).is_err());
        assert!(add_custom(&mut s, "Bad Id", box3090.clone()).is_err());
        let bad_url = Custom {
            base_url: "gpu-box:11434".into(),
            ..box3090
        };
        assert!(add_custom(&mut s, "other", bad_url).is_err());
        assert_eq!(s.custom.len(), 1);
    }
}
