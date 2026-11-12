//! `VisualGuide` and `Visualize`: interactive HTML/SVG widgets drawn inline in the transcript.
//! The guide is the design read-me the model loads once before its first widget.

use super::{Ctx, Output};
use crate::provider::ToolSpec;
use crate::widget::{MAX_CODE, Widget, lint};
use anyhow::{Result, bail};
use serde_json::{Value, json};

pub const TOOL: &str = "Visualize";
pub const GUIDE: &str = "VisualGuide";

const GUIDE_TEXT: &str = include_str!("visualize.md");

pub fn guide_spec() -> ToolSpec {
    ToolSpec {
        name: GUIDE.into(),
        description: "Returns the design guide for Visualize: theme variables, the slider/toggle/stat-tile kit, sandbox rules. \
Call it once, before your first Visualize call in a conversation. Don't mention it to the user."
            .into(),
        schema: json!({ "type": "object", "properties": {} }),
    }
}

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Show the user an interactive visual: a self-contained HTML or SVG widget (inline CSS/JS) drawn inline in the \
conversation. Use it when the user asks to see or visualize something, or to build intuition for a concept with a knob worth \
turning (physics, maths, algorithms) or data with a shape. Not for every answer. Call VisualGuide first, once per conversation. \
Make it interactive (sliders, toggles, draggable points) with stat tiles that update; colours only via CSS variables \
(var(--fg), var(--muted), var(--line), var(--c1)…var(--c8)); transparent background; no network."
            .into(),
        schema: json!({
            "type": "object",
            "properties": {
                "title": { "type": "string", "description": "Short, specific name, e.g. casimir_plate_modes" },
                "loading_messages": {
                    "type": "array", "items": { "type": "string" },
                    "description": "1-3 short lines shown while it renders"
                },
                "widget_code": { "type": "string", "description": "An HTML fragment (no <html>/<head>/<body>) or an <svg> element" }
            },
            "required": ["title", "widget_code"]
        }),
    }
}

pub fn guide(_input: &Value, ctx: &mut Ctx) -> Result<Output> {
    ctx.visual_guide = true;
    Ok(Output {
        content: GUIDE_TEXT.to_string(),
        ..Default::default()
    })
}

pub fn run(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let code = input["widget_code"]
        .as_str()
        .or_else(|| input["code"].as_str())
        .unwrap_or("");
    if code.trim().is_empty() {
        bail!("`widget_code` is empty: pass the widget's HTML fragment or <svg>.");
    }
    if code.len() > MAX_CODE {
        bail!(
            "the widget is {} KB; keep it under {} KB (compute data in JS instead of inlining it).",
            code.len() / 1000,
            MAX_CODE / 1000
        );
    }
    let title = input["title"].as_str().unwrap_or("").trim();
    let title = if title.is_empty() { "Visual" } else { title };
    let w = Widget::new(title, code);
    let notes = lint(&w.code);
    let mut content = format!(
        "The visual \"{}\" is shown to the user ({} KB). Don't describe it control by control; continue the explanation and refer to it.",
        w.title,
        w.code.len().div_ceil(1000)
    );
    if !ctx.visual_guide {
        content.push_str(
            "\nYou haven't read VisualGuide this conversation: call it before your next visual.",
        );
        ctx.visual_guide = true;
    }
    if !notes.is_empty() {
        content.push_str("\nFix next time:\n- ");
        content.push_str(&notes.join("\n- "));
    }
    Ok(Output {
        content,
        display: Some(format!("Made a visual: {}", w.title)),
        widget: Some(Box::new(w)),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guide_covers_the_essentials() {
        for needle in [
            "var(--fg)",
            "transparent",
            "tiles",
            "prefers-reduced-motion",
            "360 px",
            "cdn.jsdelivr.net",
        ] {
            assert!(GUIDE_TEXT.contains(needle), "guide lacks {needle}");
        }
    }
}
