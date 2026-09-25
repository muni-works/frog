//! Rule files: short instructions in `.frog/rules/*.md` (and `.claude/rules`, `.agents/rules`,
//! so a repo's existing rules work unchanged). A rule with `paths:` globs in its frontmatter
//! applies only to files that match; it's shown to the model the first time it reads, edits
//! or is pointed at such a file, right before that tool result, and once per session. A rule
//! without `paths` applies always and goes in the system prompt like an instruction file.
//! Both are budgeted by tier, and nothing here calls a model.

use crate::harness::Tier;
use globset::{Glob, GlobSet, GlobSetBuilder};
use std::path::{Path, PathBuf};

const DIRS: [&str; 3] = [".frog/rules", ".claude/rules", ".agents/rules"];

#[derive(Debug)]
pub struct Rule {
    pub path: PathBuf,
    /// The file name, for headings and dedupe.
    pub name: String,
    /// `None` for a rule that always applies.
    pub globs: Option<GlobSet>,
    pub patterns: Vec<String>,
    pub body: String,
}

impl Rule {
    pub fn scoped(&self) -> bool {
        self.globs.is_some()
    }

    /// Whether `rel` (a path relative to the project root) is covered.
    pub fn matches(&self, rel: &str) -> bool {
        self.globs.as_ref().is_some_and(|g| g.is_match(rel))
    }
}

/// Every rule file under `root`, in a stable order.
pub fn discover(root: &Path) -> Vec<Rule> {
    let mut out = Vec::new();
    for d in DIRS {
        let dir = root.join(d);
        let mut files = Vec::new();
        walk(&dir, 0, &mut files);
        files.sort();
        for path in files {
            if let Some(r) = read(&path) {
                out.push(r);
            }
        }
    }
    out
}

fn walk(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            if depth < 3 {
                walk(&p, depth + 1, out);
            }
        } else if p.extension().is_some_and(|x| x == "md") {
            out.push(p);
        }
    }
}

fn read(path: &Path) -> Option<Rule> {
    let text = std::fs::read_to_string(path).ok()?;
    let (patterns, body) = parse(&text);
    let body = body.trim().to_string();
    if body.is_empty() {
        return None;
    }
    let globs = if patterns.is_empty() {
        None
    } else {
        let mut b = GlobSetBuilder::new();
        for p in &patterns {
            // A bare directory covers everything under it.
            let p = if p.ends_with('/') {
                format!("{p}**")
            } else {
                p.clone()
            };
            if let Ok(g) = Glob::new(p.trim_start_matches("./")) {
                b.add(g);
            }
        }
        Some(b.build().ok()?)
    };
    Some(Rule {
        name: path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default(),
        path: path.to_path_buf(),
        globs,
        patterns,
        body,
    })
}

/// The `paths:` (or Cursor's `globs:`) list from the frontmatter, and the body. Accepts an
/// inline list, a comma-separated string, or a block list of `- item` lines.
fn parse(text: &str) -> (Vec<String>, &str) {
    let Some(rest) = text.strip_prefix("---") else {
        return (Vec::new(), text);
    };
    let rest = rest.trim_start_matches('\r');
    let Some(rest) = rest.strip_prefix('\n') else {
        return (Vec::new(), text);
    };
    let Some(end) = rest.find("\n---") else {
        return (Vec::new(), text);
    };
    let (yaml, after) = (&rest[..end], &rest[end + 4..]);
    let body = after.split_once('\n').map(|(_, b)| b).unwrap_or("");
    let mut patterns = Vec::new();
    let mut lines = yaml.lines().peekable();
    while let Some(line) = lines.next() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        if line.starts_with([' ', '\t']) || !matches!(key.trim(), "paths" | "globs") {
            continue;
        }
        let value = value.trim();
        if value.is_empty() {
            while let Some(next) = lines.peek() {
                let t = next.trim();
                if let Some(item) = t.strip_prefix("- ") {
                    patterns.push(unquote(item));
                    lines.next();
                } else if t.is_empty() {
                    lines.next();
                } else {
                    break;
                }
            }
        } else {
            let inner = value.trim_start_matches('[').trim_end_matches(']');
            patterns.extend(inner.split(',').map(unquote).filter(|s| !s.is_empty()));
        }
    }
    (patterns, body)
}

fn unquote(s: &str) -> String {
    s.trim().trim_matches(|c| c == '"' || c == '\'').to_string()
}

/// Characters of always-on rules for the system prompt, by tier.
pub fn prompt_budget(tier: Tier) -> usize {
    match tier {
        Tier::Weak => 2_000,
        Tier::Medium => 6_000,
        Tier::Strong => 16_000,
    }
}

/// Characters of scoped rules shown alongside one tool result, by tier.
pub fn inject_budget(tier: Tier) -> usize {
    match tier {
        Tier::Weak => 1_500,
        Tier::Medium => 4_000,
        Tier::Strong => 8_000,
    }
}

/// The always-on rules for the system prompt, like instruction files, within `budget`.
pub fn prompt_section(rules: &[Rule], budget: usize) -> String {
    let mut s = String::new();
    let mut omitted = 0;
    for r in rules.iter().filter(|r| !r.scoped()) {
        let head = format!("\n# Rules from {}\n", r.path.display());
        let room = budget.saturating_sub(s.len() + head.len());
        if room < 80 {
            omitted += 1;
            continue;
        }
        s.push_str(&head);
        s.push_str(&fit(&r.body, room));
        s.push('\n');
    }
    if omitted > 0 {
        s.push_str(&format!(
            "\n({omitted} rule file{} omitted for this model's budget)\n",
            if omitted == 1 { "" } else { "s" }
        ));
    }
    s
}

