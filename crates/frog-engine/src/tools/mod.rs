pub mod bash;
pub mod compare;
pub mod diagram;
pub mod docs;
pub mod fs;
pub mod image;
pub mod rank;
pub mod search;
pub mod sessions;
pub mod screenshot;
pub mod visual;
pub mod todo;
pub mod web;
pub mod websearch;

use crate::provider::ToolSpec;
use anyhow::{Result, anyhow, bail};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

pub struct Ctx {
    pub screenshot_endpoint: Option<String>,
    pub judge: Option<crate::config::Profile>,
    pub image: image::Settings,
    pub cwd: PathBuf,
    /// Files the model has seen, with the mtime at read time. Guards Edit/Write.
    pub read_files: HashMap<PathBuf, Option<SystemTime>>,
    pub todos: Vec<todo::Todo>,
    /// When set, writes (Write/Edit, and Bash via seatbelt or bubblewrap) are confined to this
    /// directory and the system temp dirs. Canonical path.
    pub sandbox: Option<PathBuf>,
    /// Run Bash sandboxed by default (writes confined to this project, temp and toolchain
    /// caches; credentials unreadable), unless a call asks for `unsandboxed`. Canonical path.
    pub shell_sandbox: Option<PathBuf>,
    /// Live output from the running tool, if someone is listening.
    pub progress: Option<tokio::sync::mpsc::UnboundedSender<String>>,
    /// Bounded approximate image deltas for transcript display, never model context.
    pub preview: Option<tokio::sync::mpsc::UnboundedSender<crate::protocol::Delta>>,
    /// Web settings, the page cache and the search backend.
    pub web: std::sync::Arc<web::Web>,
}

impl Ctx {
    pub fn new(cwd: PathBuf) -> Self {
        Self {
            cwd,
            image: Default::default(),
            screenshot_endpoint: None,
            judge: None,
            read_files: HashMap::new(),
            todos: Vec::new(),
            sandbox: None,
            shell_sandbox: None,
            progress: None,
            preview: None,
            web: Default::default(),
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
    /// Reaches the network without changing anything (WebFetch, WebSearch).
    Net,
}

#[derive(Default)]
pub struct Output {
    /// What the model sees.
    pub content: String,
    /// What the user sees, if different (diffs, summaries).
    pub display: Option<String>,
    /// Structured change, for Write/Edit.
    pub diff: Option<crate::protocol::FileDiff>,
    /// A laid-out diagram, for Diagram.
    pub diagram: Option<Box<crate::diagram::Diagram>>,
    /// Validated blocks, for Present.
    pub present: Option<Box<crate::present::Present>>,
    /// Images to show the user (MCP results).
    pub images: Vec<crate::protocol::Image>,
    /// An MCP App to host for this result.
    pub app: Option<Box<crate::protocol::AppView>>,
}

impl Output {
    pub fn text(s: impl Into<String>) -> Self {
        Self {
            content: s.into(),
            display: None,
            diff: None,
            diagram: None,
            present: None,
            images: Vec::new(),
            app: None,
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
        image::spec(),
        screenshot::spec(),
        compare::spec(),
        diagram::map_spec(),
        web::spec(),
        docs::spec(),
    ]
}

pub fn kind(name: &str) -> Kind {
    match name {
        "Bash" | "Image" | "Screenshot" | "Compare" => Kind::Exec,
        // Its command asks like Bash; a bare timer is let through (`Agent::permit`).
        crate::background::MONITOR => Kind::Exec,
        // Their read actions are exempted per call (`panes::is_read`).
        crate::panes::TERMINAL | crate::panes::PREVIEW => Kind::Exec,
        "Write" | "Edit" => Kind::Edit,
        "WebFetch" | "WebSearch" => Kind::Net,
        // MCP tools can do anything their server does: ask, like Bash.
        n if n.starts_with("mcp__") => Kind::Exec,
        crate::mcp::SEARCH_TOOL => Kind::Read,
        // A subagent can only read.
        crate::subagent::TOOL => Kind::Read,
        crate::skills::TOOL => Kind::Read,
        // Moving into a folder hands over its files and shell: always asks.
        crate::folder::TOOL => Kind::Exec,
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
        "Image" => image::run(input, ctx).await,
        "Screenshot" => screenshot::run(input, ctx).await,
        "Compare" => compare::run(input, ctx).await,
        "CodeMap" => diagram::run_map(input, ctx),
        "WebFetch" => web::run(input, ctx).await,
        "WebSearch" => websearch::run(input, ctx).await,
        "Docs" => docs::run(input, ctx).await,
        _ => bail!(
            "unknown tool `{name}`. Available: Bash, Terminal, Read, Write, Edit, Glob, Grep, TodoWrite, Diagram, Image, Screenshot, Compare, CodeMap, WebFetch, Docs"
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
        "Image" => s("prompt"),
        "Screenshot" => s("url"),
        "Compare" => format!("{} → {}",s("target"),s("actual")),
        "CodeMap" => s("path"),
        "WebFetch" => s("url"),
        "WebSearch" => s("query"),
        "Docs" => [s("package"), s("query")]
            .into_iter()
            .filter(|x| !x.is_empty())
            .collect::<Vec<_>>()
            .join(": "),
        "Task" => s("description"),
        "Monitor" => {
            let c = s("command");
            if c.is_empty() {
                format!("{}s", input["after_s"])
            } else {
                c
            }
        }
        "TaskOutput" | "TaskStop" | "JobOutput" | "JobStop" => s("id"),
        crate::folder::TOOL => s("path"),
        "Recall" => {
            let q = s("query");
            if q.is_empty() { s("file") } else { q }
        }
        crate::panes::TERMINAL | crate::panes::PREVIEW => crate::panes::label(name, input),
        "Skill" => {
            let n = s("name");
            if n.is_empty() { s("query") } else { n }
        }
        // MCP: the first string argument is usually the interesting one (a query, a path).
        n if n.starts_with("mcp__") => input
            .as_object()
            .and_then(|o| o.values().find_map(|v| v.as_str().map(String::from)))
            .unwrap_or_default(),
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
        regex::Regex::new(
            r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-B]|\x1b[=>78cDEHM]|\r",
        )
        .unwrap()
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
        let ws = std::env::temp_dir().join(format!("frog-ws-{}", crate::session::new_id()));
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
