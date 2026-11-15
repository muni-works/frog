//! `frog setup`: get a clean Mac to a working local model. Installs the `tang-llm` sidecar into
//! `~/.local/share/frog/bin` (where `sidecar::binary` looks) and downloads the default model's
//! weights into the Hugging Face cache, where tang-llm resolves `org/name` specs.

use crate::config::data_dir;
use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The model a bare `frog` starts on (see `models::pick_default`).
pub const DEFAULT_MODEL: &str = "mlx-community/Qwen3-4B-4bit";

const TANG_GIT: &str = "https://github.com/muni-works/tang";

// Prebuilt tang-llm release asset URL. The asset must be built with:
//   cargo build --release -p tang-llm --features metal
// and signed (Developer ID or ad-hoc) for Apple silicon.
//
//
const TANG_RELEASE: &str =
    "https://github.com/muni-works/tang/releases/latest/download/tang-llm-aarch64-apple-darwin.tar.gz";

/// Where setup installs sidecars; `sidecar::binary` checks it after `$FROG_*_BIN` and the
/// directory next to `frog`.
pub fn bin_dir() -> PathBuf {
    data_dir().join("bin")
}

/// The Hugging Face hub cache, the same lookup tang-llm uses.
pub fn hf_hub_dir() -> PathBuf {
    std::env::var_os("HF_HUB_CACHE")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HF_HOME").map(|h| PathBuf::from(h).join("hub")))
        .or_else(|| dirs::home_dir().map(|h| h.join(".cache/huggingface/hub")))
        .unwrap_or_default()
}

/// Whether `repo` (`org/name`) has a snapshot with weights and a tokenizer in the cache.
pub fn model_present(repo: &str) -> bool {
    if Path::new(repo).is_dir() {
        return true;
    }
    let snaps = hf_hub_dir()
        .join(format!("models--{}", repo.replace('/', "--")))
        .join("snapshots");
    std::fs::read_dir(snaps).is_ok_and(|d| {
        d.filter_map(|s| s.ok()).any(|s| {
            let p = s.path();
            p.join("tokenizer.json").is_file()
                && std::fs::read_dir(&p).is_ok_and(|mut f| {
                    f.any(|f| {
                        f.is_ok_and(|f| f.path().extension().is_some_and(|x| x == "safetensors"))
                    })
                })
        })
    })
}

pub async fn run(model: Option<&str>) -> Result<()> {
    if !(cfg!(target_os = "macos") && cfg!(target_arch = "aarch64")) {
        bail!(
            "frog setup installs tang-llm for Apple silicon Macs; elsewhere use ollama or a server"
        );
    }
    if crate::sidecar::available("tang") {
        println!("tang-llm: installed");
    } else {
        install_tang().await?;
    }
    let repo = model.unwrap_or(DEFAULT_MODEL);
    if model_present(repo) {
        println!("{repo}: downloaded");
    } else {
        download_model(repo).await?;
    }
    println!("ready. try: frog -p \"reply with just: ok\"");
    Ok(())
}

async fn install_tang() -> Result<()> {
    let dir = bin_dir();
    std::fs::create_dir_all(&dir)?;
    println!("tang-llm: fetching a prebuilt binary");
    match fetch_prebuilt(&dir).await {
        Ok(()) => return Ok(()),
        Err(e) => println!("tang-llm: no prebuilt binary ({e:#}); building from source"),
    }
    if Command::new("cargo").arg("--version").output().is_err() {
        bail!(
            "building tang-llm needs Rust: install it from https://rustup.rs, then run `frog setup` again"
        );
    }
    // --root data_dir puts the binary in data_dir/bin.
    let ok = Command::new("cargo")
        .args(["install", "--locked", "--git", TANG_GIT, "tang-llm"])
        .args(["--features", "metal", "--root"])
        .arg(data_dir())
        .status()
        .context("running cargo install")?
        .success();
    if !ok {
        bail!("cargo install tang-llm failed (see above)");
    }
    println!("tang-llm: installed to {}", dir.display());
    Ok(())
}

