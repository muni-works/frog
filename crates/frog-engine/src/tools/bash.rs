use super::{Ctx, Output, int_arg, str_arg, strip_ansi, truncate_middle};
use crate::config::SandboxConfig;
use crate::provider::ToolSpec;
use anyhow::{Result, bail};
use serde_json::{Value, json};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncReadExt;

pub fn spec() -> ToolSpec {
    let mut description = String::from(
        "Run a shell command and return its combined stdout/stderr. The working directory persists \
between calls (cd works). Use for builds, tests, git, and other terminal operations. Prefer Read/Edit/Glob/Grep \
over cat/sed/find/grep. Avoid interactive commands; they will hang until the timeout. \
To wait for a build, CI or anything slow, don't `sleep N; <check>` (it holds the turn and hits the timeout): \
start the slow command with run_in_background and you're told when it exits, or use Monitor to poll a check \
until it shows what you're waiting for.",
    );
    let mut props = json!({
        "command": { "type": "string", "description": "The command to run" },
        "timeout": { "type": "integer", "description": "Timeout in milliseconds (default 120000, max 600000)" },
        "run_in_background": { "type": "boolean", "description": "Start the command as a background job and return its id at once, for servers, watchers and long builds. Its output goes to a file; you're told when it exits (exit code and the tail of its output). Read it with JobOutput, stop it with JobStop." }
    });
    if available() {
        description.push_str(" Commands run in a sandbox: they can write only inside the project (and, in a git worktree, its git dirs so commit works), temp folders, toolchain caches and paths the user configured, and can't read credentials (~/.ssh, ~/.aws, ...). Network access works; swift builds get SwiftPM's inner sandbox disabled (frog's is the boundary), and read-only git commands can go over https to GitHub when configured. If a command fails because of the sandbox and genuinely needs more (installing globally, git push over ssh), run it again with unsandboxed: true; the user will be asked.");
        props["unsandboxed"] = json!({ "type": "boolean", "description": "Run outside the sandbox. Asks the user first. Only after the sandbox actually blocked this command — never because you think it might: builds, tests and most git already work inside it, and an unneeded escape makes the user approve the very build that would have just run. If a confined run fails with `Operation not permitted` or a read-only error, rerun it unsandboxed." });
        props["allow_hosts"] = json!({ "type": "array", "items": { "type": "string" }, "description": "Hosts beyond the session's network allow-list this command needs. Asks the user first; only after a connection was blocked." });
    }
    ToolSpec {
        name: "Bash".into(),
        description: description.into(),
        schema: json!({
            "type": "object",
            "properties": props,
            "required": ["command"]
        }),
    }
}

/// Whether Bash can be sandboxed here: macOS seatbelt, or bubblewrap on Linux.
pub fn available() -> bool {
    if cfg!(target_os = "macos") {
        std::path::Path::new("/usr/bin/sandbox-exec").exists()
    } else {
        bwrap().is_some()
    }
}

/// bubblewrap, if it's installed and can set up a sandbox here. Probed once: it can be
/// installed yet unusable (unprivileged user namespaces off, an AppArmor policy, a container
/// that forbids mounts), and then commands ask like they would unsandboxed.
fn bwrap() -> Option<&'static std::path::Path> {
    static BWRAP: std::sync::OnceLock<Option<std::path::PathBuf>> = std::sync::OnceLock::new();
    BWRAP
        .get_or_init(|| {
            if !cfg!(target_os = "linux") {
                return None;
            }
            let path = std::env::var_os("PATH")
                .into_iter()
                .flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
                .chain(["/usr/bin".into(), "/usr/local/bin".into()])
                .map(|d| d.join("bwrap"))
                .find(|p| p.is_file())?;
            let works = std::process::Command::new(&path)
                .args([
                    "--ro-bind",
                    "/",
                    "/",
                    "--dev-bind",
                    "/dev",
                    "/dev",
                    "/bin/sh",
                    "-c",
                    ":",
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .is_ok_and(|s| s.success());
            works.then_some(path)
        })
        .as_deref()
}

/// Kills the whole process group if the command is cancelled or times out: SIGTERM first so
/// shells can clean up, then SIGKILL after a short grace — an interrupt must land within ~1 s.
struct Group(i32);

impl Group {
    /// SIGTERM now, SIGKILL after `grace`. Called on cancel; Drop still SIGKILLs for the
    /// timeout path, where a hard stop is fine and no one is waiting on a graceful exit.
    fn terminate_async(&self, grace: Duration) {
        unsafe {
            libc::killpg(self.0, libc::SIGTERM);
        }
        let group = self.0;
        tokio::spawn(async move {
            tokio::time::sleep(grace).await;
            unsafe {
                libc::killpg(group, libc::SIGKILL);
            }
        });
    }
}

impl Drop for Group {
    fn drop(&mut self) {
        unsafe {
            libc::killpg(self.0, libc::SIGKILL);
        }
    }
}

pub async fn run(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let cmd = str_arg(input, "command")?;
    let timeout = Duration::from_millis(
        int_arg(input, "timeout")
            .unwrap_or(120_000)
            .clamp(1_000, 600_000),
    );
    // One file per call: concurrent calls in one process (parallel subagents, tests) would
    // otherwise read each other's final directory.
    static CALLS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let call = CALLS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let cwd_file = std::env::temp_dir().join(format!("frog-cwd-{}-{call}", std::process::id()));
    let _ = std::fs::remove_file(&cwd_file);
    // Under our sandbox, SwiftPM's own inner seatbelt sandbox can never apply (macOS rejects a
    // nested sandbox_apply outright), so `swift build` fails with "Invalid manifest" until it's
    // told not to use it. frog's sandbox stays the boundary; this only removes the redundant
    // inner one. Applied when we actually sandbox the command.
    let cmd = if ctx.shell_sandbox.is_some() || ctx.sandbox.is_some() {
        // Off the engine's event loop, and bounded: a scanner bug must never wedge the whole
        // session (Stop couldn't cancel a CPU-bound scan before the first await). On a timeout
        // the unadapted command runs; a sandboxed `swift build` failing with "Invalid manifest"
        // is recoverable, a stuck engine isn't.
        let cmd = cmd.to_string();
        let spawn = cmd.clone();
        match tokio::time::timeout(
            Duration::from_secs(2),
            tokio::task::spawn_blocking(move || adapt_swiftpm(&spawn)),
        )
        .await
        {
            Ok(Ok(adapted)) => adapted,
            // A spawn_blocking panic falls back too; the unadapted command still runs.
            _ => cmd,
        }
    } else {
        cmd.to_string()
    };
    let script = format!(
        "{{\n{cmd}\n}} 2>&1\n__frog_ec=$?\npwd -P > '{}'\nexit $__frog_ec",
        cwd_file.display()
    );
    let (mut command, jail, egress) = shell_call(input, ctx)?;
    let mut child = command
        .arg(&script)
        // Colors for the human watching; they're stripped before the model sees the output.
        .env("FORCE_COLOR", "1")
        .env("CLICOLOR_FORCE", "1")
        .env("CARGO_TERM_COLOR", "always")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true)
        .spawn()?;
    let group = Group(child.id().unwrap_or(0) as i32);
    let cancel = ctx.cancel.clone();
    let (Some(mut stdout), Some(mut stderr)) = (child.stdout.take(), child.stderr.take()) else {
        bail!("couldn't capture command output");
    };
    let progress = ctx.progress.clone();
    let collect = async {
        let (mut out, mut err) = (Capped::new(OUTPUT_CAP), Capped::new(OUTPUT_CAP / 4));
        let (mut buf, mut ebuf) = ([0u8; 8192], [0u8; 4096]);
        let (mut out_done, mut err_done) = (false, false);
        while !(out_done && err_done) {
            tokio::select! {
                r = stdout.read(&mut buf), if !out_done => match r? {
                    0 => out_done = true,
                    n => {
                        out.push(&buf[..n]);
                        if let Some(p) = &progress {
                            let _ = p.send(String::from_utf8_lossy(&buf[..n]).into_owned());
                        }
                    }
                },
                r = stderr.read(&mut ebuf), if !err_done => match r? {
                    0 => err_done = true,
                    n => err.push(&ebuf[..n]),
                },
                // The user pressed Stop: SIGTERM the group (SIGKILL follows after a grace),
                // then let the reads see EOF so the result is recorded, not dropped.
                _ = async {
                    match &cancel {
                        Some(t) => t.cancelled().await,
                        None => std::future::pending().await,
                    }
                } => {
                    group.terminate_async(Duration::from_millis(500));
                    bail!("interrupted by user");
                }
            }
        }
        let status = child.wait().await?;
        anyhow::Ok((out.finish(), err.finish(), status))
    };
    let (stdout, stderr, status) = match tokio::time::timeout(timeout, collect).await {
        Ok(r) => r?,
        Err(_) => bail!("{}", timed_out(timeout.as_secs())),
    };
    // Finished normally: leave any backgrounded processes alone.
    std::mem::forget(group);

    if let Ok(dir) = std::fs::read_to_string(&cwd_file) {
        let dir = std::path::PathBuf::from(dir.trim());
        if dir.is_dir() {
            ctx.cwd = dir;
        }
        let _ = std::fs::remove_file(&cwd_file);
    }

    let mut raw = String::from_utf8_lossy(&stdout).into_owned();
    let stderr = String::from_utf8_lossy(&stderr);
    if !stderr.trim().is_empty() {
        raw.push_str(&stderr);
    }
    let code = status.code().unwrap_or(-1);
    let finish = |text: String| {
        let mut text = truncate_middle(text.trim_end(), 30_000);
        if code != 0 {
            text.push_str(&format!("\n[exit code {code}]"));
        }
        if text.trim().is_empty() {
            "(no output)".to_string()
        } else {
            text
        }
    };
    if let Some(call) = &egress {
        egress_note(call, ctx, &mut raw);
        if cfg!(target_os = "linux")
            && jail.is_some()
            && ctx.egress.as_ref().is_some_and(|e| e.enforced())
            && blocked_network(&raw)
        {
            raw.push_str("\n(On Linux, frog can't enforce the network allow-list by host inside the sandbox, so sandboxed commands get no network at all. If the task needs the network, run the command again with unsandboxed: true; the user will be asked.)");
        }
    }
    if jail.is_some() && blocked(&raw) {
        raw.push_str("\n(This ran in frog's sandbox, which allows writes only inside the project, temp folders and toolchain caches, and hides credentials. If the command genuinely needs more, run it again with unsandboxed: true; the user will be asked.)");
    }
    let plain = strip_ansi(&raw);
    let display = (plain != raw).then(|| finish(raw.clone()));
    Ok(Output {
        content: finish(plain),
        display,
        diff: None,
        diagram: None,
        present: None,
        widget: None,
        ..Default::default()
    })
}

