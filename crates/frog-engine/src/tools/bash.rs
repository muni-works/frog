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
over cat/sed/find/grep. Avoid interactive commands; they will hang until the timeout.",
    );
    let mut props = json!({
        "command": { "type": "string", "description": "The command to run" },
        "timeout": { "type": "integer", "description": "Timeout in milliseconds (default 120000, max 600000)" },
        "run_in_background": { "type": "boolean", "description": "Start the command as a background job and return its id at once, for servers, watchers and long builds. Its output goes to a file; you're told when it exits (exit code and the tail of its output). Read it with JobOutput, stop it with JobStop." }
    });
    if available() {
        description.push_str(" Commands run in a sandbox: they can write only inside the project (and, in a git worktree, its git dirs so commit works), temp folders, toolchain caches and paths the user configured, and can't read credentials (~/.ssh, ~/.aws, ...). Network access works; swift builds get SwiftPM's inner sandbox disabled (frog's is the boundary), and read-only git commands can go over https to GitHub when configured. If a command fails because of the sandbox and genuinely needs more (installing globally, git push over ssh), run it again with unsandboxed: true; the user will be asked.");
        props["unsandboxed"] = json!({ "type": "boolean", "description": "Run outside the sandbox. Asks the user first; use only when the sandbox blocked something the task needs." });
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

/// Kills the whole process group if the command is cancelled or times out.
struct Group(i32);

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
    let cwd_file = std::env::temp_dir().join(format!("frog-cwd-{}", std::process::id()));
    let _ = std::fs::remove_file(&cwd_file);
    // Under our sandbox, SwiftPM's own inner seatbelt sandbox can never apply (macOS rejects a
    // nested sandbox_apply outright), so `swift build` fails with "Invalid manifest" until it's
    // told not to use it. frog's sandbox stays the boundary; this only removes the redundant
    // inner one. Applied when we actually sandbox the command.
    let cmd = if ctx.shell_sandbox.is_some() || ctx.sandbox.is_some() {
        adapt_swiftpm(&cmd)
    } else {
        cmd.to_string()
    };
    let script = format!(
        "{{\n{cmd}\n}} 2>&1\n__frog_ec=$?\npwd -P > '{}'\nexit $__frog_ec",
        cwd_file.display()
    );
    let (mut command, jail) = shell(input, ctx)?;
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
    let (Some(mut stdout), Some(mut stderr)) = (child.stdout.take(), child.stderr.take()) else {
        bail!("couldn't capture command output");
    };
    let progress = ctx.progress.clone();
    let collect = async {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let (mut buf, mut ebuf) = ([0u8; 8192], [0u8; 4096]);
        let (mut out_done, mut err_done) = (false, false);
        while !(out_done && err_done) {
            tokio::select! {
                r = stdout.read(&mut buf), if !out_done => match r? {
                    0 => out_done = true,
                    n => {
                        out.extend_from_slice(&buf[..n]);
                        if let Some(p) = &progress {
                            let _ = p.send(String::from_utf8_lossy(&buf[..n]).into_owned());
                        }
                    }
                },
                r = stderr.read(&mut ebuf), if !err_done => match r? {
                    0 => err_done = true,
                    n => err.extend_from_slice(&ebuf[..n]),
                },
            }
        }
        let status = child.wait().await?;
        anyhow::Ok((out, err, status))
    };
    let (stdout, stderr, status) = match tokio::time::timeout(timeout, collect).await {
        Ok(r) => r?,
        Err(_) => bail!("command timed out after {}s", timeout.as_secs()),
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
        ..Default::default()
    })
}

