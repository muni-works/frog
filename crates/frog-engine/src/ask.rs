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
one you recommend first. The user picks the number of things themselves: one, several, or none \
and their own words, so set `multi` when the options aren't exclusive (\"which of these should I \
fix too?\") and leave it off when picking two would contradict itself (\"which fix?\")."
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
        bail!("`question` is required: put the question's text in `question` and call Ask again");
    }
    // Some models send the array as a JSON string (`"options": "[{\"label\": …}]"`).
    let unquoted = input["options"]
        .as_str()
        .and_then(|s| serde_json::from_str::<Value>(s).ok());
    let options: Vec<AskOption> = match unquoted.as_ref().unwrap_or(&input["options"]) {
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
            "give {MIN_OPTIONS}-{MAX_OPTIONS} options with a `label` each (got {}): `options` is an array like [{{\"label\": \"Yes\"}}, {{\"label\": \"No\"}}]. For an open question, ask it in your reply instead of with Ask.",
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
///
/// How many picks there are is the person's decision, not `multi`'s: the model's flag is which
/// card the client draws first, and a person who answers a single-choice question with two
/// picks has given two picks. Cutting the extras here would record an answer they didn't give,
/// the same way a redirect reply recorded as an answer does.
pub fn result(q: &Question, answer: &Answer) -> String {
    let mut picked: Vec<&str> = Vec::new();
    for c in &answer.choices {
        let c = c.as_str();
        if picked.len() == MAX_OPTIONS {
            break;
        }
        if q.options.iter().any(|o| o.label == c) && !picked.contains(&c) {
            picked.push(c);
        }
    }
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
    fn the_description_teaches_multi() {
        // The bug that hid this feature: the schema had `multi`, the description never said
        // its name, so the model had no reason to set it and every card came out single-pick.
        let d = spec().description;
        assert!(d.contains("`multi`"), "the Ask description never mentions multi: {d}");
        assert!(d.contains("2-4 short options"), "the option guidance left: {d}");
        assert!(d.contains("Don't ask about things you can find out yourself"));
    }

    #[test]
    fn parses_multi() {
        let q = parse(&json!({
            "question": "?",
            "options": ["a", "b"],
            "multi": true
        }))
        .unwrap();
        assert!(q.multi);
        assert!(q.allow_other, "allow_other still defaults to true with multi");
        let off = parse(&json!({"question": "?", "options": ["a", "b"], "allow_other": false})).unwrap();
        assert!(!off.allow_other);
    }

    /// Logged: `options` sent as a JSON string, refused with "got 0".
    #[test]
    fn options_sent_as_a_json_string_are_parsed() {
        let q = parse(&json!({
            "question": "Raise the cap?",
            "options": "[{\"label\": \"Raise cap\", \"detail\": \"to $65\"}, {\"label\": \"Keep it\"}]"
        }))
        .unwrap();
        assert_eq!(q.options.len(), 2);
        assert_eq!(q.options[0].label, "Raise cap");
    }

    #[test]
    fn no_options_names_the_fix() {
        let err = parse(&json!({"question": "?"})).unwrap_err().to_string();
        assert!(err.contains("`options` is an array like"), "{err}");
        assert!(err.contains("ask it in your reply"), "{err}");
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
        // Both picks are the person's answer, and both reach the model, in the order they made
        // them: a pick order is the only preference signal a click carries.
        assert_eq!(
            result(&q, &a(&["Checksum", "Truncate"], None)),
            "The user chose: Checksum, Truncate"
        );
        // Not an option: dropped, and the real pick survives.
        assert_eq!(
            result(&q, &a(&["Rewrite it", "Checksum"], None)),
            "The user chose: Checksum"
        );
        assert_eq!(
            result(&q, &a(&[], Some("neither, revert"))),
            "The user answered in their own words: neither, revert"
        );
        assert!(result(&q, &a(&[], None)).starts_with("The user dismissed"));
        // Picks and typed words together: the free-form box is part of the answer, not a race
        // with it.
        assert_eq!(
            result(&q, &a(&["Truncate"], Some("and the docs"))),
            "The user chose: Truncate. They added: and the docs"
        );
    }

    #[test]
    fn picks_survive_a_question_the_model_called_single() {
        // The clamp that recorded an answer nobody gave: two picks on a `multi: false`
        // question came back to the model as one pick.
        let mut q = q();
        assert!(!q.multi);
        let answer = Answer {
            choices: vec!["Truncate".into(), "Checksum".into()],
            other: None,
        };
        assert_eq!(result(&q, &answer), "The user chose: Truncate, Checksum");
        q.multi = true;
        assert_eq!(result(&q, &answer), "The user chose: Truncate, Checksum");
    }

    #[test]
    fn picks_never_repeat_and_never_exceed_the_options() {
        let q = q();
        let answer = Answer {
            // The same pick twice (a client's bug), then too many.
            choices: vec!["Truncate".into(), "Truncate".into(), "Checksum".into()],
            other: None,
        };
        assert_eq!(result(&q, &answer), "The user chose: Truncate, Checksum");
        let many = Question {
            options: (0..MAX_OPTIONS)
                .map(|i| AskOption { label: format!("o{i}"), detail: None })
                .collect(),
            ..parse(&json!({"question": "?", "options": ["a", "b"]})).unwrap()
        };
        let all = Answer {
            choices: (0..MAX_OPTIONS + 3).map(|i| format!("o{i}")).collect(),
            other: None,
        };
        let text = result(&many, &all);
        let picks = text.trim_start_matches("The user chose: ");
        assert_eq!(picks.split(", ").count(), MAX_OPTIONS, "{text}");
    }
}
