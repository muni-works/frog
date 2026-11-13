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
        name: "Read".into(),
        description: "Read a text file. Returns lines prefixed with 1-based line numbers (cat -n style). \
Reads up to 2000 lines by default; use offset/limit for large files. On a directory, lists its entries \
(like `ls`, capped at 200). You must Read a file before editing it.".into(),
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
        name: "Write".into(),
        description: "Create a new file or completely overwrite an existing one. Prefer Edit for changing existing files. \
Existing files must be Read first.".into(),
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
        name: "Edit".into(),
        description: "Replace an exact string in a file. old_string must match the file exactly (including whitespace and \
indentation, without the line-number prefix from Read) and be unique unless replace_all is true. \
Include enough surrounding lines to make it unique. The file must be Read first.".into(),
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

/// The most of a file Read scans. Lines past it aren't shown or counted; the result says so.
const READ_SCAN_CAP: u64 = 64 << 20;

pub async fn read(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let path = ctx.resolve(str_arg(input, "file_path")?);
    // Credentials stay out of the model's context (and so off the network): the same paths
    // the Bash sandbox hides. A user who wants one read can do it themselves.
    if crate::credentials::is_secret_path(&path, &dirs::home_dir().unwrap_or_default()) {
        bail!(
            "{} holds credentials, which frog doesn't read. If the task genuinely needs it, ask the user to share what's needed.",
            ctx.display(&path)
        );
    }
    let meta = tokio::fs::metadata(&path)
        .await
        .with_context(|| format!("cannot read {}", path.display()))?;
    if meta.is_dir() {
        return list_dir(&path, ctx);
    }
    // A FIFO would block forever, /dev/zero would never end.
    if !meta.is_file() {
        bail!("{} isn't a regular file", path.display());
    }
    let start = int_arg(input, "offset").unwrap_or(1).max(1) as usize - 1;
    let limit = int_arg(input, "limit").unwrap_or(2000).max(1) as usize;
    let file = path.clone();
    let scan = tokio::task::spawn_blocking(move || scan_lines(&file, start, limit))
        .await
        .context("Read panicked")??;
    let Some(Scan {
        window,
        total,
        capped,
    }) = scan
    else {
        bail!("{} looks like a binary file", path.display());
    };
    ctx.mark_read(&path);
    if total == 0 {
        return Ok(Output {
            content: "(empty file)".into(),
            display: Some("empty file".into()),
            diff: None,
            diagram: None,
            present: None,
            widget: None,
            ..Default::default()
        });
    }
    let mut out = String::new();
    let shown = window.len();
    for (i, line) in window.iter().enumerate() {
        let line = match line.char_indices().nth(2000) {
            Some((cut, _)) => format!("{}… [line truncated]", &line[..cut]),
            None => line.to_string(),
        };
        let _ = writeln!(out, "{:>6}\t{line}", start + i + 1);
    }
    if start + shown < total {
        let _ = writeln!(
            out,
            "… {} more lines (use offset={} to continue)",
            total - start - shown,
            start + shown + 1
        );
    }
    if capped {
        let _ = writeln!(
            out,
            "… the file is over {} MiB; Read stopped there (use Bash for the rest)",
            READ_SCAN_CAP >> 20
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
        present: None,
        widget: None,
        ..Default::default()
    })
}

struct Scan {
    /// Lines `start..start + limit`, without their endings.
    window: Vec<String>,
    /// Lines scanned in all.
    total: usize,
    /// The scan stopped at `READ_SCAN_CAP`.
    capped: bool,
}

/// Streams a file line by line, keeping only the requested window, so memory follows the
/// window, not the file. `None`: a NUL in the first 8 KiB, so binary.
fn scan_lines(path: &Path, start: usize, limit: usize) -> Result<Option<Scan>> {
    use std::io::{BufRead, Read};
    let f = std::fs::File::open(path).with_context(|| format!("cannot read {}", path.display()))?;
    let mut r = std::io::BufReader::with_capacity(64 << 10, f.take(READ_SCAN_CAP + 1));
    if r.fill_buf()?.iter().take(8192).any(|b| *b == 0) {
        return Ok(None);
    }
    let (mut window, mut total, mut read) = (Vec::new(), 0usize, 0u64);
    let mut line = Vec::new();
    let mut capped = false;
    loop {
        line.clear();
        let n = r.read_until(b'\n', &mut line)?;
        if n == 0 {
            break;
        }
        read += n as u64;
        if read > READ_SCAN_CAP {
            capped = true;
            break;
        }
        if total >= start && total < start + limit {
            let mut l: &[u8] = &line;
            l = l.strip_suffix(b"\n").unwrap_or(l);
            l = l.strip_suffix(b"\r").unwrap_or(l);
            window.push(String::from_utf8_lossy(l).into_owned());
        }
        total += 1;
    }
    Ok(Some(Scan {
        window,
        total,
        capped,
    }))
}

