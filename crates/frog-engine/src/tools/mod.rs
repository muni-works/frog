pub mod bash;
pub mod compare;
pub mod diagram;
pub mod docs;
pub mod fs;
pub mod image;
pub mod rank;
pub mod screenshot;
pub mod search;
pub mod sessions;
pub mod todo;
pub mod visual;
pub mod web;
pub mod websearch;

use crate::provider::ToolSpec;
use anyhow::{Result, anyhow, bail};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Component, Path, PathBuf};
use std::time::SystemTime;

pub struct Ctx {
    pub screenshot_endpoint: Option<String>,
    pub judge: Option<crate::config::Profile>,
    pub image: image::Settings,
    /// The session's working directory (its checkout, a worktree when it works in one). File
    /// tools resolve relative paths against this, and writes are confined to it.
    pub root: PathBuf,
    /// Where the shell runs. Bash's `cd` moves this; it never moves `root`, so file tools
    /// keep resolving against the session's own checkout however far the shell roams.
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
    /// Extra reads the shell sandbox allows (config `[sandbox]`).
    pub sandbox_extra: crate::config::SandboxConfig,
    /// Writes outside the session's checkout that the user approved, by resolved path. The
    /// engine adds one when it asks and the user allows; the tools never go elsewhere silently.
    pub permitted: HashSet<PathBuf>,
    /// Live output from the running tool, if someone is listening.
    pub progress: Option<tokio::sync::mpsc::UnboundedSender<String>>,
    /// Bounded approximate image deltas for transcript display, never model context.
    pub preview: Option<tokio::sync::mpsc::UnboundedSender<crate::protocol::Delta>>,
    /// The turn's cancel token, when a turn is running: a long tool (Bash) selects on it so
    /// Stop interrupts it in flight instead of waiting for it to finish.
    pub cancel: Option<tokio_util::sync::CancellationToken>,
    /// Web settings, the page cache and the search backend.
    pub web: std::sync::Arc<web::Web>,
}

impl Ctx {
    pub fn new(cwd: PathBuf) -> Self {
        Self {
            root: cwd.clone(),
            cwd,
            image: Default::default(),
            screenshot_endpoint: None,
            judge: None,
            read_files: HashMap::new(),
            todos: Vec::new(),
            sandbox: None,
            shell_sandbox: None,
            sandbox_extra: Default::default(),
            permitted: HashSet::new(),
            progress: None,
            preview: None,
            cancel: None,
            web: Default::default(),
        }
    }

    pub fn resolve(&self, p: &str) -> PathBuf {
        let p = match p.strip_prefix("~/") {
            Some(rest) => dirs::home_dir().unwrap_or_default().join(rest),
            None => PathBuf::from(p),
        };
        if p.is_absolute() {
            p
        } else {
            self.root.join(p)
        }
    }

    /// The canonical session root, however it's spelled (missing trailing pieces allowed).
    fn real_root(&self) -> PathBuf {
        let mut real = PathBuf::new();
        for part in self.root.components() {
            match part {
                Component::CurDir => {}
                Component::ParentDir => {
                    real.pop();
                }
                other => real.push(other.as_os_str()),
            }
            if let Ok(resolved) = real.canonicalize() {
                real = resolved;
            }
        }
        real
    }

    /// Resolve `p` the way [`resolve`] does, then through `..` and symlinks to the nearest
    /// existing ancestor, so a not-yet-created file is judged by where it would land.
    fn real_path(&self, p: &Path) -> PathBuf {
        let abs = if p.is_absolute() {
            p.to_path_buf()
        } else {
            self.root.join(p)
        };
        let mut real = PathBuf::new();
        for part in abs.components() {
            match part {
                Component::CurDir => {}
                Component::ParentDir => {
                    real.pop();
                }
                Component::Normal(name) => {
                    real.push(name);
                    if let Ok(resolved) = real.canonicalize() {
                        real = resolved;
                    }
                }
                other => real.push(other.as_os_str()),
            }
        }
        real
    }

    /// Whether `p` (resolved like [`resolve`]) is inside the session's checkout. Absolute
    /// paths count only inside it: another checkout of the same repo (the main checkout when
    /// the session works in a worktree) is outside the project.
    pub fn inside(&self, p: &Path) -> bool {
        let real = self.real_path(p);
        let root = self.real_root();
        real.starts_with(&root)
    }

    /// Whether a write to `p` is outside the project: not in the session's checkout, and not
    /// scratch space. Temp dirs are scratch, unless the path is inside some other git checkout
    /// that happens to live there.
    pub fn outside(&self, p: &Path) -> bool {
        if self.inside(p) {
            return false;
        }
        let real = self.real_path(p);
        // The strict sandbox root, when set, is the session root.
        if self.sandbox.as_deref().is_some_and(|r| real.starts_with(r)) {
            return false;
        }
        let tmp = std::env::temp_dir()
            .canonicalize()
            .unwrap_or_else(|_| std::env::temp_dir());
        let scratch = real.starts_with(&tmp) || real.starts_with("/private/tmp");
        !scratch || self.in_other_checkout(&real)
    }