/// What a timeout says: the fix, not just the fact (models reran the same command, or slept
/// and polled, for want of it).
fn timed_out(secs: u64) -> String {
    let longer = if secs < 600 {
        "raise `timeout` (max 600000 ms), or "
    } else {
        ""
    };
    format!(
        "command timed out after {secs}s and was killed. If it just needs longer, {longer}run it with run_in_background: true (you're told when it exits). To wait for something else to finish, use Monitor rather than sleep."
    )
}

/// How much of a command's stdout frog keeps while reading (stderr gets a quarter). The model
/// sees at most ~30k characters anyway; the cap stops `yes` or a runaway log from growing
/// frog's memory without bound before that cut.
const OUTPUT_CAP: usize = 4 << 20;

/// An output buffer that keeps the first and last halves of `cap` bytes and counts what it
/// dropped between them, so memory stays bounded however much a command prints.
struct Capped {
    cap: usize,
    head: Vec<u8>,
    tail: std::collections::VecDeque<u8>,
    dropped: usize,
}

impl Capped {
    fn new(cap: usize) -> Self {
        Self {
            cap,
            head: Vec::new(),
            tail: std::collections::VecDeque::new(),
            dropped: 0,
        }
    }

    fn push(&mut self, mut bytes: &[u8]) {
        let half = self.cap / 2;
        if self.head.len() < half {
            let n = (half - self.head.len()).min(bytes.len());
            self.head.extend_from_slice(&bytes[..n]);
            bytes = &bytes[n..];
        }
        let keep = self.cap - half;
        if bytes.len() >= keep {
            self.dropped += self.tail.len() + bytes.len() - keep;
            self.tail.clear();
            self.tail.extend(&bytes[bytes.len() - keep..]);
            return;
        }
        let over = (self.tail.len() + bytes.len()).saturating_sub(keep);
        self.tail.drain(..over);
        self.dropped += over;
        self.tail.extend(bytes);
    }

    fn finish(self) -> Vec<u8> {
        let mut out = self.head;
        if self.dropped > 0 {
            out.extend_from_slice("\n…\n".as_bytes());
        }
        out.extend(self.tail);
        // Last, so the model's middle cut keeps it.
        if self.dropped > 0 {
            out.extend_from_slice(
                format!("\n[{} bytes of output dropped]", self.dropped).as_bytes(),
            );
        }
        out
    }
}

/// The user's shell, sandboxed exactly as a foreground call would be, in `ctx.cwd`, ready for
/// the script argument (`-c` is already added). Also returns the sandbox root, if any.
/// Background jobs and `Monitor` use it so they run under the same rules as Bash.
pub fn shell(
    input: &Value,
    ctx: &Ctx,
) -> Result<(tokio::process::Command, Option<std::path::PathBuf>)> {
    shell_call(input, ctx).map(|(command, jail, _)| (command, jail))
}

/// [`shell`], plus the command's registration with the egress proxy when the session has an
/// allow-list, to read what it tried to reach.
pub fn shell_call(
    input: &Value,
    ctx: &Ctx,
) -> Result<(
    tokio::process::Command,
    Option<std::path::PathBuf>,
    Option<std::sync::Arc<crate::egress::Call>>,
)> {
    let shell = std::env::var("SHELL")
        .ok()
        .filter(|s| s.ends_with("zsh") || s.ends_with("bash"))
        .unwrap_or("/bin/bash".into());
    // `--sandbox` (strict, for the bench) always applies; the everyday sandbox yields to an
    // explicit (and user-approved) `unsandboxed` call.
    let unsandboxed = input["unsandboxed"].as_bool() == Some(true);
    let jail = ctx
        .sandbox
        .clone()
        .or_else(|| (!unsandboxed).then(|| ctx.shell_sandbox.clone()).flatten());
    // The egress allow-list binds sandboxed commands only: an approved `unsandboxed` call is
    // the user's own grant past it.
    let egress = ctx.egress.as_ref().filter(|e| jail.is_some() && e.active());
    // macOS routes the sandbox through the proxy; Linux's bwrap can't reach the host's
    // loopback from its own network namespace, so there an enforced list fails closed (no
    // network at all, see `bubblewrap`).
    let enforce = egress.is_some_and(|e| e.enforced());
    let enforced_extra;
    let extra = if enforce {
        enforced_extra = SandboxConfig {
            network: Some("egress".into()),
            ..ctx.sandbox_extra.clone()
        };
        &enforced_extra
    } else {
        &ctx.sandbox_extra
    };
    let mut command = match &jail {
        None => tokio::process::Command::new(shell),
        // Git's write dirs follow the session's checkout, not the shell's current directory:
        // a `cd` into another checkout doesn't open its refs and objects for writing.
        Some(root) => sandboxed(root, &shell, extra, &git_dirs(&ctx.root))?,
    };
    // The sandbox hides frog's key files, so it hides the same secrets in its environment:
    // `env | curl …` would otherwise send ANTHROPIC_API_KEY, GH_TOKEN or AWS keys anywhere
    // the network allows.
    if jail.is_some() {
        for (k, _) in std::env::vars_os() {
            if k.to_str().is_some_and(crate::credentials::is_secret_env) {
                command.env_remove(k);
            }
        }
    }
    let cmd = input["command"].as_str().unwrap_or("");
    let mut call = None;
    if let Some(e) = egress {
        let tool = if input.get("until_regex").is_some() || input.get("until_exit").is_some() {
            crate::background::MONITOR
        } else {
            "Bash"
        };
        // Hosts the user allowed for this one command (its approval card).
        let extra_hosts = e.take_once(cmd);
        let Some((url, c)) = crate::egress::register(e, tool, cmd, extra_hosts) else {
            bail!(
                "frog's network allow-list proxy couldn't start, so sandboxed commands can't run"
            );
        };
        for k in [
            "HTTPS_PROXY",
            "https_proxy",
            "HTTP_PROXY",
            "http_proxy",
            "ALL_PROXY",
            "all_proxy",
        ] {
            command.env(k, &url);
        }
        command
            .env("NO_PROXY", "localhost,127.0.0.1,::1")
            .env("no_proxy", "localhost,127.0.0.1,::1");
        call = Some(c);
    }
    if jail.is_some()
        && egress.is_none()
        && cfg!(target_os = "macos")
        && ctx.sandbox_extra.network.as_deref() == Some("dev")
    {
        if let Some(port) = dev_proxy() {
            let url = format!("http://127.0.0.1:{port}");
            for k in ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"] {
                command.env(k, &url);
            }
        }
    }
    // Git reads that would otherwise need ~/.ssh: with `git_https` on, git's ssh URLs to
    // github.com become https through a config overlay that exists only for this one command
    // (GIT_CONFIG_* env; no file is touched), and gh's credential helper supplies auth — no
    // keys ever readable. Only for read subcommands with no `push` in the command: a push
    // stays an approval, and `url.insteadOf` would redirect its URL too.
    if jail.is_some() && ctx.sandbox_extra.git_https && git_https_applies(cmd) {
        command
            .env("GIT_CONFIG_COUNT", "2")
            .env("GIT_CONFIG_KEY_0", "url.https://github.com/.insteadOf")
            .env("GIT_CONFIG_VALUE_0", "git@github.com:")
            .env("GIT_CONFIG_KEY_1", "credential.helper")
            .env("GIT_CONFIG_VALUE_1", "!gh auth git-credential");
    }
    command
        .arg("-c")
        .current_dir(&ctx.cwd)
        .env("PAGER", "cat")
        .env("GIT_PAGER", "cat")
        .env("FROG", "1");
    Ok((command, jail, call))
}

/// Whether output looks like a connection that failed for lack of a network.
fn blocked_network(raw: &str) -> bool {
    let l = raw.to_ascii_lowercase();
    [
        "could not resolve",
        "network is unreachable",
        "temporary failure in name resolution",
        "name or service not known",
        "failed to connect",
    ]
    .iter()
    .any(|m| l.contains(m))
}

/// After an allow-list command: name the hosts a client that ignored the proxy couldn't
/// resolve (the sandbox denies DNS), and tell the model what was blocked and how to ask.
fn egress_note(call: &crate::egress::Call, ctx: &Ctx, raw: &mut String) {
    let enforced = ctx.egress.as_ref().is_some_and(|e| e.enforced());
    if !enforced {
        return;
    }
    let seen: Vec<String> = call.hits().into_iter().map(|h| h.host).collect();
    for host in crate::egress::unresolved(raw) {
        if !seen.contains(&host) && !ctx.egress.as_ref().is_some_and(|e| e.allows(&host)) {
            call.record(&host, 0);
        }
    }
    let mut hosts: Vec<String> = Vec::new();
    for h in call.hits() {
        if !hosts.contains(&h.host) {
            hosts.push(h.host);
        }
    }
    if hosts.is_empty() {
        return;
    }
    let list = hosts
        .iter()
        .map(|h| format!("\"{h}\""))
        .collect::<Vec<_>>()
        .join(", ");
    raw.push_str(&format!(
        "\n(frog blocked network access to {}: not on this session's allow-list. The attempt is logged and shown to the user. If the task genuinely needs it, run the command again with allow_hosts: [{list}]; the user will be asked.)",
        hosts.join(", ")
    ));
}

/// Output that looks like the sandbox got in the way.
fn blocked(out: &str) -> bool {
    out.contains("Operation not permitted") && out.contains("exit code")
        || out.contains("Read-only file system")
        || out.contains("deny(1) file-")
}

