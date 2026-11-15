//! A ranked repo map for small models: the project's files most likely to matter, one line
//! each with their top-level symbols, pushed into the system prompt so a model that can't
//! search well still knows where things are (Aider's idea, budgeted like everything else).
//!
//! Files rank by mention in the user's message, edits earlier this session, recent git churn
//! and fan-in (how many files reference them, from the code map's graph). Symbols come from
//! per-language regexes and are cached per project on disk by mtime, so a rebuild between
//! turns is cheap. The map is only rebuilt between turns, and only when files changed or the
//! user named a file it doesn't show, so the prompt prefix (and the server's cache) holds.

use crate::harness::Tier;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::LazyLock;

/// The cache file's name under the project's memory folder.
pub const CACHE_FILE: &str = "repomap.json";
/// The most files in the map.
const MAX_LINES: usize = 60;
/// Commits of history that count as churn.
const CHURN_COMMITS: usize = 200;

/// Characters of system prompt the map may use: about 600 tokens for small models, 1.5k for
/// mid-size ones, and none for large models, which can Glob and Grep for themselves.
pub fn budget(tier: Tier) -> usize {
    match tier {
        Tier::Weak => 2_100,
        Tier::Medium => 5_000,
        Tier::Strong => 0,
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct Entry {
    mtime: u64,
    len: u64,
    symbols: Vec<String>,
    fan_in: u32,
}

#[derive(Default, Serialize, Deserialize)]
struct Cache {
    files: HashMap<String, Entry>,
}

/// The rendered map, and what it was built from.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Map {
    pub text: String,
    /// The files shown, so a mention of one that isn't can trigger a rebuild.
    pub shown: HashSet<String>,
    /// A fingerprint of every source file's path and mtime.
    pub stamp: u64,
}

impl Map {
    /// Whether the map should be rebuilt: files changed, or `mentioned` names one it lacks.
    pub fn stale(&self, root: &Path, mentioned: &[String]) -> bool {
        if mentioned
            .iter()
            .any(|m| !self.shown.contains(m) && is_source(m))
        {
            return true;
        }
        stamp(&listing(root)) != self.stamp
    }
}

/// What to rank by, from the session so far.
#[derive(Default)]
pub struct Seeds<'a> {
    /// Files the user named in the current message (relative to the root).
    pub mentioned: &'a [String],
    /// Files edited earlier this session.
    pub edited: &'a [String],
}

/// Build the map for `root` within `budget` characters (empty when the budget is 0), using
/// and updating `cache` if given.
pub fn build(root: &Path, cache: Option<&Path>, seeds: &Seeds, budget: usize) -> Map {
    build_bounded(root, cache, seeds, budget, usize::MAX, None).0
}

pub fn build_bounded(
    root: &Path,
    cache: Option<&Path>,
    seeds: &Seeds,
    budget: usize,
    max_files: usize,
    max_time: Option<std::time::Duration>,
) -> (Map, bool) {
    if budget == 0 {
        return (Map::default(), false);
    }
    let deadline = max_time.map(|d| std::time::Instant::now() + d);
    let (paths, mut capped) = crate::codemap::source_files_bounded(root, None, max_files, deadline);
    let files = listing_paths(root, paths);
    let stamp = stamp(&files);
    let mut entries = cache
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|b| serde_json::from_slice::<Cache>(&b).ok())
        .unwrap_or_default()
        .files;
    entries.retain(|p, _| files.iter().any(|(f, _, _)| f == p));
    let changed: Vec<&(String, u64, u64)> = files
        .iter()
        .filter(|(p, mtime, len)| {
            entries
                .get(p)
                .is_none_or(|e| e.mtime != *mtime || e.len != *len)
        })
        .collect();
    for (p, mtime, len) in &changed {
        if deadline.is_some_and(|d| std::time::Instant::now() >= d) {
            capped = true;
            break;
        }
        let symbols = std::fs::read_to_string(root.join(p))
            .map(|t| symbols(p, &t))
            .unwrap_or_default();
        entries.insert(
            p.clone(),
            Entry {
                mtime: *mtime,
                len: *len,
                symbols,
                fan_in: 0,
            },
        );
    }
    if !changed.is_empty() || entries.values().all(|e| e.fan_in == 0) {
        let (g, scan_capped) = crate::codemap::scan_files_bounded(
            root,
            files.iter().map(|(p, _, _)| p.clone()).collect(),
            deadline,
        );
        capped |= scan_capped;
        let mut fan_in: HashMap<&str, u32> = HashMap::new();
        for (_, to) in g.edges.keys() {
            *fan_in.entry(to.as_str()).or_default() += 1;
        }
        for (p, e) in entries.iter_mut() {
            e.fan_in = fan_in.get(p.as_str()).copied().unwrap_or(0);
        }
        if let Some(p) = cache
            && let Some(dir) = p.parent()
            && crate::memory::create_private_dir(dir).is_ok()
            && let Ok(bytes) = serde_json::to_vec(&Cache {
                files: entries.clone(),
            })
        {
            let tmp = p.with_extension("json.tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(&tmp, p);
            }
        }
    }
    let churn = if max_time.is_none() {
        churn(root)
    } else {
        HashMap::new()
    };
    let ranked = rank(&entries, &churn, seeds);
    let (text, shown) = render(&ranked, &entries, budget);
    (Map { text, shown, stamp }, capped)
}

