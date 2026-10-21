//! Models a client can offer: configured profiles plus whatever the local ollama has installed.

use crate::config::{Config, Profile, ProviderKind, ToolMode};
use crate::harness::{self, Caps, Tier};
use serde::Serialize;
use std::path::Path;
use std::time::Duration;

#[derive(Debug, Serialize)]
pub struct ModelEntry {
    /// What to pass to `--model` / `Op::SetModel`.
    pub spec: String,
    pub provider: ProviderKind,
    pub model: String,
    /// "config", "ollama", "tang", "apple", "server" (yours) or "remote" (turned on from a
    /// provider's catalog).
    pub source: &'static str,
    pub caps: Option<Caps>,
    pub tier: Tier,
    /// What `auto` would pick, given what's known.
    pub tool_mode: ToolMode,
    /// The provider's catalog entry (name, context, inputs, price), for remote models.
    pub info: Option<crate::catalog::Model>,
}

fn entry(spec: String, source: &'static str, p: &Profile) -> ModelEntry {
    let caps = harness::cached(p);
    let tier = harness::tier(p, caps.as_ref());
    ModelEntry {
        spec,
        provider: p.provider,
        model: p.model.clone(),
        source,
        tool_mode: harness::choose_mode(p, caps.as_ref(), tier),
        caps,
        tier,
        info: None,
    }
}

fn local_ollama() -> String {
    std::env::var("OLLAMA_HOST")
        .map(|h| {
            if h.starts_with("http") {
                h
            } else {
                format!("http://{h}")
            }
        })
        .unwrap_or_else(|_| "http://localhost:11434".into())
}

/// An OpenAI-compatible server's model ids (`GET /models`).
async fn server_models(base: &str, key: Option<String>) -> Vec<String> {
    let fetch = async {
        let mut req = reqwest::Client::new().get(format!("{}/models", base.trim_end_matches('/')));
        if let Some(k) = key {
            req = req.bearer_auth(k);
        }
        let v: serde_json::Value = req.send().await.ok()?.json().await.ok()?;
        Some(
            v["data"]
                .as_array()?
                .iter()
                .filter_map(|m| m["id"].as_str().map(String::from))
                .collect::<Vec<_>>(),
        )
    };
    tokio::time::timeout(Duration::from_secs(3), fetch)
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
}

async fn ollama_tags(base: &str) -> Vec<String> {
    let fetch = async {
        let v: serde_json::Value = reqwest::get(format!("{base}/api/tags"))
            .await
            .ok()?
            .json()
            .await
            .ok()?;
        Some(
            v["models"]
                .as_array()?
                .iter()
                .filter_map(|m| m["name"].as_str().map(String::from))
                // Embedding models can't chat.
                .filter(|n| !n.contains("embed"))
                .collect(),
        )
    };
    tokio::time::timeout(Duration::from_secs(3), fetch)
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
}

pub async fn list(cfg: &Config) -> Vec<ModelEntry> {
    let mut out: Vec<ModelEntry> = cfg
        .models
        .iter()
        .map(|(name, p)| entry(name.clone(), "config", p))
        .collect();
    for tag in ollama_tags(&local_ollama()).await {
        let spec = format!("ollama/{tag}");
        if out
            .iter()
            .any(|e| e.provider == ProviderKind::Ollama && e.model == tag)
        {
            continue;
        }
        if let Ok((_, p)) = cfg.resolve(Some(&spec)) {
            out.push(entry(spec, "ollama", &p));
        }
    }
    // Servers you added (a GPU box's ollama, vLLM, llama.cpp): everything they serve.
    let state = crate::providers::State::load();
    let servers = state.custom.iter().map(|(id, c)| async move {
        let names = match c.kind {
            ProviderKind::Ollama => ollama_tags(&c.base_url).await,
            _ => server_models(&c.base_url, crate::providers::key(id)).await,
        };
        names
            .into_iter()
            .map(|n| format!("{id}/{n}"))
            .collect::<Vec<_>>()
    });
    for spec in futures_util::future::join_all(servers)
        .await
        .into_iter()
        .flatten()
    {
        if let Ok((_, p)) = cfg.resolve(Some(&spec)) {
            out.push(entry(spec, "server", &p));
        }
    }
    // Models you turned on from connected providers, described by their catalogs.
    for spec in &state.enabled {
        if out.iter().any(|e| &e.spec == spec) {
            continue;
        }
        if let Ok((_, p)) = cfg.resolve(Some(spec)) {
            let mut e = entry(spec.clone(), "remote", &p);
            e.info = crate::catalog::cached(spec);
            out.push(e);
        }
    }
    let sidecars = local_checkpoints()
        .into_iter()
        .map(|repo| crate::providers::normalize(&format!("local/{repo}")))
        .filter(|_| crate::sidecar::available("tang"))
        .chain(
            crate::sidecar::available(crate::sidecar::APPLE).then(|| "apple/on-device".to_string()),
        );
    for spec in sidecars {
        if let Ok((_, p)) = cfg.resolve(Some(&spec)) {
            let source = if p.sidecar.as_deref() == Some(crate::sidecar::APPLE) {
                "apple"
            } else {
                "tang"
            };
            out.push(entry(spec, source, &p));
        }
    }
    out
}

/// Hugging Face repos in the local cache that tang-llm can run (Qwen3 dense, bf16 or MLX
/// 4-bit), as `org/name`.
fn local_checkpoints() -> Vec<String> {
    let hub = std::env::var_os("HF_HUB_CACHE")
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HF_HOME").map(|h| std::path::PathBuf::from(h).join("hub")))
        .or_else(|| dirs::home_dir().map(|h| h.join(".cache/huggingface/hub")))
        .unwrap_or_default();
    let Ok(entries) = std::fs::read_dir(&hub) else {
        return Vec::new();
    };
    let mut out: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let name = e
                .file_name()
                .to_string_lossy()
                .strip_prefix("models--")?
                .replace("--", "/");
            let snaps = std::fs::read_dir(e.path().join("snapshots")).ok()?;
            let runnable = snaps
                .filter_map(|s| s.ok())
                .any(|s| runnable_snapshot(&s.path()));
            runnable.then_some(name)
        })
        .collect();
    out.sort();
    out
}

