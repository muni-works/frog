//! Bundled inference sidecars, OpenAI-compatible servers frog starts on demand:
//!
//! - `tang-llm serve`: open-weight models on tang's Metal backend (`tang/<model>` profiles).
//!   One shared instance; reused if it's already serving the requested model, else restarted.
//! - `frog-apple`: Apple's on-device Foundation Model (`apple/...` profiles).
//!
//! Each outlives the engine that started it, so later sessions reuse it.

use crate::config::{Profile, data_dir};
use anyhow::{Context, Result, bail};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// `Profile::sidecar` value for the Apple sidecar; anything else is a tang model.
pub const APPLE: &str = "apple";

struct Kind {
    bin: &'static str,
    env: &'static str,
    port: u16,
}

const TANG: Kind = Kind {
    bin: "tang-llm",
    env: "FROG_TANG_BIN",
    port: 8911,
};
const APPLE_KIND: Kind = Kind {
    bin: "frog-apple",
    env: "FROG_APPLE_BIN",
    port: 8912,
};

const DESKTOP: Kind = Kind {
    bin: "frog-desktop",
    env: "FROG_DESKTOP_BIN",
    port: 0,
};

/// The computer-use MCP server, if it's bundled, configured or on `PATH`.
pub fn desktop() -> Option<PathBuf> {
    let bin = binary(&DESKTOP);
    if bin.is_absolute() {
        return bin.exists().then_some(bin);
    }
    std::env::var_os("PATH").and_then(|p| {
        std::env::split_paths(&p)
            .map(|d| d.join(&bin))
            .find(|c| c.exists())
    })
}

fn kind(model: &str) -> &'static Kind {
    if model == APPLE { &APPLE_KIND } else { &TANG }
}

pub fn base_url(model: &str) -> String {
    format!("http://127.0.0.1:{}/v1", kind(model).port)
}

/// `$FROG_*_BIN`, else next to this executable (the app bundles them), else `$PATH`.
fn binary(k: &Kind) -> PathBuf {
    if let Some(p) = std::env::var_os(k.env) {
        return p.into();
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
        && dir.join(k.bin).exists()
    {
        return dir.join(k.bin);
    }
    k.bin.into()
}

/// Whether the sidecar for `model` can be started (its binary is configured, bundled, or on
/// `PATH`, and for Apple's model, this is macOS 26+ where the framework exists).
pub fn available(model: &str) -> bool {
    let k = kind(model);
    if model == APPLE
        && !std::path::Path::new("/System/Library/Frameworks/FoundationModels.framework").exists()
    {
        return false;
    }
    let bin = binary(k);
    if bin.is_absolute() {
        return bin.exists();
    }
    std::env::var_os("PATH")
        .is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(&bin).exists()))
}

fn pid_file(k: &Kind) -> PathBuf {
    data_dir().join(format!("{}.pid", k.bin))
}

pub fn log_file(model: &str) -> PathBuf {
    data_dir().join(format!("{}.log", kind(model).bin))
}

/// The model the sidecar on `k`'s port is serving right now, if it's up.
async fn serving(k: &Kind) -> Option<String> {
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .ok()?;
    let v: serde_json::Value = http
        .get(format!("http://127.0.0.1:{}/v1/models", k.port))
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;
    v["data"][0]["id"].as_str().map(String::from)
}

fn stop(k: &Kind) {
    if let Ok(pid) = std::fs::read_to_string(pid_file(k))
        && let Ok(pid) = pid.trim().parse::<i32>()
    {
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
    }
    let _ = std::fs::remove_file(pid_file(k));
}

pub async fn is_serving(model: &str) -> bool {
    serving(kind(model)).await.as_deref() == Some(model)
}

/// Make sure the sidecar for `p.sidecar` is up and serving it, starting or restarting it.
pub async fn ensure(p: &Profile) -> Result<()> {
    let Some(model) = &p.sidecar else {
        return Ok(());
    };
    let k = kind(model);
    match serving(k).await {
        Some(m) if &m == model => return Ok(()),
        Some(_) => {
            stop(k);
            // Give the old one a moment to release the port.
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        None => {}
    }
    std::fs::create_dir_all(data_dir())?;
    let log = std::fs::File::create(log_file(model))?;
    let bin = binary(k);
    let mut cmd = Command::new(&bin);
    if model != APPLE {
        cmd.args(["serve", model]);
        if let Some(n) = p.context_window {
            cmd.args(["--ctx", &n.to_string()]);
        }
        // A KV cache per conversation, as many as fit, so switching back to one doesn't
        // re-prefill it. An environment variable, which older builds ignore.
        cmd.env("TANG_KV_SLOTS", "auto");
        if let Some(d) = &p.draft_model {
            cmd.env("TANG_DRAFT_MODEL", d);
        }
    }
    cmd.args(["--port", &k.port.to_string()])
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    // Its own session, so it outlives this engine.
    unsafe {
        use std::os::unix::process::CommandExt;
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let mut child = cmd
        .spawn()
        .with_context(|| format!("starting {} (set {}?)", bin.display(), k.env))?;
    std::fs::write(pid_file(k), child.id().to_string())?;

    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(300) {
        if serving(k).await.as_deref() == Some(model.as_str()) {
            return Ok(());
        }
        // Exited early: surface the reason from the log.
        if child.try_wait()?.is_some() {
            let log = std::fs::read_to_string(log_file(model)).unwrap_or_default();
            let tail: Vec<&str> = log.lines().rev().take(5).collect();
            bail!(
                "{} exited: {}",
                k.bin,
                tail.into_iter().rev().collect::<Vec<_>>().join("\n")
            );
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    bail!(
        "{} didn't come up within 5 minutes (see {})",
        k.bin,
        log_file(model).display()
    )
}
