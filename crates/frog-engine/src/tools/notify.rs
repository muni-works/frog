//! Notifications the agent decides on: the one place a turn reaches past the transcript to
//! the person, when they aren't looking.
//!
//! Silence is the default. A finished reply is already on screen, so an alert per turn end is
//! noise (the "pushing every response to the phone" problem); the model calls `Notify` only
//! for what a person would want to be pulled away for — a long job done, something broken, a
//! decision needed. The engine emits [`crate::protocol::Event::Notify`] and each client decides
//! what that means: a banner, a Dock bounce, a push to the phone.

use super::{Ctx, Output};
use crate::protocol::NotifyUrgency;
use crate::provider::ToolSpec;
use anyhow::{Result, bail};
use serde_json::{Value, json};

pub const TOOL: &str = "Notify";

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Tell the person something outside the transcript, when they aren't \
watching: a long job finished, something broke, a decision is needed. Never for an ordinary \
reply — it's already on screen. urgency \"attention\" interrupts (a banner with sound, and a \
Dock bounce when frog is behind another app): a decision, a failure, work stopped. \"done\" is a \
quiet banner for a long job finishing. \"silent\" doesn't interrupt at all: no banner, no sound, \
no bounce — only a line to read later."
            .into(),
        schema: json!({
            "type": "object",
            "properties": {
                "title": {
                    "type": "string",
                    "description": "a few words, like a session title; optional"
                },
                "body": {
                    "type": "string",
                    "description": "one or two sentences: what happened, and what (if anything) to do"
                },
                "urgency": {
                    "type": "string",
                    "enum": ["attention", "done", "silent"],
                    "description": "attention: needs them now. done: a long job finished. silent: no interruption at all."
                }
            },
            "required": ["body"]
        }),
    }
}

/// A validated notification, ready to emit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Note {
    /// A few words, like a session title; absent means the client names the session.
    pub title: Option<String>,
    pub body: String,
    pub urgency: NotifyUrgency,
}

/// The most a title or body may be, in characters: a notification is a glance, not a report.
const TITLE_MAX: usize = 80;
const BODY_MAX: usize = 400;

/// The model's `Notify` arguments.
pub fn parse(input: &Value) -> Result<Note> {
    let Some(raw) = input["body"].as_str() else {
        bail!("missing required string parameter `body`");
    };
    let body = one_line(raw, BODY_MAX);
    if body.is_empty() {
        bail!("the notification body is empty");
    }
    let urgency = match input["urgency"].as_str() {
        Some(s) => NotifyUrgency::parse(s).ok_or_else(|| {
            anyhow::anyhow!("`urgency` must be \"attention\", \"done\" or \"silent\", not {s:?}")
        })?,
        None => NotifyUrgency::Done,
    };
    let title = input["title"]
        .as_str()
        .map(|t| one_line(t, TITLE_MAX))
        .filter(|t| !t.is_empty());
    Ok(Note {
        title,
        body,
        urgency,
    })
}

/// Trimmed, whitespace collapsed to one line, cut to `max` characters.
fn one_line(s: &str, max: usize) -> String {
    let line = s.split_whitespace().collect::<Vec<_>>().join(" ");
    line.chars().take(max).collect::<String>().trim().to_string()
}

pub fn run(input: &Value, _ctx: &mut Ctx) -> Result<Output> {
    let note = parse(input)?;
    Ok(Output {
        content: format!(
            "Notified the user ({}){}.",
            note.urgency.name(),
            note.title
                .as_ref()
                .map(|t| format!(": {t}"))
                .unwrap_or_default()
        ),
        display: Some(note.body.clone()),
        notify: Some(note),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urgency_parses_the_three_names() {
        assert_eq!(NotifyUrgency::parse("attention"), Some(NotifyUrgency::Attention));
        assert_eq!(NotifyUrgency::parse("DONE"), Some(NotifyUrgency::Done));
        assert_eq!(NotifyUrgency::parse(" silent "), Some(NotifyUrgency::Silent));
        assert_eq!(NotifyUrgency::parse("loud"), None);
    }

    #[test]
    fn a_missing_urgency_is_done() {
        let note = parse(&json!({ "body": "tests pass" })).unwrap();
        assert_eq!(note.urgency, NotifyUrgency::Done);
        assert_eq!(note.title, None);
    }

    #[test]
    fn the_body_is_one_line_and_required() {
        let note = parse(&json!({ "title": " build ", "body": "  ran\nthe  tests  " })).unwrap();
        assert_eq!(note.title.as_deref(), Some("build"));
        assert_eq!(note.body, "ran the tests");
        assert!(parse(&json!({ "body": "   " })).is_err());
        assert!(parse(&json!({})).is_err());
        assert!(parse(&json!({ "body": "x", "urgency": "loud" })).is_err());
    }

    #[test]
    fn long_text_is_cut_to_a_glance() {
        let note = parse(&json!({ "body": "x".repeat(1000) })).unwrap();
        assert_eq!(note.body.chars().count(), BODY_MAX);
    }
}
