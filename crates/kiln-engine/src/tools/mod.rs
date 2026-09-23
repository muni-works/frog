pub mod bash;
pub mod diagram;
pub mod fs;
pub mod search;
pub mod todo;

use crate::provider::ToolSpec;
use anyhow::{Result, anyhow, bail};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

pub struct Ctx {
    pub cwd: PathBuf,
    /// Files the model has seen, with the mtime at read time. Guards Edit/Write.
    pub read_files: HashMap<PathBuf, Option<SystemTime>>,
    pub todos: Vec<todo::Todo>,
    /// When set, writes (Write/Edit, and Bash on macOS via sandbox-exec) are confined to this
    /// directory and the system temp dirs. Canonical path.
    pub sandbox: Option<PathBuf>,
    /// Live output from the running tool, if someone is listening.
    pub progress: Option<tokio::sync::mpsc::UnboundedSender<String>>,
}

impl Ctx {
    pub fn new(cwd: PathBuf) -> Self {
        Self {
            cwd,
            read_files: HashMap::new(),
            todos: Vec::new(),
            sandbox: None,
            progress: None,
        }
    }

    pub fn resolve(&self, p: &str) -> PathBuf {
        let p = match p.strip_prefix("~/") {
            Some(rest) => dirs::home_dir().unwrap_or_default().join(rest),
            None => PathBuf::from(p),
        };
        if p.is_absolute() { p } else { self.cwd.join(p) }
    }

    /// Refuse writes outside the sandbox. Resolves `..` and symlinks through the nearest
    /// existing ancestor, so a not-yet-created file is judged by where it would land.
    pub fn check_writable(&self, p: &Path) -> Result<()> {
        let Some(root) = &self.sandbox else {
            return Ok(());
        };
        let mut existing = p.to_path_buf();
        let mut rest = Vec::new();
        while !existing.exists() {
            let Some(name) = existing.file_name() else {
                break;
            };
            rest.push(name.to_os_string());
            if !existing.pop() {
                break;
            }
        }
        let mut real = existing.canonicalize().unwrap_or(existing);
        for part in rest.iter().rev() {
            if part == ".." {
                real.pop();
            } else if part != "." {
                real.push(part);
            }
        }
        let tmp = std::env::temp_dir()
            .canonicalize()
            .unwrap_or_else(|_| std::env::temp_dir());
        if real.starts_with(root) || real.starts_with(&tmp) {
            Ok(())
        } else {
            bail!(
                "{} is outside the workspace ({}); writes are sandboxed",
                p.display(),
                root.display()
            )
        }
    }

    /// Path shown to the model/user: relative to cwd when possible.
    pub fn display(&self, p: &Path) -> String {
        p.strip_prefix(&self.cwd).unwrap_or(p).display().to_string()
    }

    pub fn mark_read(&mut self, p: &Path) {
        let mtime = std::fs::metadata(p).and_then(|m| m.modified()).ok();
        self.read_files.insert(p.to_path_buf(), mtime);
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Read,
    Edit,
    Exec,
}

pub struct Output {
    /// What the model sees.
    pub content: String,
    /// What the user sees, if different (diffs, summaries).
    pub display: Option<String>,
    /// Structured change, for Write/Edit.
    pub diff: Option<crate::protocol::FileDiff>,
    /// A laid-out diagram, for Diagram.
    pub diagram: Option<Box<crate::diagram::Diagram>>,
}

impl Output {
    pub fn text(s: impl Into<String>) -> Self {
        Self {
            content: s.into(),
            display: None,
            diff: None,
            diagram: None,
        }
    }
}

pub fn specs() -> Vec<ToolSpec> {
    vec![
        bash::spec(),
        fs::read_spec(),
        fs::write_spec(),
        fs::edit_spec(),
        search::glob_spec(),
        search::grep_spec(),
        todo::spec(),
        diagram::spec(),
    ]
}

pub fn kind(name: &str) -> Kind {
    match name {
        "Bash" => Kind::Exec,
        "Write" | "Edit" => Kind::Edit,
        _ => Kind::Read,
    }
}

pub async fn run(name: &str, input: &Value, ctx: &mut Ctx) -> Result<Output> {
    if let Some(raw) = input.get("_invalid_json") {
        bail!("tool arguments were not valid JSON: {raw}. Retry with valid JSON.");
    }
    match name {
        "Bash" => bash::run(input, ctx).await,
        "Read" => fs::read(input, ctx).await,
        "Write" => fs::write(input, ctx).await,
        "Edit" => fs::edit(input, ctx).await,
        "Glob" => search::glob(input, ctx).await,
        "Grep" => search::grep(input, ctx).await,
        "TodoWrite" => todo::run(input, ctx),
        "Diagram" => diagram::run(input, ctx),
        _ => bail!(
            "unknown tool `{name}`. Available: Bash, Read, Write, Edit, Glob, Grep, TodoWrite, Diagram"
        ),
    }
}

/// Short label like `Bash(cargo test)` for display.
pub fn label(name: &str, input: &Value, ctx: &Ctx) -> (String, String) {
    let s = |k: &str| input[k].as_str().unwrap_or("").to_string();
    let arg = match name {
        "Bash" => s("command").lines().next().unwrap_or("").to_string(),
        "Read" | "Write" | "Edit" => ctx.display(&ctx.resolve(&s("file_path"))),
        "Glob" | "Grep" => s("pattern"),
        "Diagram" => s("title"),
        _ => String::new(),
    };
    let arg = if arg.chars().count() > 100 {
        format!("{}…", arg.chars().take(100).collect::<String>())
    } else {
        arg
    };
    (name.to_string(), arg)
}

pub fn str_arg<'a>(input: &'a Value, key: &str) -> Result<&'a str> {
    input[key]
        .as_str()
        .ok_or_else(|| anyhow!("missing required string parameter `{key}`"))
}

/// Models often send numbers as strings; accept both.
pub fn int_arg(input: &Value, key: &str) -> Option<u64> {
    match &input[key] {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

pub fn bool_arg(input: &Value, key: &str) -> bool {
    match &input[key] {
        Value::Bool(b) => *b,
        Value::String(s) => s == "true",
        _ => false,
    }
}

/// Remove ANSI escape sequences (colors, cursor movement) so the model sees plain text.
pub fn strip_ansi(s: &str) -> String {
    static ANSI: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][0-9A-B]|\r").unwrap()
    });
    ANSI.replace_all(s, "").into_owned()
}

/// Keep the head and tail of long output.
pub fn truncate_middle(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let head = s.floor_char_boundary(max / 2);
    let tail = s.ceil_char_boundary(s.len() - max / 2);
    format!(
        "{}\n\n… [{} bytes truncated] …\n\n{}",
        &s[..head],
        tail - head,
        &s[tail..]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sandbox_write_check_resolves_dotdot_and_new_paths() {
        let ws = std::env::temp_dir().join(format!("kiln-ws-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let mut ctx = Ctx::new(ws.clone());
        assert!(
            ctx.check_writable(Path::new("/etc/passwd")).is_ok(),
            "no sandbox, no check"
        );

        ctx.sandbox = Some(ws.canonicalize().unwrap());
        assert!(ctx.check_writable(&ctx.resolve("new/dir/file.rs")).is_ok());
        let home = dirs::home_dir().unwrap().join("escape.txt");
        assert!(ctx.check_writable(&home).is_err());
        let sneaky = ctx
            .resolve("sub/../../../../../../..")
            .join(home.strip_prefix("/").unwrap());
        assert!(ctx.check_writable(&sneaky).is_err());
    }
}
