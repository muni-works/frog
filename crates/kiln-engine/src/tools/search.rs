use super::{Ctx, Output, bool_arg, int_arg, str_arg};
use crate::provider::ToolSpec;
use anyhow::{Result, bail};
use globset::{Glob, GlobMatcher};
use ignore::WalkBuilder;
use serde_json::{Value, json};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

pub fn glob_spec() -> ToolSpec {
    ToolSpec {
        name: "Glob",
        description: "Find files by glob pattern (e.g. `**/*.rs`, `src/**/test_*.py`). Respects .gitignore. \
Returns paths sorted by modification time, newest first.",
        schema: json!({
            "type": "object",
            "properties": {
                "pattern": { "type": "string", "description": "Glob pattern" },
                "path": { "type": "string", "description": "Directory to search (default: working directory)" }
            },
            "required": ["pattern"]
        }),
    }
}

pub fn grep_spec() -> ToolSpec {
    ToolSpec {
        name: "Grep",
        description: "Search file contents with a regex (Rust regex syntax). Respects .gitignore. \
output_mode: `files_with_matches` (default, lists files), `content` (matching lines as path:line:text), or `count`.",
        schema: json!({
            "type": "object",
            "properties": {
                "pattern": { "type": "string", "description": "Regular expression" },
                "path": { "type": "string", "description": "File or directory to search (default: working directory)" },
                "glob": { "type": "string", "description": "Only search files matching this glob, e.g. `*.ts`" },
                "output_mode": { "type": "string", "enum": ["files_with_matches", "content", "count"] },
                "case_insensitive": { "type": "boolean" },
                "head_limit": { "type": "integer", "description": "Max results (default 100)" }
            },
            "required": ["pattern"]
        }),
    }
}

fn matcher(pattern: &str) -> Result<GlobMatcher> {
    Ok(Glob::new(pattern)?.compile_matcher())
}

fn walk(root: &Path) -> impl Iterator<Item = PathBuf> {
    WalkBuilder::new(root)
        .hidden(false)
        .filter_entry(|e| e.file_name() != ".git")
        .build()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_some_and(|t| t.is_file()))
        .map(|e| e.into_path())
}

fn root(input: &Value, ctx: &Ctx) -> Result<PathBuf> {
    let root = ctx.resolve(input["path"].as_str().unwrap_or("."));
    if !root.exists() {
        bail!("path does not exist: {}", root.display());
    }
    Ok(root)
}

pub async fn glob(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let pattern = str_arg(input, "pattern")?;
    let root = root(input, ctx)?;
    let m = matcher(pattern)?;
    let r = root.clone();
    let mut hits: Vec<(PathBuf, std::time::SystemTime)> = tokio::task::spawn_blocking(move || {
        walk(&r)
            .filter(|p| m.is_match(p.strip_prefix(&r).unwrap_or(p)))
            .map(|p| {
                let t = std::fs::metadata(&p)
                    .and_then(|m| m.modified())
                    .unwrap_or(std::time::UNIX_EPOCH);
                (p, t)
            })
            .collect()
    })
    .await?;
    hits.sort_by_key(|h| std::cmp::Reverse(h.1));
    let total = hits.len();
    if total == 0 {
        return Ok(Output::text("No files found"));
    }
    let mut out: String = hits
        .iter()
        .take(200)
        .map(|(p, _)| ctx.display(p) + "\n")
        .collect();
    if total > 200 {
        let _ = writeln!(out, "… {} more (narrow the pattern)", total - 200);
    }
    Ok(Output {
        content: out,
        display: Some(format!("Found {total} files")),
    })
}

pub async fn grep(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let re = regex::RegexBuilder::new(str_arg(input, "pattern")?)
        .case_insensitive(bool_arg(input, "case_insensitive") || bool_arg(input, "-i"))
        .build()?;
    let root = root(input, ctx)?;
    let filter = input["glob"].as_str().map(matcher).transpose()?;
    let mode = input["output_mode"]
        .as_str()
        .unwrap_or("files_with_matches")
        .to_string();
    let limit = int_arg(input, "head_limit").unwrap_or(100) as usize;
    let cwd = ctx.cwd.clone();

    let (out, n) = tokio::task::spawn_blocking(move || {
        let files: Box<dyn Iterator<Item = PathBuf>> = if root.is_file() {
            Box::new(std::iter::once(root.clone()))
        } else {
            Box::new(walk(&root))
        };
        let mut out = Vec::new();
        for path in files {
            if out.len() >= limit {
                break;
            }
            if let Some(f) = &filter {
                let rel = path.strip_prefix(&root).unwrap_or(&path);
                if !f.is_match(rel) && !path.file_name().is_some_and(|n| f.is_match(n)) {
                    continue;
                }
            }
            let Ok(bytes) = std::fs::read(&path) else {
                continue;
            };
            if bytes.len() > 4_000_000 || bytes[..bytes.len().min(8192)].contains(&0) {
                continue;
            }
            let text = String::from_utf8_lossy(&bytes);
            let rel = path
                .strip_prefix(&cwd)
                .unwrap_or(&path)
                .display()
                .to_string();
            match mode.as_str() {
                "content" => {
                    for (i, line) in text.lines().enumerate().filter(|(_, l)| re.is_match(l)) {
                        let line: String = line.chars().take(300).collect();
                        out.push(format!("{rel}:{}:{line}", i + 1));
                        if out.len() >= limit {
                            break;
                        }
                    }
                }
                "count" => {
                    let c = text.lines().filter(|l| re.is_match(l)).count();
                    if c > 0 {
                        out.push(format!("{rel}:{c}"));
                    }
                }
                _ => {
                    if re.is_match(&text) {
                        out.push(rel);
                    }
                }
            }
        }
        let n = out.len();
        (out.join("\n"), n)
    })
    .await?;

    if n == 0 {
        return Ok(Output::text("No matches"));
    }
    let more = if n >= limit {
        format!("\n… (limited to {limit} results)")
    } else {
        String::new()
    };
    Ok(Output {
        content: out + &more,
        display: Some(format!("Found {n} results")),
    })
}
