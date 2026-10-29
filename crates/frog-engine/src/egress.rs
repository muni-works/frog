//! The egress allow-list: which hosts a sandboxed command may reach. See docs/design/egress.md.
//!
//! Seatbelt matches network peers by IP (`*` or `localhost`), never by name, so the profile can
//! only say "nothing but localhost". Names are decided here instead: under an enforced policy
//! the profile denies every outbound connection (DNS too) except to localhost, and commands get
//! `HTTPS_PROXY`/`HTTP_PROXY` pointing at this process's allow-list proxy. A host on the list is
//! tunnelled; anything else gets a 403 and becomes a [`Hit`]: logged to `egress.jsonl`, an
//! `EgressBlocked` event in the transcript and a count in the brief. A client that ignores the
//! proxy can't resolve or connect at all, so a compound command or a `python -c` one-liner is
//! caught at connect time, whatever the tool call looked like.
//!
//! The policy is `[egress]` in config.toml plus `~/.config/frog/egress.toml` for per-project
//! overrides. That file lives in frog's config dir on purpose: the sandbox can't read or write
//! it, so an agent can't widen its own allow-list by committing a file to the repo.

use crate::config::config_dir;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

/// Hosts every policy allows unless `defaults = false`. A domain covers its subdomains
/// (`github.com` covers `api.github.com`); the companions are the hosts the registries
/// actually download from.
pub const DEFAULT_HOSTS: &[&str] = &[
    "github.com",
    "githubusercontent.com",
    "crates.io",
    "pypi.org",
    "pythonhosted.org",
    "registry.npmjs.org",
    "api.frog.toys",
    "huggingface.co",
    "hf.co",
];

/// How a policy treats a host that isn't on the list.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// No proxy, no network rule: what sandboxed commands always had.
    #[default]
    Off,
    /// Routed through the proxy and recorded, but let through.
    Flag,
    /// Blocked at connect time and recorded.
    Enforce,
}

/// `[egress]` in config.toml.
#[derive(Clone, Debug, Deserialize)]
pub struct EgressConfig {
    /// Hosts beyond the built-in list. A domain covers its subdomains.
    #[serde(default)]
    pub allow: Vec<String>,
    /// Keep [`DEFAULT_HOSTS`]. False: only `allow` (and per-project hosts).
    #[serde(default = "yes")]
    pub defaults: bool,
    /// Sessions started as agents (`StartSession`, and their subagents) enforce the list.
    #[serde(default = "yes")]
    pub workers_deny_by_default: bool,
    /// Sessions you started yourself: `off` (default), `flag` or `enforce`.
    #[serde(default)]
    pub interactive: Mode,
}

fn yes() -> bool {
    true
}

impl Default for EgressConfig {
    fn default() -> Self {
        toml::from_str("").expect("empty [egress] parses")
    }
}

/// One folder's entry in `egress.toml` (`[projects."/path/to/repo"]`).
#[derive(Clone, Debug, Default, Deserialize)]
pub struct ProjectRule {
    /// More hosts for sessions in this folder.
    #[serde(default)]
    pub allow: Vec<String>,
    /// Overrides the worker/interactive mode for this folder.
    #[serde(default)]
    pub mode: Option<Mode>,
}

#[derive(Debug, Default, Deserialize)]
struct Projects {
    #[serde(default)]
    projects: BTreeMap<String, ProjectRule>,
}

fn projects_path() -> PathBuf {
    config_dir().join("egress.toml")
}

fn load_projects(file: &Path) -> Projects {
    let Ok(text) = std::fs::read_to_string(file) else {
        return Projects::default();
    };
    match toml::from_str(&text) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("egress: ignoring {}: {e}", file.display());
            Projects::default()
        }
    }
}

/// A session's resolved policy.
#[derive(Clone, Debug, PartialEq)]
pub struct Policy {
    pub mode: Mode,
    pub hosts: Vec<String>,
}

impl Policy {
    /// The policy for a session in `cwd`: `worker` when an agent started it.
    pub fn resolve(cfg: &EgressConfig, cwd: &Path, worker: bool) -> Self {
        Self::resolve_in(cfg, &load_projects(&projects_path()), cwd, worker)
    }

