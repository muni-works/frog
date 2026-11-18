//! Bundled inference sidecars, OpenAI-compatible servers frog starts on demand:
//!
//! - `tang-llm serve`: open-weight models on tang's Metal backend (`tang/<model>` profiles).
//!   One shared instance; reused if it's already serving the requested model, else restarted.
//! - `frog-apple`: Apple's on-device Foundation Model (`apple/...` profiles).
//!
//! Each outlives the engine that started it, so later sessions reuse it; started for the Mac
//! app, each goes when the app does. Starting one has a deadline, and a port held by anything
//! but this frog's own sidecar is never waited on (see [`launch`]).

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

/// Where `model`'s sidecar is served. Read when it's used: the Apple sidecar's port can move.
pub fn base_url(model: &str) -> String {
    format!("http://127.0.0.1:{}/v1", port(kind(model)))
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

/// Where this data dir's Apple sidecar listens: the port it was last started on, else 8912.
/// It moves off 8912 when something else holds that port (another Frog's sidecar, a test run's,
/// any other program), so it's written down for the engines that reuse it.
fn port_file(k: &Kind) -> PathBuf {
    data_dir().join(format!("{}.port", k.bin))
}

fn port(k: &Kind) -> u16 {
    if k.bin != APPLE_KIND.bin {
        return k.port;
    }
    std::fs::read_to_string(port_file(k))
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(k.port)
}

/// `FROG_SIDECARS`: `off` never starts one (the Mac test host sets it, so a test run can't
/// put a sidecar on a port the real app uses); `ephemeral` starts the Apple sidecar on a port
/// the OS picks instead of 8912 (for a test that needs a real one).
fn mode() -> String {
    std::env::var("FROG_SIDECARS").unwrap_or_default()
}

/// Sidecars are off for this process (`FROG_SIDECARS=off`).
pub fn off() -> bool {
    mode() == "off"
}

/// What the person sees for `model`: "Apple Intelligence", or a downloaded model's name.
pub fn display_name(model: &str) -> String {
    if model == APPLE {
        return "Apple Intelligence".into();
    }
    let name = model.rsplit('/').next().unwrap_or(model);
    let name = ["-MLX-4bit", "-MLX-8bit", "-4bit", "-8bit", "-bf16", "-MLX"]
        .iter()
        .find_map(|t| name.strip_suffix(t))
        .unwrap_or(name);
    name.replace('-', " ")
}

/// The progress label while `model`'s sidecar gets ready. A downloaded model is read into
/// memory (`loading <repo>`; the app names it); Apple's is the system's own and only started.
pub fn activity(model: &str) -> String {
    if model == APPLE {
        "starting Apple Intelligence".into()
    } else {
        format!("loading {model}")
    }
}

/// Why a sidecar couldn't be made ready. Its text is the line the turn ends with: what
/// happened, and what to do.
#[derive(Debug, Clone, PartialEq)]
pub enum StartError {
    /// `FROG_SIDECARS=off`.
    Off { name: String },
    /// The port is held by something that isn't this frog's sidecar, and this sidecar can't
    /// move (tang's port is fixed: the app and paired nodes reach it there).
    PortTaken { name: String, port: u16, by: String },
    /// The sidecar is up, but the system model behind it can't run: the system's reason.
    Unavailable { reason: String },
    /// It exited while starting.
    Exited { name: String, detail: String },
    /// It didn't answer within its deadline.
    Timeout {
        name: String,
        after: Duration,
        log: PathBuf,
    },
}

impl std::fmt::Display for StartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Off { name } => write!(
                f,
                "{name} can't start here: local models are off in this process (FROG_SIDECARS=off)."
            ),
            Self::PortTaken { name, port, by } => write!(
                f,
                "{name} can't start: port {port} is in use by {by}. Quit whatever is using it and send your message again, or pick another model."
            ),
            Self::Unavailable { reason } => write!(f, "{reason}"),
            Self::Exited { name, detail } => write!(
                f,
                "{name} stopped while starting ({detail}). Send your message again to retry, or pick another model."
            ),
            Self::Timeout { name, after, log } => write!(
                f,
                "{name} didn't start within {} seconds (log: {}). Send your message again to retry, or pick another model.",
                after.as_secs(),
                log.display()
            ),
        }
    }
}

impl std::error::Error for StartError {}

