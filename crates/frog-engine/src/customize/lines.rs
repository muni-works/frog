//! A rules or instruction file as lines, for Customize's Rules page: list them, edit one,
//! remove one, add one. A line is named by its number *and* its text, so a file changed in an
//! editor since the page read it fails the change instead of losing the wrong line.

use anyhow::{Result, bail};
use serde::Serialize;
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Line {
    /// 1-based, as in an editor.
    pub n: usize,
    pub text: String,
}

/// Where the body starts: the line after the frontmatter's closing `---`, or 0.
fn body_start(lines: &[&str]) -> usize {
    if lines.first().map(|l| l.trim_end()) != Some("---") {
        return 0;
    }
    lines
        .iter()
        .enumerate()
        .skip(1)
        .find(|(_, l)| l.trim_end() == "---")
        .map_or(0, |(i, _)| i + 1)
}

/// The file's non-blank lines, frontmatter left out.
pub fn read(text: &str) -> Vec<Line> {
    let lines: Vec<&str> = text.lines().collect();
    let start = body_start(&lines);
    lines
        .iter()
        .enumerate()
        .skip(start)
        .filter(|(_, l)| !l.trim().is_empty())
        .map(|(i, l)| Line {
            n: i + 1,
            text: l.trim_end_matches('\r').to_string(),
        })
        .collect()
}

fn check(lines: &[&str], n: usize, old: &str) -> Result<usize> {
    let i = n.checked_sub(1).filter(|i| *i < lines.len());
    match i {
        Some(i) if lines[i].trim_end_matches('\r') == old => Ok(i),
        _ => bail!("line {n} isn't \"{old}\" any more; the file changed, so reload it"),
    }
}

fn one_line(text: &str) -> Result<&str> {
    let t = text.trim();
    if t.is_empty() {
        bail!("a line can't be empty; remove it instead");
    }
    if t.contains('\n') {
        bail!("one line at a time");
    }
    Ok(t)
}

fn write(path: &Path, lines: &[String], trailing_newline: bool) -> Result<()> {
    let mut text = lines.join("\n");
    if trailing_newline && !text.is_empty() {
        text.push('\n');
    }
    let tmp = path.with_extension("customize.tmp");
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

fn load(path: &Path) -> Result<(Vec<String>, bool)> {
    let text = std::fs::read_to_string(path)?;
    let trailing = text.ends_with('\n') || text.is_empty();
    Ok((text.lines().map(String::from).collect(), trailing))
}

pub fn edit(path: &Path, n: usize, old: &str, new: &str) -> Result<()> {
    let new = one_line(new)?;
    let (mut lines, trailing) = load(path)?;
    let i = check(
        &lines.iter().map(String::as_str).collect::<Vec<_>>(),
        n,
        old,
    )?;
    lines[i] = new.to_string();
    write(path, &lines, trailing)
}

pub fn remove(path: &Path, n: usize, old: &str) -> Result<()> {
    let (mut lines, trailing) = load(path)?;
    let i = check(
        &lines.iter().map(String::as_str).collect::<Vec<_>>(),
        n,
        old,
    )?;
    lines.remove(i);
    write(path, &lines, trailing)
}

/// Add a line at the end, creating the file (and its folder) if there isn't one.
pub fn add(path: &Path, text: &str) -> Result<()> {
    let text = one_line(text)?;
    if !path.exists() {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        return write(path, &[text.to_string()], true);
    }
    let (mut lines, _) = load(path)?;
    lines.push(text.to_string());
    write(path, &lines, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_skip_frontmatter_and_blanks_and_edits_check_the_text() {
        let dir = std::env::temp_dir().join(format!("frog-lines-{}", crate::session::new_id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("rule.md");
        std::fs::write(
            &f,
            "---\npaths: src/**\n---\n# Style\n\nUse tabs.\nNo emoji.\n",
        )
        .unwrap();
        let lines = read(&std::fs::read_to_string(&f).unwrap());
        assert_eq!(
            lines,
            [
                Line {
                    n: 4,
                    text: "# Style".into()
                },
                Line {
                    n: 6,
                    text: "Use tabs.".into()
                },
                Line {
                    n: 7,
                    text: "No emoji.".into()
                },
            ]
        );
        assert!(
            edit(&f, 6, "Use spaces.", "x").is_err(),
            "stale text is refused"
        );
        edit(&f, 6, "Use tabs.", "Use spaces.").unwrap();
        remove(&f, 7, "No emoji.").unwrap();
        add(&f, "Short lines.").unwrap();
        assert_eq!(
            std::fs::read_to_string(&f).unwrap(),
            "---\npaths: src/**\n---\n# Style\n\nUse spaces.\nShort lines.\n"
        );
        assert!(add(&f, "two\nlines").is_err());
        let fresh = dir.join("new/FROG.md");
        add(&fresh, "Be brief.").unwrap();
        assert_eq!(std::fs::read_to_string(&fresh).unwrap(), "Be brief.\n");
        let _ = std::fs::remove_dir_all(dir);
    }
}