/// Add `--disable-sandbox` to `swift build`/`run`/`test`/`package` when missing. Under our
/// seatbelt sandbox SwiftPM's own (inner) sandbox can't apply — macOS rejects a nested
/// `sandbox_apply` unconditionally, so manifest compilation fails with "Invalid manifest ...
/// sandbox_apply: Operation not permitted". frog's sandbox is still the outer boundary; this
/// only skips the redundant inner one. Invocations that already pass the flag, and other
/// `swift` subcommands (`swiftc`, `swift repl`), are left alone.
///
/// Token-level single pass: everything that isn't a matched `swift <verb>` pair is copied
/// byte-for-byte, so quoting, separators and spacing survive. A `swift` inside quotes or after
/// another word (e.g. `echo swift build`) is never rewritten: we only match at a command
/// position — the start of the command, or right after `; & | ( {` or a line break.
fn adapt_swiftpm(cmd: &str) -> String {
    const VERBS: &[&str] = &["build", "run", "test", "package"];
    let looks_like_swift_verb = |tok: &str| VERBS.contains(&tok);
    let is_word = |c: char| !c.is_whitespace() && !";&|(){".contains(c);

    let mut out = String::with_capacity(cmd.len() + 24);
    let bytes: Vec<char> = cmd.chars().collect();
    let mut i = 0;
    // Command positions: the very start, or after one of ; & | ( { or a newline, once the
    // following whitespace runs out. Env prefixes and trampolines are stepped over.
    let mut at_command = true;
    let mut rewrote = false;
    while i < bytes.len() {
        let c = bytes[i];
        if ";&|({\n".contains(c) {
            out.push(c);
            i += 1;
            at_command = true;
            continue;
        }
        if c.is_whitespace() {
            out.push(c);
            i += 1;
            continue;
        }
        // Read one word.
        let start = i;
        while i < bytes.len() && is_word(bytes[i]) {
            i += 1;
        }
        if i == start {
            // `)` and `}` are neither separators nor word characters: copy and move on, or
            // this loop never advances and the engine wedges so Stop can't interrupt.
            out.push(c);
            i += 1;
            continue;
        }
        let word: String = bytes[start..i].iter().collect();
        if at_command {
            let envish = word == "env"
                || word == "nice"
                || word == "nohup"
                || word == "command"
                || (word.contains('=') && !word.starts_with('-'));
            if word == "swift" {
                // Peek the next word; if it's a verb we rewrite, unless the invocation
                // already carries the flag before the next command separator.
                let mut j = i;
                while j < bytes.len() && bytes[j].is_whitespace() && !";&|({\n".contains(bytes[j]) {
                    j += 1;
                }
                let vstart = j;
                while j < bytes.len() && is_word(bytes[j]) {
                    j += 1;
                }
                let verb: String = bytes[vstart..j].iter().collect();
                let has_flag = {
                    let mut k = j;
                    let mut found = false;
                    while k < bytes.len() {
                        if ";\n".contains(bytes[k])
                            || (bytes[k] == '&' && bytes.get(k + 1) == Some(&'&'))
                            || (bytes[k] == '|' && bytes.get(k + 1) == Some(&'|'))
                        {
                            break;
                        }
                        if bytes[k].is_whitespace() {
                            k += 1;
                            continue;
                        }
                        let ws = k;
                        while k < bytes.len() && is_word(bytes[k]) && !";&|()".contains(bytes[k]) {
                            k += 1;
                        }
                        if k == ws {
                            // A lone `)`, `}`, `(` or unmatched quote isn't a word; step past
                            // it, or this scan spins forever (Stop couldn't interrupt a
                            // command while this ran).
                            k += 1;
                            continue;
                        }
                        let w: String = bytes[ws..k].iter().collect();
                        if w == "--disable-sandbox" {
                            found = true;
                            break;
                        }
                    }
                    found
                };
                if looks_like_swift_verb(&verb) && !has_flag {
                    out.push_str(&word);
                    // Insert the whitespace we skipped between swift and the verb.
                    for b in &bytes[i..vstart] {
                        out.push(*b);
                    }
                    out.push_str(&verb);
                    out.push_str(" --disable-sandbox");
                    i = j;
                    rewrote = true;
                    at_command = false;
                    continue;
                }
            }
            out.push_str(&word);
            at_command = envish;
            continue;
        }
        out.push_str(&word);
    }
    if rewrote { out } else { cmd.to_string() }
}

/// Toolchain caches that builds write to (a `cargo build` locks ~/.cargo, npm keeps ~/.npm):
/// low-risk, and builds break without them.
const CACHES: &[&str] = &[
    ".cargo",
    ".rustup",
    ".npm",
    ".cache",
    "Library/Caches",
    "go",
    ".gradle",
    ".m2",
    ".bun",
    ".pnpm-store",
    "Library/pnpm",
    ".yarn",
    ".nuget",
    ".swiftpm",
    "Library/Developer/Xcode/DerivedData",
    // SwiftPM's user-level configuration/security fingerprints and, on newer toolchains,
    // manifest/plugin caches: builds warn or fail without them.
    "Library/org.swift.swiftpm",
    ".gem",
    ".local/share/pnpm",
    ".deno",
    ".elan",
    ".opam",
    ".stack",
    ".cabal",
    ".mix",
    ".hex",
];

/// Inside CACHES, what runs later outside the sandbox: installed binaries and toolchains on
/// PATH, and config that names a command (cargo's `runner`, gradle init scripts). Read-only,
/// so a command can fill caches but can't replace `~/.cargo/bin/cargo` for the user's next run.
const CACHE_EXEC: &[&str] = &[
    ".cargo/bin",
    ".cargo/config",
    ".cargo/config.toml",
    ".rustup/toolchains",
    ".rustup/settings.toml",
    "go/bin",
    ".bun/bin",
    ".deno/bin",
    ".elan/bin",
    ".elan/toolchains",
    ".gradle/init.d",
    ".gradle/init.gradle",
    ".gradle/gradle.properties",
    ".m2/settings.xml",
    ".yarn/bin",
    ".gem/bin",
    ".mix/escripts",
    ".cabal/bin",
    ".cabal/config",
    ".opam/default/bin",
    ".local/share/pnpm/pnpm",
];

/// Non-secret config that sandboxed commands may read by default (under $HOME). Everything a
/// build or a read-only git command routinely looks at, and nothing that holds a credential:
/// the credential paths stay in SECRETS and only open with `allow_read`.
const DEFAULT_READABLE: &[&str] = &[".gitconfig", ".cargo/config.toml", ".gitignore_global"];

/// Credentials a sandboxed command can't read, so a prompt-injected command can't read them
/// and send them over the network. Shared with Read and the classifier.
const SECRETS: &[&str] = crate::credentials::HOME_SECRETS;

/// Whether the git-https overlay should apply to this command: it's git with a read-only-ish
/// subcommand (fetch, ls-remote, clone, submodule update, status, diff, log, show, branch,
/// rev-parse, describe, remote, worktree), or `git pull` (with or without --ff-only), and no
/// `push` anywhere (auto.rs's hard rule already makes a push ask; `url.insteadOf` would
/// redirect a push's URL too, so the overlay must never see one). Applies only when sandboxed
/// and the config opt-in `[sandbox] git_https` is on (default on: it only widens what already
/// works over the network and exposes no credentials; ssh keys stay hidden either way).
fn git_https_applies(cmd: &str) -> bool {
    const READ_SUBCOMMANDS: &[&str] = &[
        "fetch",
        "ls-remote",
        "pull",
        "clone",
        "submodule",
        "status",
        "diff",
        "log",
        "show",
        "branch",
        "rev-parse",
        "describe",
        "remote",
        "worktree",
    ];
    let tokens: Vec<&str> = cmd.split_whitespace().collect();
    // Any push token anywhere disqualifies the whole command.
    if tokens.iter().any(|t| *t == "push") {
        return false;
    }
    // Any `git` whose remaining arguments contain a read subcommand before the next command
    // separator (`;`, `&&`, `|`). Covers `git fetch`, `git -C path ls-remote`, `cd x && git
    // pull --ff-only`; a `git add`/`git commit` alone doesn't trigger it.
    let mut applies = false;
    let mut i = 0;
    while i < tokens.len() {
        if tokens[i] == "git" {
            for t in &tokens[i + 1..] {
                if *t == ";" || *t == "&&" || *t == "||" || *t == "|" {
                    break;
                }
                if READ_SUBCOMMANDS.contains(t) {
                    applies = true;
                    break;
                }
            }
        }
        i += 1;
    }
    applies
}
fn readable(extra: &SandboxConfig, home: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut paths: Vec<std::path::PathBuf> = DEFAULT_READABLE
        .iter()
        .map(|c| home.join(c))
        .chain(
            // frog's own config.toml, by name: agents read it to learn the project's setup.
            // models.json and any `keys*`/`config.d/` stay denied.
            [home.join(".config/frog/config.toml")],
        )
        .chain(extra.allow_read.iter().map(|p| expand_home(p, home)))
        .filter(|p| p.is_absolute())
        .collect();
    if extra.allow_keychain && cfg!(target_os = "macos") {
        paths.push(home.join("Library/Keychains"));
    }
    paths
        .into_iter()
        .map(|p| p.canonicalize().unwrap_or(p))
        .collect()
}

/// Paths the user let sandboxed commands write (config `[sandbox] allow_write`), canonical
/// where they exist. Off by default; for things the workspace alone can't cover, like shared
/// build dirs (`~/Developer/.shared-target`) or agent worktrees of sibling projects.
fn writable(extra: &SandboxConfig, home: &std::path::Path) -> Vec<std::path::PathBuf> {
    extra
        .allow_write
        .iter()
        .map(|p| expand_home(p, home))
        .filter(|p| p.is_absolute())
        .map(|p| p.canonicalize().unwrap_or(p))
        .collect()
}

/// `~/…` → under `home`; anything else passes through.
fn expand_home(p: &str, home: &std::path::Path) -> std::path::PathBuf {
    match p.strip_prefix("~/") {
        Some(rest) => home.join(rest),
        None if p == "~" => home.to_path_buf(),
        None => p.into(),
    }
}

/// Hosts `sandbox.network = "dev"` lets commands reach (https, port 443 only).
pub const DEV_HOSTS: &[&str] = &[
    "github.com",
    "objects.githubusercontent.com",
    "codeload.github.com",
    "crates.io",
    "static.crates.io",
    "index.crates.io",
    "registry.npmjs.org",
    // Swift packages mostly resolve through GitHub; these cover the toolchain and index.
    "swiftpackageindex.com",
    "swift.org",
    "download.swift.org",
];

/// When the session's folder is a git worktree, the dirs git writes to (`index.lock`, refs,
/// objects): the per-worktree git dir and the common dir. Nothing else of the main checkout
/// opens up.
pub fn git_dirs(cwd: &std::path::Path) -> Vec<std::path::PathBuf> {
    let Ok(out) = std::process::Command::new("git")
        .args(["rev-parse", "--git-dir", "--git-common-dir"])
        .current_dir(cwd)
        .output()
    else {
        return vec![];
    };
    if !out.status.success() {
        return vec![];
    }
    let mut dirs: Vec<std::path::PathBuf> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| cwd.join(l.trim()))
        .filter_map(|p| p.canonicalize().ok())
        .collect();
    dirs.sort();
    dirs.dedup();
    dirs
}

/// Inside git dirs, what sandboxed commands must never write: config (`core.fsmonitor`,
/// `core.hooksPath`, filter drivers), hooks and `info/attributes`. frog runs git on the same
/// repo unsandboxed (checkpoints, worktrees), so any of these would run a planted command
/// outside the sandbox.
fn git_protected(git: &[std::path::PathBuf]) -> Vec<std::path::PathBuf> {
    git.iter()
        .flat_map(|d| ["config", "config.worktree", "hooks", "info"].map(|f| d.join(f)))
        .collect()
}