/// What answers on a port.
#[derive(Debug, PartialEq)]
enum Probe {
    /// Nothing: the port is free.
    Free,
    /// One of this frog's sidecars, serving `model`. `unavailable`: the system model behind
    /// it can't run, and why (frog-apple reports it).
    Ours {
        model: String,
        unavailable: Option<String>,
    },
    /// Something else, and what it looks like.
    Foreign(String),
}

/// Ask what's on `port`: a token-authenticated `/v1/models`, the way frog's own client asks.
async fn probe(port: u16, token: Option<&str>) -> Probe {
    let Ok(http) = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .redirect(reqwest::redirect::Policy::none())
        .build()
    else {
        return Probe::Foreign("an unknown server".into());
    };
    let mut req = http.get(format!("http://127.0.0.1:{port}/v1/models"));
    if let Some(t) = token {
        req = req.bearer_auth(t);
    }
    let res = match req.send().await {
        Ok(r) => r,
        Err(e) if e.is_connect() => return Probe::Free,
        Err(e) if e.is_timeout() => return Probe::Foreign("a server that doesn't answer".into()),
        Err(_) => return Probe::Foreign("something that isn't an HTTP server".into()),
    };
    let status = res.status();
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        return Probe::Foreign(
            "another frog-apple, started with a different token (another copy of Frog, or a test run)".into(),
        );
    }
    let v: serde_json::Value = match res.json().await {
        Ok(v) if status.is_success() => v,
        _ => {
            return Probe::Foreign(format!(
                "a server that isn't a frog sidecar (HTTP {})",
                status.as_u16()
            ));
        }
    };
    match v["data"][0]["id"].as_str() {
        Some(id) => Probe::Ours {
            model: id.to_string(),
            unavailable: v["data"][0]["unavailable"].as_str().map(String::from),
        },
        None => Probe::Foreign("a server that isn't a frog sidecar".into()),
    }
}

/// A port the OS isn't using, for a sidecar that has to move.
fn free_port() -> std::io::Result<u16> {
    Ok(std::net::TcpListener::bind("127.0.0.1:0")?
        .local_addr()?
        .port())
}

/// How one sidecar start goes: everything [`launch`] needs, so tests can run it against fake
/// listeners and stand-in processes without touching the data dir or real ports.
pub(crate) struct Spot {
    /// The binary's name, for log lines.
    pub bin: &'static str,
    /// What the person calls the model ("Apple Intelligence").
    pub name: String,
    /// The model id the sidecar reports.
    pub model: String,
    pub token: Option<String>,
    /// The port to use: where it last ran, or its default.
    pub port: u16,
    /// It may start on another port when `port` is taken (Apple's; tang's is fixed).
    pub movable: bool,
    pub deadline: Duration,
    /// Fail when the sidecar says its model can't run (a chat turn; not a screenshot).
    pub need_model: bool,
    /// Its log, for the reason it exited.
    pub log: PathBuf,
}

