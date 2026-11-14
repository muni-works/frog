//! Built-in tools left out of the default tool list. Every call re-sends each listed tool's
//! description and schema, and these are rarely used (measured over real session logs), so a
//! plain coding call carries only the core set. The system prompt names them in one line each
//! ([`catalog`]); calling one by name, or loading it with `ToolSearch`, appends it to the tool
//! list for the rest of the session (after everything else, so the cached prefix holds).

use crate::provider::ToolSpec;

/// Name, then the line the catalog shows: its main arguments and when to reach for it.
pub const DEFERRED: &[(&str, &str)] = &[
    (
        "Present",
        "Present(blocks, title?): results as table/chart/stats/steps/callout/compare/actions blocks when a shape reads faster than prose",
    ),
    (
        "VisualGuide",
        "VisualGuide(): the design guide; call once before the first Visualize",
    ),
    (
        "Visualize",
        "Visualize(title, widget_code): an interactive HTML/SVG widget inline, when a picture explains better than prose (a flow, architecture, a concept with a knob, data)",
    ),
    (
        "Image",
        "Image(prompt, size?, count?): generate images, only when the user asks",
    ),
    (
        "Screenshot",
        "Screenshot(url, output_path?): render a URL or local HTML/SVG file to PNG",
    ),
    (
        "Compare",
        "Compare(target, actual, notes?): score a rendered PNG against a target image",
    ),
    (
        "CodeMap",
        "CodeMap(path?): the project's module/import dependency map, shown as a diagram",
    ),
    (
        "Docs",
        "Docs(package?, query?): API docs for the dependency version installed here; prefer it to web search for library APIs",
    ),
    (
        "Notify",
        "Notify(body, urgency?=attention|done|silent): reach the person outside the transcript when they aren't watching (long job done, breakage, decision needed); never for ordinary replies",
    ),
    (
        "Next",
        "Next(text, act?): call last to suggest the user's obvious next message, e.g. \"commit this\"",
    ),
    (
        "Recall",
        "Recall(query?, file?): search your notes and past sessions in this project",
    ),
    (
        "UseFolder",
        "UseFolder(path): move this conversation into another folder (the user approves)",
    ),
    (
        "Models",
        "Models(): models runnable now, with cost and credential status; before StartSession on a model you haven't used",
    ),
    (
        "Terminal",
        "Terminal(action=run|read|type|open, command?, text?, id?): a persistent shell pane the user sees, for dev servers, watchers, REPLs",
    ),
    (
        "Preview",
        "Preview(action=open|read|screenshot|console|click|type|navigate|eval, url?, selector?, text?, js?): an in-app browser pane on what you're building",
    ),
    ("ListSessions", "ListSessions(state?, cwd_prefix?, fields?)"),
    ("SessionStatus", "SessionStatus(id)"),
    ("ReadSession", "ReadSession(id, last_n?, kinds?)"),
    ("StopSession", "StopSession(id, clear_queue?)"),
    ("ArchiveSession", "ArchiveSession(id)"),
    ("UnarchiveSession", "UnarchiveSession(id)"),
    ("RenameSession", "RenameSession(id, title)"),
    ("MoveSession", "MoveSession(id, parent?)"),
    ("SetSessionMode", "SetSessionMode(id, mode)"),
    ("SetSessionModel", "SetSessionModel(id, model)"),
    ("ListApprovals", "ListApprovals()"),
    (
        "ResolveDelegated",
        "ResolveDelegated(approval_id, decision, note?)",
    ),
];

pub fn is_deferred(name: &str) -> bool {
    DEFERRED.iter().any(|(n, _)| *n == name)
}

/// The system prompt's list of the deferred tools this session has (`available`, in table
/// order so the text never depends on load order or spec order).
pub fn catalog(available: &[ToolSpec]) -> String {
    let lines: Vec<&str> = DEFERRED
        .iter()
        .filter(|(n, _)| available.iter().any(|s| s.name == *n))
        .map(|(_, line)| *line)
        .collect();
    if lines.is_empty() {
        return String::new();
    }
    format!(
        "\n\n# More tools\nNot in your tool list until used: call one by name with the arguments shown and it loads (a wrong call returns its full schema), or load several with `{}` `select:A,B`.\n- {}\n",
        crate::mcp::SEARCH_TOOL,
        lines.join("\n- ")
    )
}

/// Deferred tools a `ToolSearch` query picks: `select:a,b` by name, else by keyword.
pub fn pick(available: &[ToolSpec], query: &str) -> Vec<String> {
    let q = query.trim().to_lowercase();
    if let Some(names) = q.strip_prefix("select:") {
        let want: Vec<&str> = names.split(',').map(str::trim).collect();
        return available
            .iter()
            .filter(|s| want.contains(&s.name.to_lowercase().as_str()))
            .map(|s| s.name.to_string())
            .collect();
    }
    let words: Vec<&str> = q.split_whitespace().collect();
    let mut scored: Vec<(usize, &ToolSpec)> = available
        .iter()
        .map(|s| {
            let (name, desc) = (s.name.to_lowercase(), s.description.to_lowercase());
            let score = words
                .iter()
                .map(|w| 3 * name.contains(w) as usize + desc.contains(w) as usize)
                .sum();
            (score, s)
        })
        .filter(|(score, _)| *score > 0)
        .collect();
    scored.sort_by_key(|s| std::cmp::Reverse(s.0));
    scored
        .into_iter()
        .take(5)
        .map(|(_, s)| s.name.to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(name: &'static str, desc: &'static str) -> ToolSpec {
        ToolSpec {
            name: name.into(),
            description: desc.into(),
            schema: serde_json::json!({"type": "object"}),
        }
    }

    #[test]
    fn select_and_keywords_pick_deferred_tools() {
        let a = [
            spec("Docs", "Look up a dependency's API"),
            spec("Notify", "Tell the person"),
        ];
        assert_eq!(pick(&a, "select:docs, Notify"), vec!["Docs", "Notify"]);
        assert_eq!(pick(&a, "dependency api"), vec!["Docs"]);
        assert!(pick(&a, "nothing").is_empty());
    }

    #[test]
    fn the_catalog_lists_only_available_tools_in_table_order() {
        let c = catalog(&[spec("Notify", ""), spec("Docs", "")]);
        assert!(
            c.find("- Docs(").unwrap() < c.find("- Notify(").unwrap(),
            "{c}"
        );
        assert!(!c.contains("Present("));
        assert!(catalog(&[]).is_empty());
    }
}
