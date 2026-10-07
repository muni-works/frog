//! Present: a few typed blocks (tables, side-by-side comparisons, steps, callouts, diagrams)
//! the model shows the user instead of prose. Validated here, block by block, so a bad block
//! costs only itself; every client draws the same data: the Mac app natively, the terminal
//! as text ([`Present::to_text`]).

use crate::diagram::Diagram;
use crate::provider::ToolSpec;
use crate::tools::Output;
use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::Path;

pub const TOOL: &str = "Present";

const MAX_BLOCKS: usize = 8;
const MAX_COLUMNS: usize = 8;
const MAX_ROWS: usize = 50;
const MAX_STEPS: usize = 20;

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Present {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub title: String,
    pub blocks: Vec<Block>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Block {
    Table {
        columns: Vec<String>,
        rows: Vec<Vec<String>>,
    },
    /// Two things side by side: before/after, option A/option B.
    Compare {
        left: Side,
        right: Side,
    },
    Steps {
        items: Vec<String>,
        /// The step in progress, 0-based; earlier ones are done.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        current: Option<usize>,
    },
    Callout {
        #[serde(default)]
        tone: Tone,
        text: String,
    },
    Diagram(Box<Diagram>),
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Side {
    pub label: String,
    pub text: String,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Tone {
    #[default]
    Info,
    Success,
    Warning,
    Danger,
}

impl Block {
    fn kind(&self) -> &'static str {
        match self {
            Self::Table { .. } => "table",
            Self::Compare { .. } => "compare",
            Self::Steps { .. } => "steps",
            Self::Callout { .. } => "callout",
            Self::Diagram(_) => "diagram",
        }
    }
}

/// The block types a model of this strength is offered. Weak models get the two that are
/// hard to get wrong.
pub fn kinds(weak: bool) -> &'static [&'static str] {
    if weak {
        &["table", "callout"]
    } else {
        &["table", "compare", "steps", "callout", "diagram"]
    }
}

pub fn spec(weak: bool) -> ToolSpec {
    let kinds = kinds(weak);
    let mut variants = vec![
        json!({"type": "object", "properties": {
            "type": {"const": "table"},
            "columns": {"type": "array", "items": {"type": "string"}},
            "rows": {"type": "array", "items": {"type": "array", "items": {"type": "string"}}}
        }, "required": ["type", "columns", "rows"]}),
        json!({"type": "object", "properties": {
            "type": {"const": "callout"},
            "tone": {"type": "string", "enum": ["info", "success", "warning", "danger"]},
            "text": {"type": "string"}
        }, "required": ["type", "text"]}),
    ];
    if kinds.contains(&"compare") {
        let side = json!({"type": "object", "properties": {"label": {"type": "string"}, "text": {"type": "string"}}, "required": ["label", "text"]});
        variants.push(json!({"type": "object", "properties": {
            "type": {"const": "compare"}, "left": side, "right": side
        }, "required": ["type", "left", "right"]}));
    }
    if kinds.contains(&"steps") {
        variants.push(json!({"type": "object", "properties": {
            "type": {"const": "steps"},
            "items": {"type": "array", "items": {"type": "string"}},
            "current": {"type": "integer", "description": "0-based step in progress; earlier ones are done"}
        }, "required": ["type", "items"]}));
    }
    if kinds.contains(&"diagram") {
        variants.push(json!({"type": "object", "properties": {
            "type": {"const": "diagram"}
        }, "required": ["type", "nodes"], "description": "the Diagram tool's arguments, plus type"}));
    }
    ToolSpec {
        name: TOOL.into(),
        description: format!(
            "Show the user structured results instead of prose: blocks of {}. Use it when \
a shape reads faster than paragraphs: test results or options as a table, a before/after, a \
plan's progress, one line that must not be missed. Don't use it for short answers, and don't \
repeat what it shows in text. The user sees the blocks; you get a confirmation and any errors \
(fix only the blocks named).",
            kinds.join(", ")
        )
        .into(),
        schema: json!({
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "blocks": {"type": "array", "maxItems": MAX_BLOCKS, "items": {"anyOf": variants}}
            },
            "required": ["blocks"]
        }),
    }
}

pub fn run(input: &Value, cwd: &Path, weak: bool) -> Result<Output> {
    let (p, errors) = parse(input, cwd, weak);
    if p.blocks.is_empty() {
        bail!("nothing to show: {}", errors.join("; "));
    }
    let mut content = format!(
        "Shown to the user ({} block{}). Don't repeat it in text; refer to it.",
        p.blocks.len(),
        if p.blocks.len() == 1 { "" } else { "s" }
    );
    if !errors.is_empty() {
        content.push_str("\nThese blocks weren't shown:\n- ");
        content.push_str(&errors.join("\n- "));
    }
    Ok(Output {
        content,
        display: Some(p.to_text()),
        present: Some(Box::new(p)),
        ..Default::default()
    })
}