/// List a directory's entries (like `ls`), capped at 200.
fn list_dir(path: &Path, ctx: &Ctx) -> Result<Output> {
    let mut entries: Vec<_> = std::fs::read_dir(path)?
        .filter_map(|e| e.ok())
        .map(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
            (name, is_dir)
        })
        .collect();
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    let total = entries.len();
    let mut out = String::new();
    for (name, is_dir) in entries.iter().take(200) {
        let _ = writeln!(out, "{}{}", name, if *is_dir { "/" } else { "" });
    }
    if total > 200 {
        let _ = writeln!(
            out,
            "… {} more (use Glob with a narrower pattern)",
            total - 200
        );
    }
    if total == 0 {
        out = "(empty directory)".to_string();
    }
    Ok(Output {
        content: out,
        display: Some(format!(
            "Listed {} entr{} in {}",
            total.min(200),
            if total.min(200) == 1 { "y" } else { "ies" },
            ctx.display(path)
        )),
        diff: None,
        diagram: None,
        present: None,
        widget: None,
        ..Default::default()
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
    let mut binary_old = None;
    let old = if path.exists() {
        check_fresh(ctx, &path)?;
        match tokio::fs::read(&path).await.map(String::from_utf8) {
            Ok(Ok(text)) => Some(text),
            // Not text: say it was overwritten rather than diffing against nothing.
            Ok(Err(e)) => {
                binary_old = Some(e.as_bytes().len());
                None
            }
            Err(_) => Some(String::new()),
        }
    } else {
        None
    };
    if let Some(dir) = path.parent() {
        tokio::fs::create_dir_all(dir).await?;
    }
    tokio::fs::write(&path, content).await?;
    ctx.mark_read(&path);
    let lines = content.lines().count();
    let display = match (&old, binary_old) {
        (Some(old), _) => diff(old, content),
        (None, Some(bytes)) => format!(
            "Overwrote binary file {} ({bytes} bytes) with {lines} lines",
            ctx.display(&path)
        ),
        (None, None) => format!("Created {} ({lines} lines)", ctx.display(&path)),
    };
    let structured = file_diff(&ctx.display(&path), old.as_deref(), content);
    Ok(Output {
        content: match binary_old {
            Some(bytes) => format!(
                "Overwrote binary file {} ({bytes} bytes) with {lines} lines of text",
                ctx.display(&path)
            ),
            None => format!("Wrote {lines} lines to {}", ctx.display(&path)),
        },
        display: Some(display),
        diff: Some(structured),
        diagram: None,
        present: None,
        widget: None,
        ..Default::default()
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
        present: None,
        widget: None,
        ..Default::default()
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tempfile::TempDir;

    fn block_on<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Runtime::new().unwrap().block_on(f)
    }

    /// Read refuses credentials: ssh keys and gh tokens under $HOME, and key files by name
    /// anywhere (a key copied into the project), before touching the file.
    #[test]
    fn read_refuses_credential_paths() {
        let tmp = TempDir::new().unwrap();
        std::fs::write(
            tmp.path().join("id_rsa"),
            "-----BEGIN OPENSSH PRIVATE KEY-----",
        )
        .unwrap();
        std::fs::write(tmp.path().join("notes.txt"), "fine").unwrap();
        let mut ctx = Ctx::new(tmp.path().to_path_buf());
        let home = dirs::home_dir().unwrap();
        for p in [
            home.join(".ssh/id_ed25519"),
            home.join(".aws/credentials"),
            home.join(".config/gh/hosts.yml"),
            home.join(".config/frog/models.json"),
            tmp.path().join("id_rsa"),
        ] {
            let err = block_on(read(&json!({ "file_path": p }), &mut ctx)).err().expect("should be refused");
            assert!(
                err.to_string().contains("holds credentials"),
                "{}: {err}",
                p.display()
            );
        }
        // A symlink in the project pointing at a key is refused too.
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(tmp.path().join("id_rsa"), tmp.path().join("innocent.txt"))
                .unwrap();
            let err = block_on(read(
                &json!({ "file_path": tmp.path().join("innocent.txt") }),
                &mut ctx,
            ))
            .err().expect("should be refused");
            assert!(err.to_string().contains("holds credentials"), "{err}");
        }
        let ok = block_on(read(
            &json!({ "file_path": tmp.path().join("notes.txt") }),
            &mut ctx,
        ))
        .unwrap();
        assert!(ok.content.contains("fine"));
    }

    /// A FIFO (or a device) isn't read: it would hang or never end.
    #[cfg(unix)]
    #[test]
    fn read_refuses_non_regular_files() {
        let tmp = TempDir::new().unwrap();
        let fifo = tmp.path().join("pipe");
        assert!(
            std::process::Command::new("mkfifo")
                .arg(&fifo)
                .status()
                .unwrap()
                .success()
        );
        let mut ctx = Ctx::new(tmp.path().to_path_buf());
        let input = json!({ "file_path": fifo });
        let read_fifo = read(&input, &mut ctx);
        let err = block_on(async {
            tokio::time::timeout(std::time::Duration::from_secs(5), read_fifo)
                .await
                .expect("Read hung on a FIFO")
        })
        .err().expect("should be refused");
        assert!(err.to_string().contains("regular file"), "{err}");
        let err = block_on(read(&json!({ "file_path": "/dev/zero" }), &mut ctx)).err().expect("should be refused");
        assert!(err.to_string().contains("regular file"), "{err}");
    }

    /// Streaming keeps numbering, the window and the remaining count right.
    #[test]
    fn read_streams_a_window_of_a_large_file() {
        let tmp = TempDir::new().unwrap();
        let f = tmp.path().join("big.log");
        let text: String = (1..=50_000).map(|i| format!("line {i}\r\n")).collect();
        std::fs::write(&f, text).unwrap();
        let mut ctx = Ctx::new(tmp.path().to_path_buf());
        let out = block_on(read(
            &json!({ "file_path": f, "offset": 49_999, "limit": 5 }),
            &mut ctx,
        ))
        .unwrap();
        assert_eq!(out.content, " 49999\tline 49999\n 50000\tline 50000\n");
        let out = block_on(read(
            &json!({ "file_path": f, "offset": 10, "limit": 1 }),
            &mut ctx,
        ))
        .unwrap();
        assert_eq!(
            out.content,
            "    10\tline 10\n… 49990 more lines (use offset=11 to continue)\n"
        );
    }

    /// Writing over a non-UTF-8 file says it overwrote a binary file, not "created".
    #[test]
    fn write_over_binary_reports_overwrite() {
        let tmp = TempDir::new().unwrap();
        let f = tmp.path().join("blob.bin");
        std::fs::write(&f, [0xffu8, 0xfe, 0x00, 0x01]).unwrap();
        let mut ctx = Ctx::new(tmp.path().to_path_buf());
        ctx.mark_read(&f);
        let out = block_on(write(
            &json!({ "file_path": f, "content": "text\n" }),
            &mut ctx,
        ))
        .unwrap();
        assert!(
            out.content.contains("Overwrote binary file"),
            "{}",
            out.content
        );
        assert!(out.display.unwrap().contains("4 bytes"));
    }

    #[test]
    fn read_on_a_directory_lists_it() {
        let tmp = TempDir::new().unwrap();
        std::fs::create_dir(tmp.path().join("sub")).unwrap();
        std::fs::write(tmp.path().join("a.txt"), "hi").unwrap();
        std::fs::write(tmp.path().join("z.txt"), "yo").unwrap();
        let mut ctx = Ctx::new(tmp.path().to_path_buf());

        let input = json!({ "file_path": tmp.path().to_str() });
        let out = block_on(read(&input, &mut ctx)).unwrap();
        // entries are sorted, directories get a trailing slash
        assert_eq!(out.content, "a.txt\nsub/\nz.txt\n");
        assert!(out.display.unwrap().contains("3 entries"),);
    }

    #[test]
    fn read_on_an_empty_directory_says_so() {
        let tmp = TempDir::new().unwrap();
        let mut ctx = Ctx::new(tmp.path().to_path_buf());
        let input = json!({ "file_path": tmp.path().to_str() });
        let out = block_on(read(&input, &mut ctx)).unwrap();
        assert_eq!(out.content, "(empty directory)");
    }

    #[test]
    fn read_on_a_directory_caps_at_200_entries() {
        let tmp = TempDir::new().unwrap();
        for i in 0..205 {
            std::fs::write(tmp.path().join(format!("f{:03}.txt", i)), "x").unwrap();
        }
        let mut ctx = Ctx::new(tmp.path().to_path_buf());
        let input = json!({ "file_path": tmp.path().to_str() });
        let out = block_on(read(&input, &mut ctx)).unwrap();
        let lines: Vec<&str> = out.content.lines().collect();
        assert_eq!(lines.len(), 201); // 200 entries + hint
        assert!(out.content.contains("… 5 more"));
        assert!(out.display.unwrap().contains("200 entries"));
    }
}
