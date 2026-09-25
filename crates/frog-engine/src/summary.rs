//! Session summaries: one short markdown file per session, built from the session log without
//! a model call, so `Recall` (and the user, with `/recall`) can find past work by keyword or
//! by file touched.
//!
//! Written under the project's memory folder, `memory/projects/<key>/sessions/<id>.md`, when
//! a turn ends, on `/clear` and at exit. Frontmatter carries the id, project, times, title,
//! files touched and outcome; the body has a line or three per turn: what the user asked, which
//! tools ran, files edited with +/-, tests run and whether they passed, and how the reply began.
//! Older turns shrink to one line each so a file stays under [`MAX_CHARS`].

use crate::protocol::{EndReason, Envelope, Event, Item, ToolOutcome};
use crate::session::Header;
use regex::Regex;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

/// About the size of one screen: enough for a dozen turns in full.
pub const MAX_CHARS: usize = 2_000;
/// The most recent turns that keep their full few sentences.
const FULL_TURNS: usize = 4;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Summary {
    pub id: String,
    pub project: String,
    /// RFC 3339.
    pub started: String,
    pub updated: String,
    pub title: String,
    /// Files edited, with lines added and removed.
    pub files: Vec<(String, u32, u32)>,
    /// How the last turn ended.
    pub outcome: String,
    pub turns: Vec<Turn>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Turn {
    pub request: String,
    pub tools: Vec<String>,
    pub edits: Vec<(String, u32, u32)>,
    /// Test commands run, and whether each passed.
    pub tests: Vec<(String, bool)>,
    pub reply: String,
    pub outcome: String,
}

/// A summary as `Recall` sees it, read back from disk.
#[derive(Clone, Debug, PartialEq)]
pub struct Stored {
    pub id: String,
    pub updated: String,
    pub title: String,
    pub files: Vec<String>,
    pub body: String,
    pub path: PathBuf,
}

/// Build the summary from a session's header and durable events.
pub fn build(header: &Header, events: &[Envelope], title: Option<&str>) -> Summary {
    let mut turns: Vec<Turn> = Vec::new();
    let mut updated = header.created;
    let mut outcome = String::new();
    let mut titled: Option<String> = None;
    for env in events {
        match &env.event {
            Event::TurnStarted { input, .. } => {
                updated = updated.max(env.created);
                turns.push(Turn {
                    request: first_line(input),
                    ..Default::default()
                });
            }
            Event::ItemCompleted { item, .. } => {
                let Some(turn) = turns.last_mut() else {
                    continue;
                };
                match item {
                    Item::Message { text } => turn.reply = first_line(text),
                    Item::ToolCall {
                        name,
                        input,
                        outcome,
                        output,
                        diff,
                        ..
                    } => {
                        if !turn.tools.contains(name) {
                            turn.tools.push(name.clone());
                        }
                        if let Some(d) = diff {
                            merge(&mut turn.edits, &d.path, d.added, d.removed);
                        }
                        if name == "Bash"
                            && let Some(cmd) = input["command"].as_str()
                            && is_test(cmd)
                        {
                            let passed = *outcome == ToolOutcome::Ok && !failed(output);
                            turn.tests.push((first_line(cmd), passed));
                        }
                    }
                    Item::Reasoning { .. } => {}
                }
            }
            Event::TurnEnded { reason, .. } => {
                updated = updated.max(env.created);
                let o = reason_label(reason);
                if let Some(t) = turns.last_mut() {
                    t.outcome = o.to_string();
                }
                outcome = o.to_string();
            }
            Event::Titled { title } => titled = Some(title.clone()),
            _ => {}
        }
    }
    let mut files: Vec<(String, u32, u32)> = Vec::new();
    for t in &turns {
        for (p, a, r) in &t.edits {
            merge(&mut files, p, *a, *r);
        }
    }
    let title = title
        .map(String::from)
        .or(titled)
        .or_else(|| turns.first().map(|t| clip(&t.request, 80)))
        .unwrap_or_default();
    Summary {
        id: header.id.clone(),
        project: header.cwd.display().to_string(),
        started: rfc3339(header.created),
        updated: rfc3339(updated),
        title,
        files,
        outcome,
        turns,
    }
}

fn merge(list: &mut Vec<(String, u32, u32)>, path: &str, added: u32, removed: u32) {
    match list.iter_mut().find(|(p, _, _)| p == path) {
        Some(e) => {
            e.1 += added;
            e.2 += removed;
        }
        None => list.push((path.to_string(), added, removed)),
    }
}

fn reason_label(r: &EndReason) -> &'static str {
    match r {
        EndReason::Complete => "complete",
        EndReason::MaxTokens => "cut off at max tokens",
        EndReason::Denied => "stopped: tool call denied",
        EndReason::Looping => "stopped: looping",
        EndReason::StepLimit => "stopped: step limit",
        EndReason::Cancelled => "cancelled",
        EndReason::Error { .. } => "error",
    }
}