fn listing_paths(root: &Path, paths: Vec<String>) -> Vec<(String, u64, u64)> {
    paths
        .into_iter()
        .map(|p| {
            let meta = std::fs::metadata(root.join(&p)).ok();
            (
                p,
                meta.as_ref().map_or(0, |m| {
                    m.modified()
                        .ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map_or(0, |d| d.as_secs())
                }),
                meta.map_or(0, |m| m.len()),
            )
        })
        .collect()
}

/// Every source file with its mtime (seconds) and length.
fn listing(root: &Path) -> Vec<(String, u64, u64)> {
    crate::codemap::source_files(root, None)
        .into_iter()
        .map(|p| {
            let meta = std::fs::metadata(root.join(&p)).ok();
            let mtime = meta
                .as_ref()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let len = meta.map(|m| m.len()).unwrap_or(0);
            (p, mtime, len)
        })
        .collect()
}

fn stamp(files: &[(String, u64, u64)]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    files.hash(&mut h);
    h.finish()
}

fn is_source(p: &str) -> bool {
    Path::new(p)
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| {
            matches!(
                e,
                "rs" | "ts" | "tsx" | "js" | "jsx" | "mjs" | "py" | "go" | "swift"
            )
        })
}

/// Per file: commits touching it in the last [`CHURN_COMMITS`], and whether one was among the
/// most recent twenty.
pub fn churn(root: &Path) -> HashMap<String, (u32, bool)> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args([
            "log",
            &format!("-n{CHURN_COMMITS}"),
            "--name-only",
            "--relative",
            "--format=%x00",
        ])
        .output();
    let mut counts: HashMap<String, (u32, bool)> = HashMap::new();
    let Ok(o) = out else { return counts };
    let mut commit = 0usize;
    for line in String::from_utf8_lossy(&o.stdout).lines() {
        let l = line.trim();
        if l == "\0" {
            commit += 1;
            continue;
        }
        if l.is_empty() {
            continue;
        }
        let e = counts.entry(l.to_string()).or_default();
        e.0 += 1;
        e.1 |= commit <= 20;
    }
    counts
}

/// Score every file and return the best first: mentions, then session edits, then churn and
/// fan-in, with the path as a tie-break.
fn rank(
    entries: &HashMap<String, Entry>,
    churn: &HashMap<String, (u32, bool)>,
    seeds: &Seeds,
) -> Vec<(String, u32)> {
    let mut scored: Vec<(String, u32)> = entries
        .keys()
        .map(|p| {
            let mut s = 0u32;
            if seeds.mentioned.iter().any(|m| m == p) {
                s += 100;
            }
            if seeds.edited.iter().any(|m| m == p) {
                s += 50;
            }
            if let Some((n, recent)) = churn.get(p) {
                s += (*n).min(10) * 2 + if *recent { 3 } else { 0 };
            }
            s += entries[p].fan_in.min(20);
            (p.clone(), s)
        })
        .collect();
    scored.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    scored
}

