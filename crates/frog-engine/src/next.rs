//! Next steps: the one prompt the user would most likely send after this turn, shown in the
//! composer as ghost text they accept or type over.
//!
//! The model writes it with the `Next` tool, in the turn, knowing what's unresolved (tests
//! failing, a diff uncommitted), so there's no side-model and no extra request. Silence is
//! the default: no call, no suggestion. The engine holds it until the turn ends and emits
//! [`crate::protocol::Event::NextSuggested`] only for a turn that completed; it's never
//! carried into another turn.

use crate::provider::ToolSpec;
use anyhow::{Result, bail};
use serde_json::{Value, json};

pub const TOOL: &str = "Next";

/// A suggested next prompt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Next {
    /// One line, in the user's words, cut to [`crate::title::MAX`].
    pub text: String,
    /// It acts outside the project (push, send, deploy): the client shows a button that
    /// needs a deliberate click, never ghost text.
    pub act: bool,
}

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Suggest the one message the user would most likely send next, shown in \
their composer for them to accept or ignore. Call it last, at most once, and only when there's \
an obvious next step (\"commit this\", \"fix the 2 failing tests\") — skip it after explanations, \
brainstorms or open questions. Write it as the user would type it: short, imperative, their \
voice. Set act when it would push, send, publish or deploy."
            .into(),
        schema: json!({
            "type": "object",
            "properties": {
                "text": {
                    "type": "string",
                    "description": "the next message, one short line in the user's voice"
                },
                "act": {
                    "type": "boolean",
                    "description": "true when it acts outside the project (push, send, deploy)"
                }
            },
            "required": ["text"]
        }),
    }
}

/// The model's `Next` arguments.
pub fn parse(input: &Value) -> Result<Next> {
    let Some(raw) = input["text"].as_str() else {
        bail!("missing required string parameter `text`");
    };
    let text = crate::title::clean(raw);
    if text.is_empty() {
        bail!("the suggestion is empty");
    }
    Ok(Next {
        text,
        act: input["act"].as_bool().unwrap_or(false),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_suggestions() {
        let n = parse(&json!({ "text": "\"commit this\"" })).unwrap();
        assert_eq!(
            n,
            Next {
                text: "commit this".into(),
                act: false
            }
        );
        assert!(
            parse(&json!({ "text": "push it", "act": true }))
                .unwrap()
                .act
        );
        for bad in [json!({}), json!({ "text": "  " })] {
            assert!(parse(&bad).is_err(), "{bad}");
        }
    }
}
