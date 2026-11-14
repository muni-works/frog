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
By default returns each matching line with its line number and 2 lines of context, grouped by file \
(`N:` a match, `N-` context), usually enough to answer without a Read. `context` sets the lines around \
each match (0 for bare lines); output_mode `files_with_matches` lists only paths, `count` counts per file. \
Stops after `head_limit` matches (default 100) or about 20k characters, then lists the remaining files.".into(),
        schema: json!({
            "type": "object",
            "properties": {
                "pattern": { "type": "string", "description": "Regular expression" },
                "path": { "type": "string", "description": "File or directory to search (default: working directory)" },
                "glob": { "type": "string", "description": "Only search files matching this glob, e.g. `*.ts`" },
                "output_mode": { "type": "string", "enum": ["content", "files_with_matches", "count"] },
                "context": { "type": "integer", "description": "Lines of context around each match (default 2)" },
                "case_insensitive": { "type": "boolean" },
                "head_limit": { "type": "integer", "description": "Max matches (default 100)" }
            },
            "required": ["pattern"]
        }),
    }
}

/// About how much matched text Grep returns before it lists the rest by file.
const GREP_BUDGET: usize = 20_000;

/// Line numbers (0-based) to show for `hits` in a file of `n` lines with `before`/`after`
/// lines of context, overlapping windows merged: runs of `(line, is_match)`.
fn windows(hits: &[usize], n: usize, before: usize, after: usize) -> Vec<Vec<(usize, bool)>> {
    let mut runs: Vec<Vec<(usize, bool)>> = Vec::new();
    let is_hit: std::collections::HashSet<usize> = hits.iter().copied().collect();
    for &h in hits {
        let (lo, hi) = (
            h.saturating_sub(before),
            (h + after).min(n.saturating_sub(1)),
        );
        match runs.last_mut() {
            Some(run) if run.last().is_some_and(|l| l.0 + 1 >= lo) => {
                let from = run.last().unwrap().0 + 1;
                run.extend((from..=hi).map(|i| (i, is_hit.contains(&i))));
            }
            _ => runs.push((lo..=hi).map(|i| (i, is_hit.contains(&i))).collect()),
        }
    }
    runs
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
        .unwrap_or("content")
        .to_string();
    let limit = int_arg(input, "head_limit").unwrap_or(100).max(1) as usize;
    // `-C`/`-A`/`-B` are what models used to grep reach for; take them as `context`.
    let around = int_arg(input, "context")
        .or_else(|| int_arg(input, "-C"))
        .unwrap_or(2)
        .clamp(0, 20) as usize;
    let before = int_arg(input, "-B").map_or(around, |n| n.clamp(0, 20) as usize);
    let after = int_arg(input, "-A").map_or(around, |n| n.clamp(0, 20) as usize);
    let cwd = ctx.root.clone();

    let (out, n, file_totals, rest) = tokio::task::spawn_blocking(move || {
        let files: Box<dyn Iterator<Item = PathBuf>> = if root.is_file() {
            Box::new(std::iter::once(root.clone()))
        } else {
            Box::new(walk(&root))
        };
        let mut out = Vec::new();
        let mut chars = 0usize;
        let mut n = 0usize;
        let mut file_totals: std::collections::HashMap<String, usize> =
            std::collections::HashMap::new();
        // Files that matched after the budget ran out: named with their counts, not shown.
        let mut rest: Vec<(String, usize)> = Vec::new();
        for path in files {
            if mode != "content" && n >= limit {
                break;
            }
            if rest.len() >= 200 {
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
                    let lines: Vec<&str> = text.lines().collect();
                    let hits: Vec<usize> = (0..lines.len())
                        .filter(|&i| re.is_match(lines[i]))
                        .collect();
                    if hits.is_empty() {
                        continue;
                    }
                    if n >= limit || chars >= GREP_BUDGET {
                        rest.push((rel, hits.len()));
                        continue;
                    }
                    let hits = &hits[..hits.len().min(limit - n)];
                    let mut block = String::new();
                    let mut first = true;
                    for run in windows(hits, lines.len(), before, after) {
                        if !first {
                            block.push_str("--\n");
                        }
                        first = false;
                        for (i, hit) in run {
                            let line: String = lines[i].chars().take(300).collect();
                            let _ =
                                writeln!(block, "{}{}{line}", i + 1, if hit { ':' } else { '-' });
                        }
                    }
                    n += hits.len();
                    file_totals.insert(rel.clone(), hits.len());
                    chars += block.len() + rel.len();
                    out.push(format!("{rel}\n{}", block.trim_end()));
                }
                "count" => {
                    let c = text.lines().filter(|l| re.is_match(l)).count();
                    if c > 0 {
                        out.push(format!("{rel}:{c}"));
                        file_totals.insert(rel.clone(), c);
                        n += 1;
                    }
                }
                _ => {
                    if re.is_match(&text) {
                        out.push(rel);
                        n += 1;
                    }
                }
            }
        }
        let sep = if mode == "content" { "\n\n" } else { "\n" };
        (out.join(sep), n, file_totals, rest)
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
    let mut more = String::new();
    if !rest.is_empty() {
        let total: usize = rest.iter().map(|r| r.1).sum();
        let _ = write!(
            more,
            "\n\n… {total} more matches in {} more files (narrow `path`/`glob`, or Read the ones you need):",
            rest.len()
        );
        for (f, c) in rest.iter().take(50) {
            let _ = write!(more, "\n{f}: {c}");
        }
        if rest.len() > 50 {
            let _ = write!(more, "\n… and {} more files", rest.len() - 50);
        }
    } else if n >= limit {
        more = format!("\n… (limited to {limit} results)");
    }
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
        let shown = output
            .content
            .lines()
            .filter(|l| l.ends_with(":hello"))
            .count();
        assert_eq!(shown, 5, "content: {}", output.content);
        assert!(
            output.content.contains("more matches in"),
            "{}",
            output.content
        );
        assert!(output.content.contains("1:hello"));
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

    #[test]
    fn grep_shows_matches_with_context_by_default() {
        let tmp = TempDir::new().unwrap();
        let mut ctx = setup_ctx(&tmp);
        let body: String = (1..=20).map(|i| format!("line {i}\n")).collect();
        fs::write(
            tmp.path().join("a.rs"),
            body.replace("line 10\n", "fn target() {}\n"),
        )
        .unwrap();
        let output = block_on(grep(&json!({ "pattern": "target" }), &mut ctx)).unwrap();
        // The file, then the match with two lines either side, numbered: no Read needed.
        assert_eq!(
            output.content, "a.rs\n8-line 8\n9-line 9\n10:fn target() {}\n11-line 11\n12-line 12",
            "{}",
            output.content
        );
        // Matches close together share one window; far apart ones are split by `--`.
        let body: String = (1..=40).map(|i| format!("x{i}\n")).collect();
        fs::write(tmp.path().join("a.rs"), body).unwrap();
        let output = block_on(grep(
            &json!({ "pattern": "^x(3|5|30)$", "context": 1 }),
            &mut ctx,
        ))
        .unwrap();
        assert_eq!(
            output.content, "a.rs\n2-x2\n3:x3\n4-x4\n5:x5\n6-x6\n--\n29-x29\n30:x30\n31-x31",
            "{}",
            output.content
        );
        // files_with_matches still lists just paths.
        let output = block_on(grep(
            &json!({ "pattern": "x3", "output_mode": "files_with_matches" }),
            &mut ctx,
        ))
        .unwrap();
        assert_eq!(output.content, "a.rs");
    }

    #[test]
    fn grep_past_its_budget_names_the_remaining_files() {
        let tmp = TempDir::new().unwrap();
        let mut ctx = setup_ctx(&tmp);
        let long = "needle ".to_string() + &"y".repeat(250) + "\n";
        for i in 0..40 {
            fs::write(tmp.path().join(format!("f{i}.txt")), long.repeat(3)).unwrap();
        }
        let output = block_on(grep(
            &json!({ "pattern": "needle", "head_limit": 1000 }),
            &mut ctx,
        ))
        .unwrap();
        assert!(
            output.content.len() < GREP_BUDGET + 8_000,
            "{}",
            output.content.len()
        );
        assert!(
            output.content.contains("more matches in"),
            "{}",
            output.content
        );
        // Every file is accounted for: shown, or named with its count.
        for i in 0..40 {
            assert!(
                output.content.contains(&format!("f{i}.txt")),
                "f{i}.txt missing"
            );
        }
    }

    // Helper to run async functions in tests
    fn block_on<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Runtime::new().unwrap().block_on(f)
    }
}