/// A tang checkpoint needs its weights, Qwen config and tokenizer artifacts. A partial Hugging
/// Face download can have the first two, but tang cannot start without the tokenizer.
fn runnable_snapshot(dir: &Path) -> bool {
    let has_weights = std::fs::read_dir(dir).is_ok_and(|mut d| {
        d.any(|f| f.is_ok_and(|f| f.path().extension().is_some_and(|x| x == "safetensors")))
    });
    let cfg: Option<serde_json::Value> = std::fs::read(dir.join("config.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok());
    has_weights
        && dir.join("tokenizer.json").is_file()
        && dir.join("tokenizer_config.json").is_file()
        && cfg.is_some_and(|c| c["model_type"] == "qwen3")
}

/// The model a bare `frog` starts on when nothing names one (no `-m`, `FROG_MODEL`,
/// `default_model` or last pick): the first that would answer right now, and why it was
/// chosen. Order: this Mac first (frog's own engine, a running ollama or LM Studio, whose
/// pulled models are likely bigger than anything frog would pick, then Apple's on-device
/// model), then frog cloud when connected, then a cloud model you turned on, then Anthropic
/// with a key in the environment. None when nothing here can answer.
pub async fn pick_default() -> Option<(String, String)> {
    if crate::sidecar::available("tang") {
        return Some((
            crate::config::LOCAL_DEFAULT.into(),
            "frog's own engine".into(),
        ));
    }
    let base = local_ollama();
    let (ollama, lmstudio) = tokio::join!(
        ollama_tags(&base),
        server_models("http://localhost:1234/v1", None)
    );
    if let Some(tag) = best_local(&ollama) {
        return Some((format!("ollama/{tag}"), "running in ollama".into()));
    }
    if let Some(id) = best_local(&lmstudio) {
        return Some((format!("lmstudio/{id}"), "running in LM Studio".into()));
    }
    if crate::sidecar::available(crate::sidecar::APPLE) {
        return Some(("apple/on-device".into(), "Apple Intelligence".into()));
    }
    pick_remote(
        crate::providers::key_source(crate::providers::CLOUD).is_some(),
        crate::providers::State::load().enabled.into_iter().next(),
        std::env::var_os("ANTHROPIC_API_KEY").is_some(),
    )
}

/// After this Mac: a connected frog cloud, then a cloud model you turned on
/// (`--enable-model`), then Anthropic with a key in the environment.
fn pick_remote(
    cloud: bool,
    enabled: Option<String>,
    anthropic_env: bool,
) -> Option<(String, String)> {
    if cloud {
        let spec = crate::catalog::cloud_models()
            .into_iter()
            .next()
            .map_or_else(|| "cloud/qwen3-coder-next".to_string(), |m| m.spec);
        return Some((spec, "frog cloud is connected".into()));
    }
    if let Some(spec) = enabled {
        return Some((spec, "a cloud model you turned on".into()));
    }
    anthropic_env.then(|| {
        (
            "anthropic/claude-sonnet-5".into(),
            "ANTHROPIC_API_KEY is set".into(),
        )
    })
}

/// A coding model if one is installed, else the first chat model.
fn best_local(names: &[String]) -> Option<&String> {
    names
        .iter()
        .find(|n| n.to_lowercase().contains("coder"))
        .or_else(|| names.first())
}

/// The model last picked with `/model`, which a bare `frog` starts on.
pub fn last_used() -> Option<String> {
    let s = std::fs::read_to_string(crate::config::data_dir().join("last-model")).ok()?;
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    // One-time migration: a pick saved under an old provider id gets today's name.
    let new = crate::providers::normalize(s);
    if new != s {
        remember_last_used(&new);
    }
    Some(new)
}

pub fn remember_last_used(spec: &str) {
    let _ = std::fs::write(crate::config::data_dir().join("last-model"), spec);
}

#[cfg(test)]
mod pick_tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn best_local_prefers_coders() {
        let n = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            best_local(&n(&["llama3", "qwen3-coder:30b"])).map(String::as_str),
            Some("qwen3-coder:30b")
        );
        assert_eq!(
            best_local(&n(&["llama3"])).map(String::as_str),
            Some("llama3")
        );
        assert_eq!(best_local(&[]), None);
    }

    #[test]
    fn default_prefers_cloud_over_enabled_anthropic() {
        let enabled = Some("anthropic/claude-sonnet-5".to_string());
        let (spec, _) = pick_remote(true, enabled.clone(), true).unwrap();
        assert!(spec.starts_with("cloud/"), "{spec}");
        let (spec, _) = pick_remote(false, enabled, true).unwrap();
        assert_eq!(spec, "anthropic/claude-sonnet-5");
        assert_eq!(pick_remote(false, None, false), None);
    }

    #[test]
    fn checkpoint_requires_tokenizer_artifacts() {
        let dir = std::env::temp_dir().join(format!(
            "frog-models-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("config.json"), r#"{"model_type":"qwen3"}"#).unwrap();
        std::fs::write(dir.join("model.safetensors"), []).unwrap();
        assert!(!runnable_snapshot(&dir));
        std::fs::write(dir.join("tokenizer.json"), "{}").unwrap();
        std::fs::write(dir.join("tokenizer_config.json"), "{}").unwrap();
        assert!(runnable_snapshot(&dir));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
