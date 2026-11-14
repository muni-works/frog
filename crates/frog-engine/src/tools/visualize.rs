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
turning (physics, maths, algorithms) or data with a shape. Not for every answer. Call VisualGuide first, once per conversation \
(skip it and the guide comes back with your first result). \
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
    // The guide loads itself on first use. Small models skip the read-me and paint white
    // static boxes, so a widget that breaks its rules still costs one retry (with the guide
    // in hand, no separate VisualGuide call). One that follows them is shown: most refusals
    // in the session logs were widgets already written to the kit, in a session whose guide
    // call was before a restart.
    let unguided = !std::mem::replace(&mut ctx.visual_guide, true);
    if unguided && !notes.is_empty() {
        bail!(
            "not shown: the widget breaks the Visualize guide, which you hadn't loaded:\n- {}\nHere is the guide (no need to call VisualGuide now). Call Visualize again with the widget rewritten to follow it.\n\n{GUIDE_TEXT}",
            notes.join("\n- ")
        );
    }
    let mut content = format!(
        "The visual \"{}\" is shown to the user ({} KB). Don't describe it control by control; continue the explanation and refer to it.",
        w.title,
        w.code.len().div_ceil(1000)
    );
    if !notes.is_empty() {
        content.push_str("\nFix next time:\n- ");
        content.push_str(&notes.join("\n- "));
    }
    if unguided {
        content.push_str("\n\nYou hadn't loaded the design guide; here it is for your next visual (no need to call VisualGuide):\n\n");
        content.push_str(GUIDE_TEXT);
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

    const GOOD: &str = "<div class=\"row\"><input type=\"range\" id=\"v\"></div><script>1</script>";

    /// Visualize before VisualGuide used to be refused outright (5 of a day's calls).
    #[test]
    fn the_first_visual_is_shown_without_the_guide_and_brings_it_along() {
        let mut ctx = Ctx::new(std::env::temp_dir());
        let input = json!({ "title": "t", "widget_code": GOOD });
        let out = run(&input, &mut ctx).unwrap();
        assert!(out.widget.is_some());
        assert!(
            out.content.contains("cdn.jsdelivr.net"),
            "the guide didn't come along"
        );
        // Once only.
        let out = run(&input, &mut ctx).unwrap();
        assert!(!out.content.contains("cdn.jsdelivr.net"));
    }

    #[test]
    fn an_unguided_visual_that_breaks_the_rules_gets_the_guide_instead_of_a_bare_refusal() {
        let mut ctx = Ctx::new(std::env::temp_dir());
        let bad = json!({ "title": "t", "widget_code": "<html><body>hi</body></html>" });
        let Err(err) = run(&bad, &mut ctx) else {
            panic!("a whole document was shown unguided")
        };
        let err = err.to_string();
        assert!(err.contains("Send a fragment"), "{err}");
        assert!(
            err.contains("cdn.jsdelivr.net"),
            "the guide isn't in the refusal: {err}"
        );
        // The retry needs no VisualGuide call, and after the guide a lint is a note, not a refusal.
        assert!(run(&json!({ "title": "t", "widget_code": GOOD }), &mut ctx).is_ok());
        assert!(run(&bad, &mut ctx).is_ok());
    }

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
