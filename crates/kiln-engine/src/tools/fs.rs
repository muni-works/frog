use super::{Ctx, Output, bool_arg, int_arg, str_arg};
use crate::protocol::{DiffLine, FileDiff, Hunk, LineKind};
use crate::provider::ToolSpec;
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use similar::{ChangeTag, TextDiff};
use std::fmt::Write as _;
use std::path::Path;

pub fn read_spec() -> ToolSpec {
    ToolSpec {
        name: "Read",
        description: "Read a text file. Returns lines prefixed with 1-based line numbers (cat -n style). \
Reads up to 2000 lines by default; use offset/limit for large files. You must Read a file before editing it.",
        schema: json!({
            "type": "object",
            "properties": {
                "file_path": { "type": "string", "description": "Path to the file, absolute or relative to the working directory" },
                "offset": { "type": "integer", "description": "1-based line number to start reading from" },
                "limit": { "type": "integer", "description": "Maximum number of lines to read" }
            },
            "required": ["file_path"]
        }),
    }
}

pub fn write_spec() -> ToolSpec {
    ToolSpec {
        name: "Write",
        description: "Create a new file or completely overwrite an existing one. Prefer Edit for changing existing files. \
Existing files must be Read first.",
        schema: json!({
            "type": "object",
            "properties": {
                "file_path": { "type": "string", "description": "Path to the file" },
                "content": { "type": "string", "description": "Full file content" }
            },
            "required": ["file_path", "content"]
        }),
    }
}

pub fn edit_spec() -> ToolSpec {
    ToolSpec {
        name: "Edit",
        description: "Replace an exact string in a file. old_string must match the file exactly (including whitespace and \
indentation, without the line-number prefix from Read) and be unique unless replace_all is true. \
Include enough surrounding lines to make it unique. The file must be Read first.",
        schema: json!({
            "type": "object",
            "properties": {
                "file_path": { "type": "string", "description": "Path to the file" },
                "old_string": { "type": "string", "description": "Exact text to replace" },
                "new_string": { "type": "string", "description": "Replacement text" },
                "replace_all": { "type": "boolean", "description": "Replace every occurrence (default false)" }
            },
            "required": ["file_path", "old_string", "new_string"]
        }),
    }
}

pub async fn read(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let path = ctx.resolve(str_arg(input, "file_path")?);
    let meta = tokio::fs::metadata(&path)
        .await
        .with_context(|| format!("cannot read {}", path.display()))?;
    if meta.is_dir() {
        bail!(
            "{} is a directory. Use Glob or `ls` via Bash.",
            path.display()
        );
    }
    let bytes = tokio::fs::read(&path).await?;
    if bytes[..bytes.len().min(8192)].contains(&0) {
        bail!("{} looks like a binary file", path.display());
    }
    ctx.mark_read(&path);
    let text = String::from_utf8_lossy(&bytes);
    let total = text.lines().count();
    if total == 0 {
        return Ok(Output {
            content: "(empty file)".into(),
            display: Some("empty file".into()),
            diff: None,
            diagram: None,
        });
    }
    let start = int_arg(input, "offset").unwrap_or(1).max(1) as usize - 1;
    let limit = int_arg(input, "limit").unwrap_or(2000).max(1) as usize;
    let mut out = String::new();
    let mut shown = 0;
    for (i, line) in text.lines().enumerate().skip(start).take(limit) {
        let line = match line.char_indices().nth(2000) {
            Some((cut, _)) => format!("{}… [line truncated]", &line[..cut]),
            None => line.to_string(),
        };
        let _ = writeln!(out, "{:>6}\t{line}", i + 1);
        shown += 1;
    }
    if start + shown < total {
        let _ = writeln!(
            out,
            "… {} more lines (use offset={} to continue)",
            total - start - shown,
            start + shown + 1
        );
    }
    if shown == 0 {
        out = format!(
            "offset {} is past the end of the file ({total} lines)",
            start + 1
        );
    }
    Ok(Output {
        content: out,
        display: Some(format!("Read {shown} lines")),
        diff: None,
        diagram: None,
    })
}

/// Edits must be based on what the model actually saw.
fn check_fresh(ctx: &Ctx, path: &Path) -> Result<()> {
    let Some(seen) = ctx.read_files.get(path) else {
        bail!("you must Read {} before modifying it", ctx.display(path));
    };
    let now = std::fs::metadata(path).and_then(|m| m.modified()).ok();
    if now != *seen {
        bail!(
            "{} changed on disk since you last read it. Read it again first.",
            ctx.display(path)
        );
    }
    Ok(())
}

pub async fn write(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let path = ctx.resolve(str_arg(input, "file_path")?);
    let content = str_arg(input, "content")?;
    ctx.check_writable(&path)?;
    let old = if path.exists() {
        check_fresh(ctx, &path)?;
        Some(tokio::fs::read_to_string(&path).await.unwrap_or_default())
    } else {
        None
    };
    if let Some(dir) = path.parent() {
        tokio::fs::create_dir_all(dir).await?;
    }
    tokio::fs::write(&path, content).await?;
    ctx.mark_read(&path);
    let lines = content.lines().count();
    let display = match &old {
        Some(old) => diff(old, content),
        None => format!("Created {} ({lines} lines)", ctx.display(&path)),
    };
    let structured = file_diff(&ctx.display(&path), old.as_deref(), content);
    Ok(Output {
        content: format!("Wrote {lines} lines to {}", ctx.display(&path)),
        display: Some(display),
        diff: Some(structured),
        diagram: None,
    })
}