/// The user's shell, sandboxed exactly as a foreground call would be, in `ctx.cwd`, ready for
/// the script argument (`-c` is already added). Also returns the sandbox root, if any.
/// Background jobs and `Monitor` use it so they run under the same rules as Bash.
pub fn shell(
    input: &Value,
    ctx: &Ctx,
) -> Result<(tokio::process::Command, Option<std::path::PathBuf>)> {
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
    let mut command = match &jail {
        None => tokio::process::Command::new(shell),
        Some(root) => sandboxed(root, &shell, &ctx.sandbox_extra, &git_dirs(&ctx.cwd))?,
    };
    if jail.is_some()
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
    let cmd = input["command"].as_str().unwrap_or("");
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
    Ok((command, jail))
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

/// Non-secret config that sandboxed commands may read by default (under $HOME). Everything a
/// build or a read-only git command routinely looks at, and nothing that holds a credential:
/// the credential paths stay in SECRETS and only open with `allow_read`.
const DEFAULT_READABLE: &[&str] = &[
    ".gitconfig",
    ".cargo/config.toml",
    ".gitignore_global",
];

/// Credentials a sandboxed command can't read, so a prompt-injected command can't read them
/// and send them over the network.
const SECRETS: &[&str] = &[
    ".ssh",
    ".aws",
    ".gnupg",
    ".netrc",
    ".docker/config.json",
    ".kube",
    ".config/gh",
    ".config/gcloud",
    ".azure",
    ".password-store",
    "Library/Keychains",
    // frog's config dir holds config.toml (which may embed `api_key`) and models.json. The
    // non-secret file agents read, config.toml, is allowed by name after the deny — keys
    // added to this dir later (providers' `keys*`) stay hidden.
    ".config/frog",
    ".npmrc",
    ".pypirc",
    ".git-credentials",
    ".config/op",
    ".vault-token",
];

/// Whether the git-https overlay should apply to this command: it's git with a read-only-ish
/// subcommand (fetch, ls-remote, clone, submodule update, status, diff, log, show, branch,
/// rev-parse, describe, remote, worktree), or `git pull` (with or without --ff-only), and no
/// `push` anywhere (auto.rs's hard rule already makes a push ask; `url.insteadOf` would
/// redirect a push's URL too, so the overlay must never see one). Applies only when sandboxed
/// and the config opt-in `[sandbox] git_https` is on (default on: it only widens what already
/// works over the network and exposes no credentials; ssh keys stay hidden either way).
fn git_https_applies(cmd: &str) -> bool {
    const READ_SUBCOMMANDS: &[&str] = &[
        "fetch", "ls-remote", "pull", "clone", "submodule", "status", "diff", "log", "show",
        "branch", "rev-parse", "describe", "remote", "worktree",
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

/// When `cwd` is in a git worktree, the dirs git writes to (`index.lock`, refs, objects): the
/// per-worktree git dir and the common dir. Nothing else of the main checkout opens up.
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
    let git: String = git
        .iter()
        .map(|p| format!("\n  (subpath \"{}\")", quote(p)))
        .collect();
    let writes: String = writable(extra, &home)
        .iter()
        .map(|p| format!("\n  (subpath \"{}\")", quote(p)))
        .collect();
    let network = if extra.network.as_deref() == Some("dev") {
        "\n(deny network-outbound)\n(allow network-outbound (remote ip \"localhost:*\"))"
            .to_string()
    } else {
        String::new()
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
  (regex #"^/dev/fd/"){caches}{git}{writes})
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
/// even when the workspace contains them (a project at `~`). Network, `/proc` and `/dev` are
/// shared, like seatbelt's `allow default`. No `--die-with-parent` or `--new-session`: a
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
    cmd.arg("--").arg(shell);
    cmd
}

#[cfg(all(test, any(target_os = "macos", target_os = "linux")))]
mod tests {
    use super::*;

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
            profile.contains(&format!("(allow file-read* (subpath \"{home_s}/.gitconfig\"))")),
            ".gitconfig read missing:\n{profile}"
        );
        assert!(
            profile.contains(&format!("(subpath \"{home_s}/.config/frog/config.toml\")")),
            "frog config.toml read missing:\n{profile}"
        );
        // allow_write became a writable subpath.
        assert!(
            profile.contains(&format!("(subpath \"{home_s}/Developer/.shared-target\")")),
            "allow_write missing:\n{profile}"
        );
        // allow_read is read-only.
        assert!(
            !profile.contains(&format!("(allow file-write*\n  (subpath \"{home_s}/.config/gh\")")),
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
            .find(&format!("(allow file-read* (subpath \"{home_s}/.config/frog/config.toml\"))"))
            .unwrap();
        assert!(deny_pos < allow_pos, "config.toml allow must come after the deny");
    }

    /// `adapt_swiftpm` adds the flag to sandboxed swift builds and leaves everything else
    /// alone, byte-for-byte.
    #[test]
    fn sandbox_swiftpm_adaptation_rewrites_only_swift_build_invocations() {
        let f = |cmd: &str| adapt_swiftpm(cmd);
        assert_eq!(f("swift build"), "swift build --disable-sandbox");
        assert_eq!(f("swift build -c release"), "swift build --disable-sandbox -c release");
        assert_eq!(
            f("swift test --package-path sidecars/frog-apple"),
            "swift test --disable-sandbox --package-path sidecars/frog-apple"
        );
        assert_eq!(f("cd /tmp && swift run App"), "cd /tmp && swift run --disable-sandbox App");
        assert_eq!(
            f("FOO=1 swift package resolve"),
            "FOO=1 swift package --disable-sandbox resolve"
        );
        // Already has it: untouched.
        assert_eq!(f("swift build --disable-sandbox"), "swift build --disable-sandbox");
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
        let _ = std::fs::remove_dir_all(dirs::home_dir().unwrap().join("Library/Caches/org.swift.swiftpm/manifests"));

        // Without the adaptation (`sh -c` hides the invocation from the rewriter), plain
        // `swift build` fails: SwiftPM's inner sandbox can't apply inside ours.
        let plain = run(
            &json!({ "command": "sh -c 'swift build'" }),
            &mut ctx,
        )
        .await
        .unwrap();
        assert!(
            !plain.content.contains("Build complete"),
            "plain swift build unexpectedly worked:\n{}",
            plain.content
        );

        // With the engine's adaptation, the same command the agent writes builds fine.
        let adapted = run(&json!({ "command": "swift build" }), &mut ctx).await.unwrap();
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
        let out = run(&json!({ "command": "swift --version" }), &mut ctx).await.unwrap();
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
            out.content.contains("7fd1a60b01f91b314f59955a4e4d4e80d8edf11d"),
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
            out.content.contains("7fd1a60b01f91b314f59955a4e4d4e80d8edf11d"),
            "ssh ls-remote didn't resolve over https:\n{}",
            out.content
        );
        let _ = std::fs::remove_dir_all(&ws);
    }
}
