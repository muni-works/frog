pub mod bash;
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
}

impl Ctx {
    pub fn new(cwd: PathBuf) -> Self {
        Self {
            cwd,
            read_files: HashMap::new(),
            todos: Vec::new(),
        }
    }

    pub fn resolve(&self, p: &str) -> PathBuf {
        let p = match p.strip_prefix("~/") {
            Some(rest) => dirs::home_dir().unwrap_or_default().join(rest),
            None => PathBuf::from(p),
        };
        if p.is_absolute() { p } else { self.cwd.join(p) }
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
}

impl Output {
    pub fn text(s: impl Into<String>) -> Self {
        Self {
            content: s.into(),
            display: None,
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
        _ => bail!(
            "unknown tool `{name}`. Available: Bash, Read, Write, Edit, Glob, Grep, TodoWrite"
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