static TEST_CMD: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?x)(?:^|[\s;&|])(?:
            cargo\s+(?:test|nextest)|npm\s+(?:run\s+)?test|pnpm\s+test|yarn\s+test|bun\s+test|
            pytest|python3?\s+-m\s+(?:pytest|unittest)|go\s+test|swift\s+test|xcodebuild\s+test|
            (?:npx\s+)?(?:jest|vitest|mocha)|make\s+test|mix\s+test|rspec|dotnet\s+test|gradle\w*\s+test
        )\b",
    )
    .unwrap()
});

static FAILED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)\bFAILED\b|\b[1-9]\d*\s+(?:failed|failing|failures?)\b|^error(?:\[|:)|\bTests?\s+failed\b")
        .unwrap()
});

fn is_test(cmd: &str) -> bool {
    TEST_CMD.is_match(cmd)
}

fn failed(output: &str) -> bool {
    FAILED.is_match(output)
}

fn first_line(s: &str) -> String {
    let line = s
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty() && !l.starts_with('<'))
        .unwrap_or("");
    clip(line, 200)
}

fn clip(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        return s.to_string();
    }
    format!("{}…", s.chars().take(n - 1).collect::<String>())
}

fn rfc3339(ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(ms)
        .map(|t| {
            t.with_timezone(&chrono::Local)
                .format("%Y-%m-%dT%H:%M:%S%:z")
                .to_string()
        })
        .unwrap_or_default()
}

