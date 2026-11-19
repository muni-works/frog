//! Note vectors: what lets each turn bring back only the notes that fit, and places notes on
//! the Memory map.
//!
//! A vector is lexical and computed here, with no model and no download, so it's the same on
//! a Mac, in a Frog Cloud sandbox and in tests. Content words are cut to a five-letter stem
//! and character trigrams of each stem are added at half weight, all hashed (signed) into
//! [`DIMS`] buckets, then normalized. Near in this space means the notes share words or word
//! pieces. It is deterministic: the same text always gives the same vector.
//!
//! Vectors are kept beside the notes, one `.vectors.json` per notes folder (global, and each
//! project's), keyed by note id with a hash of the note's text, plus when each note was last
//! brought into a turn. [`Index::sync`] drops entries whose note is gone, so a forgotten note
//! leaves every index the next time either is read, and [`prune`] does it at once.

use crate::memory::{Note, Scope};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const DIMS: usize = 256;
/// Bumped when the vector recipe changes, so stored vectors are recomputed.
pub const MODEL: &str = "lexical-1";
const FILE: &str = ".vectors.json";

/// Words that carry no subject.
const STOP: &[&str] = &[
    "the", "and", "for", "are", "but", "not", "you", "your", "with", "this", "that", "they",
    "them", "its", "was", "were", "has", "have", "had", "will", "would", "should", "can", "could",
    "from", "into", "onto", "our", "out", "all", "any", "one", "use", "uses", "used", "using",
    "don't", "dont", "does", "never", "always", "here", "there", "then", "than", "when", "what",
    "which", "who", "how", "also", "just", "only", "every", "each", "via", "per", "please", "some",
    "make", "let", "lets", "now", "get", "want", "need", "like", "about", "it's", "i'm",
];

/// The stems a vector is made of, in order: content words, lower case, cut to five letters.
pub fn stems(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !(c.is_alphanumeric() || c == '\''))
        .map(|w| w.trim_matches('\''))
        .filter(|w| w.chars().count() >= 3 && !STOP.contains(w))
        .map(|w| {
            // Plurals and third persons meet their singular: "tests" and "test", "icons", "uses".
            let w = if w.chars().count() > 3 && w.ends_with('s') && !w.ends_with("ss") {
                &w[..w.len() - 1]
            } else {
                w
            };
            w.chars().take(5).collect()
        })
        .collect()
}

fn fnv(s: &str) -> u64 {
    s.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

fn add(v: &mut [f32], token: &str, w: f32) {
    let h = fnv(token);
    let i = (h % DIMS as u64) as usize;
    v[i] += if h >> 63 == 0 { w } else { -w };
}

/// The vector of `text`, unit length (all zero for text with no content words).
pub fn vector(text: &str) -> Vec<f32> {
    let mut v = vec![0f32; DIMS];
    for s in stems(text) {
        add(&mut v, &format!("w:{s}"), 1.0);
        let padded: Vec<char> = format!("^{s}$").chars().collect();
        for g in padded.windows(3) {
            add(&mut v, &format!("g:{}", g.iter().collect::<String>()), 0.5);
        }
    }
    normalize(&mut v);
    v
}

pub fn normalize(v: &mut [f32]) {
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if n > 0.0 {
        v.iter_mut().for_each(|x| *x /= n);
    }
}

pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// What a note's vector is made from: its text and the files it cites.
fn source(n: &Note) -> String {
    format!("{} {}", n.body, n.cites.join(" "))
}

/// A note's entry in its folder's index.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Entry {
    /// FNV-1a of the text the vector was made from, hex.
    pub hash: String,
    pub v: Vec<f32>,
    /// RFC 3339: the last turn this note was brought into.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_used: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct Folder {
    model: String,
    dims: usize,
    notes: BTreeMap<String, Entry>,
    /// Flagged pairs the user chose to keep both of (`memmap::pair_key`): not flagged again.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    settled: Vec<String>,
}