    fn resolve_in(cfg: &EgressConfig, projects: &Projects, cwd: &Path, worker: bool) -> Self {
        let mut mode = match worker {
            true if cfg.workers_deny_by_default => Mode::Enforce,
            true => Mode::Off,
            false => cfg.interactive,
        };
        let mut hosts: Vec<String> = cfg
            .defaults
            .then_some(DEFAULT_HOSTS)
            .into_iter()
            .flatten()
            .map(|h| h.to_string())
            .chain(cfg.allow.iter().cloned())
            .collect();
        // The nearest folder with an entry decides, as in `policy`.
        let dir = cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf());
        if let Some(rule) = dir
            .ancestors()
            .find_map(|a| projects.projects.get(a.to_string_lossy().as_ref()))
        {
            hosts.extend(rule.allow.iter().cloned());
            mode = rule.mode.unwrap_or(mode);
        }
        let mut hosts: Vec<String> = hosts
            .iter()
            .map(|h| normalize(h))
            .filter(|h| !h.is_empty())
            .collect();
        hosts.sort();
        hosts.dedup();
        Self { mode, hosts }
    }

    pub fn allows(&self, host: &str) -> bool {
        covered(&self.hosts, host)
    }
}

/// A host as the list compares it: lowercase, no brackets, no trailing dot, no `*.`.
pub fn normalize(h: &str) -> String {
    let h = h.trim().to_ascii_lowercase();
    let h = h.strip_prefix("*.").unwrap_or(&h);
    h.trim_start_matches('[')
        .trim_end_matches(']')
        .trim_end_matches('.')
        .to_string()
}

/// Whether `host` is one of `list` or a subdomain of one (on a label boundary: `github.com`
/// covers `api.github.com`, never `github.com.evil.example`).
fn covered(list: &[String], host: &str) -> bool {
    let host = normalize(host);
    !host.is_empty()
        && list
            .iter()
            .any(|d| host == *d || host.strip_suffix(d.as_str()).is_some_and(|r| r.ends_with('.')))
}

/// One attempted connection to a host off the list.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Hit {
    pub host: String,
    /// 0 when the sandbox stopped the lookup itself (a client that ignores the proxy).
    pub port: u16,
    /// The tool whose command tried it (`Bash`, `Monitor`).
    pub tool: String,
    /// The start of that command.
    pub command: String,
    /// Blocked (`enforce`), or only recorded (`flag`).
    pub enforced: bool,
}

/// A session's egress state, shared by its tool calls, subagents and the proxy.
#[derive(Debug)]
pub struct Egress {
    pub policy: Policy,
    /// Hosts the user allowed for the rest of the session (an approval card's "always").
    granted: Mutex<Vec<String>>,
    /// Hosts the user allowed for one command, waiting for that command to run.
    once: Mutex<Vec<(String, Vec<String>)>>,
    /// Hits not yet turned into events.
    hits: Mutex<Vec<Hit>>,
    /// The session id, for the log.
    session: Mutex<String>,
}

impl Egress {
    pub fn new(policy: Policy) -> Arc<Self> {
        Arc::new(Self {
            policy,
            granted: Mutex::default(),
            once: Mutex::default(),
            hits: Mutex::default(),
            session: Mutex::default(),
        })
    }

    pub fn active(&self) -> bool {
        self.policy.mode != Mode::Off
    }

    pub fn enforced(&self) -> bool {
        self.policy.mode == Mode::Enforce
    }

    pub fn set_session(&self, id: &str) {
        *self.session.lock().unwrap() = id.to_string();
    }

    /// On the policy's list or granted for the session.
    pub fn allows(&self, host: &str) -> bool {
        self.policy.allows(host) || covered(&self.granted.lock().unwrap(), host)
    }

    /// Of `hosts`, those this session doesn't already allow.
    pub fn missing(&self, hosts: &[String]) -> Vec<String> {
        let mut out: Vec<String> = hosts
            .iter()
            .map(|h| normalize(h))
            .filter(|h| !h.is_empty() && !self.allows(h))
            .collect();
        out.dedup();
        out
    }

    /// The user allowed these hosts for the rest of the session.
    pub fn grant(&self, hosts: &[String]) {
        self.granted
            .lock()
            .unwrap()
            .extend(hosts.iter().map(|h| normalize(h)));
    }

    /// The user allowed these hosts for one run of `command`.
    pub fn grant_once(&self, command: &str, hosts: Vec<String>) {
        let hosts = hosts.iter().map(|h| normalize(h)).collect();
        self.once
            .lock()
            .unwrap()
            .push((command.trim().to_string(), hosts));
    }

