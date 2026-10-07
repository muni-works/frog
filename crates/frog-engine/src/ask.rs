//! Ask: the model puts a question with a few options to the user and waits for the answer.
//! The engine sends [`Event::Question`](crate::protocol::Event::Question) and the client answers
//! with [`Op::Answer`](crate::protocol::Op::Answer); offered only when a client says a person can
//! answer, and never to subagents.

use crate::protocol::{Answer, AskOption};
use crate::provider::ToolSpec;
use anyhow::{Result, bail};
use serde_json::{Value, json};

pub const TOOL: &str = "Ask";

const MIN_OPTIONS: usize = 2;
const MAX_OPTIONS: usize = 4;

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Ask the user to choose between a few options, and wait for the answer. Use \
it only when the choice is genuinely theirs: the request is ambiguous in a way the code can't \
settle, or the options trade off in ways they care about (scope, an irreversible change, a \
public API). Don't ask about things you can find out yourself or that have an obvious default; \
pick it and say so. Give 2-4 short options, each with an optional one-line detail, and put the \
one you recommend first."
            .into(),
        schema: json!({
            "type": "object",
            "properties": {
                "question": { "type": "string" },
                "options": {
                    "type": "array",
                    "minItems": MIN_OPTIONS,
                    "maxItems": MAX_OPTIONS,
                    "items": {
                        "type": "object",
                        "properties": {
                            "label": { "type": "string", "description": "a few words" },
                            "detail": { "type": "string", "description": "one line: what it means or costs" }
                        },
                        "required": ["label"]
                    }
                },
                "multi": { "type": "boolean", "description": "the user may pick more than one" },
                "allow_other": { "type": "boolean", "description": "the user may type their own answer (default true)" }
            },
            "required": ["question", "options"]
        }),
    }
}

/// A question, validated.
#[derive(Debug, PartialEq)]
pub struct Question {
    pub question: String,
    pub options: Vec<AskOption>,
    pub multi: bool,
    pub allow_other: bool,
}

pub fn parse(input: &Value) -> Result<Question> {
    let question = input["question"].as_str().unwrap_or("").trim().to_string();
    if question.is_empty() {
        bail!("`question` is required");
    }
    let options: Vec<AskOption> = match &input["options"] {
        Value::Array(a) => a
            .iter()
            .filter_map(|o| match o {
                // A bare string is a label: small models write options that way.
                Value::String(s) => Some(AskOption {
                    label: s.trim().to_string(),
                    detail: None,
                }),
                _ => serde_json::from_value::<AskOption>(o.clone()).ok(),
            })
            .filter(|o| !o.label.trim().is_empty())
            .collect(),
        _ => Vec::new(),
    };
    if !(MIN_OPTIONS..=MAX_OPTIONS).contains(&options.len()) {
        bail!(
            "give {MIN_OPTIONS}-{MAX_OPTIONS} options with a `label` each (got {})",
            options.len()
        );
    }
    let mut seen = std::collections::HashSet::new();
    if let Some(dup) = options.iter().find(|o| !seen.insert(o.label.trim())) {
        bail!("two options are labelled `{}`", dup.label);
    }
    Ok(Question {
        question,
        options,
        multi: crate::tools::bool_arg(input, "multi"),
        allow_other: input
            .get("allow_other")
            .is_none_or(|_| crate::tools::bool_arg(input, "allow_other")),
    })
}

/// What the model gets back. Picks that weren't offered are dropped, so a client can't put
/// words in the user's mouth through `choices`; that's what `other` is for.
pub fn result(q: &Question, answer: &Answer) -> String {
    let picked: Vec<&str> = answer
        .choices
        .iter()
        .filter(|c| q.options.iter().any(|o| &o.label == *c))
        .map(String::as_str)
        .take(if q.multi { MAX_OPTIONS } else { 1 })
        .collect();
    let other = answer
        .other
        .as_deref()
        .map(str::trim)
        .filter(|o| !o.is_empty() && q.allow_other);
    match (picked.as_slice(), other) {
        ([], None) => "The user dismissed the question without answering. Don't ask it again; \
continue with your best judgment and say what you chose, or stop and wait if you can't."
            .into(),
        ([], Some(o)) => format!("The user answered in their own words: {o}"),
        (p, None) => format!("The user chose: {}", p.join(", ")),
        (p, Some(o)) => format!("The user chose: {}. They added: {o}", p.join(", ")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn q() -> Question {
        parse(&json!({
            "question": "Which fix?",
            "options": [{"label": "Truncate", "detail": "2 files"}, "Checksum"]
        }))
        .unwrap()
    }

    #[test]
    fn parses_objects_and_bare_labels() {
        let q = q();
        assert_eq!(q.options[1].label, "Checksum");
        assert!(q.allow_other && !q.multi);
    }

    #[test]
    fn rejects_too_few_or_duplicate_options() {
        let one = parse(&json!({"question": "?", "options": ["a"]}));
        assert!(one.unwrap_err().to_string().contains("2-4 options"));
        let dup = parse(&json!({"question": "?", "options": ["a", "a"]}));
        assert!(dup.unwrap_err().to_string().contains("labelled `a`"));
        assert!(parse(&json!({"options": ["a", "b"]})).is_err());
    }

    #[test]
    fn results() {
        let q = q();
        let a = |c: &[&str], o: Option<&str>| Answer {
            choices: c.iter().map(|s| s.to_string()).collect(),
            other: o.map(String::from),
        };
        assert_eq!(
            result(&q, &a(&["Truncate"], None)),
            "The user chose: Truncate"
        );
        // Not an option, and only one pick when not multi.
        assert_eq!(
            result(&q, &a(&["Rewrite it", "Checksum", "Truncate"], None)),
            "The user chose: Checksum"
        );
        assert_eq!(
            result(&q, &a(&[], Some("neither, revert"))),
            "The user answered in their own words: neither, revert"
        );
        assert!(result(&q, &a(&[], None)).starts_with("The user dismissed"));
    }
}