/// The vectors of every note one [`crate::memory::Store`] can see.
#[derive(Clone, Debug, Default)]
pub struct Index {
    folders: Vec<(Scope, PathBuf, Folder)>,
}

fn read_folder(path: &Path) -> Folder {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str::<Folder>(&s).ok())
        .filter(|f| f.model == MODEL && f.dims == DIMS)
        .unwrap_or_else(|| Folder {
            model: MODEL.into(),
            dims: DIMS,
            notes: BTreeMap::new(),
            settled: Vec::new(),
        })
}

fn write_folder(path: &Path, f: &Folder) -> anyhow::Result<()> {
    if let Some(dir) = path.parent() {
        crate::memory::create_private_dir(dir)?;
    }
    crate::memory::write_private(path, &serde_json::to_string(f)?)
}

impl Index {
    /// Read the indexes beside `notes` and bring them up to date: a vector for every note
    /// (recomputed when its text changed), none for a note that's gone. Writes what changed.
    /// `Err` only when an index can't be written; the caller then falls back to the whole list.
    pub fn sync(store: &crate::memory::Store, notes: &[Note]) -> anyhow::Result<Self> {
        let mut folders = Vec::new();
        for scope in [Scope::Project, Scope::Global] {
            let Some(dir) = store.scope_dir(scope) else {
                continue;
            };
            let path = dir.join(FILE);
            let mut f = read_folder(&path);
            let mut changed = !path.exists() && notes.iter().any(|n| n.scope == scope);
            let here: Vec<&Note> = notes.iter().filter(|n| n.scope == scope).collect();
            let before = f.notes.len();
            f.notes.retain(|id, _| here.iter().any(|n| &n.id == id));
            changed |= f.notes.len() != before;
            // A settled pair goes with either of its notes.
            let alive = |k: &str| {
                let (s, id) = k.split_once(':').unwrap_or(("", k));
                notes
                    .iter()
                    .any(|n| n.id == id && (s == "g") == (n.scope == Scope::Global))
            };
            let before = f.settled.len();
            f.settled.retain(|k| k.split('|').all(alive));
            changed |= f.settled.len() != before;
            for n in here {
                let src = source(n);
                let hash = format!("{:016x}", fnv(&src));
                let e = f.notes.entry(n.id.clone()).or_default();
                if e.hash != hash {
                    e.hash = hash;
                    e.v = vector(&src);
                    changed = true;
                }
            }
            if changed {
                write_folder(&path, &f)?;
            }
            folders.push((scope, path, f));
        }
        Ok(Self { folders })
    }

    pub fn get(&self, scope: Scope, id: &str) -> Option<&Entry> {
        self.folders
            .iter()
            .find(|(s, _, _)| *s == scope)
            .and_then(|(_, _, f)| f.notes.get(id))
    }

    /// Every entry, with its scope and id.
    pub fn entries(&self) -> impl Iterator<Item = (Scope, &str, &Entry)> {
        self.folders
            .iter()
            .flat_map(|(s, _, f)| f.notes.iter().map(move |(id, e)| (*s, id.as_str(), e)))
    }

    /// Pairs the user chose to keep both of.
    pub fn settled(&self) -> Vec<String> {
        self.folders
            .iter()
            .flat_map(|(_, _, f)| f.settled.iter().cloned())
            .collect()
    }

    /// Record "show both" for a flagged pair: kept with the project's notes when there's a
    /// project, else with the global ones.
    pub fn settle(&mut self, key: &str) -> anyhow::Result<()> {
        let Some((_, path, f)) = self.folders.first_mut() else {
            anyhow::bail!("no notes here");
        };
        if !f.settled.iter().any(|k| k == key) {
            f.settled.push(key.to_string());
            write_folder(path, f)?;
        }
        Ok(())
    }

    /// Record that these notes were brought into a turn now.
    pub fn mark_used(&mut self, used: &[(Scope, String)], now: &str) -> anyhow::Result<()> {
        for (scope, path, f) in &mut self.folders {
            let mut changed = false;
            for (s, id) in used {
                if s == scope
                    && let Some(e) = f.notes.get_mut(id)
                {
                    e.last_used = Some(now.to_string());
                    changed = true;
                }
            }
            if changed {
                write_folder(path, f)?;
            }
        }
        Ok(())
    }
}