    /// The hosts granted for this run of `command`, used up.
    pub fn take_once(&self, command: &str) -> Vec<String> {
        let mut once = self.once.lock().unwrap();
        match once.iter().position(|(c, _)| c == command.trim()) {
            Some(i) => once.remove(i).1,
            None => Vec::new(),
        }
    }

    /// Record a hit: queued for an event and appended to the log at once.
    pub fn record(&self, hit: Hit) {
        let session = self.session.lock().unwrap().clone();
        append_log(&log_path(), &session, &hit);
        self.hits.lock().unwrap().push(hit);
    }

    /// The hits since the last drain, for events.
    pub fn drain(&self) -> Vec<Hit> {
        std::mem::take(&mut *self.hits.lock().unwrap())
    }
}

/// The egress state for a session in `cwd`, or `None` when its policy is off.
pub fn for_session(cfg: &crate::config::Config, cwd: &Path) -> Option<Arc<Egress>> {
    // A hermetic run (the bench, tests) sees none of this machine's per-project overrides.
    let projects = match cfg.hermetic {
        true => Projects::default(),
        false => load_projects(&projects_path()),
    };
    let policy = Policy::resolve_in(&cfg.egress, &projects, cwd, cfg.worker);
    (policy.mode != Mode::Off).then(|| Egress::new(policy))
}

// ---- the log and the digest ----

fn log_path() -> PathBuf {
    if cfg!(test) {
        // Tests' attempts never reach your log or your brief.
        return std::env::temp_dir().join(format!("frog-egress-test-{}.jsonl", std::process::id()));
    }
    crate::config::data_dir().join("egress.jsonl")
}

#[derive(Serialize, Deserialize)]
struct LogLine {
    at: i64,
    #[serde(default)]
    session: String,
    #[serde(flatten)]
    hit: Hit,
}

fn append_log(file: &Path, session: &str, hit: &Hit) {
    use std::io::Write;
    let line = LogLine {
        at: chrono::Utc::now().timestamp_millis(),
        session: session.to_string(),
        hit: hit.clone(),
    };
    let Ok(text) = serde_json::to_string(&line) else {
        return;
    };
    if let Some(dir) = file.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(file)
    {
        let _ = writeln!(f, "{text}");
    }
}

/// Blocked connections since a moment, for the brief.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Digest {
    /// Attempts blocked (flagged ones aren't counted).
    pub blocked: usize,
    /// Sessions they came from.
    pub sessions: usize,
    /// The most-tried hosts, with counts, most first (at most five).
    pub hosts: Vec<(String, usize)>,
}

/// What `egress.jsonl` says was blocked since `since_ms` (Unix milliseconds).
pub fn digest(since_ms: i64) -> Digest {
    digest_in(&log_path(), since_ms)
}

fn digest_in(file: &Path, since_ms: i64) -> Digest {
    let text = std::fs::read_to_string(file).unwrap_or_default();
    let lines: Vec<LogLine> = text
        .lines()
        .filter_map(|l| serde_json::from_str::<LogLine>(l).ok())
        .filter(|l| l.at >= since_ms && l.hit.enforced)
        .collect();
    let mut hosts: BTreeMap<&str, usize> = BTreeMap::new();
    let mut sessions: Vec<&str> = Vec::new();
    for l in &lines {
        *hosts.entry(&l.hit.host).or_default() += 1;
        sessions.push(&l.session);
    }
    sessions.sort();
    sessions.dedup();
    let mut hosts: Vec<(String, usize)> =
        hosts.into_iter().map(|(h, n)| (h.to_string(), n)).collect();
    hosts.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    hosts.truncate(5);
    Digest {
        blocked: lines.len(),
        sessions: sessions.len(),
        hosts,
    }
}

// ---- the proxy ----

/// One sandboxed command's view of the proxy: its session's policy, the hosts granted for
/// it alone, and what it tried.
#[derive(Debug)]
pub struct Call {
    egress: Arc<Egress>,
    tool: String,
    command: String,
    extra: Vec<String>,
    hits: Mutex<Vec<Hit>>,
}

impl Call {
    /// The hits this command caused so far.
    pub fn hits(&self) -> Vec<Hit> {
        self.hits.lock().unwrap().clone()
    }

    fn allows(&self, host: &str) -> bool {
        covered(&self.extra, host) || self.egress.allows(host)
    }

