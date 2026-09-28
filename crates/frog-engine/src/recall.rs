//! `Recall`: a read-only search over the user's memory notes and this project's session
//! summaries, by keyword and by file touched. Also behind `/recall <query>`, which answers as
//! a notice so the user can push results at a model too small to ask for them.
//!
//! Ranking is deterministic: every query word must appear (case-insensitive) somewhere in a
//! hit's title, body or files; hits score by where the words land (title and files count
//! more than the body), then by recency. Output is a handful of compact hits within a
//! per-tier budget, with the lines that matched, so the model can act on it inline.

use crate::harness::Tier;
use crate::memory::Note;
use crate::provider::ToolSpec;
use crate::summary::Stored;
use crate::tools::Output;
use anyhow::{Result, bail};
use serde_json::Value;

pub const TOOL: &str = "Recall";
/// Hits returned unless the caller asks for fewer.
const DEFAULT_LIMIT: usize = 5;
const MAX_LIMIT: usize = 20;
/// Matching lines shown per hit.
const LINES_PER_HIT: usize = 3;

/// Characters of output: about 1.5k for small models, 4k for large ones.
pub fn budget(tier: Tier) -> usize {
    match tier {
        Tier::Weak => 1_500,
        Tier::Medium => 3_000,
        Tier::Strong => 4_000,
    }
}

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Search your notes and past sessions in this project (read-only). Use it before asking the user how something was done before, or when a file's history matters. `query` matches keywords (all words must appear); `file` finds sessions that edited a path.".into(),
        schema: serde_json::json!({
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Keywords to search for"},
                "file": {"type": "string", "description": "A file path (or part of one) to find sessions that touched it"},
                "limit": {"type": "integer", "description": "Most hits to return (default 5)"}
            }
        }),
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    /// `note` or `session`.
    pub source: &'static str,
    pub id: String,
    /// The date part of the timestamp.
    pub date: String,
    pub first_line: String,
    pub files: Vec<String>,
    pub matching: Vec<String>,
    pub score: u32,
}

/// What `Recall` searches.
pub struct Sources<'a> {
    pub notes: &'a [Note],
    pub sessions: &'a [Stored],
}

/// Run the tool: `query` and/or `file`, at least one.
pub fn run(sources: &Sources, input: &Value, tier: Tier) -> Result<Output> {
    let query = input["query"].as_str().unwrap_or("").trim();
    let file = input["file"].as_str().unwrap_or("").trim();
    if query.is_empty() && file.is_empty() {
        bail!("give a `query` (keywords) or a `file` (a path to find sessions that touched it)");
    }
    let limit = crate::tools::int_arg(input, "limit")
        .map(|n| (n as usize).clamp(1, MAX_LIMIT))
        .unwrap_or(DEFAULT_LIMIT);
    let hits = search(sources, query, file, limit);
    Ok(Output::text(render(&hits, query, file, budget(tier))))
}

/// `/recall <query>`: the same search, worded for the user.
pub fn command(sources: &Sources, args: &str, tier: Tier) -> String {
    let args = args.trim();
    if args.is_empty() {
        return "usage: /recall <keywords>; /recall file:<path> finds sessions that edited it"
            .into();
    }
    let (query, file) = match args.strip_prefix("file:") {
        Some(f) => ("", f.trim()),
        None => (args, ""),
    };
    let hits = search(sources, query, file, DEFAULT_LIMIT);
    render(&hits, query, file, budget(tier).max(3_000))
}

/// Ranked hits: every query word must appear; `file` must match a file touched (or cited).
pub fn search(sources: &Sources, query: &str, file: &str, limit: usize) -> Vec<Hit> {
    let words: Vec<String> = query
        .split_whitespace()
        .map(|w| {
            w.trim_matches(|c: char| !c.is_alphanumeric())
                .to_lowercase()
        })
        .filter(|w| !w.is_empty())
        .collect();
    let file = file.trim_start_matches("./").to_lowercase();
    let mut hits: Vec<Hit> = Vec::new();
    for n in sources.notes {
        let files: Vec<String> = n
            .cites
            .iter()
            .map(|c| c.split('#').next().unwrap_or(c).to_string())
            .collect();
        if let Some(h) = score(
            "note",
            &n.id,
            &n.created,
            n.first_line(),
            &n.body,
            &files,
            &words,
            &file,
        ) {
            hits.push(h);
        }
    }
    for s in sources.sessions {
        if let Some(h) = score(
            "session", &s.id, &s.updated, &s.title, &s.body, &s.files, &words, &file,
        ) {
            hits.push(h);
        }
    }
    hits.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| b.date.cmp(&a.date)));
    hits.truncate(limit);
    hits
}