/// Remove a note from its folder's index now (`/forget`, Customize, undo).
pub fn prune(dir: &Path, id: &str) {
    let path = dir.join(FILE);
    if !path.exists() {
        return;
    }
    let mut f = read_folder(&path);
    if f.notes.remove(id).is_some() {
        let _ = write_folder(&path, &f);
    }
}

// ---- choosing the notes for a turn ----

/// A note chosen for a turn.
#[derive(Clone, Debug, PartialEq)]
pub struct Chosen {
    pub scope: Scope,
    pub id: String,
    pub score: f32,
}

/// Below this a note isn't about the message.
pub const FLOOR: f32 = 0.2;

/// The notes that fit a turn: scored against the user's words, with a lift for notes that cite
/// a file in play; at most `k`, best first, each above [`FLOOR`], and their lines within
/// `budget` tokens (about four characters each).
pub fn choose(
    notes: &[Note],
    index: &Index,
    words: &str,
    files: &[String],
    k: usize,
    budget: usize,
) -> Vec<Chosen> {
    let q = vector(&format!("{words} {}", files.join(" ")));
    let asked: std::collections::BTreeSet<String> = stems(words).into_iter().collect();
    if q.iter().all(|x| *x == 0.0) && files.is_empty() {
        return Vec::new();
    }
    let mut scored: Vec<(f32, &Note)> = notes
        .iter()
        .filter_map(|n| {
            let e = index.get(n.scope, &n.id)?;
            // Cosine, plus how much of what was asked the note covers: a short question
            // naming one thing ("publish the docs") still finds a longer note about it.
            let mut s = cosine(&q, &e.v);
            if !asked.is_empty() {
                let have: std::collections::BTreeSet<String> = stems(&n.body).into_iter().collect();
                let covered = asked.iter().filter(|w| have.contains(*w)).count();
                s += 0.3 * covered as f32 / asked.len() as f32;
            }
            if n.cites.iter().any(|c| {
                let c = c.split('#').next().unwrap_or(c);
                files
                    .iter()
                    .any(|f| f == c || f.ends_with(c) || c.ends_with(f.as_str()))
            }) {
                s += 0.3;
            }
            (s >= FLOOR).then_some((s, n))
        })
        .collect();
    scored.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));
    let mut out = Vec::new();
    let mut used = 0;
    for (s, n) in scored.into_iter().take(k) {
        let cost = (n.first_line().len() + n.id.len() + 20).div_ceil(4);
        if used + cost > budget {
            break;
        }
        used += cost;
        out.push(Chosen {
            scope: n.scope,
            id: n.id.clone(),
            score: s,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(id: &str, body: &str) -> Note {
        Note {
            id: id.into(),
            created: String::new(),
            scope: Scope::Project,
            source: "user".into(),
            cites: Vec::new(),
            body: body.into(),
            path: PathBuf::from(format!("/nowhere/{id}.md")),
            missing: Vec::new(),
            session: None,
            session_title: None,
            kind: None,
            turn: None,
            from: None,
        }
    }

    #[test]
    fn vectors_are_deterministic_and_unit() {
        let a = vector("The staging database is wiped every Monday.");
        assert_eq!(a, vector("The staging database is wiped every Monday."));
        assert!((cosine(&a, &a) - 1.0).abs() < 1e-5);
        assert!(vector("the and for").iter().all(|x| *x == 0.0));
    }

    #[test]
    fn related_beats_unrelated() {
        let staging = vector("The staging database is wiped every Monday.");
        let near = cosine(
            &staging,
            &vector("seed some data into the staging database"),
        );
        let far = cosine(&staging, &vector("write a test for the import job"));
        assert!(near > FLOOR && far < FLOOR, "near {near} far {far}");
    }
}

/// The miss rate, honestly: twenty notes, each with a question a user might ask that should
/// bring it back, written the way people talk rather than to share words. Printed for the PR;
/// `cargo test -p frog-engine memvec::miss_rate -- --nocapture`.
#[cfg(test)]
#[test]
fn miss_rate() {
    let cases = [
        (
            "The staging database is wiped every Monday.",
            "seed some data into staging",
        ),
        (
            "The staging database is wiped every Monday.",
            "why did my seed rows vanish over the weekend",
        ),
        (
            "Tests live in spec/, one file per module.",
            "where should the new test go?",
        ),
        (
            "Tests live in spec/, one file per module.",
            "add coverage for the importer",
        ),
        (
            "Release notes lead with fixes people asked for.",
            "write the 0.7.1 release notes",
        ),
        (
            "Release notes lead with fixes people asked for.",
            "draft the changelog for this version",
        ),
        (
            "The sidecar listens on port 8912.",
            "the apple sidecar won't start, port taken?",
        ),
        ("The sidecar listens on port 8912.", "what's using 8912?"),
        (
            "Icons are drawn at 16 points with a 1.5 point stroke.",
            "make a new icon for the toolbar",
        ),
        (
            "Icons are drawn at 16 points with a 1.5 point stroke.",
            "the glyph looks too heavy",
        ),
        (
            "The docs site deploys from the site folder by hand.",
            "publish the docs",
        ),
        (
            "The docs site deploys from the site folder by hand.",
            "ship the documentation update",
        ),
        (
            "Benchmarks run on the M4 Max with the lid open.",
            "run the benchmarks again",
        ),
        (
            "Benchmarks run on the M4 Max with the lid open.",
            "why are the tok/s numbers lower today?",
        ),
        (
            "The billing page shows dollars per token.",
            "change the billing page copy",
        ),
        (
            "The billing page shows dollars per token.",
            "how should we show what a request costs?",
        ),
        (
            "Screenshots for the README live in video/stills.",
            "update the README screenshots",
        ),
        (
            "Screenshots for the README live in video/stills.",
            "where do the hero images go?",
        ),
        (
            "The CI runner caches cargo builds between jobs.",
            "CI builds are slow",
        ),
        (
            "The CI runner caches cargo builds between jobs.",
            "the pipeline takes forever",
        ),
    ];
    let mut notes: Vec<Note> = Vec::new();
    for (i, (body, _)) in cases.iter().enumerate() {
        if !notes.iter().any(|n| n.body == *body) {
            notes.push(note_for_eval(&format!("n{i}"), body));
        }
    }
    // Thirty more on other subjects, so it's a store past the whole-store budget.
    for i in 0..30 {
        notes.push(note_for_eval(
            &format!("f{i}"),
            &format!("Filler fact {i} about the onboarding flow and email templates"),
        ));
    }
    let dir = std::env::temp_dir().join(format!("frog-missrate-{}", crate::session::new_id()));
    std::fs::create_dir_all(dir.join("repo/.git")).unwrap();
    let store = crate::memory::Store::new(&dir.join("memory"), Some(&dir.join("repo")));
    let index = Index::sync(&store, &notes).unwrap();
    let mut misses = Vec::new();
    for (body, q) in cases {
        let got = choose(&notes, &index, q, &[], 5, 400);
        let want = notes.iter().find(|n| n.body == body).unwrap();
        if !got.iter().any(|c| c.id == want.id) {
            misses.push(q);
        }
    }
    eprintln!(
        "miss rate: {} of {} ({}%); missed: {misses:?}",
        misses.len(),
        cases.len(),
        misses.len() * 100 / cases.len()
    );
    let _ = std::fs::remove_dir_all(dir);
}

#[cfg(test)]
fn note_for_eval(id: &str, body: &str) -> Note {
    Note {
        id: id.into(),
        created: String::new(),
        scope: Scope::Project,
        source: "user".into(),
        cites: Vec::new(),
        body: body.into(),
        path: PathBuf::from(format!("/nowhere/{id}.md")),
        missing: Vec::new(),
        session: None,
        session_title: None,
        kind: None,
        turn: None,
        from: None,
    }
}
