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
        description.push_str(" Commands run in a sandbox: they can write only inside the project, temp folders and toolchain caches, and can't read credentials (~/.ssh, ~/.aws, ...). Network access works. If a command fails because of the sandbox and genuinely needs more (installing globally, git push over ssh), run it again with unsandboxed: true; the user will be asked.");
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
        Some(root) => sandboxed(root, &shell, &ctx.sandbox_extra)?,
    };
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
    ".config/frog",
    ".npmrc",
    ".pypirc",
    ".git-credentials",
    ".config/op",
    ".vault-token",
];

/// Paths the user let sandboxed commands read (config `[sandbox]`), canonical where they
/// exist. Reads only: none of them becomes writable.
fn readable(extra: &SandboxConfig, home: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut paths: Vec<std::path::PathBuf> = extra
        .allow_read
        .iter()
        .map(|p| match p.strip_prefix("~/") {
            Some(rest) => home.join(rest),
            None if p == "~" => home.to_path_buf(),
            None => p.into(),
        })
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

/// Wrap the shell in the OS sandbox: writes only inside the workspace, temp dirs and toolchain
/// caches, credentials unreadable (except what `extra` allows), everything else (including
/// network) allowed. Fails closed where there's no sandbox to use.
fn sandboxed(
    root: &std::path::Path,
    shell: &str,
    extra: &SandboxConfig,
) -> Result<tokio::process::Command> {
    if cfg!(target_os = "macos") {
        seatbelt(root, shell, extra)
    } else if let Some(bwrap) = bwrap() {
        Ok(bubblewrap(
            bwrap,
            root,
            &dirs::home_dir().unwrap_or_default(),
            shell,
            extra,
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
  (regex #"^/dev/fd/"){caches})
(deny file-read* file-write*{secrets}){reads}"#,
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
) -> tokio::process::Command {
    use std::path::{Path, PathBuf};
    let real = |p: &Path| p.canonicalize().ok();
    let home = real(home).unwrap_or_else(|| home.to_path_buf());

    let mut cmd = tokio::process::Command::new(bwrap);
    cmd.args(["--ro-bind", "/", "/", "--dev-bind", "/dev", "/dev"]);
    let mut writable: Vec<PathBuf> = vec![root.to_path_buf()];
    writable.extend(real(&std::env::temp_dir()));
    writable.extend(
        ["/tmp", "/var/tmp"]
            .iter()
            .filter_map(|p| real(Path::new(p))),
    );
    writable.extend(CACHES.iter().filter_map(|c| real(&home.join(c))));
    writable.sort();
    writable.dedup();
    for p in &writable {
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
}