fn edits_text(edits: &[(String, u32, u32)]) -> String {
    edits
        .iter()
        .map(|(p, a, r)| format!("{p} (+{a}/-{r})"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// The whole turn: request, tools, edits, tests and the reply's first line.
fn turn_full(i: usize, t: &Turn) -> String {
    let mut s = format!("{}. User: {}", i + 1, t.request);
    let mut did = Vec::new();
    if !t.tools.is_empty() {
        did.push(format!("Ran {}", t.tools.join(", ")));
    }
    if !t.edits.is_empty() {
        did.push(format!("edited {}", edits_text(&t.edits)));
    }
    for (cmd, ok) in &t.tests {
        did.push(format!(
            "tests `{}` {}",
            clip(cmd, 60),
            if *ok { "passed" } else { "failed" }
        ));
    }
    if !did.is_empty() {
        s.push_str(&format!(" {}.", did.join("; ")));
    }
    if !t.reply.is_empty() {
        s.push_str(&format!(" Reply: {}", t.reply));
    }
    if !t.outcome.is_empty() && t.outcome != "complete" {
        s.push_str(&format!(" ({})", t.outcome));
    }
    s
}

/// One line: the request and what was edited.
fn turn_short(i: usize, t: &Turn) -> String {
    let mut s = format!("{}. {}", i + 1, clip(&t.request, 100));
    if !t.edits.is_empty() {
        s.push_str(&format!(
            " → {}",
            t.edits
                .iter()
                .map(|(p, _, _)| p.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    if let Some((_, false)) = t.tests.last() {
        s.push_str(" (tests failed)");
    }
    s
}

/// The markdown file: frontmatter and a numbered line or three per turn, within [`MAX_CHARS`].
pub fn render(s: &Summary) -> String {
    let mut files: Vec<String> = s
        .files
        .iter()
        .take(30)
        .map(|(p, a, r)| format!("{p} (+{a}/-{r})"))
        .collect();
    if s.files.len() > 30 {
        files.push(format!("… {} more", s.files.len() - 30));
    }
    let mut head = format!(
        "---\nid: {}\nproject: {}\nstarted: {}\nupdated: {}\ntitle: {}\nfiles: {}\noutcome: {}\n---\n",
        s.id,
        s.project,
        s.started,
        s.updated,
        yaml_str(&s.title),
        serde_json::to_string(&files).unwrap_or_else(|_| "[]".into()),
        s.outcome
    );
    let n = s.turns.len();
    let full_from = n.saturating_sub(FULL_TURNS);
    let mut lines: Vec<String> = s
        .turns
        .iter()
        .enumerate()
        .map(|(i, t)| {
            if i >= full_from {
                turn_full(i, t)
            } else {
                turn_short(i, t)
            }
        })
        .collect();
    // Room for the lines, less the "omitted" note that may follow the frontmatter.
    let room = MAX_CHARS.saturating_sub(head.len() + 32);
    let total = |lines: &[String]| lines.iter().map(|l| l.len() + 1).sum::<usize>();
    // Drop the oldest lines first; if the recent turns alone don't fit, shorten them too,
    // oldest first.
    let mut dropped = 0;
    while total(&lines) > room && lines.len() > FULL_TURNS.min(n).max(1) {
        lines.remove(0);
        dropped += 1;
    }
    let mut i = 0;
    while total(&lines) > room && i < lines.len() {
        lines[i] = turn_short(dropped + i, &s.turns[dropped + i]);
        i += 1;
    }
    if dropped > 0 {
        head.push_str(&format!("({dropped} earlier turns omitted)\n"));
    }
    let (body, _) = crate::memory::redact(&lines.join("\n"));
    format!("{head}{body}\n")
}

fn yaml_str(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| format!("\"{s}\""))
}

/// Write the summary to `dir/<id>.md` (private to the user).
pub fn write(dir: &Path, s: &Summary) -> std::io::Result<PathBuf> {
    crate::memory::create_private_dir(dir).map_err(|e| std::io::Error::other(format!("{e:#}")))?;
    let path = dir.join(format!("{}.md", s.id));
    crate::memory::write_private(&path, &render(s))
        .map_err(|e| std::io::Error::other(format!("{e:#}")))?;
    Ok(path)
}

/// Every summary in `dir`, newest first.
pub fn load(dir: &Path) -> Vec<Stored> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<Stored> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "md"))
        .filter_map(|p| read(&p))
        .collect();
    out.sort_by(|a, b| b.updated.cmp(&a.updated).then_with(|| b.id.cmp(&a.id)));
    out
}

fn read(path: &Path) -> Option<Stored> {
    let text = std::fs::read_to_string(path).ok()?;
    let (meta, body): (BTreeMap<String, String>, &str) = crate::skills::split(&text)?;
    let id = meta
        .get("id")
        .cloned()
        .or_else(|| path.file_stem().map(|s| s.to_string_lossy().into_owned()))?;
    let files = meta
        .get("files")
        .map(|f| {
            serde_json::from_str::<Vec<String>>(f)
                .unwrap_or_default()
                .into_iter()
                .map(|f| f.split(" (+").next().unwrap_or(&f).to_string())
                .collect()
        })
        .unwrap_or_default();
    Some(Stored {
        id,
        updated: meta.get("updated").cloned().unwrap_or_default(),
        title: meta.get("title").map(|t| unquote(t)).unwrap_or_default(),
        files,
        body: body.trim().to_string(),
        path: path.to_path_buf(),
    })
}

fn unquote(s: &str) -> String {
    serde_json::from_str::<String>(s).unwrap_or_else(|_| s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{FileDiff, ItemKind, TurnUsage};

    fn env(seq: u64, created: i64, event: Event) -> Envelope {
        Envelope {
            seq,
            session: "s".into(),
            created,
            event,
        }
    }

    fn call(name: &str, input: serde_json::Value, output: &str, diff: Option<FileDiff>) -> Event {
        Event::ItemCompleted {
            id: "i".into(),
            item: Item::ToolCall {
                name: name.into(),
                arg: String::new(),
                input,
                outcome: ToolOutcome::Ok,
                output: output.into(),
                display: None,
                diff,
                diagram: None,
                images: Vec::new(),
                app: None,
            },
        }
    }

    fn diff(path: &str, added: u32, removed: u32) -> FileDiff {
        FileDiff {
            path: path.into(),
            created: false,
            added,
            removed,
            hunks: Vec::new(),
        }
    }

    fn header() -> Header {
        Header {
            version: 1,
            id: "20260924-101010-ab12".into(),
            cwd: PathBuf::from("/tmp/proj"),
            model: "m".into(),
            created: 1_000,
            forked_from: None,
        }
    }

    fn fixture() -> Vec<Envelope> {
        let turn_started = |seq, created, input: &str| {
            env(
                seq,
                created,
                Event::TurnStarted {
                    turn: seq,
                    input: input.into(),
                    images: Vec::new(),
                },
            )
        };
        let mut evs = vec![turn_started(1, 2_000, "fix the login bug\nmore detail")];
        evs.push(env(
            2,
            2_100,
            call("Read", serde_json::json!({}), "…", None),
        ));
        evs.push(env(
            3,
            2_200,
            call(
                "Edit",
                serde_json::json!({}),
                "ok",
                Some(diff("src/auth.rs", 5, 2)),
            ),
        ));
        evs.push(env(
            4,
            2_300,
            call(
                "Bash",
                serde_json::json!({"command": "cargo test -p app"}),
                "test result: ok. 3 passed; 0 failed",
                None,
            ),
        ));
        evs.push(env(
            5,
            2_400,
            Event::ItemCompleted {
                id: "m".into(),
                item: Item::Message {
                    text: "Fixed the null check in auth.rs. Token was password=hunter2secret"
                        .into(),
                },
            },
        ));
        evs.push(env(
            6,
            2_500,
            Event::TurnEnded {
                turn: 1,
                reason: EndReason::Complete,
                usage: TurnUsage::default(),
            },
        ));
        evs.push(env(
            7,
            2_600,
            Event::ItemStarted {
                id: "x".into(),
                kind: ItemKind::Message,
            },
        ));
        evs.push(turn_started(8, 3_000, "now add a test"));
        evs.push(env(
            9,
            3_100,
            call(
                "Write",
                serde_json::json!({}),
                "ok",
                Some(diff("tests/auth.rs", 20, 0)),
            ),
        ));
        evs.push(env(
            10,
            3_200,
            call(
                "Bash",
                serde_json::json!({"command": "cargo test"}),
                "test result: FAILED. 1 failed",
                None,
            ),
        ));
        evs.push(env(
            11,
            3_300,
            Event::TurnEnded {
                turn: 2,
                reason: EndReason::Denied,
                usage: TurnUsage::default(),
            },
        ));
        evs
    }

    #[test]
    fn summary_is_built_from_the_log() {
        let s = build(&header(), &fixture(), None);
        assert_eq!(s.title, "fix the login bug");
        assert_eq!(s.outcome, "stopped: tool call denied");
        assert_eq!(
            s.files,
            vec![
                ("src/auth.rs".to_string(), 5, 2),
                ("tests/auth.rs".to_string(), 20, 0)
            ]
        );
        assert_eq!(s.turns.len(), 2);
        let t = &s.turns[0];
        assert_eq!(t.tools, vec!["Read", "Edit", "Bash"]);
        assert_eq!(t.tests, vec![("cargo test -p app".to_string(), true)]);
        assert!(t.reply.starts_with("Fixed the null check"));
        assert_eq!(s.turns[1].tests, vec![("cargo test".to_string(), false)]);

        let text = render(&s);
        assert!(text.starts_with("---\nid: 20260924-101010-ab12\nproject: /tmp/proj\n"));
        assert!(text.contains("title: \"fix the login bug\"\n"));
        assert!(text.contains("files: [\"src/auth.rs (+5/-2)\",\"tests/auth.rs (+20/-0)\"]\n"));
        assert!(text.contains("1. User: fix the login bug Ran Read, Edit, Bash; edited src/auth.rs (+5/-2); tests `cargo test -p app` passed. Reply: Fixed the null check"));
        assert!(text.contains("2. User: now add a test Ran Write, Bash; edited tests/auth.rs (+20/-0); tests `cargo test` failed. (stopped: tool call denied)"));
        assert!(text.contains("password=[REDACTED]"), "{text}");
        assert!(!text.contains("hunter2"));
        assert!(text.len() <= MAX_CHARS);
    }

    #[test]
    fn long_sessions_shrink_older_turns_and_stay_under_budget() {
        let mut evs = Vec::new();
        for i in 0..40u64 {
            evs.push(env(
                i * 3,
                2_000 + i as i64,
                Event::TurnStarted {
                    turn: i,
                    input: format!(
                        "turn {i}: please do something fairly long-winded about module {i}"
                    ),
                    images: Vec::new(),
                },
            ));
            evs.push(env(
                i * 3 + 1,
                2_001 + i as i64,
                call(
                    "Edit",
                    serde_json::json!({}),
                    "ok",
                    Some(diff(&format!("src/m{i}.rs"), 1, 1)),
                ),
            ));
            evs.push(env(
                i * 3 + 2,
                2_002 + i as i64,
                Event::TurnEnded {
                    turn: i,
                    reason: EndReason::Complete,
                    usage: TurnUsage::default(),
                },
            ));
        }
        let s = build(&header(), &evs, Some("Long one"));
        let text = render(&s);
        assert!(text.len() <= MAX_CHARS, "{}", text.len());
        assert!(text.contains("earlier turns omitted"));
        assert!(
            text.contains("40. User: turn 39"),
            "newest turn is kept in full"
        );
        assert!(!text.contains("1. User:"), "oldest turns are gone");

        let dir = std::env::temp_dir().join(format!("frog-summary-{}", crate::session::new_id()));
        let path = write(&dir, &s).unwrap();
        let stored = load(&dir);
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].path, path);
        assert_eq!(stored[0].title, "Long one");
        assert!(stored[0].files.contains(&"src/m3.rs".to_string()));
        assert!(
            stored[0].files.iter().any(|f| f.starts_with("… ")),
            "{:?}",
            stored[0].files
        );
        assert!(!stored[0].files[0].contains("(+"));
    }

    #[test]
    fn test_commands_are_recognized() {
        assert!(is_test("cargo test -p frog-engine"));
        assert!(is_test("cd app && npm test"));
        assert!(is_test("pytest tests/"));
        assert!(!is_test("cargo build"));
        assert!(!is_test("ls testdata"));
        assert!(failed("test result: FAILED. 1 passed; 2 failed"));
        assert!(!failed("test result: ok. 3 passed; 0 failed; 0 ignored"));
    }
}
