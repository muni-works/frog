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
        name: "Glob".into(),
        description:
            "Find files by glob pattern (e.g. `**/*.rs`, `src/**/test_*.py`). Respects .gitignore. \
Returns paths sorted by modification time, newest first, at most 200; past that, the total \
and a count per top-level directory, to narrow the pattern with."
                .into(),
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
        name: "Grep".into(),
        description: "Search file contents with a regex (Rust regex syntax). Respects .gitignore. \
output_mode: `files_with_matches` (default, lists files), `content` (matching lines as path:line:text), or `count`. \
Returns at most `head_limit` results (default 100).".into(),
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
    // Every match counted by top-level directory (files at the root under "./"), so a cut
    // list still says where the rest are.
    let mut dir_counts: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for (p, _) in &hits {
        let rel = p.strip_prefix(&root).unwrap_or(p);
        let mut parts = rel.components();
        let top = parts
            .next()
            .map(|c| c.as_os_str().to_string_lossy().to_string());
        let top = match (top, parts.next()) {
            (Some(dir), Some(_)) => format!("{dir}/"),
            _ => "./".to_string(),
        };
        *dir_counts.entry(top).or_insert(0) += 1;
    }
    let mut dirs: Vec<_> = dir_counts.into_iter().collect();
    dirs.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    let mut counts_str = String::new();
    for (dir, count) in dirs.iter().take(5) {
        let _ = writeln!(counts_str, "  {dir}: {count}");
    }
    if dirs.len() > 5 {
        let _ = writeln!(counts_str, "  … and {} more directories", dirs.len() - 5);
    }
    let mut out: String = hits
        .iter()
        .take(200)
        .map(|(p, _)| ctx.display(p) + "\n")
        .collect();
    if total > 200 {
        let _ = writeln!(
            out,
            "… {} more (narrow the pattern). All {total} by directory:",
            total - 200
        );
        out.push_str(&counts_str);
    }
    let files = format!("Found {total} file{}", if total == 1 { "" } else { "s" });
    let display = if dirs.len() > 1 {
        format!(
            "{files} in {} directories:\n{}",
            dirs.len(),
            counts_str.trim_end()
        )
    } else {
        files
    };
    Ok(Output {
        content: out,
        display: Some(display),
        diff: None,
        diagram: None,
        present: None,
        widget: None,
        ..Default::default()
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
    let cwd = ctx.root.clone();

    let (out, n, file_totals) = tokio::task::spawn_blocking(move || {
        let files: Box<dyn Iterator<Item = PathBuf>> = if root.is_file() {
            Box::new(std::iter::once(root.clone()))
        } else {
            Box::new(walk(&root))
        };
        let mut out = Vec::new();
        let mut file_totals: std::collections::HashMap<String, usize> =
            std::collections::HashMap::new();
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
                    let mut file_matches = 0;
                    for (i, line) in text.lines().enumerate().filter(|(_, l)| re.is_match(l)) {
                        let line: String = line.chars().take(300).collect();
                        out.push(format!("{rel}:{}:{line}", i + 1));
                        file_matches += 1;
                        if out.len() >= limit {
                            break;
                        }
                    }
                    if file_matches > 0 {
                        file_totals.insert(rel.clone(), file_matches);
                    }
                }
                "count" => {
                    let c = text.lines().filter(|l| re.is_match(l)).count();
                    if c > 0 {
                        out.push(format!("{rel}:{c}"));
                        file_totals.insert(rel.clone(), c);
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
        (out.join("\n"), n, file_totals)
    })
    .await?;

    if n == 0 {
        return Ok(Output::text("No matches"));
    }
    // Build display with file totals
    let mut display = format!("Found {n} result{}", if n == 1 { "" } else { "s" });
    if !file_totals.is_empty() {
        display.push_str(" in ");
        let mut files: Vec<_> = file_totals.into_iter().collect();
        files.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        let mut parts: Vec<String> = files
            .iter()
            .take(5)
            .map(|(f, c)| format!("{f}: {c}"))
            .collect();
        if files.len() > 5 {
            parts.push(format!("… and {} more files", files.len() - 5));
        }
        display.push_str(&parts.join(", "));
    }
    let more = if n >= limit {
        format!("\n… (limited to {limit} results)")
    } else {
        String::new()
    };
    Ok(Output {
        content: out + &more,
        display: Some(display),
        diff: None,
        diagram: None,
        present: None,
        widget: None,
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;
    use tempfile::TempDir;

    fn setup_ctx(tmp: &TempDir) -> Ctx {
        Ctx::new(tmp.path().to_path_buf())
    }

    #[test]
    fn glob_shows_directory_counts() {
        let tmp = TempDir::new().unwrap();
        let mut ctx = setup_ctx(&tmp);

        // Create directories and files
        fs::create_dir(tmp.path().join("src")).unwrap();
        fs::create_dir(tmp.path().join("tests")).unwrap();
        fs::create_dir(tmp.path().join("docs")).unwrap();

        fs::write(tmp.path().join("src/a.rs"), "fn main() {}").unwrap();
        fs::write(tmp.path().join("src/b.rs"), "fn foo() {}").unwrap();
        fs::write(tmp.path().join("tests/t1.rs"), "#[test] fn t() {}").unwrap();
        fs::write(tmp.path().join("tests/t2.rs"), "").unwrap();
        fs::write(tmp.path().join("tests/t3.rs"), "").unwrap();
        fs::write(tmp.path().join("docs/readme.md"), "# Docs").unwrap();

        let input = json!({
            "pattern": "**/*.rs",
            "path": tmp.path().to_str()
        });
        let output = block_on(glob(&input, &mut ctx)).unwrap();

        assert!(output.content.contains("src"));
        assert!(output.content.contains("tests"));
        let display = output.display.clone().unwrap();
        assert!(display.contains("src/: 2"), "{display}");
        assert!(display.contains("tests/: 3"), "{display}");
        assert!(
            display.contains("Found 5 files in 2 directories"),
            "{display}"
        );
        // An uncut list needs no breakdown in the model's text.
        assert!(
            !output.content.contains("by directory"),
            "{}",
            output.content
        );
    }

    #[test]
    fn glob_caps_at_200_with_hint() {
        let tmp = TempDir::new().unwrap();
        let mut ctx = setup_ctx(&tmp);

        // Create 205 files
        for i in 0..205 {
            fs::write(tmp.path().join(format!("file{}.txt", i)), "content").unwrap();
        }

        let input = json!({
            "pattern": "*.txt",
            "path": tmp.path().to_str()
        });
        let output = block_on(glob(&input, &mut ctx)).unwrap();

        let lines: Vec<&str> = output.content.lines().collect();
        assert_eq!(lines.len(), 202, "{}", output.content); // 200 files, the hint, one count
        assert!(output.content.contains("… 5 more (narrow the pattern)"));
        // The breakdown counts every match, not just the 200 shown.
        assert!(
            output.content.ends_with("  ./: 205\n"),
            "{}",
            output.content
        );
    }

    #[test]
    fn grep_limits_results_with_file_totals() {
        let tmp = TempDir::new().unwrap();
        let mut ctx = setup_ctx(&tmp);

        fs::write(tmp.path().join("a.txt"), "hello\nworld\nhello\nhello").unwrap();
        fs::write(tmp.path().join("b.txt"), "hello\nfoo\nbar").unwrap();
        fs::write(tmp.path().join("c.txt"), "hello\nhello\nhello\nhello").unwrap();

        let input = json!({
            "pattern": "hello",
            "path": tmp.path().to_str(),
            "output_mode": "content",
            "head_limit": 5
        });
        let output = block_on(grep(&input, &mut ctx)).unwrap();

        // walk order isn't alphabetical, so only the cap itself is asserted here
        let lines: Vec<&str> = output.content.lines().collect();
        assert_eq!(lines.len(), 6, "content: {}", output.content); // 5 + the note
        assert!(output.content.contains("… (limited to 5 results)"));
        assert!(output.content.contains(":1:hello"));
        let display = output.display.clone().unwrap();
        assert!(display.contains("Found 5 results"), "{display}");

        // without a limit, every match is counted per file
        let input = json!({
            "pattern": "hello",
            "path": tmp.path().to_str(),
            "output_mode": "content"
        });
        let output = block_on(grep(&input, &mut ctx)).unwrap();
        let display = output.display.clone().unwrap();
        assert!(display.contains("a.txt: 3"), "{display}");
        assert!(display.contains("b.txt: 1"), "{display}");
        assert!(display.contains("c.txt: 4"), "{display}");
        assert!(display.contains("Found 8 results"), "{display}");
    }

    #[test]
    fn grep_shows_file_totals_in_display() {
        let tmp = TempDir::new().unwrap();
        let mut ctx = setup_ctx(&tmp);

        fs::write(tmp.path().join("x.txt"), "test\ntest\ntest").unwrap();
        fs::write(tmp.path().join("y.txt"), "test").unwrap();

        let input = json!({
            "pattern": "test",
            "path": tmp.path().to_str(),
            "output_mode": "count"
        });
        let output = block_on(grep(&input, &mut ctx)).unwrap();

        let display = output.display.unwrap();
        assert!(display.contains("x.txt: 3"), "{display}");
        assert!(display.contains("y.txt: 1"), "{display}");
    }

    // Helper to run async functions in tests
    fn block_on<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Runtime::new().unwrap().block_on(f)
    }
}