fn render(
    ranked: &[(String, u32)],
    entries: &HashMap<String, Entry>,
    budget: usize,
) -> (String, HashSet<String>) {
    const HEAD: &str = "\n\n# Repo map\nFiles most likely to matter, with their top-level symbols (ranked by mention, recent edits, git churn and how many files import them). It's a hint, not the whole project: use Glob, Grep and Read to see more.\n";
    let mut s = String::from(HEAD);
    let mut shown = HashSet::new();
    for (p, _) in ranked.iter().take(MAX_LINES) {
        let syms = &entries[p].symbols;
        let mut line = format!("{p}:");
        for (i, sym) in syms.iter().enumerate() {
            if line.len() + sym.len() + 2 > 140 {
                line.push_str(&format!(" +{}", syms.len() - i));
                break;
            }
            line.push_str(if i == 0 { " " } else { ", " });
            line.push_str(sym);
        }
        if s.len() + line.len() + 1 > budget {
            break;
        }
        s.push_str(&line);
        s.push('\n');
        shown.insert(p.clone());
    }
    if shown.is_empty() {
        return (String::new(), shown);
    }
    (s, shown)
}

static RS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+|unsafe\s+|const\s+)*(?:fn|struct|enum|trait|type|mod|static|const|macro_rules!)\s+([A-Za-z_][A-Za-z0-9_]*)").unwrap()
});
static JS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^(?:export\s+(?:default\s+)?)?(?:async\s+)?(?:function\*?|class|interface|type|enum|const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)").unwrap()
});
static PY: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^(?:async\s+)?(?:def|class)\s+([A-Za-z_][A-Za-z0-9_]*)").unwrap()
});
static GO: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^(?:func\s+(?:\([^)]*\)\s*)?|type\s+)([A-Za-z_][A-Za-z0-9_]*)").unwrap()
});
static SWIFT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^(?:(?:public|private|internal|open|fileprivate|final|indirect)\s+)*(?:class|struct|enum|protocol|actor|func|extension)\s+([A-Za-z_][A-Za-z0-9_]*)").unwrap()
});

