//! `CodeMap`: the project's structure as a diagram. (The model-facing `Diagram` tool is gone:
//! boxes-and-arrows are drawn with `Visualize` now; old sessions still carry their diagrams.)
use super::{Ctx, Output};
use crate::provider::ToolSpec;
use anyhow::{Result, bail};
use serde_json::{Value, json};

pub fn map_spec() -> ToolSpec {
    ToolSpec {
        name: "CodeMap".into(),
        description: "Map the project's structure from its code: which files or directories \
depend on which (Rust modules and crates, TS/JS and Python imports, Go packages, Swift type \
references), with recently changed areas marked [hot]. Shows the user a diagram and returns a \
compact dependency list to you. Use it to get oriented in an unfamiliar codebase or when the user \
asks how the project is organized. Pass `path` to map one subdirectory in more detail."
            .into(),
        schema: json!({
            "type": "object",
            "properties": {
                "path": { "type": "string", "description": "subdirectory to map (default: the whole project)" },
                "max_nodes": { "type": "integer", "description": "most boxes before files collapse into directories (default 30)" }
            }
        }),
    }
}

pub fn run_map(input: &Value, ctx: &mut Ctx) -> Result<Output> {
    let focus = input["path"]
        .as_str()
        .map(str::trim)
        .filter(|p| !p.is_empty() && *p != ".")
        .map(std::path::PathBuf::from);
    if let Some(f) = &focus
        && !ctx.root.join(f).is_dir()
    {
        bail!("`{}` isn't a directory in the project", f.display());
    }
    let opts = crate::codemap::Options {
        focus,
        max_nodes: super::int_arg(input, "max_nodes")
            .map(|n| n.clamp(5, 60) as usize)
            .unwrap_or(30),
    };
    let (mut d, summary) = crate::codemap::map_with_summary(&ctx.root, &opts);
    if d.nodes.is_empty() {
        return Ok(Output::text(
            "No source files with dependencies between them were found.",
        ));
    }
    d.finish(&ctx.root);
    let summary = super::truncate_middle(&summary, 8000);
    Ok(Output {
        content: format!("The map is shown to the user.\n{summary}"),
        // Box art only reads for small maps; bigger ones get the list in the terminal.
        display: Some(if d.nodes.len() <= 12 {
            d.to_ascii()
        } else {
            summary
        }),
        diff: None,
        diagram: Some(Box::new(d)),
        ..Default::default()
    })
}