    /// Note an attempt to a host off the list.
    pub fn record(&self, host: &str, port: u16) {
        let hit = Hit {
            host: normalize(host),
            port,
            tool: self.tool.clone(),
            command: head(&self.command),
            enforced: self.egress.enforced(),
        };
        self.hits.lock().unwrap().push(hit.clone());
        self.egress.record(hit);
    }
}

/// The start of a command, for a notice: its first line, at most 120 characters.
pub fn head(command: &str) -> String {
    let line = command.trim().lines().next().unwrap_or("");
    let mut out: String = line.chars().take(120).collect();
    if out.len() < line.len() || command.trim().lines().nth(1).is_some() {
        out.push('…');
    }
    out
}

/// How many calls the proxy remembers: a token older than this (a very long background job)
/// falls back to the newest call's policy.
const REMEMBERED: usize = 1024;

fn registry() -> &'static Mutex<VecDeque<(String, Arc<Call>)>> {
    static CALLS: OnceLock<Mutex<VecDeque<(String, Arc<Call>)>>> = OnceLock::new();
    CALLS.get_or_init(Mutex::default)
}

/// Register a command with the proxy. Returns the proxy URL to put in its environment (the
/// token in it ties each connection back to this call) and the call, to read its hits.
pub fn register(
    egress: &Arc<Egress>,
    tool: &str,
    command: &str,
    extra: Vec<String>,
) -> Option<(String, Arc<Call>)> {
    let port = proxy_port()?;
    let token = crate::session::new_id().replace('-', "");
    let call = Arc::new(Call {
        egress: egress.clone(),
        tool: tool.to_string(),
        command: command.to_string(),
        extra: extra.iter().map(|h| normalize(h)).collect(),
        hits: Mutex::default(),
    });
    let mut calls = registry().lock().unwrap();
    calls.push_back((token.clone(), call.clone()));
    while calls.len() > REMEMBERED {
        calls.pop_front();
    }
    Some((format!("http://frog:{token}@127.0.0.1:{port}"), call))
}

fn lookup(token: Option<&str>) -> Option<Arc<Call>> {
    let calls = registry().lock().unwrap();
    token
        .and_then(|t| calls.iter().rev().find(|(k, _)| k == t))
        .or_else(|| calls.back())
        .map(|(_, c)| c.clone())
}

/// The proxy's port. It runs on its own thread and runtime, so it outlives whichever runtime
/// first asked for it (each test has its own).
fn proxy_port() -> Option<u16> {
    static PORT: OnceLock<Option<u16>> = OnceLock::new();
    *PORT.get_or_init(|| {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").ok()?;
        listener.set_nonblocking(true).ok()?;
        let port = listener.local_addr().ok()?.port();
        std::thread::Builder::new()
            .name("frog-egress".into())
            .spawn(move || {
                let Ok(rt) = tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(2)
                    .enable_all()
                    .build()
                else {
                    return;
                };
                rt.block_on(async move {
                    let Ok(listener) = tokio::net::TcpListener::from_std(listener) else {
                        return;
                    };
                    while let Ok((conn, _)) = listener.accept().await {
                        tokio::spawn(async move {
                            let _ = serve(conn).await;
                        });
                    }
                });
            })
            .ok()?;
        Some(port)
    })
}

/// The request a proxy client sent: where to, and how.
#[derive(Debug, PartialEq)]
struct Target {
    host: String,
    port: u16,
    /// `CONNECT` (a tunnel) rather than a plain-http request in absolute form.
    tunnel: bool,
}

fn parse_target(request_line: &str) -> Option<Target> {
    let mut parts = request_line.split_whitespace();
    let method = parts.next()?;
    let target = parts.next()?;
    if method.eq_ignore_ascii_case("CONNECT") {
        let (host, port) = split_host_port(target)?;
        return Some(Target {
            host,
            port: port?,
            tunnel: true,
        });
    }
    let rest = target.strip_prefix("http://")?;
    let authority = rest.split(['/', '?', '#']).next()?;
    let authority = authority.rsplit('@').next()?;
    let (host, port) = split_host_port(authority)?;
    Some(Target {
        host,
        port: port.unwrap_or(80),
        tunnel: false,
    })
}