/// Get `spot`'s sidecar serving: reuse ours, move off a port someone else holds (or fail fast
/// when it can't move), start one with `spawn(port)`, and wait for it within the deadline.
/// `stop` ends this data dir's own sidecar (for a model switch). Every outcome is a line through
/// `note`, which is the engine log. Returns the port and, when it started one, the child.
pub(crate) async fn launch(
    spot: &Spot,
    stop: impl FnOnce() + Send,
    spawn: impl FnOnce(u16) -> std::io::Result<std::process::Child> + Send,
    note: &(dyn Fn(String) + Sync),
) -> Result<(u16, Option<std::process::Child>), StartError> {
    let fail = |e: StartError| {
        note(format!("{}: {e}", spot.bin));
        e
    };
    let ready = |unavailable: Option<String>| match unavailable {
        Some(reason) if spot.need_model => Err(StartError::Unavailable { reason }),
        _ => Ok(()),
    };
    let token = spot.token.as_deref();
    let mut port = spot.port;
    let taken = match probe(port, token).await {
        Probe::Ours { model, unavailable } if model == spot.model => {
            ready(unavailable).map_err(fail)?;
            return Ok((port, None));
        }
        Probe::Ours { model, .. } => {
            note(format!(
                "{}: on port {port} serving {model}; restarting it for {}",
                spot.bin, spot.model
            ));
            stop();
            // Give the old one a moment to release the port.
            let until = Instant::now() + Duration::from_secs(3);
            loop {
                match probe(port, token).await {
                    Probe::Free => break None,
                    _ if Instant::now() < until => {
                        tokio::time::sleep(Duration::from_millis(100)).await
                    }
                    Probe::Ours { .. } => {
                        break Some("the sidecar it was told to stop".to_string());
                    }
                    Probe::Foreign(by) => break Some(by),
                }
            }
        }
        Probe::Foreign(by) => Some(by),
        Probe::Free => None,
    };
    if let Some(by) = taken {
        if !spot.movable {
            return Err(fail(StartError::PortTaken {
                name: spot.name.clone(),
                port,
                by,
            }));
        }
        let to = free_port().map_err(|e| {
            fail(StartError::Exited {
                name: spot.name.clone(),
                detail: format!("no free port: {e}"),
            })
        })?;
        note(format!(
            "{}: port {port} is in use by {by}; starting on {to}",
            spot.bin
        ));
        port = to;
    }
    let mut child = spawn(port).map_err(|e| {
        fail(StartError::Exited {
            name: spot.name.clone(),
            detail: format!("couldn't run {}: {e}", spot.bin),
        })
    })?;
    let until = Instant::now() + spot.deadline;
    loop {
        if let Probe::Ours { model, unavailable } = probe(port, token).await
            && model == spot.model
        {
            if let Err(e) = ready(unavailable) {
                // It runs, but can't do what it was started for: don't leave it behind.
                let _ = child.kill();
                let _ = child.wait();
                return Err(fail(e));
            }
            note(format!(
                "{}: serving {} on port {port}",
                spot.bin, spot.model
            ));
            return Ok((port, Some(child)));
        }
        if let Ok(Some(status)) = child.try_wait() {
            let log = std::fs::read_to_string(&spot.log).unwrap_or_default();
            let tail: Vec<&str> = log
                .lines()
                .filter(|l| !l.trim().is_empty())
                .rev()
                .take(3)
                .collect();
            let detail = if tail.is_empty() {
                format!("it exited with {status}")
            } else {
                tail.into_iter().rev().collect::<Vec<_>>().join("; ")
            };
            return Err(fail(StartError::Exited {
                name: spot.name.clone(),
                detail,
            }));
        }
        if Instant::now() >= until {
            let _ = child.kill();
            let _ = child.wait();
            return Err(fail(StartError::Timeout {
                name: spot.name.clone(),
                after: spot.deadline,
                log: spot.log.clone(),
            }));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Whether `pid` is a running `bin` (a pid file can outlive its process, and the pid be reused).
fn is_running(pid: i32, bin: &str) -> bool {
    Command::new("ps")
        .args(["-o", "comm=", "-p", &pid.to_string()])
        .output()
        .ok()
        .is_some_and(|o| String::from_utf8_lossy(&o.stdout).trim().ends_with(bin))
}

fn stop(k: &Kind) {
    if let Ok(pid) = std::fs::read_to_string(pid_file(k))
        && let Ok(pid) = pid.trim().parse::<i32>()
        && is_running(pid, k.bin)
    {
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
    }
    let _ = std::fs::remove_file(pid_file(k));
}

pub async fn is_serving(model: &str) -> bool {
    let k = kind(model);
    let token = (model == APPLE).then(apple_token).flatten();
    matches!(probe(port(k), token.as_deref()).await, Probe::Ours { model: m, .. } if m == model)
}

/// Make sure the sidecar for `p.sidecar` is up and serving it, starting or restarting it, and
/// that its model can run. Errors are [`StartError`]s.
pub async fn ensure(p: &Profile) -> Result<()> {
    start(p, true).await
}

/// [`ensure`], for the sidecar's other services (frog-apple's screenshots and images), which
/// work whether or not the language model can.
pub async fn ensure_running(p: &Profile) -> Result<()> {
    start(p, false).await
}

/// Unit tests never start a real sidecar: they'd share this user's data dir and ports. A
/// `test-unavailable` model stands for one whose system model can't run.
#[cfg(test)]
fn scripted(model: &str) -> Result<()> {
    if model == "test-unavailable" {
        return Err(StartError::Unavailable {
            reason: "Apple Intelligence is turned off. Turn it on in System Settings, or pick another model.".into(),
        }
        .into());
    }
    Ok(())
}

async fn start(p: &Profile, need_model: bool) -> Result<()> {
    let Some(model) = &p.sidecar else {
        return Ok(());
    };
    #[cfg(test)]
    {
        let _ = need_model;
        return scripted(model);
    }
    #[allow(unreachable_code)]
    let k = kind(model);
    let name = display_name(model);
    if off() {
        return Err(StartError::Off { name }.into());
    }
    if model != APPLE && !crate::setup::model_present(model) {
        bail!("{model} isn't downloaded; run `frog setup` (or `frog setup {model}`)");
    }
    std::fs::create_dir_all(data_dir())?;
    let apple = model == APPLE;
    let token = if apple {
        Some(apple_token().context("making frog-apple's token")?)
    } else {
        None
    };
    let recorded = apple && port_file(k).exists();
    let port = if apple && !recorded && mode() == "ephemeral" {
        free_port()?
    } else {
        port(k)
    };
    let spot = Spot {
        bin: k.bin,
        name: name.clone(),
        model: model.clone(),
        token: token.clone(),
        port,
        movable: apple,
        // frog-apple is up in about a second; tang reads a model's weights on its first
        // request, not here, but a big model's first start still takes a while.
        deadline: if apple {
            Duration::from_secs(15)
        } else {
            Duration::from_secs(300)
        },
        need_model,
        log: log_file(model),
    };
    let bin = binary(k);
    let spawn = |port: u16| -> std::io::Result<std::process::Child> {
        let log = std::fs::File::create(log_file(model))?;
        let mut cmd = Command::new(&bin);
        if !apple {
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
        } else if let Some(t) = &token {
            cmd.env("FROG_APPLE_TOKEN", t);
        }
        cmd.args(["--port", &port.to_string()])
            .stdin(Stdio::null())
            .stdout(log.try_clone()?)
            .stderr(log);
        // Its own session, so it outlives this engine (it goes with the app: `watch_app`, and
        // frog-apple watches `FROG_APP_PID` itself).
        unsafe {
            use std::os::unix::process::CommandExt;
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
        cmd.spawn()
    };
    let note = |line: String| eprintln!("sidecar: {line}");
    let (port, child) = launch(&spot, || stop(k), spawn, &note).await?;
    if apple {
        std::fs::write(port_file(k), port.to_string())?;
    }
    if let Some(child) = child {
        std::fs::write(pid_file(k), child.id().to_string())?;
        if !apple {
            watch_app(child.id());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const TOKEN: &str = "test-token-0123456789abcdef0123456789";

    /// How a fake server on a port answers `/v1/models`.
    #[derive(Clone, Copy)]
    enum Answer {
        /// frog-apple with our token, its model ready.
        Sidecar,
        /// frog-apple with our token, its model unable to run.
        Unavailable,
        /// A frog-apple started with someone else's token.
        WrongToken,
        /// Some other program's web server.
        NotASidecar,
    }

    /// A fake server on `port` (0: one the OS picks); returns the port.
    async fn serve(port: u16, answer: Answer) -> u16 {
        let l = tokio::net::TcpListener::bind(("127.0.0.1", port))
            .await
            .unwrap();
        let port = l.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let Ok((mut c, _)) = l.accept().await else {
                    return;
                };
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 4096];
                    let mut n = 0;
                    while !buf[..n].windows(4).any(|w| w == b"\r\n\r\n") {
                        match c.read(&mut buf[n..]).await {
                            Ok(0) | Err(_) => return,
                            Ok(k) => n += k,
                        }
                    }
                    let head = String::from_utf8_lossy(&buf[..n]).to_lowercase();
                    let ours = head.contains(&format!("authorization: bearer {TOKEN}"));
                    let (status, body) = match answer {
                        Answer::WrongToken => ("401 Unauthorized", r#"{"error":{"message":"missing or wrong bearer token"}}"#.to_string()),
                        Answer::NotASidecar => ("200 OK", "<html>hello</html>".to_string()),
                        _ if !ours => ("401 Unauthorized", "{}".to_string()),
                        Answer::Sidecar => ("200 OK", r#"{"data":[{"id":"apple"}]}"#.to_string()),
                        Answer::Unavailable => (
                            "200 OK",
                            r#"{"data":[{"id":"apple","unavailable":"Apple Intelligence is turned off. Turn it on in System Settings."}]}"#.to_string(),
                        ),
                    };
                    let res = format!(
                        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = c.write_all(res.as_bytes()).await;
                });
            }
        });
        port
    }

    fn spot(port: u16, movable: bool) -> Spot {
        Spot {
            bin: "frog-apple",
            name: "Apple Intelligence".into(),
            model: "apple".into(),
            token: Some(TOKEN.into()),
            port,
            movable,
            deadline: Duration::from_secs(2),
            need_model: true,
            log: std::env::temp_dir().join(format!("frog-sidecar-test-{}.log", std::process::id())),
        }
    }

    /// The engine log, as a test sees it.
    fn notes() -> (Arc<Mutex<Vec<String>>>, impl Fn(String) + Sync) {
        let lines = Arc::new(Mutex::new(Vec::new()));
        let l = lines.clone();
        (lines, move |s: String| l.lock().unwrap().push(s))
    }

    /// A stand-in sidecar process (it serves nothing itself), its pid kept for checking it's gone.
    fn stand_in(pid: &Arc<Mutex<Option<u32>>>) -> std::io::Result<std::process::Child> {
        let child = Command::new("sleep").arg("30").spawn()?;
        *pid.lock().unwrap() = Some(child.id());
        Ok(child)
    }

    fn gone(pid: u32) -> bool {
        unsafe { libc::kill(pid as i32, 0) != 0 }
    }

    /// Cam's hang: a test run's frog-apple (another token) held the port. Ours starts on a free
    /// port instead of polling the stranger for five minutes.
    #[tokio::test]
    async fn a_sidecar_with_another_token_on_the_port_is_moved_around() {
        let taken = serve(0, Answer::WrongToken).await;
        let (lines, note) = notes();
        let pid = Arc::new(Mutex::new(None));
        let began = Instant::now();
        let (port, child) = launch(
            &spot(taken, true),
            || panic!("never stop a sidecar that isn't ours"),
            |p| {
                tokio::spawn(serve(p, Answer::Sidecar));
                stand_in(&pid)
            },
            &note,
        )
        .await
        .expect("started");
        assert!(
            began.elapsed() < Duration::from_secs(5),
            "took {:?}",
            began.elapsed()
        );
        assert_ne!(port, taken);
        child.expect("a child").kill().unwrap();
        let lines = lines.lock().unwrap().join("\n");
        assert!(
            lines.contains(&format!("port {taken} is in use by another frog-apple")),
            "{lines}"
        );
        assert!(
            lines.contains(&format!("serving apple on port {port}")),
            "{lines}"
        );
    }

    /// Something that isn't a sidecar on the port: never waited on either.
    #[tokio::test]
    async fn another_program_on_the_port_is_moved_around() {
        let taken = serve(0, Answer::NotASidecar).await;
        let (lines, note) = notes();
        let pid = Arc::new(Mutex::new(None));
        let (port, child) = launch(
            &spot(taken, true),
            || panic!("never stop a sidecar that isn't ours"),
            |p| {
                tokio::spawn(serve(p, Answer::Sidecar));
                stand_in(&pid)
            },
            &note,
        )
        .await
        .expect("started");
        assert_ne!(port, taken);
        child.unwrap().kill().unwrap();
        assert!(
            lines
                .lock()
                .unwrap()
                .join("\n")
                .contains("isn't a frog sidecar")
        );
    }

    /// tang's port can't move (the app and paired nodes reach it on 8911): a stranger there is
    /// a fast, typed failure that says what holds it.
    #[tokio::test]
    async fn a_fixed_port_held_by_another_program_fails_fast() {
        let taken = serve(0, Answer::NotASidecar).await;
        let (lines, note) = notes();
        let began = Instant::now();
        let err = launch(
            &spot(taken, false),
            || panic!("not ours"),
            |_| panic!("nothing starts"),
            &note,
        )
        .await
        .unwrap_err();
        assert!(
            began.elapsed() < Duration::from_secs(3),
            "took {:?}",
            began.elapsed()
        );
        assert!(
            matches!(&err, StartError::PortTaken { port, .. } if *port == taken),
            "{err:?}"
        );
        assert!(err.to_string().contains("pick another model"), "{err}");
        assert!(
            lines
                .lock()
                .unwrap()
                .join("\n")
                .contains(&format!("port {taken} is in use"))
        );
    }

    /// One that starts but never answers: past the deadline the turn gets a reason, the
    /// engine log a line, and the process is stopped rather than left behind.
    #[tokio::test]
    async fn a_sidecar_that_never_becomes_ready_times_out_and_is_stopped() {
        let free = free_port().unwrap();
        let (lines, note) = notes();
        let pid = Arc::new(Mutex::new(None));
        let began = Instant::now();
        let err = launch(&spot(free, true), || {}, |_| stand_in(&pid), &note)
            .await
            .unwrap_err();
        assert!(
            began.elapsed() < Duration::from_secs(4),
            "took {:?}",
            began.elapsed()
        );
        assert!(matches!(err, StartError::Timeout { .. }), "{err:?}");
        assert!(
            err.to_string().contains("didn't start within 2 seconds"),
            "{err}"
        );
        assert!(
            gone(pid.lock().unwrap().unwrap()),
            "the stand-in was left running"
        );
        assert!(
            lines
                .lock()
                .unwrap()
                .join("\n")
                .contains("didn't start within")
        );
    }

    /// Up, but the system model can't run (Apple Intelligence off, an unsupported Mac, still
    /// downloading): the system's reason, not a wait. Screenshots don't need the model.
    #[tokio::test]
    async fn a_sidecar_whose_model_is_unavailable_says_why() {
        let free = free_port().unwrap();
        let (lines, note) = notes();
        let pid = Arc::new(Mutex::new(None));
        let err = launch(
            &spot(free, true),
            || {},
            |p| {
                tokio::spawn(serve(p, Answer::Unavailable));
                stand_in(&pid)
            },
            &note,
        )
        .await
        .unwrap_err();
        assert_eq!(
            err,
            StartError::Unavailable {
                reason: "Apple Intelligence is turned off. Turn it on in System Settings.".into()
            }
        );
        assert!(gone(pid.lock().unwrap().unwrap()), "left running");
        assert!(
            lines
                .lock()
                .unwrap()
                .join("\n")
                .contains("Apple Intelligence is turned off")
        );

        // Already running that way: the same reason, nothing started.
        let up = serve(0, Answer::Unavailable).await;
        let err = launch(&spot(up, true), || {}, |_| panic!("nothing starts"), &note)
            .await
            .unwrap_err();
        assert!(matches!(err, StartError::Unavailable { .. }));
        // For a screenshot it's fine.
        let mut s = spot(up, true);
        s.need_model = false;
        let (port, child) = launch(&s, || {}, |_| panic!("nothing starts"), &note)
            .await
            .unwrap();
        assert_eq!((port, child.is_none()), (up, true));
    }

    /// One that exits while starting (frog-apple can't bind its port): its own words, at once.
    #[tokio::test]
    async fn a_sidecar_that_exits_while_starting_says_why() {
        let s = spot(free_port().unwrap(), true);
        let (_lines, note) = notes();
        let log = s.log.clone();
        let began = Instant::now();
        let err = launch(
            &s,
            || {},
            |p| {
                let f = std::fs::File::create(&log)?;
                Command::new("/bin/sh")
                    .args(["-c", &format!("echo 'frog-apple: can'\\''t listen on 127.0.0.1:{p}: address in use' >&2; exit 1")])
                    .stderr(f)
                    .spawn()
            },
            &note,
        )
        .await
        .unwrap_err();
        assert!(
            began.elapsed() < Duration::from_secs(2),
            "took {:?}",
            began.elapsed()
        );
        assert!(err.to_string().contains("can't listen on"), "{err}");
        let _ = std::fs::remove_file(&log);
    }

    /// Our own sidecar, already serving the model: reused, nothing started.
    #[tokio::test]
    async fn our_running_sidecar_is_reused() {
        let up = serve(0, Answer::Sidecar).await;
        let (_lines, note) = notes();
        let (port, child) = launch(
            &spot(up, true),
            || panic!("no restart"),
            |_| panic!("nothing starts"),
            &note,
        )
        .await
        .unwrap();
        assert_eq!((port, child.is_none()), (up, true));
    }

    #[test]
    fn apple_intelligence_is_started_and_downloaded_models_loaded() {
        assert_eq!(activity(APPLE), "starting Apple Intelligence");
        assert_eq!(
            activity("mlx-community/Qwen3-32B-4bit"),
            "loading mlx-community/Qwen3-32B-4bit"
        );
        assert_eq!(display_name(APPLE), "Apple Intelligence");
        assert_eq!(display_name("mlx-community/Qwen3-32B-4bit"), "Qwen3 32B");
    }

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
