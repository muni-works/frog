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

/// Started for the Mac app (`FROG_APP_PID` set), a sidecar goes when the app does — even on a
/// crash or SIGKILL. `tang-llm` can't watch the pid itself, so a detached `/bin/sh` loop does:
/// it terminates the sidecar once the app's pid is gone, and ends when the sidecar does.
/// (`frog-apple` watches `FROG_APP_PID` on its own.) From the CLI, nothing changes: the
/// sidecar outlives the engine so later sessions reuse it.
fn watch_app(child: u32) {
    let Some(app) = std::env::var("FROG_APP_PID")
        .ok()
        .and_then(|p| p.parse::<u32>().ok())
    else {
        return;
    };
    let mut cmd = Command::new("/bin/sh");
    cmd.args(["-c", WATCH, "frog-parent-watch", &app.to_string(), &child.to_string()])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // Its own session, like the sidecar, so it survives this engine.
    unsafe {
        use std::os::unix::process::CommandExt;
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let _ = cmd.spawn();
}

/// The watch loop: `$1` the app, `$2` the sidecar (same as the Mac app's `ParentWatch`).
const WATCH: &str = r#"p=$1 c=$2
while kill -0 "$c" 2>/dev/null; do
  if ! kill -0 "$p" 2>/dev/null; then
    kill -TERM "$c" 2>/dev/null; sleep 3; kill -KILL "$c" 2>/dev/null; exit 0
  fi
  sleep 1
done"#;

fn kind(model: &str) -> &'static Kind {
    if model == APPLE { &APPLE_KIND } else { &TANG }
}

/// The bearer token `frog-apple` requires, from `<data dir>/frog-apple.token` (owner-only),
/// made on first use. A file, not per-engine, because later engines reuse the running sidecar.
pub fn apple_token() -> Option<String> {
    use std::io::{Read, Write};
    use std::os::unix::fs::OpenOptionsExt;
    let path = data_dir().join("frog-apple.token");
    if let Ok(t) = std::fs::read_to_string(&path)
        && t.trim().len() >= 32
    {
        return Some(t.trim().to_string());
    }
    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .ok()?
        .read_exact(&mut bytes)
        .ok()?;
    let token: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    std::fs::create_dir_all(data_dir()).ok()?;
    let _ = std::fs::remove_file(&path);
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .ok()?;
    f.write_all(token.as_bytes()).ok()?;
    Some(token)
}

pub fn base_url(model: &str) -> String {
    format!("http://127.0.0.1:{}/v1", kind(model).port)
}

/// `$FROG_*_BIN`, else next to this executable (the app bundles them), else where `frog setup`
/// installs them (`~/.local/share/frog/bin`), else `$PATH`.
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
    let installed = crate::setup::bin_dir().join(k.bin);
    if installed.exists() {
        return installed;
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
    let mut req = http.get(format!("http://127.0.0.1:{}/v1/models", k.port));
    if k.bin == APPLE_KIND.bin
        && let Some(t) = apple_token()
    {
        req = req.bearer_auth(t);
    }
    let v: serde_json::Value = req.send().await.ok()?.json().await.ok()?;
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
    } else {
        cmd.env(
            "FROG_APPLE_TOKEN",
            apple_token().context("making frog-apple's token")?,
        );
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
    if model != APPLE && !crate::setup::model_present(model) {
        bail!("{model} isn't downloaded; run `frog setup` (or `frog setup {model}`)");
    }
    let mut child = cmd.spawn().with_context(|| {
        if model == APPLE {
            format!("starting {} (set {}?)", bin.display(), k.env)
        } else {
            format!(
                "starting {} (run `frog setup` to install it, or set {})",
                bin.display(),
                k.env
            )
        }
    })?;
    std::fs::write(pid_file(k), child.id().to_string())?;
    if model != APPLE {
        watch_app(child.id());
    }

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

#[cfg(test)]
mod tests {
    use super::*;

    /// The watch loop ends the sidecar once the app's pid is gone (a stand-in `sleep` for each).
    #[test]
    fn watch_ends_the_sidecar_when_the_app_dies() {
        let mut app = Command::new("sleep").arg("60").spawn().unwrap();
        let mut sidecar = Command::new("sleep").arg("60").spawn().unwrap();
        let mut watch = Command::new("/bin/sh")
            .args(["-c", WATCH, "w", &app.id().to_string(), &sidecar.id().to_string()])
            .spawn()
            .unwrap();
        std::thread::sleep(Duration::from_millis(300));
        assert!(sidecar.try_wait().unwrap().is_none(), "alive while the app is");
        app.kill().unwrap();
        app.wait().unwrap();
        let start = Instant::now();
        while sidecar.try_wait().unwrap().is_none() {
            assert!(start.elapsed() < Duration::from_secs(5), "the sidecar outlived the app");
            std::thread::sleep(Duration::from_millis(100));
        }
        watch.wait().unwrap();
    }

    /// And it ends on its own when the sidecar exits first.
    #[test]
    fn watch_ends_when_the_sidecar_does() {
        let mut sidecar = Command::new("sleep").arg("60").spawn().unwrap();
        let mut watch = Command::new("/bin/sh")
            .args(["-c", WATCH, "w", &std::process::id().to_string(), &sidecar.id().to_string()])
            .spawn()
            .unwrap();
        sidecar.kill().unwrap();
        sidecar.wait().unwrap();
        let start = Instant::now();
        while watch.try_wait().unwrap().is_none() {
            assert!(start.elapsed() < Duration::from_secs(5), "the watch outlived the sidecar");
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}
