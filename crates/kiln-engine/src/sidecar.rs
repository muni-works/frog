//! The bundled inference sidecar: `tang-llm serve`, an OpenAI-compatible server running models
//! on tang's Metal backend. `tang/<model>` profiles start it on demand and share one instance:
//! if it's already serving the requested model it's reused, otherwise it's restarted.

use crate::config::{Profile, data_dir};
use anyhow::{Context, Result, bail};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const PORT: u16 = 8911;

pub fn base_url() -> String {
    format!("http://127.0.0.1:{PORT}/v1")
}

/// `KILN_TANG_BIN`, else `tang-llm` next to this executable (the app bundles it), else `$PATH`.
fn binary() -> PathBuf {
    if let Some(p) = std::env::var_os("KILN_TANG_BIN") {
        return p.into();
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
        && dir.join("tang-llm").exists()
    {
        return dir.join("tang-llm");
    }
    "tang-llm".into()
}

fn pid_file() -> PathBuf {
    data_dir().join("tang-llm.pid")
}

pub fn log_file() -> PathBuf {
    data_dir().join("tang-llm.log")
}

/// The model the sidecar is serving right now, if it's up.
async fn serving() -> Option<String> {
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .ok()?;
    let v: serde_json::Value = http
        .get(format!("{}/models", base_url()))
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;
    v["data"][0]["id"].as_str().map(String::from)
}

fn stop() {
    if let Ok(pid) = std::fs::read_to_string(pid_file())
        && let Ok(pid) = pid.trim().parse::<i32>()
    {
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
    }
    let _ = std::fs::remove_file(pid_file());
}

pub async fn is_serving(model: &str) -> bool {
    serving().await.as_deref() == Some(model)
}

/// Make sure the sidecar is serving `p.sidecar`, starting or restarting it if needed.
pub async fn ensure(p: &Profile) -> Result<()> {
    let Some(model) = &p.sidecar else {
        return Ok(());
    };
    match serving().await {
        Some(m) if &m == model => return Ok(()),
        Some(_) => {
            stop();
            // Give the old one a moment to release the port.
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        None => {}
    }
    std::fs::create_dir_all(data_dir())?;
    let log = std::fs::File::create(log_file())?;
    let mut cmd = Command::new(binary());
    cmd.args(["serve", model, "--port", &PORT.to_string()])
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    if let Some(n) = p.context_window {
        cmd.args(["--ctx", &n.to_string()]);
    }
    // Its own session: it outlives this engine, and later engines reuse it.
    unsafe {
        use std::os::unix::process::CommandExt;
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let mut child = cmd
        .spawn()
        .with_context(|| format!("starting {} (set KILN_TANG_BIN?)", binary().display()))?;
    std::fs::write(pid_file(), child.id().to_string())?;

    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(300) {
        if serving().await.as_deref() == Some(model.as_str()) {
            return Ok(());
        }
        // Exited early: surface the reason from the log.
        if child.try_wait()?.is_some() {
            let log = std::fs::read_to_string(log_file()).unwrap_or_default();
            let tail: Vec<&str> = log.lines().rev().take(5).collect();
            bail!(
                "tang-llm exited: {}",
                tail.into_iter().rev().collect::<Vec<_>>().join("\n")
            );
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    bail!(
        "tang-llm didn't come up within 5 minutes (see {})",
        log_file().display()
    )
}