async fn fetch_prebuilt(dir: &Path) -> Result<()> {
    let resp = reqwest::get(TANG_RELEASE).await?.error_for_status()?;
    let bytes = resp.bytes().await?;
    // The release ships `<asset>.sha256` ("<hex>  <name>"); refuse anything that doesn't match.
    let sums = reqwest::get(format!("{TANG_RELEASE}.sha256"))
        .await?
        .error_for_status()?
        .text()
        .await?;
    let want = sums.split_whitespace().next().unwrap_or("").to_lowercase();
    let got: String = {
        use sha2::{Digest, Sha256};
        Sha256::digest(&bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    };
    if want != got {
        bail!("tang-llm download failed its checksum (expected {want}, got {got})");
    }
    let tmp = dir.join("tang-llm.tar.gz");
    std::fs::write(&tmp, &bytes)?;
    let ok = Command::new("tar")
        .arg("-xzf")
        .arg(&tmp)
        .arg("-C")
        .arg(dir)
        .status()?
        .success();
    let _ = std::fs::remove_file(&tmp);
    if !ok || !dir.join("tang-llm").is_file() {
        bail!("the release archive didn't contain tang-llm");
    }
    unquarantine(&dir.join("tang-llm"));
    println!("tang-llm: installed to {}", dir.display());
    Ok(())
}

/// Let an unsigned build run. A reqwest download carries no quarantine attribute, but clear it
/// anyway, and give the binary an ad-hoc signature if it has none (Apple silicon won't run
/// unsigned code). Signed, notarized builds pass `codesign -v` and are left alone.
fn unquarantine(bin: &Path) {
    let _ = Command::new("xattr")
        .args(["-d", "com.apple.quarantine"])
        .arg(bin)
        .stderr(std::process::Stdio::null())
        .status();
    let signed = Command::new("codesign")
        .arg("-v")
        .arg(bin)
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    if !signed {
        let _ = Command::new("codesign")
            .args(["-s", "-", "-f"])
            .arg(bin)
            .stderr(std::process::Stdio::null())
            .status();
    }
}

/// Download `repo`'s files into the hub cache layout tang-llm reads:
/// `models--org--name/snapshots/<sha>/<file>` plus `refs/main`.
async fn download_model(repo: &str) -> Result<()> {
    let http = reqwest::Client::new();
    let info: serde_json::Value = http
        .get(format!("https://huggingface.co/api/models/{repo}"))
        .send()
        .await?
        .error_for_status()
        .with_context(|| format!("looking up {repo} on Hugging Face"))?
        .json()
        .await?;
    let sha = info["sha"]
        .as_str()
        .context("no revision in the model info")?;
    let files: Vec<&str> = info["siblings"]
        .as_array()
        .map(|s| s.iter().filter_map(|f| f["rfilename"].as_str()).collect())
        .unwrap_or_default();
    let root = hf_hub_dir().join(format!("models--{}", repo.replace('/', "--")));
    let snap = root.join("snapshots").join(sha);
    std::fs::create_dir_all(&snap)?;
    std::fs::create_dir_all(root.join("refs"))?;
    println!("{repo}: downloading {} files", files.len());
    for f in files {
        let dest = snap.join(f);
        if dest.is_file() {
            continue;
        }
        if let Some(p) = dest.parent() {
            std::fs::create_dir_all(p)?;
        }
        let url = format!("https://huggingface.co/{repo}/resolve/{sha}/{f}");
        fetch(&http, &url, &dest, f).await?;
    }
    std::fs::write(root.join("refs/main"), sha)?;
    Ok(())
}

async fn fetch(http: &reqwest::Client, url: &str, dest: &Path, name: &str) -> Result<()> {
    let resp = http.get(url).send().await?.error_for_status()?;
    let total = resp.content_length().unwrap_or(0);
    let mut part = dest.as_os_str().to_owned();
    part.push(".part");
    let part = PathBuf::from(part);
    let mut out = std::fs::File::create(&part)?;
    let mut got = 0u64;
    let mut shown = 0u64;
    let mut body = resp.bytes_stream();
    while let Some(chunk) = body.next().await {
        let chunk = chunk?;
        out.write_all(&chunk)?;
        got += chunk.len() as u64;
        if got - shown >= 16 << 20 {
            shown = got;
            let pct = if total > 0 { got * 100 / total } else { 0 };
            print!("\r  {name}: {} / {} MB ({pct}%)", got >> 20, total >> 20);
            let _ = std::io::stdout().flush();
        }
    }
    println!("\r  {name}: {} MB          ", got >> 20);
    std::fs::rename(&part, dest)?;
    Ok(())
}