/// Top-level declarations in `text`, in order, without duplicates.
pub fn symbols(path: &str, text: &str) -> Vec<String> {
    let ext = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");
    let re: &Regex = match ext {
        "rs" => &RS,
        "ts" | "tsx" | "js" | "jsx" | "mjs" => &JS,
        "py" => &PY,
        "go" => &GO,
        "swift" => &SWIFT,
        _ => return Vec::new(),
    };
    let mut out: Vec<String> = Vec::new();
    for c in re.captures_iter(text) {
        let s = c[1].to_string();
        if !out.contains(&s) {
            out.push(s);
        }
        if out.len() >= 40 {
            break;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn git(root: &Path, args: &[&str]) {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    fn repo() -> PathBuf {
        let root = std::env::temp_dir().join(format!("frog-repomap-{}", crate::session::new_id()));
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(
            root.join("src/lib.rs"),
            "pub mod store;\npub mod api;\npub mod util;\npub fn run() {}\n",
        )
        .unwrap();
        std::fs::write(
            root.join("src/store.rs"),
            "pub struct Store;\nimpl Store { pub fn new() -> Self { Store } }\npub fn open() {}\n",
        )
        .unwrap();
        std::fs::write(
            root.join("src/api.rs"),
            "pub fn handle() { crate::store::open(); crate::util::x(); }\n",
        )
        .unwrap();
        std::fs::write(
            root.join("src/util.rs"),
            "pub fn x() { crate::store::open(); }\nfn private() {}\n",
        )
        .unwrap();
        std::fs::write(root.join("src/quiet.rs"), "pub fn quiet() {}\n").unwrap();
        git(&root, &["init", "-q"]);
        git(&root, &["add", "."]);
        git(&root, &["commit", "-qm", "init"]);
        for i in 0..3 {
            std::fs::write(
                root.join("src/api.rs"),
                format!("pub fn handle() {{ crate::store::open(); crate::util::x(); }} // {i}\n"),
            )
            .unwrap();
            git(&root, &["commit", "-qam", "churn"]);
        }
        root
    }

    #[test]
    fn ranks_by_mention_edits_churn_and_fan_in() {
        let root = repo();
        let churn = churn(&root);
        assert_eq!(churn["src/api.rs"], (4, true));
        assert_eq!(churn["src/quiet.rs"], (1, true));

        let cache = root.join("cache/repomap.json");
        let m = build(&root, Some(&cache), &Seeds::default(), 5_000);
        assert!(cache.exists());
        let order: Vec<&str> = m
            .text
            .lines()
            .filter(|l| l.starts_with("src/"))
            .map(|l| l.split(':').next().unwrap())
            .collect();
        // Churn puts api first; fan-in (two importers) puts store next.
        assert_eq!(order[0], "src/api.rs");
        assert_eq!(order[1], "src/store.rs");
        assert_eq!(*order.last().unwrap(), "src/quiet.rs");
        assert!(m.text.contains("src/store.rs: Store, open\n"), "{}", m.text);
        assert!(m.text.contains("src/util.rs: x, private\n"));

        let mentioned = vec!["src/quiet.rs".to_string()];
        let edited = vec!["src/util.rs".to_string()];
        let m2 = build(
            &root,
            Some(&cache),
            &Seeds {
                mentioned: &mentioned,
                edited: &edited,
            },
            5_000,
        );
        let order: Vec<&str> = m2
            .text
            .lines()
            .filter(|l| l.starts_with("src/"))
            .map(|l| l.split(':').next().unwrap())
            .collect();
        assert_eq!(&order[..3], ["src/quiet.rs", "src/util.rs", "src/api.rs"]);
        assert_eq!(m2.stamp, m.stamp);
        assert!(!m2.stale(&root, &mentioned));

        // A small budget keeps only the top lines; zero means no map.
        let small = build(&root, Some(&cache), &Seeds::default(), 250);
        assert!(small.text.len() <= 250);
        assert_eq!(small.shown.len(), 1);
        assert!(small.stale(&root, &["src/quiet.rs".to_string()]));
        assert!(!small.stale(&root, &["README.md".to_string()]));
        assert!(build(&root, None, &Seeds::default(), 0).text.is_empty());

        // Touching a file changes the stamp, and the cache picks up its new symbols.
        std::thread::sleep(std::time::Duration::from_millis(1_100));
        std::fs::write(
            root.join("src/quiet.rs"),
            "pub fn quiet() {}\npub fn louder() {}\n",
        )
        .unwrap();
        assert!(m.stale(&root, &[]));
        let m3 = build(&root, Some(&cache), &Seeds::default(), 5_000);
        assert!(m3.text.contains("src/quiet.rs: quiet, louder"));
        assert_ne!(m3.stamp, m.stamp);
    }

    #[test]
    fn symbols_per_language() {
        assert_eq!(
            symbols(
                "a.rs",
                "pub(crate) fn a() {}\nfn b() {}\n    fn inner() {}\npub struct S;\nmacro_rules! m {}\n"
            ),
            ["a", "b", "S", "m"]
        );
        assert_eq!(
            symbols(
                "a.ts",
                "export default class App {}\nexport async function load() {}\nconst x = 1;\n  const y = 2;\n"
            ),
            ["App", "load", "x"]
        );
        assert_eq!(
            symbols(
                "a.py",
                "class A:\n    def m(self): pass\nasync def f(): pass\n"
            ),
            ["A", "f"]
        );
        assert_eq!(
            symbols("a.go", "func (s *S) M() {}\nfunc F() {}\ntype T struct{}\n"),
            ["M", "F", "T"]
        );
        assert_eq!(
            symbols(
                "a.swift",
                "public final class V {}\nstruct S {}\nextension S {}\n  func inner() {}\n"
            ),
            ["V", "S"]
        );
        assert!(symbols("a.md", "# hi").is_empty());
    }
}