    /// Whether `real` (canonical) is inside a git work tree other than the session's.
    fn in_other_checkout(&self, real: &Path) -> bool {
        let mut dir = real.to_path_buf();
        while !dir.is_dir() {
            if !dir.pop() {
                return false;
            }
        }
        let Ok(out) = std::process::Command::new("git")
            .args(["rev-parse", "--show-toplevel"])
            .current_dir(&dir)
            .output()
        else {
            return false;
        };
        if !out.status.success() {
            return false;
        }
        let top = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim());
        let top = top.canonicalize().unwrap_or(top);
        top != self.real_root()
    }

    /// Refuse writes outside the session's checkout (and temp dirs). With no sandbox
    /// configured this still holds: a file tool never writes into another checkout (the main
    /// repo when the session is in a worktree) — that needs the user's approval, which the
    /// engine asks for and records in `permitted`.
    pub fn check_writable(&self, p: &Path) -> Result<()> {
        if !self.outside(p) || self.permitted.contains(p) {
            return Ok(());
        }
        bail!(
            "{} is outside this session's folder ({}); writing elsewhere needs your approval",
            p.display(),
            self.root.display()
        )
    }

    /// Path shown to the model/user: relative to the session root when possible.
    pub fn display(&self, p: &Path) -> String {
        p.strip_prefix(&self.root)
            .unwrap_or(p)
            .display()
            .to_string()
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
        "Compare" => format!("{} → {}", s("target"), s("actual")),
        "CodeMap" => s("path"),
        "WebFetch" => s("url"),
        "WebSearch" => s("query"),
        "Docs" => [s("package"), s("query")]
            .into_iter()
            .filter(|x| !x.is_empty())
            .collect::<Vec<_>>()
            .join(": "),
        "Task" => s("description"),
        crate::title::TOOL => s("title"),
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
        // No sandbox, and still: writes stay inside the session's folder (or temp).
        assert!(
            ctx.check_writable(Path::new("/etc/passwd")).is_err(),
            "a file tool never writes outside the session's folder"
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

    /// A git repo and a worktree of it, for path-root tests: (main checkout, worktree).
    fn repo_with_worktree(tag: &str) -> (PathBuf, PathBuf) {
        let base =
            std::env::temp_dir().join(format!("frog-ctx-{}-{}", tag, crate::session::new_id()));
        let main = base.join("main");
        let wt = base.join("wt");
        std::fs::create_dir_all(&main).unwrap();
        let git = |args: &[&str]| {
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
                .current_dir(&main)
                .status()
                .unwrap()
                .success();
            assert!(ok, "git {args:?} failed");
        };
        git(&["init", "-q"]);
        std::fs::write(main.join("seed.txt"), "seed\n").unwrap();
        git(&["add", "."]);
        git(&["commit", "-qm", "init"]);
        git(&["worktree", "add", "-q", wt.to_str().unwrap()]);
        (main, wt)
    }

    /// Relative paths resolve against the session's checkout, not wherever the shell has `cd`d.
    /// A session rooted in a worktree writes there even after `ctx.cwd` moves to the main
    /// checkout, and an absolute path into the main checkout counts as outside the project.
    #[test]
    fn file_tools_resolve_against_the_session_root_not_the_shell_cwd() {
        let (main, wt) = repo_with_worktree("resolve");
        let mut ctx = Ctx::new(wt.clone());
        // The shell `cd`d to the main checkout (what Bash does to `ctx.cwd` after a call).
        ctx.cwd = main.clone();

        assert_eq!(ctx.resolve("file.rs"), wt.join("file.rs"));
        assert_eq!(ctx.display(&wt.join("file.rs")), "file.rs");
        // The same file in the main checkout is a different, outside path.
        assert!(!ctx.inside(&main.join("file.rs")));
        assert!(ctx.inside(&wt.join("file.rs")));
        assert!(ctx.check_writable(&main.join("file.rs")).is_err());
        // Until the user approves that exact path.
        ctx.permitted.insert(main.join("approved.rs"));
        assert!(ctx.check_writable(&main.join("approved.rs")).is_ok());
        // Dot-dot is judged from the session root, so it takes real paths into account.
        let up = wt.join("../wt/escape.rs");
        assert!(ctx.inside(&up), "{up:?} should resolve inside the worktree");
        assert!(ctx.check_writable(&up).is_ok());
        let _ = std::fs::remove_dir_all(main.parent().unwrap());
    }

    /// A plain (non-worktree) session keeps behaving as before: relative writes inside,
    /// home and friends outside.
    #[test]
    fn check_writable_holds_without_a_sandbox() {
        let ws = std::env::temp_dir().join(format!("frog-plain-{}", crate::session::new_id()));
        std::fs::create_dir_all(&ws).unwrap();
        let ctx = Ctx::new(ws.clone());
        assert!(ctx.check_writable(&ctx.resolve("deep/new/file.rs")).is_ok());
        assert!(
            ctx.check_writable(&std::env::temp_dir().join("frog-tmp-out.txt"))
                .is_ok(),
            "temp stays writable"
        );
        let home = dirs::home_dir().unwrap().join("frog-home-out.txt");
        assert!(ctx.check_writable(&home).is_err());
        let _ = std::fs::remove_dir_all(ws);
    }
}
