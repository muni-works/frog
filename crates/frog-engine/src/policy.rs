//! Whether a project's code may go to cloud models. The answer belongs to a folder and
//! everything under it, is kept in `~/.config/frog/projects.json`, and is enforced here, where
//! models are chosen, so every client (the app, the terminal, ACP) keeps the same promise.
//! See docs/models.md.

use crate::config::{Profile, ProviderKind, config_dir};
use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::net::IpAddr;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Cloud {
    /// Not decided: clients ask before the first cloud turn.
    #[default]
    Ask,
    Allow,
    /// Keep the project's code on your devices: cloud models are refused.
    Deny,
}

#[derive(Default, Serialize, Deserialize)]
struct Projects {
    /// Folder path → its answer. The nearest folder with an answer decides.
    #[serde(default)]
    cloud: BTreeMap<String, Cloud>,
}

fn path() -> PathBuf {
    config_dir().join("projects.json")
}

fn load(file: &Path) -> Projects {
    std::fs::read(file)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

fn canonical(dir: &Path) -> PathBuf {
    dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf())
}

fn cloud_in(p: &Projects, dir: &Path) -> Cloud {
    canonical(dir)
        .ancestors()
        .find_map(|a| p.cloud.get(a.to_string_lossy().as_ref()).copied())
        .unwrap_or_default()
}

/// This folder's answer, inherited from the nearest folder above it that has one.
pub fn cloud(dir: &Path) -> Cloud {
    cloud_in(&load(&path()), dir)
}

fn set_in(file: &Path, dir: &Path, c: Cloud) -> Result<()> {
    let mut p = load(file);
    let key = canonical(dir).to_string_lossy().into_owned();
    if c == Cloud::Ask {
        p.cloud.remove(&key);
    } else {
        p.cloud.insert(key, c);
    }
    if let Some(parent) = file.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(file, serde_json::to_vec_pretty(&p)?)?;
    Ok(())
}

/// Record this folder's answer (`Ask` forgets it).
pub fn set_cloud(dir: &Path, c: Cloud) -> Result<()> {
    set_in(&path(), dir, c)
}

/// Whether a model sends what it's given off your devices: a hosted API, or any server that
/// isn't this Mac, a `.local` name or a private address. frog's own engine never does.
pub fn is_cloud(p: &Profile) -> bool {
    if p.sidecar.is_some() {
        return false;
    }
    match &p.base_url {
        // The hosted APIs; Ollama's default is this Mac.
        None => matches!(p.provider, ProviderKind::Anthropic | ProviderKind::Openai),
        Some(url) => !reqwest::Url::parse(url)
            .ok()
            .and_then(|u| u.host_str().map(str::to_owned))
            .is_some_and(|h| is_private_host(&h)),
    }
}

fn is_private_host(host: &str) -> bool {
    let h = host.trim_start_matches('[').trim_end_matches(']').to_ascii_lowercase();
    if h == "localhost" || h.ends_with(".local") || h.ends_with(".localhost") || !h.contains('.') && h.parse::<IpAddr>().is_err() {
        // Bare names ("mew", "gpu-box") resolve on your own network.
        return true;
    }
    match h.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => ip.is_loopback() || ip.is_private() || ip.is_link_local() || {
            // Tailscale's CGNAT range: your own devices, reached over your tailnet.
            let [a, b, ..] = ip.octets();
            a == 100 && (64..128).contains(&b)
        },
        Ok(IpAddr::V6(ip)) => ip.is_loopback() || (ip.segments()[0] & 0xfe00) == 0xfc00 || (ip.segments()[0] & 0xffc0) == 0xfe80,
        Err(_) => h.ends_with(".ts.net") || h.ends_with(".lan") || h.ends_with(".home.arpa"),
    }
}

/// Refuse a cloud model in a folder that keeps its code on your devices.
pub fn check(dir: &Path, name: &str, profile: &Profile) -> Result<()> {
    if is_cloud(profile) && cloud(dir) == Cloud::Deny {
        bail!(
            "{name} is a cloud model, and this project keeps its code on your devices. Allow cloud models for it to use one."
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(provider: ProviderKind, base_url: Option<&str>) -> Profile {
        let mut p: Profile = serde_json::from_value(serde_json::json!({
            "provider": match provider { ProviderKind::Openai => "openai", ProviderKind::Anthropic => "anthropic", ProviderKind::Ollama => "ollama" },
            "model": "m",
        }))
        .unwrap();
        p.base_url = base_url.map(str::to_owned);
        p
    }

    #[test]
    fn where_models_run() {
        assert!(is_cloud(&profile(ProviderKind::Anthropic, None)));
        assert!(is_cloud(&profile(ProviderKind::Openai, None)));
        assert!(is_cloud(&profile(ProviderKind::Openai, Some("https://openrouter.ai/api/v1"))));
        assert!(!is_cloud(&profile(ProviderKind::Ollama, None)));
        for local in [
            "http://localhost:11434",
            "http://127.0.0.1:8080/v1",
            "http://mew:8000/v1",
            "http://gpu-box.local:8000/v1",
            "http://192.168.1.20:8000/v1",
            "http://10.0.0.5/v1",
            "http://100.101.102.103:8000/v1",
            "http://mew.tail1234.ts.net:8000/v1",
            "http://[::1]:8000/v1",
        ] {
            assert!(!is_cloud(&profile(ProviderKind::Openai, Some(local))), "{local}");
        }
        let mut sidecar = profile(ProviderKind::Openai, Some("http://127.0.0.1:9000/v1"));
        sidecar.sidecar = Some("mlx-community/Qwen3-4B-4bit".into());
        assert!(!is_cloud(&sidecar));
    }

    #[test]
    fn nearest_folder_decides() {
        let tmp = tempdir();
        let file = tmp.join("projects.json");
        let project = tmp.join("kiln");
        let sub = project.join("apps/macos");
        std::fs::create_dir_all(&sub).unwrap();
        assert_eq!(cloud_in(&load(&file), &sub), Cloud::Ask);
        set_in(&file, &project, Cloud::Deny).unwrap();
        assert_eq!(cloud_in(&load(&file), &sub), Cloud::Deny);
        set_in(&file, &sub, Cloud::Allow).unwrap();
        assert_eq!(cloud_in(&load(&file), &sub), Cloud::Allow);
        assert_eq!(cloud_in(&load(&file), &project), Cloud::Deny);
        set_in(&file, &project, Cloud::Ask).unwrap();
        assert_eq!(cloud_in(&load(&file), &project), Cloud::Ask);
        let _ = std::fs::remove_dir_all(tmp);
    }

    fn tempdir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("frog-policy-{}-{}", std::process::id(), line!()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }
}
