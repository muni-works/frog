//! Replay calls that asked (in auto mode, or as #72's resolved prompts) through
//! the new provenance layer and report BEFORE/AFTER ask counts by category.
//!
//! ```sh
//! cargo run --example replay_scope -- asks.json
//! ```
//!
//! `asks.json` is a list of `{session, cwd, reason, name, input, set?}`: every
//! call that asked, with its full input and the session's checkout as root.
//! Before = they all asked. After = what still asks once the new layers run,
//! applied exactly as `engine::permit` does: the read-only parser, then
//! (Bash) no credentials + no hard rule + `routine` + `own_scope`, or
//! (Write/Edit) `path_in_own_scope`. `created` simulates provenance: the temp
//! dirs this session was first to name, in calls before this one.

use serde_json::{Value, json};
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

#[derive(serde::Deserialize)]
struct Ask {
    cwd: Option<String>,
    name: String,
    input: Value,
    set: Option<String>,
    /// Temp dirs this session introduced before this call (its provenance).
    #[serde(default)]
    created: Vec<PathBuf>,
}

/// NECESSARY: an ask that must stay one. SKITTISH: an ask the data says was routine.
fn category(name: &str, input: &Value, root: &Path) -> &'static str {
    let cmd = input["command"].as_str().unwrap_or("");
    match name {
        "Bash" | "Terminal" => {
            if frog_engine::shell::touches_credentials(cmd) {
                "NECESSARY: credentials"
            } else if let Some(why) =
                frog_engine::auto::hard_rule("Bash", &json!({"command": cmd}), root)
            {
                match why {
                    "pushes to a remote" | "publishes" => "NECESSARY: push/publish",
                    _ => "NECESSARY: destructive/system",
                }
            } else if frog_engine::shell::read_only(cmd) {
                // Read-only commands (reads outside included) already ran unasked on
                // main's layer 1; these asked only because an older engine build missed them.
                "SKITTISH: read-only"
            } else if frog_engine::approval::paths(cmd, root).iter().any(|p| {
                !p.starts_with(root) && !p.starts_with("/private/tmp") && !p.starts_with("/tmp")
            }) {
                "NECESSARY: outside project"
            } else if frog_engine::approval::routine(cmd) {
                "SKITTISH: build/test own dirs"
            } else {
                "GRAY: unknown program in scope"
            }
        }
        "Write" | "Edit" => {
            let p = Path::new(input["file_path"].as_str().unwrap_or(""));
            let s = p.to_string_lossy();
            let nested = s.strip_prefix(root.to_string_lossy().as_ref()).is_some_and(|rest| {
                rest.contains("/.frog/worktrees/") || rest.contains("/.claude/worktrees/")
            });
            if nested {
                "NECESSARY: another checkout"
            } else if p.starts_with(root) || p.is_relative() {
                "MODE: in-project edit (non-auto)"
            } else if p.starts_with("/private/tmp") || p.starts_with("/tmp") {
                "SKITTISH: own tmp write"
            } else {
                "NECESSARY: outside project"
            }
        }
        _ if name.starts_with("mcp__") => {
            if frog_engine::auto::read_tool(name, input) {
                "SKITTISH: mcp read verb"
            } else {
                "NECESSARY: mcp write/action"
            }
        }
        "WebFetch" | "WebSearch" => {
            if name == "WebSearch"
                || frog_engine::tools::web::public_host(input["url"].as_str().unwrap_or(""))
            {
                "SKITTISH: public web read"
            } else {
                "NECESSARY: non-public fetch"
            }
        }
        _ => "OTHER: non-shell tool",
    }
}

/// Which new layer lets this call run without asking, if any.
fn now_allowed(
    name: &str,
    input: &Value,
    root: &Path,
    created: &HashSet<PathBuf>,
) -> Option<&'static str> {
    match name {
        "Bash" => {
            let cmd = input["command"].as_str().unwrap_or("").trim();
            if frog_engine::shell::touches_credentials(cmd) {
                return None;
            }
            if frog_engine::shell::read_only(cmd) {
                return Some(if new_parser_program(cmd) { "parser (new)" } else { "parser (main)" });
            }
            let gate = frog_engine::auto::hard_rule("Bash", input, root).is_none()
                && frog_engine::approval::routine(cmd)
                && frog_engine::approval::own_scope(cmd, root, root, created);
            gate.then_some("provenance")
        }
        "Write" | "Edit" => {
            let p = frog_engine::approval::normalize(Path::new(
                input["file_path"].as_str().unwrap_or(""),
            ));
            (!p.starts_with(root) && frog_engine::approval::path_in_own_scope(&p, root, created))
                .then_some("provenance")
        }
        _ if name.starts_with("mcp__") => {
            frog_engine::auto::read_tool(name, input).then_some("mcp-read")
        }
        "WebFetch" => frog_engine::tools::web::public_host(input["url"].as_str().unwrap_or(""))
            .then_some("web-read"),
        "WebSearch" => Some("web-read"),
        _ => None,
    }
}

