use super::{Ctx, Output};
use crate::diagram::Diagram;
use crate::provider::ToolSpec;
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: "Diagram",
        description: "Show the user a diagram. Use it when a picture explains better than prose: \
architecture (components and how they connect), data or control flow, a request's path through \
the code, or the order of calls between parts (kind \"sequence\"). Prefer it when the user asks \
how something works or fits together. Keep diagrams small (usually 4-15 nodes) and label edges \
with what flows along them. Link nodes to source with `file` (a path relative to the project) \
and optional `line` when a node is a specific file or function. The user sees the drawing; you \
get a short confirmation. For sequence diagrams, nodes are the participants in order and edges \
are the messages in time order (style \"dashed\" for replies).",
        schema: json!({
            "type": "object",
            "properties": {
                "kind": { "type": "string", "enum": ["flow", "sequence"] },
                "title": { "type": "string" },
                "direction": { "type": "string", "enum": ["down", "right"], "description": "flow only; default down" },
                "nodes": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "id": { "type": "string" },
                            "label": { "type": "string" },
                            "shape": { "type": "string", "enum": ["box", "rounded", "store", "actor", "decision", "external"] },
                            "group": { "type": "string", "description": "id of a group to draw this node inside" },
                            "file": { "type": "string" },
                            "line": { "type": "integer" },
                            "detail": { "type": "string", "description": "one sentence shown on hover" }
                        },
                        "required": ["id", "label"]
                    }
                },
                "edges": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "from": { "type": "string" },
                            "to": { "type": "string" },
                            "label": { "type": "string" },
                            "style": { "type": "string", "enum": ["solid", "dashed", "thick"] }
                        },
                        "required": ["from", "to"]
                    }
                },
                "groups": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": { "id": { "type": "string" }, "label": { "type": "string" } },
                        "required": ["id", "label"]
                    }
                }
            },
            "required": ["kind", "title", "nodes", "edges"]
        }),
    }
}

pub fn run(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let mut d: Diagram = serde_json::from_value(input.clone())
        .context("diagram arguments don't match the schema")?;
    let warnings = d.finish(&ctx.cwd);
    if d.nodes.is_empty() {
        bail!("the diagram has no nodes");
    }
    let mut content = format!(
        "Diagram \"{}\" is shown to the user ({} nodes, {} edges). Don't repeat it in text; refer to it.",
        if d.title.is_empty() {
            "untitled"
        } else {
            &d.title
        },
        d.nodes.len(),
        d.edges.len()
    );
    if !warnings.is_empty() {
        content.push_str("\nNotes:\n- ");
        content.push_str(&warnings.join("\n- "));
    }
    Ok(Output {
        content,
        display: Some(d.to_ascii()),
        diff: None,
        diagram: Some(Box::new(d)),
    })
}
