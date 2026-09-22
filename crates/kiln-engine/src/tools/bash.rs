use super::{Ctx, Output, int_arg, str_arg, truncate_middle};
use crate::provider::ToolSpec;
use anyhow::{Result, bail};
use serde_json::{Value, json};
use std::process::Stdio;
use std::time::Duration;

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

    let child = tokio::process::Command::new(shell)
        .arg("-c")
        .arg(&script)
        .current_dir(&ctx.cwd)
        .env("PAGER", "cat")
        .env("GIT_PAGER", "cat")
        .env("KILN", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true)
        .spawn()?;
    let group = Group(child.id().unwrap_or(0) as i32);

    let out = match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(out) => out?,
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

    let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr);
    if !stderr.trim().is_empty() {
        text.push_str(&stderr);
    }
    let mut text = truncate_middle(text.trim_end(), 30_000);
    let code = out.status.code().unwrap_or(-1);
    if code != 0 {
        text.push_str(&format!("\n[exit code {code}]"));
    }
    if text.trim().is_empty() {
        text = "(no output)".into();
    }
    Ok(Output::text(text))
}