/// Whether the read-only parser passes `cmd` only thanks to this change's
/// additions; otherwise main's layer 1 already ran it.
fn new_parser_program(cmd: &str) -> bool {
    frog_engine::shell::segments(cmd).unwrap_or_default().iter().any(|s| {
        // pgrep with -lf has a path-ish arg that the old parser wouldn't pass; the
        // new one does. `ls` was already allowed by main.
        matches!(frog_engine::approval::program(s).as_str(), "pgrep")
    })
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: replay_scope asks.json");
    let asks: Vec<Ask> = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let mut table: BTreeMap<(String, &str), (usize, usize)> = BTreeMap::new();
    let mut flips: Vec<(String, &str, &str, String)> = Vec::new();
    for a in &asks {
        let root = frog_engine::approval::normalize(Path::new(
            a.cwd.as_deref().unwrap_or("/nonexistent"),
        ));
        let set = a.set.clone().unwrap_or_else(|| "today".into());
        let created: HashSet<PathBuf> = a.created.iter().map(|p| frog_engine::approval::normalize(p)).collect();
        let cat = category(&a.name, &a.input, &root);
        let verdict = now_allowed(&a.name, &a.input, &root, &created);
        // Already allowed on main (layer 1 from #72): not an ask today's engine makes.
        if verdict == Some("parser (main)") {
            continue;
        }
        let row = table.entry((set.clone(), cat)).or_default();
        row.0 += 1;
        match verdict {
            Some(layer) => {
                let what = a.input["command"]
                    .as_str()
                    .or(a.input["file_path"].as_str())
                    .unwrap_or("");
                let short: String = what.replace('\n', "\\n").chars().take(90).collect();
                flips.push((set, cat, layer, short));
            }
            None => row.1 += 1,
        }
    }
    println!("{:<6} {:<34} {:>6} {:>6}", "set", "category", "before", "after");
    let (mut b, mut af) = (0, 0);
    for ((set, cat), (before, after)) in &table {
        println!("{set:<6} {cat:<34} {before:>6} {after:>6}");
        b += before;
        af += after;
    }
    println!(
        "{:<6} {:<34} {b:>6} {af:>6}  (-{}%)",
        "all",
        "TOTAL",
        100 * (b - af) / b.max(1)
    );
    let bad: Vec<_> = flips.iter().filter(|f| !f.1.starts_with("SKITTISH")).collect();
    println!(
        "\nnewly allowed: {} (non-skittish among them: {})",
        flips.len(),
        bad.len()
    );
    for (set, cat, layer, what) in &bad {
        println!("  !! [{set}] {cat} via {layer}: {what}");
    }
    if std::env::var_os("VERBOSE").is_some() {
        for (set, cat, layer, what) in &flips {
            println!("  [{set}] {cat} via {layer}: {what}");
        }
    }
    if let Some(want) = std::env::var_os("STILL") {
        let want = want.to_string_lossy().to_string();
        for a in &asks {
            let root = frog_engine::approval::normalize(Path::new(a.cwd.as_deref().unwrap_or("/nonexistent")));
            let created: HashSet<PathBuf> = a.created.iter().map(|p| frog_engine::approval::normalize(p)).collect();
            if category(&a.name, &a.input, &root).contains(want.as_str())
                && now_allowed(&a.name, &a.input, &root, &created).is_none()
            {
                let what = a.input["command"].as_str().or(a.input["file_path"].as_str()).unwrap_or("");
                let seg = if !frog_engine::approval::routine(what) {
                    frog_engine::shell::segments(what)
                        .and_then(|v| v.into_iter().find(|s| !frog_engine::approval::routine(s)))
                        .unwrap_or_else(|| "(unparsable)".into())
                } else {
                    // routine but out of scope: show the first path that isn't ours
                    frog_engine::approval::paths(what, &root).first()
                        .map(|p| format!("path: {}", p.display()))
                        .unwrap_or_else(|| "(no paths)".into())
                };
                println!("  still: {} || first non-routine: {}", what.replace('\n', "\\n").chars().take(70).collect::<String>(), seg.chars().take(70).collect::<String>());
            }
        }
    }
}
