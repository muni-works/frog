//! Project files named in a prompt ("calc.py has a bug in sub(); fix it."), and replies that ask
//! the user for them. Small models often treat a bare filename as something they can't see and
//! ask the user to paste it, even with Read in the tool list; the engine inlines or points at
//! the files up front, and nudges a model that asks anyway.

use regex::Regex;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

/// Files walked when looking a bare name up in the project; past this the lookup gives up.
const MAX_INDEX: usize = 20_000;

/// A word that looks like a file: a path with a slash, or a name with an extension.
static FILE_LIKE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?:[A-Za-z0-9_+.\-]+/)*[A-Za-z0-9_+.\-]*[A-Za-z0-9_\-]\.[A-Za-z][A-Za-z0-9]{0,9}$|^(?:[A-Za-z0-9_+.\-]+/)+[A-Za-z0-9_+.\-]+$")
        .unwrap()
});

/// Asking the user to hand something over ("Could you please share …", "Please paste …").
static ASKS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(?:could you|can you|would you|will you|please|need you to|kindly)\b[^?!.]{0,20}?\b(?:share|paste|provide|send|upload|show me|copy|give me)\b")
        .unwrap()
});

/// What's asked for is code or a file's contents…
static CODE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(?:contents?|source|code|snippet|implementation|definition)\b").unwrap()
});

/// …or a file, but not its path or name (a location, not contents).
static FILE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\bfiles?\b(\s+(?:path|name|location)s?\b)?").unwrap());

/// Claiming it can't see the project ("I can't directly access your files").
static NO_ACCESS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(?:can'?t|can’t|cannot|can not|unable to|(?:do not|don'?t|don’t) have (?:the ability|access|a way) to)\s+(?:directly\s+)?(?:access|read|open|see|view|look at|browse|inspect)\s+(?:(?:your|the|any|local|its|this)\s+)*(?:files?|code(?:base)?|project|repo(?:sitory)?|file ?system|director(?:y|ies)|source)\b|\b(?:do not|don'?t|don’t) have access to (?:(?:your|the|any|local)\s+)*(?:files?|code(?:base)?|project|repo(?:sitory)?|file ?system)\b")
        .unwrap()
});

/// Words in `text` that look like file names or relative paths, in order, without repeats.
/// URLs, `@` mentions (inlined separately), home and parent paths are left out.
pub fn candidates(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for word in text.split_whitespace() {
        let w = word.trim_start_matches(['`', '"', '\'', '(', '[', '<', '*', '“', '‘']);
        if w.starts_with(['@', '~']) || w.contains("://") || w.starts_with("www.") {
            continue;
        }
        let mut w = w.trim_end_matches([
            '`', '"', '\'', ')', ']', '>', ',', ';', '!', '?', '*', '”', '’', ':', '.',
        ]);
        w = w.strip_suffix("'s").unwrap_or(w);
        // `src/app.rs:12:5` names the file.
        while let Some((head, tail)) = w.rsplit_once(':') {
            if tail.is_empty() || !tail.bytes().all(|b| b.is_ascii_digit()) {
                break;
            }
            w = head;
        }
        let w = w.strip_prefix("./").unwrap_or(w);
        if !FILE_LIKE.is_match(w) || w.split('/').any(|seg| seg == "..") {
            continue;
        }
        if !out.iter().any(|o| o == w) {
            out.push(w.to_string());
        }
    }
    out
}

/// The project's files (relative, `/`-separated), honoring ignore files. `None` if the project
/// is too big to index.
fn index(root: &Path) -> Option<Vec<String>> {
    let mut out = Vec::new();
    for e in ignore::WalkBuilder::new(root)
        .hidden(true)
        .build()
        .flatten()
    {
        if !e.file_type().is_some_and(|t| t.is_file()) {
            continue;
        }
        if out.len() >= MAX_INDEX {
            return None;
        }
        if let Ok(rel) = e.path().strip_prefix(root) {
            out.push(rel.to_string_lossy().replace('\\', "/"));
        }
    }
    Some(out)
}

/// `name` as a file under `root`: the exact relative path if it exists, else the one indexed
/// file whose path ends with it. Several matches resolve to nothing rather than a guess.
fn resolve(root: &Path, name: &str, idx: &mut Option<Option<Vec<String>>>) -> Option<PathBuf> {
    let direct = root.join(name);
    if direct.is_file() {
        return Some(direct);
    }
    let files = idx.get_or_insert_with(|| index(root)).as_ref()?;
    let suffix = format!("/{name}");
    let mut hits = files.iter().filter(|f| f.ends_with(&suffix));
    let hit = hits.next()?;
    hits.next().is_none().then(|| root.join(hit))
}