fn split_host_port(s: &str) -> Option<(String, Option<u16>)> {
    if let Some(rest) = s.strip_prefix('[') {
        let (host, after) = rest.split_once(']')?;
        let port = after.strip_prefix(':').and_then(|p| p.parse().ok());
        return Some((host.to_string(), port));
    }
    match s.rsplit_once(':') {
        Some((h, p)) => Some((h.to_string(), Some(p.parse().ok()?))),
        None => Some((s.to_string(), None)),
    }
}

/// The token from a `Proxy-Authorization: Basic base64(frog:<token>)` header.
fn token(head: &str) -> Option<String> {
    use base64::Engine;
    let value = head.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.trim()
            .eq_ignore_ascii_case("proxy-authorization")
            .then(|| v.trim().to_string())
    })?;
    let b64 = value
        .strip_prefix("Basic ")
        .or_else(|| value.strip_prefix("basic "))?;
    let raw = base64::engine::general_purpose::STANDARD
        .decode(b64.trim())
        .ok()?;
    let creds = String::from_utf8(raw).ok()?;
    creds.split_once(':').map(|(_, t)| t.to_string())
}

/// A plain-http request's head for the upstream: no proxy headers, and one request per
/// connection, so a client can't reuse an approved upstream for a second host.
fn upstream_head(head: &str) -> String {
    let mut lines = head.split("\r\n");
    let mut out = String::new();
    if let Some(first) = lines.next() {
        out.push_str(first);
        out.push_str("\r\n");
    }
    for l in lines.filter(|l| !l.is_empty()) {
        let name = l.split(':').next().unwrap_or("").trim().to_ascii_lowercase();
        if matches!(
            name.as_str(),
            "proxy-authorization" | "proxy-connection" | "connection" | "keep-alive"
        ) {
            continue;
        }
        out.push_str(l);
        out.push_str("\r\n");
    }
    out.push_str("Connection: close\r\n\r\n");
    out
}