/// Parse the tool's input: every block that validates, and a note for each that doesn't
/// (`blocks[2]: …`). Diagram blocks are finished (checked against `cwd` and laid out).
pub fn parse(input: &Value, cwd: &Path, weak: bool) -> (Present, Vec<String>) {
    let mut errors = Vec::new();
    let title = input["title"].as_str().unwrap_or("").trim().to_string();
    let raw = match &input["blocks"] {
        Value::Array(a) => a.as_slice(),
        _ => {
            errors.push("`blocks` must be an array of blocks".into());
            &[]
        }
    };
    if raw.len() > MAX_BLOCKS {
        errors.push(format!(
            "only the first {MAX_BLOCKS} of {} blocks are shown",
            raw.len()
        ));
    }
    let allowed = kinds(weak);
    let mut blocks = Vec::new();
    for (i, b) in raw.iter().take(MAX_BLOCKS).enumerate() {
        let parsed = serde_json::from_value::<Block>(b.clone())
            .map_err(|e| format!("doesn't match the schema ({e})"))
            .and_then(|b| {
                if allowed.contains(&b.kind()) {
                    Ok(b)
                } else {
                    Err(format!("`{}` blocks aren't available here", b.kind()))
                }
            })
            .and_then(|b| check(b, cwd));
        match parsed {
            Ok(b) => blocks.push(b),
            Err(e) => errors.push(format!("blocks[{i}]: {e}")),
        }
    }
    (Present { title, blocks }, errors)
}

fn check(block: Block, cwd: &Path) -> Result<Block, String> {
    Ok(match block {
        Block::Table { columns, rows } => {
            if columns.is_empty() || columns.len() > MAX_COLUMNS {
                return Err(format!("a table needs 1-{MAX_COLUMNS} columns"));
            }
            if rows.is_empty() {
                return Err("a table needs at least one row".into());
            }
            if let Some(r) = rows.iter().position(|r| r.len() > columns.len()) {
                return Err(format!(
                    "row {r} has {} cells but there are {} columns",
                    rows[r].len(),
                    columns.len()
                ));
            }
            // Short rows are padded: a missing trailing cell is just empty.
            let rows = rows
                .into_iter()
                .take(MAX_ROWS)
                .map(|mut r| {
                    r.resize(columns.len(), String::new());
                    r
                })
                .collect();
            Block::Table { columns, rows }
        }
        Block::Compare { left, right } => {
            if [&left, &right]
                .iter()
                .any(|s| s.label.trim().is_empty() || s.text.trim().is_empty())
            {
                return Err("both sides need a label and text".into());
            }
            Block::Compare { left, right }
        }
        Block::Steps { items, current } => {
            if items.is_empty() || items.len() > MAX_STEPS {
                return Err(format!("steps need 1-{MAX_STEPS} items"));
            }
            if current.is_some_and(|c| c >= items.len()) {
                return Err("`current` is past the last step".into());
            }
            Block::Steps { items, current }
        }
        Block::Callout { tone, text } => {
            if text.trim().is_empty() {
                return Err("a callout needs text".into());
            }
            Block::Callout { tone, text }
        }
        Block::Diagram(mut d) => {
            d.finish(cwd);
            if d.nodes.is_empty() {
                return Err("the diagram has no nodes".into());
            }
            Block::Diagram(d)
        }
    })
}

impl Present {
    /// Plain text for the terminal and other clients that don't draw blocks.
    pub fn to_text(&self) -> String {
        let mut out = Vec::new();
        if !self.title.is_empty() {
            out.push(self.title.clone());
        }
        for b in &self.blocks {
            out.push(match b {
                Block::Table { columns, rows } => table(columns, rows),
                Block::Compare { left, right } => table(
                    &[left.label.clone(), right.label.clone()],
                    &[vec![left.text.clone(), right.text.clone()]],
                ),
                Block::Steps { items, current } => items
                    .iter()
                    .enumerate()
                    .map(|(i, s)| {
                        let mark = match current {
                            Some(c) if i < *c => "✓",
                            Some(c) if i == *c => "▸",
                            _ => "·",
                        };
                        format!("{mark} {}. {s}", i + 1)
                    })
                    .collect::<Vec<_>>()
                    .join("\n"),
                Block::Callout { tone, text } => {
                    let mark = match tone {
                        Tone::Info => "ℹ",
                        Tone::Success => "✓",
                        Tone::Warning => "!",
                        Tone::Danger => "✗",
                    };
                    format!("{mark} {text}")
                }
                Block::Diagram(d) => d.to_ascii(),
            });
        }
        out.join("\n\n")
    }
}

