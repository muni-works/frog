//! Session titles: a short name for the sidebar, `--sessions` and `Recall`.
//!
//! The model names the session with the `SetTitle` tool in its first reply, and again when
//! the work identifies itself better or changes; before that (headless runs, models that never call it) the first input is cleaned
//! up as a fallback: leading boilerplate the client prepends is stripped, so
//! "RULES: ... Continue this branch: fix the login bug" titles as "fix the login bug".

use crate::provider::ToolSpec;
use anyhow::{Result, bail};
use serde_json::{Value, json};

pub const TOOL: &str = "SetTitle";

/// The most a title may be, in characters (same as `Op::SetTitle` and `session::retitle`).
pub const MAX: usize = 80;

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Name this session for the session list: in your first reply, from the first \
message, and again only when the real topic turns out different. 2-3 lowercase words naming the \
work itself (\"fix login timeout\"), not the rules or context around the request; no \
punctuation, paths, quotes or markdown."
            .into(),
        schema: json!({
            "type": "object",
            "properties": {
                "title": {
                    "type": "string",
                    "description": "2-3 lowercase words naming the session's topic"
                }
            },
            "required": ["title"]
        }),
    }
}

/// A cleaned title: trimmed, quotes and markdown stripped, cut to [`MAX`].
pub fn clean(raw: &str) -> String {
    let mut t = raw.trim();
    // Models love wrapping short answers in quotes or emphasis; a title has no use for them.
    while t.len() > 1
        && t.starts_with(['"', '\'', '`', '*', '_'])
        && t.ends_with(['"', '\'', '`', '*', '_'])
    {
        t = t[1..t.len() - 1].trim();
    }
    // One line: a multi-word title has no newline, and this keeps a spilled description short.
    t.lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .trim()
        .trim_end_matches(['.', '!', ':', ';', ','])
        .chars()
        .take(MAX)
        .collect::<String>()
        .trim()
        .to_string()
}

/// The model's `SetTitle` arguments.
pub fn parse(input: &Value) -> Result<String> {
    let Some(raw) = input["title"].as_str() else {
        bail!("missing required string parameter `title`");
    };
    let t = clean(raw);
    if t.is_empty() {
        bail!("the title is empty");
    }
    Ok(t)
}

/// Labels that mark a line as pure boilerplate — the wrapper's rules, with the user's
/// request on a later line. Matched case-sensitively against the trimmed label.
const PREFIXES: &[&str] = &[
    "RULES",
    "INSTRUCTIONS",
    "IMPORTANT",
    "NOTES",
    "TASK",
    "TASK CONTEXT",
    "CONTEXT",
    "BACKGROUND",
    "PREAMBLE",
    "CONSTRAINTS",
];

/// Whole-word phrases a wrapper starts the real request with, after any rules. Matched
/// case-insensitively, on a word boundary, so "Continue this branch: fix the bug" drops them.
const LEAD_PHRASES: &[&str] = &[
    "continue this branch",
    "continue the branch",
    "finish the task",
    "finish this task",
    "task",
    "task context",
    "the task",
    "your task",
    "the goal",
    "context",
];

/// A fallback title from the session's first input: the first line that isn't boilerplate
/// (a `LABEL:` rule line, a prefix like `RULES:` or `Continue this branch:`), clipped.
pub fn derive(input: &str) -> String {
    for line in input.lines().map(str::trim) {
        if line.is_empty() {
            continue;
        }
        // A bare label line ("RULES:") carries nothing; the request follows.
        if line.ends_with(':')
            && (PREFIXES.contains(&line.trim_end_matches(':'))
                || is_lead_phrase(line.trim_end_matches(':')))
        {
            continue;
        }
        let Some((label, rest)) = line.split_once(": ") else {
            // Not a labeled line at all: this is the user's own words.
            return clip(line);
        };
        let (label, rest) = (label.trim(), rest.trim());
        if rest.is_empty() {
            // "RULES:" with the payload on later lines; keep looking.
            continue;
        }
        if is_lead_phrase(label) {
            // "Continue this branch: fix the login bug" — the request is what follows.
            return clip(rest);
        }
        let upper = label.to_uppercase();
        if PREFIXES.contains(&upper.as_str()) {
            // The whole line is the wrapper's ("RULES: work ONLY inside ..."); keep looking.
            continue;
        }
        if !is_label_marker(label) {
            // "note: this stays" — a colon mid-sentence is not a prefix.
            return clip(line);
        }
        // A rule marker we don't know ("PREAMBLE: ...") is boilerplate; keep looking.
    }
    String::new()
}

/// Whether `label` is one of the known lead phrases, case-insensitively.
fn is_lead_phrase(label: &str) -> bool {
    let lower = label.trim().to_lowercase();
    LEAD_PHRASES.contains(&lower.as_str())
}

/// A short all-caps label with no space: a rule marker (`RULES:`, `TASK_CONTEXT:`), not a request.
fn is_label_marker(label: &str) -> bool {
    let label = label.trim();
    !label.is_empty()
        && label.len() <= 24
        && !label.contains(' ')
        && label.chars().all(|c| c.is_uppercase() || c == '_')
}

/// Clip to one line and [`MAX`] characters, with an ellipsis like the summary's.
fn clip(s: &str) -> String {
    let first = s.lines().next().unwrap_or("").trim();
    if first.chars().count() <= MAX {
        first.to_string()
    } else {
        format!("{}…", first.chars().take(MAX - 1).collect::<String>())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_titles() {
        assert_eq!(clean("  fix login timeout  "), "fix login timeout");
        assert_eq!(clean("\"fix login timeout\""), "fix login timeout");
        assert_eq!(clean("**fix login timeout**"), "fix login timeout");
        assert_eq!(clean("fix login timeout."), "fix login timeout");
        // A long title is cut, not rejected.
        assert_eq!(clean(&"x".repeat(90)).len(), MAX);
    }

    #[test]
    fn empty_titles_are_rejected_by_the_tool_but_clean_never_panics() {
        assert!(parse(&json!({ "title": "ok" })).is_ok());
        for bad in ["", "  ", "\"\"", "   \n  "] {
            assert!(parse(&json!({ "title": bad })).is_err(), "{bad:?}");
        }
        // Without the parameter, the error names it.
        assert!(parse(&json!({})).is_err());
    }

    #[test]
    fn derives_titles_stripping_client_boilerplate() {
        // The exact shape this branch's sessions start with.
        let input = "RULES: work ONLY inside /tmp/work. Never cd into another checkout. \n\n\
Continue this branch: check git status and diff and keep the good partial work, then finish the \
task described in the branch's first commit message or, if none, in docs/ notes. Commit with \
git commit -s after each step.";
        let expected: String = "check git status and diff and keep the good partial work, then \
finish the task described in the branch's first commit message or, if none, in docs/ notes. \
Commit with git commit -s after each step."
            .chars()
            .take(MAX - 1)
            .collect::<String>()
            + "…";
        assert_eq!(derive(input), expected);

        assert_eq!(derive("fix the login bug"), "fix the login bug");
        assert_eq!(
            derive("Continue this branch: finish the SetTitle tool"),
            "finish the SetTitle tool"
        );
        assert_eq!(
            derive("TASK CONTEXT: two words, lowercase\n\nDo the thing."),
            "two words, lowercase"
        );
        // A colon that isn't a label is left alone.
        assert_eq!(derive("note: this stays"), "note: this stays");
        // All-boilerplate input falls back to the first line.
        assert_eq!(derive("RULES:\nbe nice"), "be nice");
        assert_eq!(derive(""), "");
        assert_eq!(derive("   \n \n"), "");
    }
}
