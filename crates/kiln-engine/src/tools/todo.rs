use super::{Ctx, Output};
use crate::provider::ToolSpec;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Todo {
    pub content: String,
    pub status: String,
}

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: "TodoWrite",
        description: "Create or update the task list for multi-step work (3+ steps). Always send the full list. \
Keep exactly one item in_progress while working, and mark items completed as soon as they're done.",
        schema: json!({
            "type": "object",
            "properties": {
                "todos": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "content": { "type": "string" },
                            "status": { "type": "string", "enum": ["pending", "in_progress", "completed"] }
                        },
                        "required": ["content", "status"]
                    }
                }
            },
            "required": ["todos"]
        }),
    }
}

pub fn render(todos: &[Todo]) -> String {
    todos
        .iter()
        .map(|t| {
            let mark = match t.status.as_str() {
                "completed" => "☒",
                "in_progress" => "◐",
                _ => "☐",
            };
            format!("{mark} {}", t.content)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn run(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    // Some models send the array JSON-encoded as a string.
    let todos = match &input["todos"] {
        Value::String(s) => serde_json::from_str(s),
        v => serde_json::from_value(v.clone()),
    }
    .context("`todos` must be an array of {content, status}")?;
    ctx.todos = todos;
    Ok(Output {
        content: "Todo list updated.".into(),
        display: Some(render(&ctx.todos)),
        diff: None,
    })
}
