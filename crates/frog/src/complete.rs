//! Tab completion for the prompt: slash commands, `/model` specs, `/mode` names and `@path`
//! mentions.

use frog_engine::models::ModelEntry;
use reedline::{Completer, CompletionResult, Span, Suggestion};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// Files walked for `@` completion; a huge tree just completes less.
const MAX_FILES: usize = 20_000;
const MAX_SHOWN: usize = 12;

pub const COMMANDS: &[(&str, &str)] = &[
    ("/model", "switch model"),
    ("/mode", "default · accept-edits · auto · yolo"),
    ("/compact", "summarize to free context"),
    ("/clear", "start a fresh conversation"),
    ("/context", "show context usage"),
    ("/todos", "show the todo list"),
    ("/remember", "keep a note for this project"),
    ("/forget", "delete a note"),
    ("/memory", "list notes"),
    ("/recall", "search notes and past sessions"),
    ("/help", "list commands"),
    ("/exit", "quit"),
];

const MODES: &[(&str, &str)] = &[
    ("default", "ask before edits and commands"),
    ("accept-edits", "edits run, commands ask"),
    ("auto", "a classifier decides"),
    ("yolo", "nothing asks"),
];

/// Models are listed in the background at startup, since probing servers takes seconds.
pub type Models = Arc<Mutex<Vec<ModelEntry>>>;

pub struct FrogCompleter {
    cwd: PathBuf,
    files: Option<Vec<String>>,
    models: Models,
}

impl FrogCompleter {
    pub fn new(cwd: PathBuf, models: Models) -> Self {
        Self {
            cwd,
            files: None,
            models,
        }
    }

    /// Walked on first use, honoring .gitignore.
    fn files(&mut self) -> &[String] {
        let cwd = &self.cwd;
        self.files.get_or_insert_with(|| walk(cwd))
    }
}

fn walk(cwd: &Path) -> Vec<String> {
    let mut out: Vec<String> = ignore::WalkBuilder::new(cwd)
        .build()
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_some_and(|t| t.is_file()))
        .filter_map(|e| {
            let rel = e.path().strip_prefix(cwd).ok()?;
            Some(rel.to_string_lossy().replace('\\', "/"))
        })
        .take(MAX_FILES)
        .collect();
    out.sort();
    out
}

/// Prefix matches first, then paths whose file name starts with the query, then any substring.
fn rank_paths<'a>(files: &'a [String], q: &str) -> Vec<&'a String> {
    let q = q.to_lowercase();
    let score = |f: &str| {
        let f = f.to_lowercase();
        let name = f.rsplit('/').next().unwrap_or(&f);
        if f.starts_with(&q) {
            Some(0)
        } else if name.starts_with(&q) {
            Some(1)
        } else if f.contains(&q) {
            Some(2)
        } else {
            None
        }
    };
    let mut hits: Vec<(u8, &String)> = files
        .iter()
        .filter_map(|f| score(f).map(|s| (s, f)))
        .collect();
    hits.sort_by_key(|(s, f)| (*s, f.len()));
    hits.into_iter().take(MAX_SHOWN).map(|(_, f)| f).collect()
}

fn suggestion(value: String, description: Option<String>, span: Span) -> Suggestion {
    Suggestion {
        value,
        description,
        span,
        append_whitespace: true,
        ..Default::default()
    }
}

impl Completer for FrogCompleter {
    fn complete(&mut self, line: &str, pos: usize) -> CompletionResult {
        CompletionResult::fresh(self.suggest(line, pos))
    }
}

impl FrogCompleter {
    fn suggest(&mut self, line: &str, pos: usize) -> Vec<Suggestion> {
        let before = &line[..pos];
        let start = before.rfind(char::is_whitespace).map_or(0, |i| i + 1);
        let word = &before[start..];
        let span = Span::new(start, pos);

        if let Some(q) = word.strip_prefix('@') {
            return rank_paths(self.files(), q)
                .into_iter()
                .map(|f| suggestion(format!("@{f}"), None, span))
                .collect();
        }
        if start == 0 && word.starts_with('/') {
            return COMMANDS
                .iter()
                .filter(|(c, _)| c.starts_with(word))
                .map(|(c, d)| suggestion((*c).into(), Some((*d).into()), span))
                .collect();
        }
        let cmd = before.split_whitespace().next().unwrap_or("");
        if cmd == "/mode" && start > 0 {
            return MODES
                .iter()
                .filter(|(m, _)| m.starts_with(word))
                .map(|(m, d)| suggestion((*m).into(), Some((*d).into()), span))
                .collect();
        }
        if cmd == "/model" && start > 0 {
            let models = self.models.lock().unwrap();
            let q = word.to_lowercase();
            let mut hits: Vec<&ModelEntry> = models
                .iter()
                .filter(|m| m.spec.to_lowercase().contains(&q))
                .collect();
            // Local models first: they're what frog is for.
            hits.sort_by_key(|m| matches!(m.source, "remote" | "server"));
            return hits
                .into_iter()
                .take(MAX_SHOWN * 2)
                .map(|m| suggestion(m.spec.clone(), Some(model_note(m)), span))
                .collect();
        }
        Vec::new()
    }
}

/// `strong · native · ollama`
fn model_note(m: &ModelEntry) -> String {
    let tier = format!("{:?}", m.tier).to_lowercase();
    let mode = format!("{:?}", m.tool_mode).to_lowercase();
    let probed = if m.caps.is_some() {
        ""
    } else {
        " · not probed"
    };
    format!("{tier} · {mode} · {}{probed}", m.source)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn completer(files: &[&str]) -> FrogCompleter {
        let mut c = FrogCompleter::new(PathBuf::from("/nowhere"), Models::default());
        c.files = Some(files.iter().map(|s| s.to_string()).collect());
        c
    }

    fn values(s: Vec<Suggestion>) -> Vec<String> {
        s.into_iter().map(|s| s.value).collect()
    }

    #[test]
    fn slash_completes_commands_only_at_start() {
        let mut c = completer(&[]);
        assert_eq!(values(c.suggest("/mo", 3)), ["/model", "/mode"]);
        assert!(c.suggest("fix /mo", 7).is_empty());
    }

    #[test]
    fn mode_completes_names() {
        let mut c = completer(&[]);
        let s = c.suggest("/mode a", 7);
        assert_eq!(values(s.clone()), ["accept-edits", "auto"]);
        assert_eq!(s[0].span, Span::new(6, 7));
    }

    #[test]
    fn at_ranks_prefix_then_name_then_substring() {
        let mut c = completer(&[
            "src/render.rs",
            "readme.md",
            "crates/x/src/replay.rs",
            "a/prerender",
        ]);
        assert_eq!(
            values(c.suggest("look at @re", 11)),
            [
                "@readme.md",
                "@src/render.rs",
                "@crates/x/src/replay.rs",
                "@a/prerender"
            ]
        );
    }
}