/// Seatbelt can only match `*` or localhost for network peers, so `network = "dev"` blocks all
/// outbound except localhost and sends HTTPS through this allowlisting CONNECT proxy. Started
/// once per process; returns its port.
fn dev_proxy() -> Option<u16> {
    static PORT: std::sync::OnceLock<Option<u16>> = std::sync::OnceLock::new();
    *PORT.get_or_init(|| {
        let std_listener = std::net::TcpListener::bind("127.0.0.1:0").ok()?;
        std_listener.set_nonblocking(true).ok()?;
        let port = std_listener.local_addr().ok()?.port();
        let listener = tokio::net::TcpListener::from_std(std_listener).ok()?;
        tokio::spawn(async move {
            while let Ok((conn, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let _ = proxy_connection(conn).await;
                });
            }
        });
        Some(port)
    })
}

async fn proxy_connection(mut conn: tokio::net::TcpStream) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut head = Vec::new();
    let mut buf = [0u8; 1024];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") && head.len() < 8192 {
        let n = conn.read(&mut buf).await?;
        if n == 0 {
            return Ok(());
        }
        head.extend_from_slice(&buf[..n]);
    }
    let line = String::from_utf8_lossy(&head);
    let target = line
        .lines()
        .next()
        .and_then(|l| l.strip_prefix("CONNECT "))
        .and_then(|l| l.split_whitespace().next())
        .and_then(|t| t.rsplit_once(':'));
    let Some((host, "443")) = target else {
        return conn
            .write_all(b"HTTP/1.1 403 Forbidden\r\n\r\nfrog sandbox: only https to dev hosts\r\n")
            .await;
    };
    if !DEV_HOSTS.contains(&host.to_ascii_lowercase().as_str()) {
        return conn
            .write_all(b"HTTP/1.1 403 Forbidden\r\n\r\nfrog sandbox: host not in sandbox.network = \"dev\"\r\n")
            .await;
    }
    let mut upstream = tokio::net::TcpStream::connect((host, 443)).await?;
    conn.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        .await?;
    tokio::io::copy_bidirectional(&mut conn, &mut upstream).await?;
    Ok(())
}

/// Wrap the shell in the OS sandbox: writes only inside the workspace, temp dirs and toolchain
/// caches, credentials unreadable (except what `extra` allows), everything else (including
/// network) allowed. Fails closed where there's no sandbox to use.
fn sandboxed(
    root: &std::path::Path,
    shell: &str,
    extra: &SandboxConfig,
    git: &[std::path::PathBuf],
) -> Result<tokio::process::Command> {
    if cfg!(target_os = "macos") {
        seatbelt(root, shell, extra, git)
    } else if let Some(bwrap) = bwrap() {
        Ok(bubblewrap(
            bwrap,
            root,
            &dirs::home_dir().unwrap_or_default(),
            shell,
            extra,
            git,
        ))
    } else if cfg!(target_os = "linux") {
        bail!(
            "the Bash sandbox needs bubblewrap (`bwrap`), which isn't installed or can't run here"
        )
    } else {
        bail!("the Bash sandbox is only implemented on macOS and Linux")
    }
}