/// A box-drawn table. Multi-line cells are flattened; widths are in chars.
fn table(columns: &[String], rows: &[Vec<String>]) -> String {
    let flat = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
    let head: Vec<String> = columns.iter().map(|c| flat(c)).collect();
    let body: Vec<Vec<String>> = rows
        .iter()
        .map(|r| r.iter().map(|c| flat(c)).collect())
        .collect();
    let width = |i: usize| {
        std::iter::once(&head[i])
            .chain(body.iter().map(|r| &r[i]))
            .map(|s| s.chars().count())
            .max()
            .unwrap_or(0)
    };
    let widths: Vec<usize> = (0..head.len()).map(width).collect();
    let rule = |l: &str, m: &str, r: &str| {
        let segs: Vec<String> = widths.iter().map(|w| "─".repeat(w + 2)).collect();
        format!("{l}{}{r}", segs.join(m))
    };
    let line = |cells: &[String]| {
        let segs: Vec<String> = cells
            .iter()
            .zip(&widths)
            .map(|(c, w)| format!(" {c}{} ", " ".repeat(w - c.chars().count())))
            .collect();
        format!("│{}│", segs.join("│"))
    };
    let mut out = vec![rule("┌", "┬", "┐"), line(&head), rule("├", "┼", "┤")];
    out.extend(body.iter().map(|r| line(r)));
    out.push(rule("└", "┴", "┘"));
    out.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn cwd() -> &'static Path {
        Path::new(".")
    }

    #[test]
    fn bad_blocks_cost_only_themselves() {
        let input = json!({
            "title": "Tests",
            "blocks": [
                {"type": "table", "columns": ["test", "result"], "rows": [["resume", "ok"], ["crash"]]},
                {"type": "steps", "items": ["a"], "current": 3},
                {"type": "nope"},
                {"type": "callout", "tone": "danger", "text": "2 failed"}
            ]
        });
        let (p, errors) = parse(&input, cwd(), false);
        assert_eq!(p.blocks.len(), 2);
        // The short row was padded.
        assert!(matches!(&p.blocks[0], Block::Table { rows, .. } if rows[1] == ["crash", ""]));
        assert_eq!(errors.len(), 2);
        assert!(errors[0].starts_with("blocks[1]: `current`"));
        assert!(errors[1].starts_with("blocks[2]: doesn't match"));
    }

    #[test]
    fn weak_models_get_tables_and_callouts_only() {
        let input = json!({"blocks": [
            {"type": "compare", "left": {"label": "a", "text": "x"}, "right": {"label": "b", "text": "y"}},
            {"type": "callout", "text": "hi"}
        ]});
        let (p, errors) = parse(&input, cwd(), true);
        assert_eq!(p.blocks.len(), 1);
        assert_eq!(
            errors,
            ["blocks[0]: `compare` blocks aren't available here"]
        );
    }

    #[test]
    fn rows_wider_than_the_header_are_rejected() {
        let input = json!({"blocks": [{"type": "table", "columns": ["a"], "rows": [["1", "2"]]}]});
        let (p, errors) = parse(&input, cwd(), false);
        assert!(p.blocks.is_empty());
        assert_eq!(
            errors,
            ["blocks[0]: row 0 has 2 cells but there are 1 columns"]
        );
    }

    #[test]
    fn text_rendering() {
        let p = Present {
            title: "Plan".into(),
            blocks: vec![
                Block::Table {
                    columns: vec!["test".into(), "ms".into()],
                    rows: vec![vec!["resume".into(), "12".into()]],
                },
                Block::Steps {
                    items: vec!["read".into(), "fix".into(), "test".into()],
                    current: Some(1),
                },
            ],
        };
        assert_eq!(
            p.to_text(),
            "Plan\n\n\
┌────────┬────┐\n\
│ test   │ ms │\n\
├────────┼────┤\n\
│ resume │ 12 │\n\
└────────┴────┘\n\n\
✓ 1. read\n▸ 2. fix\n· 3. test"
        );
    }

    #[test]
    fn round_trips_tagged() {
        let b = Block::Callout {
            tone: Tone::Warning,
            text: "careful".into(),
        };
        let s = serde_json::to_string(&b).unwrap();
        assert_eq!(s, r#"{"type":"callout","tone":"warning","text":"careful"}"#);
        assert_eq!(serde_json::from_str::<Block>(&s).unwrap(), b);
    }
}