async fn serve(mut conn: tokio::net::TcpStream) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let end = loop {
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        if buf.len() > 16 * 1024 {
            return conn
                .write_all(b"HTTP/1.1 431 Request Header Fields Too Large\r\n\r\n")
                .await;
        }
        let n = conn.read(&mut chunk).await?;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&buf[..end]).into_owned();
    let rest = buf[end..].to_vec();
    let Some(target) = parse_target(head.lines().next().unwrap_or("")) else {
        return conn
            .write_all(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\nfrog egress: send CONNECT or an absolute http:// URL\r\n")
            .await;
    };
    let Some(call) = lookup(token(&head).as_deref()) else {
        return conn
            .write_all(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\nfrog egress: no session\r\n")
            .await;
    };
    if !call.allows(&target.host) {
        call.record(&target.host, target.port);
        if call.egress.enforced() {
            let body = format!(
                "frog egress: {} is not on this session's network allow-list; the attempt was blocked and logged\r\n",
                normalize(&target.host)
            );
            let reply = format!(
                "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            return conn.write_all(reply.as_bytes()).await;
        }
    }
    let mut upstream =
        match tokio::net::TcpStream::connect((target.host.as_str(), target.port)).await {
            Ok(u) => u,
            Err(_) => {
                return conn
                    .write_all(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
                    .await;
            }
        };
    if target.tunnel {
        conn.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            .await?;
        if !rest.is_empty() {
            upstream.write_all(&rest).await?;
        }
    } else {
        upstream.write_all(upstream_head(&head).as_bytes()).await?;
        upstream.write_all(&rest).await?;
    }
    tokio::io::copy_bidirectional(&mut conn, &mut upstream).await?;
    Ok(())
}

/// Hosts a client that ignored the proxy failed to resolve, from its output (the sandbox
/// denies DNS, so this is how those attempts get named).
pub fn unresolved(output: &str) -> Vec<String> {
    const MARKERS: &[&str] = &[
        "Could not resolve host: ",
        "getaddrinfo ENOTFOUND ",
        "Could not resolve hostname ",
        "unable to resolve host ",
    ];
    let mut out: Vec<String> = Vec::new();
    for line in output.lines() {
        for m in MARKERS {
            if let Some(rest) = line.split(m).nth(1) {
                let host: String = rest
                    .chars()
                    .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
                    .collect();
                let host = normalize(&host);
                if host.contains('.') && !out.contains(&host) {
                    out.push(host);
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("frog-egress-{tag}-{}", crate::session::new_id()));
        std::fs::create_dir_all(&d).unwrap();
        d.canonicalize().unwrap()
    }

    #[test]
    fn defaults_parse_and_workers_enforce() {
        let cfg = EgressConfig::default();
        assert!(cfg.defaults && cfg.workers_deny_by_default);
        assert_eq!(cfg.interactive, Mode::Off);
        let none = Projects::default();
        let dir = std::env::temp_dir();
        let worker = Policy::resolve_in(&cfg, &none, &dir, true);
        assert_eq!(worker.mode, Mode::Enforce);
        let me = Policy::resolve_in(&cfg, &none, &dir, false);
        assert_eq!(me.mode, Mode::Off);
        for h in [
            "github.com",
            "api.github.com",
            "objects.githubusercontent.com",
            "index.crates.io",
            "pypi.org",
            "files.pythonhosted.org",
            "registry.npmjs.org",
            "api.frog.toys",
            "huggingface.co",
            "GitHub.com.",
        ] {
            assert!(worker.allows(h), "{h}");
        }
        for h in [
            "oss-cn-beijing.aliyuncs.com",
            "github.com.evil.example",
            "evilgithub.com",
            "npmjs.org",
            "frog.toys",
            "1.1.1.1",
            "",
        ] {
            assert!(!worker.allows(h), "{h}");
        }
    }

    #[test]
    fn config_and_project_overrides() {
        let cfg: EgressConfig = toml::from_str(
            r#"allow = ["*.Example.com", "pkg.go.dev"]
defaults = false
workers_deny_by_default = false
interactive = "flag""#,
        )
        .unwrap();
        let none = Projects::default();
        let dir = tempdir("cfg");
        let p = Policy::resolve_in(&cfg, &none, &dir, false);
        assert_eq!(p.mode, Mode::Flag);
        assert_eq!(p.hosts, vec!["example.com", "pkg.go.dev"]);
        assert!(!p.allows("github.com"), "defaults = false drops the built-in list");
        assert_eq!(Policy::resolve_in(&cfg, &none, &dir, true).mode, Mode::Off);

        // egress.toml: the nearest folder decides the mode and adds hosts.
        let sub = dir.join("apps/web");
        std::fs::create_dir_all(&sub).unwrap();
        let file = dir.join("egress.toml");
        std::fs::write(
            &file,
            format!(
                "[projects.\"{}\"]\nallow = [\"registry.yarnpkg.com\"]\nmode = \"enforce\"\n",
                dir.display()
            ),
        )
        .unwrap();
        let projects = load_projects(&file);
        let p = Policy::resolve_in(&EgressConfig::default(), &projects, &sub, false);
        assert_eq!(p.mode, Mode::Enforce);
        assert!(p.allows("registry.yarnpkg.com") && p.allows("github.com"));
        // A folder outside it isn't touched.
        let other = Policy::resolve_in(&EgressConfig::default(), &projects, &std::env::temp_dir(), false);
        assert_eq!(other.mode, Mode::Off);
        assert!(!other.allows("registry.yarnpkg.com"));
        // A broken file is ignored, not fatal.
        std::fs::write(&file, "projects = 3").unwrap();
        assert!(load_projects(&file).projects.is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn grants_widen_for_the_session_or_one_command() {
        let e = Egress::new(Policy::resolve_in(
            &EgressConfig::default(),
            &Projects::default(),
            &std::env::temp_dir(),
            true,
        ));
        let want = vec!["pkg.go.dev".to_string(), "github.com".to_string()];
        assert_eq!(e.missing(&want), vec!["pkg.go.dev"]);
        e.grant_once("go get x", vec!["pkg.go.dev".into()]);
        assert!(e.take_once("go build").is_empty());
        assert_eq!(e.take_once("go get x"), vec!["pkg.go.dev"]);
        assert!(e.take_once("go get x").is_empty(), "a one-call grant is used up");
        assert!(!e.allows("proxy.golang.org"));
        e.grant(&["proxy.golang.org".into()]);
        assert!(e.allows("sum.proxy.golang.org"));
    }

    #[test]
    fn proxy_requests_parse() {
        assert_eq!(
            parse_target("CONNECT oss-cn-beijing.aliyuncs.com:443 HTTP/1.1"),
            Some(Target {
                host: "oss-cn-beijing.aliyuncs.com".into(),
                port: 443,
                tunnel: true
            })
        );
        assert_eq!(
            parse_target("GET http://user@example.com:8080/x?y HTTP/1.1"),
            Some(Target {
                host: "example.com".into(),
                port: 8080,
                tunnel: false
            })
        );
        assert_eq!(
            parse_target("CONNECT [::1]:443 HTTP/1.1").map(|t| t.host),
            Some("::1".into())
        );
        assert_eq!(parse_target("GET / HTTP/1.1"), None);
        assert_eq!(parse_target("CONNECT example.com HTTP/1.1"), None);
        let req = "CONNECT a:443 HTTP/1.1\r\nProxy-Authorization: Basic ZnJvZzphYmM=\r\n\r\n";
        assert_eq!(token(req), Some("abc".into()));
        let up = upstream_head(
            "GET http://a/ HTTP/1.1\r\nHost: a\r\nProxy-Authorization: Basic x\r\nConnection: keep-alive\r\n\r\n",
        );
        assert_eq!(up, "GET http://a/ HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n");
        assert_eq!(
            unresolved("curl: (6) Could not resolve host: oss-cn-beijing.aliyuncs.com\nok"),
            vec!["oss-cn-beijing.aliyuncs.com"]
        );
        assert_eq!(head("curl x\ny"), "curl x…");
    }

    /// The proxy itself: an off-list host gets a 403 and a hit, an on-list one is tunnelled
    /// (to a local server, so the test needs no network).
    #[tokio::test]
    async fn proxy_blocks_off_list_hosts_and_tunnels_listed_ones() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let upstream = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let up_port = upstream.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (mut s, _) = upstream.accept().await.unwrap();
            s.write_all(b"hello").await.unwrap();
        });
        let mut cfg = EgressConfig::default();
        cfg.allow.push("127.0.0.1".into());
        let e = Egress::new(Policy::resolve_in(&cfg, &Projects::default(), &std::env::temp_dir(), true));
        let (url, call) = register(&e, "Bash", "curl … && upload", vec![]).unwrap();
        let tok = url.split(':').nth(2).unwrap().split('@').next().unwrap().to_string();
        let port: u16 = url.rsplit(':').next().unwrap().parse().unwrap();
        use base64::Engine;
        let auth = base64::engine::general_purpose::STANDARD.encode(format!("frog:{tok}"));
        let ask = |target: String| {
            let auth = auth.clone();
            async move {
                let mut s = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
                s.write_all(
                    format!("CONNECT {target} HTTP/1.1\r\nProxy-Authorization: Basic {auth}\r\n\r\n").as_bytes(),
                )
                .await
                .unwrap();
                let mut out = Vec::new();
                let _ = tokio::time::timeout(
                    std::time::Duration::from_secs(5),
                    s.read_to_end(&mut out),
                )
                .await;
                String::from_utf8_lossy(&out).into_owned()
            }
        };
        let blocked = ask("oss-cn-beijing.aliyuncs.com:443".into()).await;
        assert!(blocked.starts_with("HTTP/1.1 403"), "{blocked}");
        assert!(blocked.contains("allow-list"), "{blocked}");
        let ok = ask(format!("127.0.0.1:{up_port}")).await;
        assert!(ok.starts_with("HTTP/1.1 200"), "{ok}");
        assert!(ok.ends_with("hello"), "{ok}");
        let hits = call.hits();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].host, "oss-cn-beijing.aliyuncs.com");
        assert!(hits[0].enforced);
        assert_eq!(e.drain(), hits);
    }

    #[test]
    fn the_digest_counts_blocked_attempts() {
        let dir = tempdir("log");
        let file = dir.join("egress.jsonl");
        let hit = |host: &str, enforced| Hit {
            host: host.into(),
            port: 443,
            tool: "Bash".into(),
            command: "curl".into(),
            enforced,
        };
        append_log(&file, "a", &hit("x.aliyuncs.com", true));
        append_log(&file, "a", &hit("x.aliyuncs.com", true));
        append_log(&file, "b", &hit("evil.example", true));
        append_log(&file, "b", &hit("flagged.example", false));
        let d = digest_in(&file, 0);
        assert_eq!(d.blocked, 3);
        assert_eq!(d.sessions, 2);
        assert_eq!(d.hosts[0], ("x.aliyuncs.com".into(), 2));
        assert_eq!(digest_in(&file, i64::MAX).blocked, 0);
        let _ = std::fs::remove_dir_all(dir);
    }
}
