//! Models a client can offer: configured profiles plus whatever the local ollama has installed.

use crate::config::{Config, Profile, ProviderKind, ToolMode};
use crate::harness::{self, Caps, Tier};
use serde::Serialize;
use std::time::Duration;

#[derive(Debug, Serialize)]
pub struct ModelEntry {
    /// What to pass to `--model` / `Op::SetModel`.
    pub spec: String,
    pub provider: ProviderKind,
    pub model: String,
    /// "config" or "ollama".
    pub source: &'static str,
    pub caps: Option<Caps>,
    pub tier: Tier,
    /// What `auto` would pick, given what's known.
    pub tool_mode: ToolMode,
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
    }
}

async fn ollama_tags() -> Vec<String> {
    let base = std::env::var("OLLAMA_HOST")
        .map(|h| {
            if h.starts_with("http") {
                h
            } else {
                format!("http://{h}")
            }
        })
        .unwrap_or_else(|_| "http://localhost:11434".into());
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
    tokio::time::timeout(Duration::from_secs(2), fetch)
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
    for tag in ollama_tags().await {
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
    let sidecars = local_checkpoints()
        .into_iter()
        .map(|repo| format!("tang/{repo}"))
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
            let runnable = snaps.filter_map(|s| s.ok()).any(|s| {
                let dir = s.path();
                let has_weights = std::fs::read_dir(&dir).is_ok_and(|mut d| {
                    d.any(|f| {
                        f.is_ok_and(|f| f.path().extension().is_some_and(|x| x == "safetensors"))
                    })
                });
                let cfg: Option<serde_json::Value> = std::fs::read(dir.join("config.json"))
                    .ok()
                    .and_then(|b| serde_json::from_slice(&b).ok());
                has_weights && cfg.is_some_and(|c| c["model_type"] == "qwen3")
            });
            runnable.then_some(name)
        })
        .collect();
    out.sort();
    out
}