#[allow(clippy::too_many_arguments)]
fn score(
    source: &'static str,
    id: &str,
    stamp: &str,
    title: &str,
    body: &str,
    files: &[String],
    words: &[String],
    file: &str,
) -> Option<Hit> {
    let title_l = title.to_lowercase();
    let body_l = body.to_lowercase();
    let files_l: Vec<String> = files.iter().map(|f| f.to_lowercase()).collect();
    let mut score = 0u32;
    if !file.is_empty() {
        let n = files_l.iter().filter(|f| f.contains(file)).count();
        if n == 0 {
            return None;
        }
        score += 4 + n.min(3) as u32;
    }
    for w in words {
        let mut found = false;
        if title_l.contains(w.as_str()) {
            score += 3;
            found = true;
        }
        if files_l.iter().any(|f| f.contains(w.as_str())) {
            score += 2;
            found = true;
        }
        if body_l.contains(w.as_str()) {
            score += 1;
            found = true;
        }
        if !found {
            return None;
        }
    }
    let matching: Vec<String> = if words.is_empty() {
        Vec::new()
    } else {
        body.lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .filter(|l| {
                let ll = l.to_lowercase();
                words.iter().any(|w| ll.contains(w.as_str()))
            })
            .take(LINES_PER_HIT)
            .map(|l| clip(l, 160))
            .collect()
    };
    Some(Hit {
        source,
        id: id.to_string(),
        date: stamp.get(..10).unwrap_or(stamp).to_string(),
        first_line: clip(title, 120),
        files: files.to_vec(),
        matching,
        score,
    })
}

/// Compact text: one hit per block, within `budget` characters.
pub fn render(hits: &[Hit], query: &str, file: &str, budget: usize) -> String {
    let what = match (query.is_empty(), file.is_empty()) {
        (false, false) => format!("\"{query}\" touching {file}"),
        (false, true) => format!("\"{query}\""),
        (true, false) => format!("sessions touching {file}"),
        (true, true) => String::new(),
    };
    if hits.is_empty() {
        return format!("No notes or past sessions match {what}.");
    }
    let mut s = format!(
        "{} hit{} for {what}:\n",
        hits.len(),
        if hits.len() == 1 { "" } else { "s" }
    );
    let mut shown = 0;
    for h in hits {
        let mut block = format!("- [{} {} {}] {}\n", h.source, h.date, h.id, h.first_line);
        if !h.files.is_empty() {
            block.push_str(&format!("  files: {}\n", clip(&h.files.join(", "), 200)));
        }
        for l in &h.matching {
            if *l != h.first_line {
                block.push_str(&format!("  > {l}\n"));
            }
        }
        if s.len() + block.len() > budget {
            // Always show at least the first hit's header line.
            if shown == 0 {
                s.push_str(block.lines().next().unwrap_or(""));
                s.push('\n');
                shown += 1;
            }
            break;
        }
        s.push_str(&block);
        shown += 1;
    }
    if shown < hits.len() {
        s.push_str(&format!("({} more not shown)\n", hits.len() - shown));
    }
    s.trim_end().to_string()
}