/// macOS: a seatbelt profile.
fn seatbelt(
    root: &std::path::Path,
    shell: &str,
    extra: &SandboxConfig,
    git: &[std::path::PathBuf],
) -> Result<tokio::process::Command> {
    let tmp = std::env::temp_dir()
        .canonicalize()
        .unwrap_or_else(|_| std::env::temp_dir());
    let quote = |p: &std::path::Path| {
        p.display()
            .to_string()
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
    };
    let home = dirs::home_dir().unwrap_or_default();
    let home = home.canonicalize().unwrap_or(home);
    let caches: String = CACHES
        .iter()
        .map(|c| format!("\n  (subpath \"{}\")", quote(&home.join(c))))
        .collect();
    let secrets: String = SECRETS
        .iter()
        .map(|c| format!("\n  (subpath \"{}\")", quote(&home.join(c))))
        .collect();
    // Later rules win: these re-allow reading (never writing) what the user opted into.
    let reads: String = readable(extra, &home)
        .iter()
        .map(|p| format!("\n(allow file-read* (subpath \"{}\"))", quote(p)))
        .collect();
    // Later rules win: git's config and hooks, and the toolchains in the caches, stay
    // read-only inside their writable dirs.
    let protected: String = git_protected(git)
        .into_iter()
        .chain(CACHE_EXEC.iter().map(|c| home.join(c)))
        .map(|p| format!("\n(deny file-write* (subpath \"{}\"))", quote(&p)))
        .collect();
    let git: String = git
        .iter()
        .map(|p| format!("\n  (subpath \"{}\")", quote(p)))
        .collect();
    let writes: String = writable(extra, &home)
        .iter()
        .map(|p| format!("\n  (subpath \"{}\")", quote(p)))
        .collect();
    let network = match extra.network.as_deref() {
        Some("dev") | Some("none") => {
            "\n(deny network-outbound)\n(allow network-outbound (remote ip \"localhost:*\"))"
                .to_string()
        }
        // The egress allow-list: nothing leaves but through the localhost proxy, which
        // decides by name. Local unix sockets keep working (build daemons, agents), except
        // mDNSResponder's: with it, any lookup (`dig`, `getaddrinfo`) would still reach DNS,
        // which carries data out on its own.
        Some("egress") => concat!(
            "\n(deny network-outbound)",
            "\n(allow network-outbound (remote ip \"localhost:*\"))",
            "\n(allow network-outbound (remote unix-socket))",
            "\n(deny network-outbound (remote unix-socket (path-literal \"/private/var/run/mDNSResponder\")))"
        )
        .to_string(),
        _ => String::new(),
    };
    let profile = format!(
        r#"(version 1)
(allow default)
(deny file-write*)
(allow file-write*
  (subpath "{}")
  (subpath "{}")
  (subpath "/private/tmp")
  (subpath "/private/var/folders")
  (literal "/dev/null")
  (literal "/dev/tty")
  (regex #"^/dev/fd/"){caches}{git}{writes}){protected}
(deny file-read* file-write*{secrets}){reads}{network}"#,
        quote(root),
        quote(&tmp)
    );
    let mut cmd = tokio::process::Command::new("/usr/bin/sandbox-exec");
    cmd.arg("-p").arg(profile).arg(shell);
    Ok(cmd)
}

/// Linux: bubblewrap. The whole filesystem read-only, the workspace, temp dirs and existing
/// toolchain caches bound writable over it, then credentials masked last so they stay hidden
/// even when the workspace contains them (a project at `~`). `/proc` and `/dev` are shared,
/// like seatbelt's `allow default`; the network is too unless `sandbox.network` (or an
/// enforced egress list) restricts it, which unshares it (`denies_network`). No `--die-with-parent` or `--new-session`: a
/// command's background processes outlive it the way they do unsandboxed, and staying in our
/// process group is what lets a timeout kill them all.
fn bubblewrap(
    bwrap: &std::path::Path,
    root: &std::path::Path,
    home: &std::path::Path,
    shell: &str,
    extra: &SandboxConfig,
    git: &[std::path::PathBuf],
) -> tokio::process::Command {
    use std::path::{Path, PathBuf};
    let real = |p: &Path| p.canonicalize().ok();
    let home = real(home).unwrap_or_else(|| home.to_path_buf());

    let mut cmd = tokio::process::Command::new(bwrap);
    cmd.args(["--ro-bind", "/", "/", "--dev-bind", "/dev", "/dev"]);
    let mut writable_paths: Vec<PathBuf> = vec![root.to_path_buf()];
    writable_paths.extend(real(&std::env::temp_dir()));
    writable_paths.extend(
        ["/tmp", "/var/tmp"]
            .iter()
            .filter_map(|p| real(Path::new(p))),
    );
    writable_paths.extend(CACHES.iter().filter_map(|c| real(&home.join(c))));
    writable_paths.extend(git.iter().cloned());
    writable_paths.extend(writable(extra, &home));
    writable_paths.sort();
    writable_paths.dedup();
    for p in &writable_paths {
        cmd.arg("--bind").arg(p).arg(p);
    }
    // Git's config and hooks, and the caches' toolchains, read-only over their writable dirs
    // (see `git_protected`, `CACHE_EXEC`).
    let exec = CACHE_EXEC.iter().filter_map(|c| real(&home.join(c)));
    for p in git_protected(git)
        .into_iter()
        .chain(exec)
        .filter(|p| p.exists())
    {
        cmd.arg("--ro-bind").arg(&p).arg(&p);
    }
    // Credentials the user let commands read stay visible, read-only even inside a writable
    // bind (a project at `~`).
    let readable = readable(extra, &home);
    for secret in SECRETS.iter().filter_map(|s| real(&home.join(s))) {
        if readable.iter().any(|r| secret.starts_with(r)) {
            cmd.arg("--ro-bind").arg(&secret).arg(&secret);
        } else if secret.is_dir() {
            cmd.arg("--tmpfs")
                .arg(&secret)
                .arg("--remount-ro")
                .arg(&secret);
        } else {
            cmd.arg("--ro-bind").arg("/dev/null").arg(&secret);
        }
    }
    if denies_network(extra) {
        cmd.arg("--unshare-net");
    }
    cmd.arg("--").arg(shell);
    cmd
}

/// Whether bwrap gives the command its own empty network namespace (loopback only). Any
/// `sandbox.network` other than unset/"open" does: `"none"` asks for it, and the allow-lists
/// (`"dev"`, an enforced egress list) can't be enforced by name on Linux, since the sandbox
/// can't reach a proxy on the host's loopback from its own namespace. They fail closed.
fn denies_network(extra: &SandboxConfig) -> bool {
    extra
        .network
        .as_deref()
        .is_some_and(|n| !n.is_empty() && n != "open")
}

#[cfg(all(test, any(target_os = "macos", target_os = "linux")))]
mod tests {
    use super::*;

    /// A command that runs `sleep <secs>` as a child of the tool's shell and records that
    /// child's own pid in `ws/pid`, so a test can check exactly the process it started.
    /// (Matching `pgrep -f "sleep N"` machine-wide also catches any other `sleep N` on the
    /// box: another session's, a CI neighbour's.)
    fn sleeper(ws: &std::path::Path, secs: u32) -> String {
        format!(
            "sleep {secs} & echo $! > '{}'; wait",
            ws.join("pid").display()
        )
    }

    /// Drives `run` until the sleeper has recorded its pid (up to 10s), so a test cancels a
    /// command that really started. (A fixed sleep while `run` sits pinned and unpolled
    /// never spawns it at all.)
    async fn until_sleeping<F: std::future::Future + Unpin>(run: &mut F, ws: &std::path::Path) {
        let pid = ws.join("pid");
        let started = async {
            for _ in 0..200 {
                if std::fs::read_to_string(&pid).is_ok_and(|s| !s.trim().is_empty()) {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            panic!("the sleeper never started");
        };
        tokio::select! {
            _ = run => panic!("the command finished before it was interrupted"),
            _ = started => {}
        }
    }

    /// Polls up to 2s for the sleeper's recorded pid to be gone (a zombie counts as gone).
    async fn sleeper_gone(ws: &std::path::Path) -> bool {
        let pid =
            std::fs::read_to_string(ws.join("pid")).expect("the sleeper never recorded its pid");
        let pid = pid.trim().to_string();
        assert!(pid.parse::<u32>().is_ok(), "bad pid {pid:?}");
        for _ in 0..20 {
            let stat = std::process::Command::new("ps")
                .args(["-o", "stat=", "-p", &pid])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_default();
            if stat.is_empty() || stat.starts_with('Z') {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        false
    }

    /// Provider keys, tokens and other secret-shaped variables in frog's environment don't
    /// reach sandboxed commands; ordinary ones do.
    #[tokio::test]
    async fn sandbox_strips_secrets_from_the_environment() {
        if !available() {
            eprintln!("no OS sandbox here; skipping");
            return;
        }
        // Names no other test or tool reads, so setting them can't race anything.
        const VARS: &[&str] = &[
            "FROG_SANDBOX_TEST_API_KEY",
            "FROG_SANDBOX_TEST_TOKEN",
            "FROG_SANDBOX_TEST_SECRET_X",
            "RUNPOD_SECRET_frog_sandbox_test",
        ];
        for v in VARS {
            unsafe { std::env::set_var(v, "sk-leak") };
        }
        unsafe { std::env::set_var("FROG_SANDBOX_TEST_PLAIN", "kept") };
        let ws = std::env::temp_dir().join(format!("frog-envkey-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let ws = ws.canonicalize().unwrap();
        let mut ctx = Ctx::new(ws.clone());
        ctx.sandbox = Some(ws.clone());
        let out = run(
            &json!({ "command": "env | grep -c sk-leak; echo \"plain=[${FROG_SANDBOX_TEST_PLAIN:-}]\"" }),
            &mut ctx,
        )
        .await
        .unwrap();
        for v in VARS.iter().chain(&["FROG_SANDBOX_TEST_PLAIN"]) {
            unsafe { std::env::remove_var(v) };
        }
        assert!(out.content.starts_with('0'), "{}", out.content);
        assert!(out.content.contains("plain=[kept]"), "{}", out.content);
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// A sandboxed command can commit, but can't touch git's config or hooks: frog runs git on
    /// the same repo unsandboxed, so either would plant a command that escapes the sandbox.
    #[tokio::test]
    async fn sandbox_keeps_git_config_and_hooks_read_only() {
        if !available() {
            eprintln!("no OS sandbox here; skipping");
            return;
        }
        let repo = std::env::temp_dir().join(format!("frog-gitcfg-{}", crate::session::new_id()));
        std::fs::create_dir_all(&repo).unwrap();
        assert!(
            std::process::Command::new("git")
                .args(["init", "-q"])
                .current_dir(&repo)
                .status()
                .unwrap()
                .success()
        );
        let repo = repo.canonicalize().unwrap();
        let mut ctx = Ctx::new(repo.clone());
        ctx.sandbox = Some(repo.clone());
        let out = run(
            &json!({ "command": "echo a > a.txt && git add a.txt && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm ok && echo committed" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(out.content.contains("committed"), "{}", out.content);
        for cmd in [
            "git config core.fsmonitor 'touch pwned'",
            "echo x > .git/hooks/post-checkout",
            "mkdir -p .git/info && echo x > .git/info/attributes",
        ] {
            let _ = run(&json!({ "command": cmd }), &mut ctx).await;
        }
        let config = std::fs::read_to_string(repo.join(".git/config")).unwrap();
        assert!(!config.contains("fsmonitor"), "{config}");
        assert!(!repo.join(".git/hooks/post-checkout").exists());
        assert!(!repo.join(".git/info/attributes").exists());
        let _ = std::fs::remove_dir_all(&repo);
    }

    /// A commit inside a linked worktree works (index.lock, refs, objects live outside the
    /// worktree); a write elsewhere in the main checkout still fails.
    #[tokio::test]
    async fn sandbox_lets_git_commit_in_a_linked_worktree() {
        if !available() {
            eprintln!("no OS sandbox here; skipping");
            return;
        }
        let base = std::env::temp_dir().join(format!("frog-wt-{}", crate::session::new_id()));
        let main = base.join("main");
        let wt = base.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        let git = |dir: &std::path::Path, args: &[&str]| {
            let ok = std::process::Command::new("git")
                .args([
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t@t",
                    "-c",
                    "commit.gpgsign=false",
                ])
                .args(args)
                .current_dir(dir)
                .status()
                .unwrap()
                .success();
            assert!(ok, "git {args:?} failed");
        };
        git(&main, &["init", "-q"]);
        std::fs::write(main.join("a.txt"), "a").unwrap();
        git(&main, &["add", "."]);
        git(&main, &["commit", "-qm", "init"]);
        git(&main, &["worktree", "add", "-q", wt.to_str().unwrap()]);

        let mut ctx = Ctx::new(wt.clone());
        ctx.sandbox = Some(wt.canonicalize().unwrap());
        let out = run(
            &json!({ "command": "echo b > b.txt && git add b.txt && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm wt && git log --oneline | head -1" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(out.content.contains("wt"), "{}", out.content);

        // Temp dirs are writable, so the "outside" path lives in home.
        let outside = dirs::home_dir()
            .unwrap()
            .join(".frog-sandbox-worktree-escape-test");
        let out = run(
            &json!({ "command": format!("touch '{}'", outside.display()) }),
            &mut ctx,
        )
        .await
        .unwrap();
        let escaped = outside.exists();
        let _ = std::fs::remove_file(&outside);
        assert!(!escaped, "write outside the allowed set succeeded");
        assert!(out.content.contains("exit code"), "{}", out.content);
        let _ = std::fs::remove_dir_all(&base);
    }

    /// `network = "dev"` yields a valid profile (the command still runs) and blocks a host
    /// that isn't on the list, without needing the network to be up.
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn dev_network_profile_is_valid_and_blocks_other_hosts() {
        let ws = std::env::temp_dir().join(format!("frog-net-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        ctx.sandbox = Some(ws.canonicalize().unwrap());
        ctx.sandbox_extra.network = Some("dev".into());
        let ok = run(&json!({ "command": "echo fine" }), &mut ctx)
            .await
            .unwrap();
        assert!(ok.content.contains("fine"), "{}", ok.content);
        let out = run(
            &json!({ "command": "curl -sS -m 5 -o /dev/null --noproxy '*' https://1.1.1.1/ ; echo rc=$?" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(!out.content.contains("rc=0"), "{}", out.content);
        // Through the proxy, a host off the list gets 403 (curl rc 56) without touching the net.
        let out = run(
            &json!({ "command": "curl -sS -m 5 -o /dev/null https://example.com/ ; echo rc=$?" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(!out.content.contains("rc=0"), "{}", out.content);
    }

    fn egress_ctx(ws: &std::path::Path, mode: crate::egress::Mode, allow: &[&str]) -> Ctx {
        let mut ctx = Ctx::new(ws.to_path_buf());
        ctx.shell_sandbox = Some(ws.canonicalize().unwrap());
        let mut cfg = crate::config::Config {
            hermetic: true,
            worker: true,
            ..Default::default()
        };
        cfg.egress.workers_deny_by_default = mode == crate::egress::Mode::Enforce;
        cfg.egress.interactive = mode;
        cfg.worker = mode == crate::egress::Mode::Enforce;
        cfg.egress.allow = allow.iter().map(|s| s.to_string()).collect();
        ctx.egress = crate::egress::for_session(&cfg, ws);
        ctx
    }

    /// Under an enforced list: a listed host goes through the proxy (plain http, to a local
    /// server, so no network is needed); a client that ignores the proxy can't even resolve,
    /// and the host it tried is still named; DNS itself is closed.
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn egress_passes_listed_hosts_and_names_proxy_dodgers() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let ws = std::env::temp_dir().join(format!("frog-eg-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let server = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = server.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (mut s, _) = server.accept().await.unwrap();
            let mut buf = [0u8; 1024];
            let n = s.read(&mut buf).await.unwrap();
            let head = String::from_utf8_lossy(&buf[..n]).to_string();
            let ok = !head.to_ascii_lowercase().contains("proxy-authorization");
            let body = if ok { "listed-ok" } else { "leaked-token" };
            s.write_all(
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
                    body.len()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        });
        let mut ctx = egress_ctx(&ws, crate::egress::Mode::Enforce, &["localhost"]);
        // `--noproxy ''` overrides NO_PROXY so localhost goes through the proxy too.
        let out = run(
            &json!({ "command": format!("curl -sS -m 5 --noproxy '' http://localhost:{port}/x") }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(out.content.contains("listed-ok"), "{}", out.content);
        let out = run(
            &json!({ "command": "curl -sS -m 5 --noproxy '*' https://oss-cn-beijing.aliyuncs.com/ ; python3 -c \"import socket; socket.getaddrinfo('dns-exfil.example.com', 53)\" 2>&1 | tail -1; echo rc=$?" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(
            out.content.contains("Could not resolve host"),
            "{}",
            out.content
        );
        assert!(
            out.content.contains("gaierror"),
            "DNS is closed: {}",
            out.content
        );
        assert!(
            out.content
                .contains("allow_hosts: [\"oss-cn-beijing.aliyuncs.com\"]"),
            "{}",
            out.content
        );
        let hits = ctx.egress.as_ref().unwrap().drain();
        assert!(
            hits.iter()
                .any(|h| h.host == "oss-cn-beijing.aliyuncs.com" && h.port == 0),
            "{hits:?}"
        );
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// The everyday tools through the real network under an enforced list: git, curl and
    /// python reach the listed hosts. Needs the network, so run by hand (`--ignored`).
    #[cfg(target_os = "macos")]
    #[tokio::test]
    #[ignore]
    async fn egress_listed_hosts_work_over_the_network() {
        let ws = std::env::temp_dir().join(format!("frog-egn-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = egress_ctx(&ws, crate::egress::Mode::Enforce, &[]);
        let out = run(
            &json!({ "command": "git ls-remote https://github.com/octocat/Hello-World HEAD | cut -c1-7 && curl -sS -o /dev/null -w 'crates=%{http_code}\\n' https://index.crates.io/config.json && python3 -c \"import urllib.request as u; print('pypi', u.urlopen('https://pypi.org/simple/', timeout=10).status)\" && curl -sS -m 5 https://example.com/ ; echo rc=$?" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(out.content.contains("crates=200"), "{}", out.content);
        assert!(out.content.contains("pypi 200"), "{}", out.content);
        assert!(
            out.content
                .contains("frog blocked network access to example.com"),
            "{}",
            out.content
        );
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// `flag` records an off-list host but doesn't block it (and the profile stays open).
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn egress_flag_mode_records_without_blocking() {
        let ws = std::env::temp_dir().join(format!("frog-egf-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = egress_ctx(&ws, crate::egress::Mode::Flag, &[]);
        let out = run(
            &json!({ "command": "curl -sS -m 5 -o /dev/null https://unlisted.invalid/ ; echo rc=$?" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(!out.content.contains("frog blocked"), "{}", out.content);
        assert!(!out.content.contains("403"), "{}", out.content);
        let hits = ctx.egress.as_ref().unwrap().drain();
        assert_eq!(hits.len(), 1, "{hits:?}");
        assert!(hits[0].host == "unlisted.invalid" && !hits[0].enforced);
        let _ = std::fs::remove_dir_all(&ws);
    }

    #[tokio::test]
    async fn sandbox_confines_shell_writes_to_the_workspace() {
        if !available() {
            eprintln!("no OS sandbox here; skipping");
            return;
        }
        let ws = std::env::temp_dir().join(format!("frog-sbx-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        ctx.sandbox = Some(ws.canonicalize().unwrap());

        let inside = run(
            &json!({ "command": "echo ok > inside.txt && cat inside.txt" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert_eq!(inside.content.trim(), "ok");

        let escape = dirs::home_dir().unwrap().join(".frog-sandbox-escape-test");
        let cmd = format!("touch '{}'", escape.display());
        let out = run(&json!({ "command": cmd }), &mut ctx).await.unwrap();
        let escaped = escape.exists();
        let _ = std::fs::remove_file(&escape);
        assert!(!escaped, "sandbox let a write escape the workspace");

        assert!(out.content.contains("exit code"), "{}", out.content);

        // Credentials are hidden, even for reading: seatbelt denies the read, bubblewrap shows
        // an empty directory in its place.
        let ssh = dirs::home_dir().unwrap().join(".ssh");
        if let Some(entry) = std::fs::read_dir(&ssh).ok().and_then(|mut d| d.next()) {
            let name = entry.unwrap().file_name().to_string_lossy().into_owned();
            let out = run(
                &json!({ "command": format!("ls -A '{}'", ssh.display()) }),
                &mut ctx,
            )
            .await
            .unwrap();
            assert!(!out.content.contains(&name), "{}", out.content);
        }
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn bubblewrap_hides_secrets_inside_the_workspace_and_keeps_caches_writable() {
        if !available() {
            eprintln!("bubblewrap can't run here; skipping");
            return;
        }
        // A fake home with the project inside it. It sits in the (writable) temp dir, so this
        // checks the masks and the cache bind, not write confinement.
        let home = std::env::temp_dir().join(format!("frog-bwrap-{}", crate::session::new_id()));
        std::fs::create_dir_all(home.join("proj")).unwrap();
        std::fs::create_dir_all(home.join(".ssh")).unwrap();
        std::fs::create_dir_all(home.join(".cargo")).unwrap();
        std::fs::write(home.join(".ssh/id_ed25519"), "secret").unwrap();
        std::fs::write(home.join(".netrc"), "machine x password y").unwrap();
        let home = home.canonicalize().unwrap();
        let script = "ls -A .ssh; cat .netrc; echo masked > .ssh/new; echo built > .cargo/lock && cat .cargo/lock";
        let out = bubblewrap(
            bwrap().unwrap(),
            &home.join("proj"),
            &home,
            "/bin/bash",
            &Default::default(),
            &[],
        )
        .current_dir(&home)
        .arg("-c")
        .arg(script)
        .output()
        .await
        .unwrap();
        let text = String::from_utf8_lossy(&out.stdout).into_owned()
            + &String::from_utf8_lossy(&out.stderr);
        assert!(!text.contains("id_ed25519"), "{text}");
        assert!(!text.contains("password"), "{text}");
        assert!(text.contains("built"), "{text}");
        assert!(!home.join(".ssh/new").exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    /// `[sandbox] allow_read` opens a credential directory for reading only; without it the
    /// directory stays hidden.
    #[tokio::test]
    async fn allow_read_opens_a_credential_dir_for_reading_only() {
        if !available() {
            eprintln!("no OS sandbox here; skipping");
            return;
        }
        let gh = dirs::home_dir().unwrap().join(".config/gh");
        let Some(file) = std::fs::read_dir(&gh)
            .ok()
            .and_then(|d| d.flatten().find(|e| e.path().is_file()))
        else {
            eprintln!("no ~/.config/gh here; skipping");
            return;
        };
        let file = file.path();
        let ws = std::env::temp_dir().join(format!("frog-sbx-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        ctx.shell_sandbox = Some(ws.canonicalize().unwrap());
        let read =
            json!({ "command": format!("cat '{}' >/dev/null && echo READ_OK", file.display()) });

        // Defaults: hidden.
        let out = run(&read, &mut ctx).await.unwrap();
        assert!(!out.content.contains("READ_OK"), "{}", out.content);

        // Opted in: readable, still not writable.
        ctx.sandbox_extra.allow_read = vec!["~/.config/gh".into()];
        let out = run(&read, &mut ctx).await.unwrap();
        assert!(out.content.contains("READ_OK"), "{}", out.content);
        let probe = gh.join(".frog-sandbox-write-test");
        let write = json!({ "command": format!("touch '{}'", probe.display()) });
        let _ = run(&write, &mut ctx).await.unwrap();
        let wrote = probe.exists();
        let _ = std::fs::remove_file(&probe);
        assert!(!wrote, "allow_read made a credential dir writable");
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// The real thing, on a machine logged in to gh: `gh auth status` fails in the default
    /// sandbox, and passes with `allow_read = ["~/.config/gh"]` plus either `allow_keychain`
    /// (macOS, where gh keeps its token in the Keychain) or `GH_TOKEN`. Run with `--ignored`.
    #[tokio::test]
    #[ignore]
    async fn gh_auth_status_works_with_the_opt_in_config() {
        let ws = std::env::temp_dir().join(format!("frog-sbx-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        ctx.shell_sandbox = Some(ws.canonicalize().unwrap());
        let gh = json!({ "command": "env -u GH_TOKEN -u GITHUB_TOKEN gh auth status" });
        let out = run(&gh, &mut ctx).await.unwrap();
        assert!(!out.content.contains("Logged in"), "{}", out.content);
        ctx.sandbox_extra.allow_read = vec!["~/.config/gh".into()];
        ctx.sandbox_extra.allow_keychain = cfg!(target_os = "macos");
        let out = run(&gh, &mut ctx).await.unwrap();
        assert!(out.content.contains("Logged in"), "{}", out.content);

        // The recommended setup: the token in the environment, the config dir readable, no
        // Keychain.
        ctx.sandbox_extra.allow_keychain = false;
        let token = std::process::Command::new("gh")
            .args(["auth", "token"])
            .output()
            .unwrap();
        let token = String::from_utf8(token.stdout).unwrap();
        let gh = json!({ "command": format!("GH_TOKEN='{}' gh auth status", token.trim()) });
        let out = run(&gh, &mut ctx).await.unwrap();
        assert!(out.content.contains("Logged in"), "{}", out.content);
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// The seatbelt profile text carries the SwiftPM caches and the default-readable config,
    /// still denies every credential path, and adds `allow_write` paths as writable. Pure
    /// string check on the generated profile: no sandbox is executed.
    #[cfg(target_os = "macos")]
    #[test]
    fn sandbox_profile_has_the_expected_holes_and_still_hides_credentials() {
        // `seatbelt` builds subpaths under the real home, so test against that.
        let home = dirs::home_dir().unwrap();
        let home_s = home.display().to_string();
        let extra = SandboxConfig {
            allow_read: vec!["~/.config/gh".into()],
            allow_write: vec!["~/Developer/.shared-target".into()],
            ..Default::default()
        };
        let git = vec![std::path::PathBuf::from("/definitely/not/home/.git")];
        let cmd = seatbelt(home.join("proj").as_path(), "/bin/zsh", &extra, &git).unwrap();
        // `seatbelt` builds the command; the profile is its second arg.
        let borrowed = cmd.as_std();
        let profile = borrowed
            .get_args()
            .nth(1)
            .and_then(|a| a.to_str().map(|s| s.to_string()))
            .expect("profile after -p");

        // SwiftPM's user-level dir is writable (nested-sandbox workaround needs its caches).
        assert!(
            profile.contains(&format!("(subpath \"{home_s}/Library/org.swift.swiftpm\")")),
            "swiftpm cache missing:\n{profile}"
        );
        // The default-readable config is re-allowed for reading, after the secrets deny.
        assert!(
            profile.contains(&format!(
                "(allow file-read* (subpath \"{home_s}/.gitconfig\"))"
            )),
            ".gitconfig read missing:\n{profile}"
        );
        assert!(
            profile.contains(&format!("(subpath \"{home_s}/.config/frog/config.toml\")")),
            "frog config.toml read missing:\n{profile}"
        );
        // Toolchain binaries and git's config stay read-only after the writable caches.
        for denied in [
            format!("{home_s}/.cargo/bin"),
            format!("{home_s}/.rustup/toolchains"),
            "/definitely/not/home/.git/config".into(),
            "/definitely/not/home/.git/hooks".into(),
        ] {
            let rule = format!("(deny file-write* (subpath \"{denied}\"))");
            let at = profile
                .find(&rule)
                .unwrap_or_else(|| panic!("{rule} missing:\n{profile}"));
            assert!(
                at > profile.find("(allow file-write*").unwrap(),
                "{profile}"
            );
        }
        // allow_write became a writable subpath.
        assert!(
            profile.contains(&format!("(subpath \"{home_s}/Developer/.shared-target\")")),
            "allow_write missing:\n{profile}"
        );
        // allow_read is read-only.
        assert!(
            !profile.contains(&format!(
                "(allow file-write*\n  (subpath \"{home_s}/.config/gh\")"
            )),
            "allow_read path became writable:\n{profile}"
        );
        // Every credential path is still denied.
        for secret in SECRETS {
            assert!(
                profile.contains(&format!("(subpath \"{home_s}/{secret}\")")),
                "secret {secret} missing from the deny set:\n{profile}"
            );
        }
        // frog's config dir is denied but its config.toml re-allowed: both must appear.
        let deny_pos = profile.find("(deny file-read* file-write*").unwrap();
        let allow_pos = profile
            .find(&format!(
                "(allow file-read* (subpath \"{home_s}/.config/frog/config.toml\"))"
            ))
            .unwrap();
        assert!(
            deny_pos < allow_pos,
            "config.toml allow must come after the deny"
        );
    }

    /// `adapt_swiftpm` adds the flag to sandboxed swift builds and leaves everything else
    /// alone, byte-for-byte.
    #[test]
    fn sandbox_swiftpm_adaptation_rewrites_only_swift_build_invocations() {
        let f = |cmd: &str| adapt_swiftpm(cmd);
        assert_eq!(f("swift build"), "swift build --disable-sandbox");
        assert_eq!(
            f("swift build -c release"),
            "swift build --disable-sandbox -c release"
        );
        assert_eq!(
            f("swift test --package-path sidecars/frog-apple"),
            "swift test --disable-sandbox --package-path sidecars/frog-apple"
        );
        assert_eq!(
            f("cd /tmp && swift run App"),
            "cd /tmp && swift run --disable-sandbox App"
        );
        assert_eq!(
            f("FOO=1 swift package resolve"),
            "FOO=1 swift package --disable-sandbox resolve"
        );
        // Already has it: untouched.
        assert_eq!(
            f("swift build --disable-sandbox"),
            "swift build --disable-sandbox"
        );
        // Other subcommands and non-command positions: untouched.
        assert_eq!(f("swiftc foo.swift"), "swiftc foo.swift");
        assert_eq!(f("swift repl"), "swift repl");
        assert_eq!(f("echo swift build"), "echo swift build");
        assert_eq!(f("swiftlint"), "swiftlint");
        // Quoting and spacing survive.
        assert_eq!(
            f("swift build  --package-path \"a b\""),
            "swift build --disable-sandbox  --package-path \"a b\""
        );
        // Two invocations in one command both get it.
        assert_eq!(
            f("swift build; swift test"),
            "swift build --disable-sandbox; swift test --disable-sandbox"
        );
        // Closing parens/braces and lone pipes used to spin this forever.
        assert_eq!(
            f("ps aux | grep -E 'git (reset|commit|status)' | head -5"),
            "ps aux | grep -E 'git (reset|commit|status)' | head -5"
        );
        assert_eq!(f("{ echo hi; }"), "{ echo hi; }");
        assert_eq!(f("(cd x)"), "(cd x)");
        assert_eq!(
            f("swift build | tee log (x)"),
            "swift build --disable-sandbox | tee log (x)"
        );
    }

    /// The git-https overlay targets git reads and never a command that pushes.
    #[test]
    fn sandbox_git_https_overlay_targets_read_commands_only() {
        let f = |cmd: &str| git_https_applies(cmd);
        assert!(f("git fetch"));
        assert!(f("git ls-remote origin"));
        assert!(f("git -C /Users/x/proj ls-remote https://github.com/o/r"));
        assert!(f("cd /tmp && git pull --ff-only"));
        assert!(f("git clone git@github.com:o/r.git d"));
        assert!(f("git status && git diff"));
        // Pushes and non-reads are left alone.
        assert!(!f("git push origin main"));
        assert!(!f("git fetch && git push origin main"));
        assert!(!f("git commit -m x"));
        assert!(!f("git add . && git commit"));
        assert!(!f("cargo build"));
    }

    /// `--disable-sandbox` really does make `swift build` work under the frog sandbox: a tiny
    /// package builds sandboxed once the inner sandbox is off. Run with `cargo test -- --ignored`
    /// on macOS with Xcode installed; ~30s.
    #[cfg(target_os = "macos")]
    #[tokio::test]
    #[ignore]
    async fn sandboxed_swift_build_works_with_the_inner_sandbox_disabled() {
        let base = std::env::temp_dir().join(format!("frog-swift-{}", crate::session::new_id()));
        let pkg = base.join("SwiftPkg");
        std::fs::create_dir_all(pkg.join("Sources/SwiftPkg")).unwrap();
        std::fs::write(
            pkg.join("Package.swift"),
            "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"SwiftPkg\", targets: [.target(name: \"SwiftPkg\")])\n",
        )
        .unwrap();
        std::fs::write(
            pkg.join("Sources/SwiftPkg/SwiftPkg.swift"),
            "public func hi() -> String { \"hello\" }\n",
        )
        .unwrap();
        let mut ctx = Ctx::new(pkg.clone());
        ctx.sandbox = Some(pkg.canonicalize().unwrap());
        // Cold manifest cache is the failure case: drop it so the manifest really compiles.
        let _ = std::fs::remove_dir_all(
            dirs::home_dir()
                .unwrap()
                .join("Library/Caches/org.swift.swiftpm/manifests"),
        );

        // Without the adaptation (`sh -c` hides the invocation from the rewriter), plain
        // `swift build` fails: SwiftPM's inner sandbox can't apply inside ours.
        let plain = run(&json!({ "command": "sh -c 'swift build'" }), &mut ctx)
            .await
            .unwrap();
        assert!(
            !plain.content.contains("Build complete"),
            "plain swift build unexpectedly worked:\n{}",
            plain.content
        );

        // With the engine's adaptation, the same command the agent writes builds fine.
        let adapted = run(&json!({ "command": "swift build" }), &mut ctx)
            .await
            .unwrap();
        assert!(
            adapted.content.contains("Build complete"),
            "adapted swift build failed:\n{}",
            adapted.content
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    /// A trivially sandboxed command (`swift --version`) still runs: the sandbox profile
    /// doesn't break the toolchain itself. Run with `cargo test -- --ignored`.
    #[tokio::test]
    #[ignore]
    async fn sandboxed_swift_version_works() {
        let ws = std::env::temp_dir().join(format!("frog-swift-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        ctx.sandbox = Some(ws.canonicalize().unwrap());
        let out = run(&json!({ "command": "swift --version" }), &mut ctx)
            .await
            .unwrap();
        assert!(
            out.content.contains("Swift version"),
            "swift --version failed:\n{}",
            out.content
        );
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// Read-only git over https works sandboxed (network is open by default; this checks the
    /// whole path). Run with `cargo test -- --ignored` with the network up.
    #[tokio::test]
    #[ignore]
    async fn sandboxed_git_ls_remote_https_works() {
        let ws = std::env::temp_dir().join(format!("frog-git-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        ctx.sandbox = Some(ws.canonicalize().unwrap());
        let out = run(
            &json!({ "command": "git ls-remote https://github.com/octocat/Hello-World HEAD" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(
            out.content
                .contains("7fd1a60b01f91b314f59955a4e4d4e80d8edf11d"),
            "ls-remote failed:\n{}",
            out.content
        );
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// With `[sandbox] git_https` on, an ssh URL to a public GitHub repo resolves over https
    /// through the overlay, sandboxed, without ~/.ssh being readable. Run with
    /// `cargo test -- --ignored` with the network up.
    #[tokio::test]
    #[ignore]
    async fn sandboxed_git_ls_remote_ssh_becomes_https_with_git_https_config() {
        let ws = std::env::temp_dir().join(format!("frog-git-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        ctx.sandbox = Some(ws.canonicalize().unwrap());
        ctx.sandbox_extra.git_https = true;
        let out = run(
            &json!({ "command": "git ls-remote git@github.com:octocat/Hello-World HEAD" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(
            out.content
                .contains("7fd1a60b01f91b314f59955a4e4d4e80d8edf11d"),
            "ssh ls-remote didn't resolve over https:\n{}",
            out.content
        );
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// `git_https` changes only the command's environment, never the profile: no read rule
    /// opens ~/.config/gh or the Keychain because of it.
    #[cfg(target_os = "macos")]
    #[test]
    fn sandbox_git_https_adds_no_credential_reads_to_the_profile() {
        let home = dirs::home_dir().unwrap();
        let home = home.canonicalize().unwrap_or(home);
        let profile = |extra: &SandboxConfig| {
            let cmd = seatbelt(home.join("proj").as_path(), "/bin/zsh", extra, &[]).unwrap();
            cmd.as_std()
                .get_args()
                .nth(1)
                .and_then(|a| a.to_str().map(String::from))
                .unwrap()
        };
        let off = profile(&SandboxConfig::default());
        let on = profile(&SandboxConfig {
            git_https: true,
            ..Default::default()
        });
        assert_eq!(off, on, "git_https must not change the profile");
        let h = home.display();
        for p in [".config/gh", "Library/Keychains"] {
            assert!(
                !on.contains(&format!("(allow file-read* (subpath \"{h}/{p}")),
                "{p} readable with git_https:\n{on}"
            );
            assert!(
                on.contains(&format!("(subpath \"{h}/{p}\")")),
                "{p} not denied"
            );
        }
    }

    /// With `git_https` on and the default sandbox (no `allow_read`/`allow_keychain`), an
    /// ordinary sandboxed command can't get the GitHub token: not from gh, gh's config, the
    /// Keychain, or by asking the overlay's helper directly. Public ls-remote over the overlay
    /// still works. Needs a real sandbox, a logged-in gh and the network: run with `--ignored`.
    #[cfg(target_os = "macos")]
    #[tokio::test]
    #[ignore]
    async fn sandboxed_git_https_does_not_expose_the_github_token() {
        let token = std::process::Command::new("gh")
            .args(["auth", "token"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_default();
        assert!(token.len() > 20, "needs a logged-in gh outside the sandbox");
        let ws = std::env::temp_dir().join(format!("frog-tok-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        ctx.shell_sandbox = Some(ws.canonicalize().unwrap());
        ctx.sandbox_extra.git_https = true;
        let ask = "printf 'protocol=https\\nhost=github.com\\n\\n'";
        let probes = [
            "env -u GH_TOKEN -u GITHUB_TOKEN gh auth token".to_string(),
            "cat ~/.config/gh/hosts.yml ~/.config/gh/config.yml".to_string(),
            "security find-internet-password -s github.com -w".to_string(),
            "security find-generic-password -s gh:github.com -w".to_string(),
            format!("{ask} | env -u GH_TOKEN -u GITHUB_TOKEN gh auth git-credential get"),
            format!("{ask} | git -c credential.helper='!gh auth git-credential' credential fill"),
        ];
        for probe in &probes {
            let out = run(&json!({ "command": probe }), &mut ctx).await.unwrap();
            let first = out
                .content
                .lines()
                .next()
                .unwrap_or("")
                .replace(&token, "<TOKEN>");
            eprintln!("probe `{probe}` -> {first}");
            assert!(
                !out.content.contains(&token),
                "token leaked to a sandboxed command: {probe}"
            );
        }
        let out = run(
            &json!({ "command": "git ls-remote git@github.com:octocat/Hello-World HEAD" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(
            out.content
                .contains("7fd1a60b01f91b314f59955a4e4d4e80d8edf11d"),
            "{}",
            out.content
        );
        // Informational: a private repo, if FROG_PRIVATE_REPO names one (e.g. `ecto/frog`).
        // With the default sandbox the overlay's helper can't read gh's token either, so this
        // is expected to fail auth; it's printed, not asserted.
        if let Ok(repo) = std::env::var("FROG_PRIVATE_REPO") {
            let cmd = format!("GIT_TERMINAL_PROMPT=0 git ls-remote git@github.com:{repo} HEAD");
            let out = run(&json!({ "command": cmd }), &mut ctx).await.unwrap();
            let first = out
                .content
                .lines()
                .next()
                .unwrap_or("")
                .replace(&token, "<TOKEN>");
            eprintln!("private `{repo}` -> {first}");
        }
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// A fuzz probe for the shell scanners: random shells of metacharacters must terminate
    /// and return quickly. A scanner that stalls on one (adapt_swiftpm used to spin forever
    /// on `)` and `}`, wedging the engine so Stop couldn't fire) fails here.
    #[test]
    fn scanners_terminate_on_random_metacharacter_strings() {
        const META: &[char] = &[
            ')', '(', '}', '{', '|', '&', '<', '>', ';', '"', '\'', ' ', '\n',
        ];
        let mut state = 0x2545F4914F6CDD1Du64;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for _ in 0..5_000 {
            let len = (next() % 40) as usize;
            let s: String = (0..len)
                .map(|_| META[(next() as usize) % META.len()])
                .collect();
            let t = std::time::Instant::now();
            let _ = adapt_swiftpm(&s);
            let _ = git_https_applies(&s);
            // A runaway scanner takes seconds; a busy CI runner can stall a fast one ~100ms.
            assert!(
                t.elapsed() < Duration::from_millis(500),
                "scanner took {:?} on {s:?}",
                t.elapsed()
            );
        }
    }

    /// Stop must kill a sleeping command within ~2 s: the token is watched while the tool
    /// future runs, the group gets SIGTERM then SIGKILL, and the result reads as interrupted.
    #[tokio::test]
    async fn interrupt_kills_a_running_command_and_its_group() {
        let ws = std::env::temp_dir().join(format!("frog-itp-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        let token = tokio_util::sync::CancellationToken::new();
        ctx.cancel = Some(token.clone());
        let marker = ws.join("done");
        let _ = std::fs::remove_file(&marker);
        let cmd = format!("{} && touch '{}'", sleeper(&ws, 61), marker.display());
        let input = json!({ "command": cmd, "timeout": 120000 });
        let run = run(&input, &mut ctx);
        tokio::pin!(run);
        // Drive the command until it has spawned and is sleeping.
        until_sleeping(&mut run, &ws).await;
        let started = std::time::Instant::now();
        token.cancel();
        let out = tokio::time::timeout(Duration::from_secs(2), run).await;
        let _elapsed = started.elapsed();
        let out = out.expect("interrupt must finish the tool within 2s");
        assert!(
            out.is_err() || out.as_ref().unwrap().content.contains("Interrupted"),
            "expected an interrupted result, got {:?}",
            out.as_ref().map(|o| &o.content)
        );
        assert!(!marker.exists(), "the cancelled command must not finish");
        // The whole process group is gone: nothing sleeps on.
        assert!(
            sleeper_gone(&ws).await,
            "the `sleep 61` from the cancelled group is still running"
        );
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// A grandchild left running with `&` is still in the child's process group, so the
    /// group kill takes it too.
    #[tokio::test]
    async fn interrupt_kills_backgrounded_grandchildren() {
        let ws = std::env::temp_dir().join(format!("frog-itp-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        let token = tokio_util::sync::CancellationToken::new();
        ctx.cancel = Some(token.clone());
        let marker = ws.join("bg");
        let _ = std::fs::remove_file(&marker);
        let cmd = format!(
            "{} & echo bg > '{}'; wait",
            sleeper(&ws, 62),
            marker.display()
        );
        let input = json!({ "command": cmd });
        let run = run(&input, &mut ctx);
        tokio::pin!(run);
        until_sleeping(&mut run, &ws).await;
        token.cancel();
        let err = match tokio::time::timeout(Duration::from_secs(2), run).await {
            // Elapsed without finishing, or finished as an error: both prove the interrupt
            // ended the tool; the Err case is what production records.
            Err(_) => anyhow::anyhow!("interrupt did not finish within 2s"),
            Ok(Err(e)) => e,
            Ok(Ok(o)) => panic!("expected an interrupted result, got {:?}", o.content),
        };
        assert!(err.to_string().contains("interrupted"), "{err}");
        assert!(
            sleeper_gone(&ws).await,
            "the backgrounded `sleep 62` escaped the group kill"
        );
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// Same interrupt through the seatbelt wrapper (sandbox-exec is in the same process
    /// group, so the kill reaches the real shell).
    #[tokio::test]
    async fn interrupt_kills_a_sandboxed_command() {
        if !available() {
            eprintln!("no OS sandbox here; skipping");
            return;
        }
        let ws = std::env::temp_dir().join(format!("frog-itp-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        ctx.shell_sandbox = Some(ws.canonicalize().unwrap());
        let token = tokio_util::sync::CancellationToken::new();
        ctx.cancel = Some(token.clone());
        let input = json!({ "command": sleeper(&ws, 63) });
        let run = run(&input, &mut ctx);
        tokio::pin!(run);
        until_sleeping(&mut run, &ws).await;
        token.cancel();
        let out = tokio::time::timeout(Duration::from_secs(2), run)
            .await
            .expect("interrupt must finish within 2s");
        assert!(
            out.is_err() || out.as_ref().unwrap().content.contains("Interrupted"),
            "expected an interrupted result, got {:?}",
            out.as_ref().map(|o| &o.content)
        );
        assert!(
            sleeper_gone(&ws).await,
            "the sandboxed `sleep 63` survived the interrupt"
        );
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// Regression: the plain timeout still fires when nothing cancels.
    #[tokio::test]
    async fn timeout_still_ends_a_stuck_command() {
        let ws = std::env::temp_dir().join(format!("frog-itp-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        let started = std::time::Instant::now();
        let err = match run(
            &json!({ "command": sleeper(&ws, 30), "timeout": 1000 }),
            &mut ctx,
        )
        .await
        {
            Err(e) => e,
            Ok(o) => panic!("expected a timeout, got {:?}", o.content),
        };
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "took {:?}",
            started.elapsed()
        );
        assert!(err.to_string().contains("timed out"), "{err}");
        assert!(err.to_string().contains("run_in_background"), "{err}");
        assert!(
            sleeper_gone(&ws).await,
            "the timed-out `sleep 30` is still running"
        );
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// Output is bounded while it's read: the head and tail survive, the middle is counted.
    #[test]
    fn capped_output_keeps_head_and_tail_within_the_cap() {
        let mut c = Capped::new(100);
        for i in 0..10_000u32 {
            c.push(format!("{i:05}\n").as_bytes());
            assert!(c.head.len() + c.tail.len() <= 100);
        }
        let out = String::from_utf8(c.finish()).unwrap();
        assert!(out.starts_with("00000\n"), "{out}");
        assert!(out.contains("09999\n"), "{out}");
        assert!(out.contains("bytes of output dropped"), "{out}");
        // A single huge chunk too.
        let mut c = Capped::new(100);
        c.push(&vec![b'a'; 1 << 20]);
        assert!(c.head.len() + c.tail.len() <= 100);
    }

    /// A command printing far more than the cap doesn't make frog buffer all of it.
    #[tokio::test]
    async fn runaway_output_is_capped_while_reading() {
        let ws = std::env::temp_dir().join(format!("frog-cap-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        let n = OUTPUT_CAP * 3;
        let out = run(
            &json!({ "command": format!("head -c {n} /dev/zero | tr '\\0' a") }),
            &mut ctx,
        )
        .await
        .unwrap();
        let dropped = n - OUTPUT_CAP;
        assert!(
            out.content
                .contains(&format!("[{dropped} bytes of output dropped]")),
            "{}",
            &out.content[..out.content.len().min(400)]
        );
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// Linux: `sandbox.network = "none"` gives bwrap its own network namespace, loopback only.
    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn bubblewrap_denies_network_when_configured() {
        if !available() {
            eprintln!("no bwrap here; skipping");
            return;
        }
        let ws = std::env::temp_dir().join(format!("frog-net-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let ws = ws.canonicalize().unwrap();
        let ifaces = "cat /proc/net/dev | tail -n +3 | cut -d: -f1 | tr -d ' ' | sort | tr '\\n' ,";
        let mut ctx = Ctx::new(ws.clone());
        ctx.sandbox = Some(ws.clone());
        // Open by default: the host's interfaces are visible.
        let open = run(&json!({ "command": ifaces }), &mut ctx).await.unwrap();
        ctx.sandbox_extra.network = Some("none".into());
        let shut = run(&json!({ "command": ifaces }), &mut ctx).await.unwrap();
        assert_eq!(shut.content.trim(), "lo,", "open: {}", open.content);
        // And a connection out fails outright.
        let tcp = run(
            &json!({ "command": "(exec 3<>/dev/tcp/1.1.1.1/80) 2>&1; echo rc=$?" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(!tcp.content.contains("rc=0"), "{}", tcp.content);
        let _ = std::fs::remove_dir_all(&ws);
    }

    /// Linux: an enforced egress allow-list can't be enforced by host inside bwrap, so it
    /// fails closed (no network) instead of leaving the network open as it used to.
    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn bubblewrap_enforced_egress_fails_closed() {
        if !available() {
            eprintln!("no bwrap here; skipping");
            return;
        }
        let ws = std::env::temp_dir().join(format!("frog-eg-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let ws = ws.canonicalize().unwrap();
        let mut ctx = egress_ctx(&ws, crate::egress::Mode::Enforce, &["example.com"]);
        let out = run(
            &json!({ "command": "cat /proc/net/dev | tail -n +3 | cut -d: -f1 | tr -d ' ' | sort | tr '\\n' ," }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert_eq!(out.content.trim(), "lo,", "{}", out.content);
        let _ = std::fs::remove_dir_all(&ws);
    }
}
