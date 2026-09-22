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
    out
}
