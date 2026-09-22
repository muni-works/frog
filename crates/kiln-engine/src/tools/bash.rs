use super::{Ctx, Output, int_arg, str_arg, strip_ansi, truncate_middle};
use crate::provider::ToolSpec;
use anyhow::{Result, bail};
use serde_json::{Value, json};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncReadExt;

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: "Bash",
        description: "Run a shell command and return its combined stdout/stderr. The working directory persists \
between calls (cd works). Use for builds, tests, git, and other terminal operations. Prefer Read/Edit/Glob/Grep \
over cat/sed/find/grep. Avoid interactive commands; they will hang until the timeout.",
        schema: json!({
            "type": "object",
            "properties": {
                "command": { "type": "string", "description": "The command to run" },
                "timeout": { "type": "integer", "description": "Timeout in milliseconds (default 120000, max 600000)" }
            },
            "required": ["command"]
        }),
    }
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
    let cwd_file = std::env::temp_dir().join(format!("kiln-cwd-{}", std::process::id()));
    let _ = std::fs::remove_file(&cwd_file);
    let script = format!(
        "{{\n{cmd}\n}} 2>&1\n__kiln_ec=$?\npwd -P > '{}'\nexit $__kiln_ec",
        cwd_file.display()
    );
    let shell = std::env::var("SHELL")
        .ok()
        .filter(|s| s.ends_with("zsh") || s.ends_with("bash"))
        .unwrap_or("/bin/bash".into());

    let mut command = match &ctx.sandbox {
        None => tokio::process::Command::new(shell),
        Some(root) => sandboxed(root, &shell)?,
    };
    let mut child = command
        .arg("-c")
        .arg(&script)
        .current_dir(&ctx.cwd)
        .env("PAGER", "cat")
        .env("GIT_PAGER", "cat")
        .env("KILN", "1")
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
    let plain = strip_ansi(&raw);
    let display = (plain != raw).then(|| finish(raw.clone()));
    Ok(Output {
        content: finish(plain),
        display,
        diff: None,
    })
}

/// Wrap the shell in macOS seatbelt: everything allowed except file writes outside the
/// workspace and temp dirs. Fails closed on other platforms until bubblewrap support lands.
fn sandboxed(root: &std::path::Path, shell: &str) -> Result<tokio::process::Command> {
    if !cfg!(target_os = "macos") {
        bail!("the Bash sandbox is only implemented on macOS so far");
    }
    let tmp = std::env::temp_dir()
        .canonicalize()
        .unwrap_or_else(|_| std::env::temp_dir());
    let quote = |p: &std::path::Path| {
        p.display()
            .to_string()
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
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
  (regex #"^/dev/fd/"))"#,
        quote(root),
        quote(&tmp)
    );
    let mut cmd = tokio::process::Command::new("/usr/bin/sandbox-exec");
    cmd.arg("-p").arg(profile).arg(shell);
    Ok(cmd)
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[tokio::test]
    async fn sandbox_confines_shell_writes_to_the_workspace() {
        let ws = std::env::temp_dir().join(format!("kiln-sbx-{}", crate::session::new_id()));
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

        let escape = dirs::home_dir().unwrap().join(".kiln-sandbox-escape-test");
        let cmd = format!("touch '{}'", escape.display());
        let out = run(&json!({ "command": cmd }), &mut ctx).await.unwrap();
        let escaped = escape.exists();
        let _ = std::fs::remove_file(&escape);
        assert!(!escaped, "sandbox let a write escape the workspace");
        assert!(out.content.contains("exit code"), "{}", out.content);
    }
}