pub async fn edit(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let path = ctx.resolve(str_arg(input, "file_path")?);
    let old_s = str_arg(input, "old_string")?;
    let new_s = str_arg(input, "new_string")?;
    let all = bool_arg(input, "replace_all");
    if old_s == new_s {
        bail!("old_string and new_string are identical");
    }
    if old_s.is_empty() {
        if path.exists() {
            bail!("old_string is empty; use Write to replace a whole file");
        }
        return write(
            &json!({ "file_path": input["file_path"], "content": new_s }),
            ctx,
        )
        .await;
    }
    ctx.check_writable(&path)?;
    check_fresh(ctx, &path)?;
    let text = tokio::fs::read_to_string(&path).await?;
    let n = text.matches(old_s).count();
    if n == 0 {
        let hint = if text.contains(old_s.trim()) {
            " (a whitespace-trimmed version exists; check indentation)"
        } else {
            ""
        };
        bail!(
            "old_string not found in {}{hint}. It must match exactly. Read the file again if unsure.",
            ctx.display(&path)
        );
    }
    if n > 1 && !all {
        bail!(
            "old_string matches {n} places. Add surrounding context to make it unique, or set replace_all."
        );
    }
    let updated = if all {
        text.replace(old_s, new_s)
    } else {
        text.replacen(old_s, new_s, 1)
    };
    tokio::fs::write(&path, &updated).await?;
    ctx.mark_read(&path);
    let what = if n > 1 {
        format!(" ({n} replacements)")
    } else {
        String::new()
    };
    Ok(Output {
        content: format!("Edited {}{what}", ctx.display(&path)),
        display: Some(diff(&text, &updated)),
        diff: Some(file_diff(&ctx.display(&path), Some(&text), &updated)),
        diagram: None,
    })
}

/// What an Edit or Write would change, computed without touching the file.
/// `None` when it can't be previewed (e.g. old_string not found; the tool will report that).
pub fn preview(name: &str, input: &Value, ctx: &Ctx) -> Option<FileDiff> {
    let path = ctx.resolve(input["file_path"].as_str()?);
    let label = ctx.display(&path);
    match name {
        "Write" => {
            let new = input["content"].as_str()?;
            let old = std::fs::read_to_string(&path).ok();
            Some(file_diff(&label, old.as_deref(), new))
        }
        "Edit" => {
            let (old_s, new_s) = (input["old_string"].as_str()?, input["new_string"].as_str()?);
            if old_s.is_empty() {
                return (!path.exists()).then(|| file_diff(&label, None, new_s));
            }
            let text = std::fs::read_to_string(&path).ok()?;
            if !text.contains(old_s) {
                return None;
            }
            let updated = if bool_arg(input, "replace_all") {
                text.replace(old_s, new_s)
            } else {
                text.replacen(old_s, new_s, 1)
            };
            Some(file_diff(&label, Some(&text), &updated))
        }
        _ => None,
    }
}

/// Structured diff for clients. `old` is `None` for a newly created file.
pub fn file_diff(path: &str, old: Option<&str>, new: &str) -> FileDiff {
    let d = TextDiff::from_lines(old.unwrap_or(""), new);
    let (mut added, mut removed) = (0, 0);
    let hunks = d
        .grouped_ops(3)
        .iter()
        .map(|group| Hunk {
            lines: group
                .iter()
                .flat_map(|op| d.iter_changes(op))
                .map(|c| {
                    let kind = match c.tag() {
                        ChangeTag::Delete => {
                            removed += 1;
                            LineKind::Remove
                        }
                        ChangeTag::Insert => {
                            added += 1;
                            LineKind::Add
                        }
                        ChangeTag::Equal => LineKind::Context,
                    };
                    DiffLine {
                        kind,
                        old: c.old_index().map(|n| n as u32 + 1),
                        new: c.new_index().map(|n| n as u32 + 1),
                        text: c.value().trim_end_matches('\n').to_string(),
                    }
                })
                .collect(),
        })
        .collect();
    FileDiff {
        path: path.to_string(),
        created: old.is_none(),
        added,
        removed,
        hunks,
    }
}

/// Compact line diff: `+`/`-`/` ` prefixed lines with line numbers, hunks separated by `⋮`.
pub fn diff(old: &str, new: &str) -> String {
    let d = TextDiff::from_lines(old, new);
    let mut out = String::new();
    for (i, group) in d.grouped_ops(2).iter().enumerate() {
        if i > 0 {
            out.push_str("   ⋮\n");
        }
        for op in group {
            for c in d.iter_changes(op) {
                let (sign, n) = match c.tag() {
                    ChangeTag::Delete => ('-', c.old_index()),
                    ChangeTag::Insert => ('+', c.new_index()),
                    ChangeTag::Equal => (' ', c.new_index()),
                };
                let _ = writeln!(
                    out,
                    "{sign}{:>4} {}",
                    n.map(|n| n + 1).unwrap_or(0),
                    c.value().trim_end_matches('\n')
                );
            }
        }
    }
    out
}