/// The scoped rules `rel` matches, skipping any in `seen` (and adding the rest to it).
pub fn due<'a>(
    rules: &'a [Rule],
    rel: &str,
    seen: &mut std::collections::HashSet<PathBuf>,
) -> Vec<&'a Rule> {
    rules
        .iter()
        .filter(|r| r.matches(rel))
        .filter(|r| seen.insert(r.path.clone()))
        .collect()
}

/// The block shown before a tool result: `<rules for path>…</rules>`, within `budget`.
pub fn block(rules: &[&Rule], rel: &str, budget: usize) -> String {
    if rules.is_empty() {
        return String::new();
    }
    let mut s = format!("<rules for {rel}>\n");
    let per = (budget / rules.len()).max(200);
    for r in rules {
        let head = format!("## {} ({})\n", r.name, r.patterns.join(", "));
        s.push_str(&head);
        s.push_str(&fit(&r.body, per.saturating_sub(head.len())));
        s.push('\n');
    }
    s.push_str("</rules>\n");
    s
}

/// Cut on a line boundary, with a note.
fn fit(body: &str, room: usize) -> String {
    if body.len() <= room {
        return body.to_string();
    }
    let mut out = String::new();
    for line in body.lines() {
        if out.len() + line.len() + 1 > room.saturating_sub(40) {
            break;
        }
        out.push_str(line);
        out.push('\n');
    }
    out.push_str("(… truncated for this model's budget)");
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn project() -> PathBuf {
        let root = std::env::temp_dir().join(format!("frog-rules-{}", crate::session::new_id()));
        std::fs::create_dir_all(root.join(".frog/rules")).unwrap();
        std::fs::create_dir_all(root.join(".claude/rules/nested")).unwrap();
        std::fs::write(
            root.join(".frog/rules/api.md"),
            "---\npaths: [\"src/api/**\", \"*.swift\"]\n---\nAPI handlers return Result.\n",
        )
        .unwrap();
        std::fs::write(
            root.join(".claude/rules/nested/tests.md"),
            "---\npaths:\n  - \"tests/**\"\n  - 'crates/*/src/**'\ndescription: x\n---\nTests use the fixture dir.\n",
        )
        .unwrap();
        std::fs::write(
            root.join(".frog/rules/always.md"),
            "Commit messages are imperative.\n",
        )
        .unwrap();
        std::fs::write(
            root.join(".frog/rules/empty.md"),
            "---\npaths: [\"a\"]\n---\n\n",
        )
        .unwrap();
        root
    }

    #[test]
    fn rules_are_found_and_match_globs() {
        let root = project();
        let rules = discover(&root);
        let names: Vec<&str> = rules.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, ["always", "api", "tests"]);
        let api = &rules[1];
        assert_eq!(api.patterns, ["src/api/**", "*.swift"]);
        assert!(api.matches("src/api/users.rs"));
        assert!(api.matches("apps/macos/View.swift"));
        assert!(!api.matches("src/lib.rs"));
        let tests = &rules[2];
        assert_eq!(tests.patterns, ["tests/**", "crates/*/src/**"]);
        assert!(tests.matches("crates/frog/src/main.rs"));
        assert!(!tests.matches("src/api/users.rs"));
        assert!(!rules[0].scoped());
        assert!(!rules[0].matches("anything"));

        let section = prompt_section(&rules, 6_000);
        assert!(section.contains("# Rules from"));
        assert!(section.contains("always.md\nCommit messages are imperative."));
        assert!(!section.contains("API handlers"));
        assert!(prompt_section(&rules, 50).contains("1 rule file omitted"));
    }

    #[test]
    fn scoped_rules_show_once_per_session_within_budget() {
        let root = project();
        let rules = discover(&root);
        let mut seen = HashSet::new();
        let hit = due(&rules, "src/api/users.rs", &mut seen);
        assert_eq!(hit.len(), 1);
        let text = block(&hit, "src/api/users.rs", 1_500);
        assert_eq!(
            text,
            "<rules for src/api/users.rs>\n## api (src/api/**, *.swift)\nAPI handlers return Result.\n</rules>\n"
        );
        // The same rule isn't repeated for another matching file.
        assert!(due(&rules, "src/api/orders.rs", &mut seen).is_empty());
        assert!(due(&rules, "Foo.swift", &mut seen).is_empty());
        assert_eq!(due(&rules, "tests/a.rs", &mut seen).len(), 1);
        assert!(due(&rules, "README.md", &mut seen).is_empty());

        let long = Rule {
            path: PathBuf::from("/r/long.md"),
            name: "long".into(),
            globs: None,
            patterns: vec!["**".into()],
            body: (0..100).map(|i| format!("line {i}\n")).collect(),
        };
        let text = block(&[&long], "x", 300);
        assert!(text.len() < 400, "{}", text.len());
        assert!(text.contains("truncated"));
    }

    #[test]
    fn frontmatter_forms() {
        assert_eq!(parse("no frontmatter").0, Vec::<String>::new());
        assert_eq!(
            parse("---\nglobs: src/*.ts, lib/**\n---\nb").0,
            ["src/*.ts", "lib/**"]
        );
        assert_eq!(parse("---\nname: x\n---\nbody").1, "body");
        assert_eq!(parse("---\npaths:\n  - a/\n---\n").0, ["a/"]);
    }
}