fn clip(s: &str, n: usize) -> String {
    let one = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if one.chars().count() <= n {
        return one;
    }
    format!(
        "{}…",
        one.chars().take(n.saturating_sub(1)).collect::<String>()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory::Scope;
    use std::path::PathBuf;

    fn note(id: &str, body: &str, cites: &[&str]) -> Note {
        Note {
            id: id.into(),
            created: "2026-09-01T10:00:00+00:00".into(),
            scope: Scope::Project,
            source: "user".into(),
            cites: cites.iter().map(|c| c.to_string()).collect(),
            body: body.into(),
            path: PathBuf::from("/nowhere"),
            missing: Vec::new(),
        }
    }

    fn session(id: &str, updated: &str, title: &str, files: &[&str], body: &str) -> Stored {
        Stored {
            id: id.into(),
            updated: updated.into(),
            title: title.into(),
            files: files.iter().map(|f| f.to_string()).collect(),
            body: body.into(),
            path: PathBuf::from("/nowhere"),
        }
    }

    fn sources() -> (Vec<Note>, Vec<Stored>) {
        (
            vec![
                note(
                    "use-npm",
                    "Use npm, not pnpm. See package.json",
                    &["package.json"],
                ),
                note(
                    "auth-flow",
                    "Auth tokens are refreshed in src/auth.rs",
                    &["src/auth.rs"],
                ),
            ],
            vec![
                session(
                    "20260920-090000-0001",
                    "2026-09-20T09:30:00+00:00",
                    "fix the login bug",
                    &["src/auth.rs"],
                    "1. User: fix the login bug Ran Read, Edit; edited src/auth.rs (+5/-2). Reply: Fixed the null check",
                ),
                session(
                    "20260922-090000-0002",
                    "2026-09-22T09:30:00+00:00",
                    "auth refresh timing",
                    &["src/auth.rs", "src/clock.rs"],
                    "1. User: auth refresh timing is off Ran Grep. Reply: the login retry waits too long",
                ),
                session(
                    "20260923-090000-0003",
                    "2026-09-23T09:30:00+00:00",
                    "add a README",
                    &["README.md"],
                    "1. User: add a README Ran Write; edited README.md (+40/-0).",
                ),
            ],
        )
    }

    #[test]
    fn all_words_must_match_and_titles_rank_first() {
        let (notes, sessions) = sources();
        let src = Sources {
            notes: &notes,
            sessions: &sessions,
        };
        let hits = search(&src, "login bug", "", 5);
        assert_eq!(hits.len(), 1, "{hits:?}");
        assert_eq!(hits[0].id, "20260920-090000-0001");

        let hits = search(&src, "auth", "", 5);
        let ids: Vec<&str> = hits.iter().map(|h| h.id.as_str()).collect();
        // Title hits beat body hits; ties go to the newest.
        assert_eq!(
            ids,
            ["20260922-090000-0002", "auth-flow", "20260920-090000-0001"]
        );
        assert_eq!(hits[1].source, "note");
        assert_eq!(
            hits[0].matching,
            vec![
                "1. User: auth refresh timing is off Ran Grep. Reply: the login retry waits too long"
            ]
        );

        let hits = search(&src, "", "src/auth.rs", 5);
        let ids: Vec<&str> = hits.iter().map(|h| h.id.as_str()).collect();
        assert_eq!(
            ids,
            ["20260922-090000-0002", "20260920-090000-0001", "auth-flow"]
        );

        let hits = search(&src, "login", "clock", 5);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, "20260922-090000-0002");

        assert!(search(&src, "nothing here", "", 5).is_empty());
        assert_eq!(search(&src, "auth", "", 1).len(), 1);
    }

    #[test]
    fn output_fits_the_budget_and_says_what_was_cut() {
        let (notes, sessions) = sources();
        let src = Sources {
            notes: &notes,
            sessions: &sessions,
        };
        let hits = search(&src, "auth", "", 5);
        let full = render(&hits, "auth", "", 4_000);
        assert!(full.starts_with("3 hits for \"auth\":\n- [session 2026-09-22 20260922-090000-0002] auth refresh timing\n  files: src/auth.rs, src/clock.rs\n"));
        assert!(!full.contains("not shown"));

        let small = render(&hits, "auth", "", 250);
        assert!(small.len() <= 250 + 40, "{small}");
        assert!(small.contains("more not shown"));

        let tiny = render(&hits, "auth", "", 10);
        assert!(
            tiny.contains("20260922-090000-0002"),
            "the first hit always shows: {tiny}"
        );

        let out = run(&src, &serde_json::json!({"file": "README"}), Tier::Weak).unwrap();
        assert!(out.content.contains("add a README"));
        assert!(run(&src, &serde_json::json!({}), Tier::Weak).is_err());
        assert_eq!(
            render(&[], "x", "", 100),
            "No notes or past sessions match \"x\"."
        );
        assert!(command(&src, "file:clock.rs", Tier::Weak).contains("auth refresh timing"));
        assert!(command(&src, "", Tier::Weak).starts_with("usage:"));
    }
}