/// The files under `root` that `text` names, in order of first mention.
pub fn named(text: &str, root: &Path) -> Vec<PathBuf> {
    let canon_root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let mut idx = None;
    let mut out: Vec<PathBuf> = Vec::new();
    for name in candidates(text) {
        let Some(path) = resolve(root, &name, &mut idx) else {
            continue;
        };
        // Symlinks out of the project don't count.
        let inside = path
            .canonicalize()
            .is_ok_and(|p| p.starts_with(&canon_root));
        if inside && !out.contains(&path) {
            out.push(path);
        }
    }
    out
}

/// A reply that asks the user for code or a file instead of reading it, or says it can't.
pub fn asks_for_files(reply: &str) -> bool {
    claims_no_access(reply)
        || ASKS.find_iter(reply).any(|m| {
            // The rest of the request: to the end of the sentence, or through a list of asks.
            let rest = &reply[m.end()..];
            let end = if rest.trim_start().starts_with(':') {
                rest.len().min(300)
            } else {
                rest.find(['?', '!', '.', '\n']).unwrap_or(rest.len())
            };
            let rest = &rest[..rest.floor_char_boundary(end)];
            CODE.is_match(rest) || FILE.captures_iter(rest).any(|c| c.get(1).is_none())
        })
}

/// A reply that says the model can't see the project's files.
pub fn claims_no_access(reply: &str) -> bool {
    NO_ACCESS.is_match(reply)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "frog-named-files-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        for f in [
            "calc.py",
            "src/app.rs",
            "src/main.rs",
            "tools/main.rs",
            "docs/guide.md",
        ] {
            let p = dir.join(f);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, "x\n").unwrap();
        }
        dir
    }

    fn rel(root: &Path, paths: Vec<PathBuf>) -> Vec<String> {
        paths
            .iter()
            .map(|p| p.strip_prefix(root).unwrap().to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn picks_out_file_like_words() {
        assert_eq!(
            candidates("calc.py has a bug in sub(); fix it."),
            ["calc.py"]
        );
        assert_eq!(
            candidates("see `src/app.rs:12`, (docs/guide.md) and ./calc.py's tests"),
            ["src/app.rs", "docs/guide.md", "calc.py"]
        );
        assert!(
            candidates(
                "read https://example.com/a.py and www.site.com, @calc.py, ~/x.py, ../up.py"
            )
            .is_empty()
        );
        assert!(candidates("call sub() or self.value() for 1.2.3").is_empty());
    }

    #[test]
    fn resolves_unique_names_and_skips_ambiguous_or_missing_ones() {
        let root = project();
        assert_eq!(
            rel(&root, named("calc.py has a bug in sub(); fix it.", &root)),
            ["calc.py"]
        );
        // A bare name found once in the index.
        assert_eq!(
            rel(&root, named("what does `app.rs` do?", &root)),
            ["src/app.rs"]
        );
        assert_eq!(rel(&root, named("open guide.md", &root)), ["docs/guide.md"]);
        // Two main.rs files: no guessing, but the full path works.
        assert!(named("fix main.rs", &root).is_empty());
        assert_eq!(rel(&root, named("fix src/main.rs", &root)), ["src/main.rs"]);
        assert!(named("nope.py and missing/dir.rs", &root).is_empty());
        assert!(named("see https://x.dev/calc.py", &root).is_empty());
        // Repeats collapse.
        assert_eq!(
            rel(&root, named("calc.py vs ./calc.py", &root)),
            ["calc.py"]
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn spots_requests_for_file_contents() {
        for yes in [
            "Could you please share the contents of calc.py?",
            "Please paste the code for sub() so I can take a look.",
            "Can you provide the source of calc.py, especially the sub() function?",
            "I'm unable to access your files directly.",
            "Since I can't directly look at the code, here's a guess.",
            "I don't have access to your project's files.",
            "I do not have the ability to read files on your machine.",
            "Can you show me the file?",
            "Could you provide:\n1. The file name of the calculator module?\n2. The current implementation of the `sub()` function?",
        ] {
            assert!(asks_for_files(yes), "{yes}");
        }
        for no in [
            "Fixed: sub() now returns a - b.",
            "Could you share more details about the expected behavior?",
            "Can you paste the full error output?",
            "Please provide the file path you want me to change.",
            "I can't reproduce the failure; the tests pass.",
            "The file has been updated. Run the tests to confirm.",
            "Paste the following code into calc.py to add a mul() helper.",
            "Could you share more details? The code looks fine to me.",
        ] {
            assert!(!asks_for_files(no), "{no}");
        }
    }
}
