//! What the Memory page's map needs, from the same vectors that choose a turn's notes
//! (`memvec`): a stable 2D position per note, a coarse group with a short label, staleness, and
//! pairs of notes that likely duplicate or disagree, flagged for the user (never resolved here).
//!
//! Stable means deterministic for a given store, and a new note moves the others little:
//! - Notes are grouped in the order they were written. Each joins the closest group of its
//!   scope (cosine to the group's centroid at least [`JOIN`]) or starts one, so a new note never
//!   changes where an older one went; it only nudges the centroid of the group it joins.
//! - A group sits at an angle given by its centroid's projection on two fixed axes (similar
//!   groups get similar angles) and a radius fixed by its first note, so it doesn't drift.
//! - A note sits near its group's centre, offset by its own difference from the centroid.
//!
//! Coordinates run 0 to 1 on both axes. Near means the notes share words (lexical, not
//! meaning); distances are approximate.

use crate::memory::{Note, Scope};
use crate::memvec::{Index, cosine, normalize};
use std::collections::BTreeMap;

/// A note joins a group when it's at least this close to the group's centroid.
pub const JOIN: f32 = 0.3;
/// Not brought into a turn (or written) in this many days: faded on the map.
pub const STALE_DAYS: i64 = 60;
/// This close, the two notes say the same thing.
pub const DUPLICATE: f32 = 0.85;
/// This close, the two notes are about the same thing (and may disagree).
pub const SAME_SUBJECT: f32 = 0.3;

#[derive(Clone, Debug, PartialEq)]
pub struct Placed {
    pub scope: Scope,
    pub id: String,
    pub x: f32,
    pub y: f32,
    /// Index into [`Map::groups`].
    pub group: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Group {
    pub label: String,
    pub scope: Scope,
    pub x: f32,
    pub y: f32,
    pub count: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Map {
    pub groups: Vec<Group>,
    pub notes: Vec<Placed>,
}

fn fnv(s: &str) -> u64 {
    s.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// A fixed unit axis, the same in every build and on every machine.
fn axis(name: &str, dims: usize) -> Vec<f32> {
    let mut v: Vec<f32> = (0..dims)
        .map(|i| {
            let h = fnv(&format!("{name}:{i}"));
            (h % 2001) as f32 / 1000.0 - 1.0
        })
        .collect();
    normalize(&mut v);
    v
}

fn r4(x: f32) -> f32 {
    (x.clamp(0.02, 0.98) * 10_000.0).round() / 10_000.0
}

/// Notes in the order they were written (then by id), which grouping follows.
fn written_order(notes: &[Note]) -> Vec<&Note> {
    let mut v: Vec<&Note> = notes.iter().collect();
    v.sort_by(|a, b| {
        ts(&a.created)
            .cmp(&ts(&b.created))
            .then_with(|| a.id.cmp(&b.id))
    });
    v
}

fn ts(s: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|t| t.timestamp())
        .unwrap_or(0)
}

/// Place every note that has a vector.
pub fn map(notes: &[Note], index: &Index) -> Map {
    struct G<'a> {
        scope: Scope,
        sum: Vec<f32>,
        members: Vec<(&'a Note, &'a [f32])>,
    }
    let mut groups: Vec<G> = Vec::new();
    for n in written_order(notes) {
        let Some(e) = index.get(n.scope, &n.id) else {
            continue;
        };
        let v = e.v.as_slice();
        let best = groups
            .iter()
            .enumerate()
            .filter(|(_, g)| g.scope == n.scope)
            .map(|(i, g)| {
                let mut c = g.sum.clone();
                normalize(&mut c);
                (i, cosine(&c, v))
            })
            .max_by(|a, b| a.1.total_cmp(&b.1));
        match best {
            Some((i, s)) if s >= JOIN => {
                let g = &mut groups[i];
                g.sum.iter_mut().zip(v).for_each(|(a, b)| *a += b);
                g.members.push((n, v));
            }
            _ => groups.push(G {
                scope: n.scope,
                sum: v.to_vec(),
                members: vec![(n, v)],
            }),
        }
    }
    let dims = crate::memvec::DIMS;
    let (ax, ay) = (axis("map-x", dims), axis("map-y", dims));
    let mut out = Map {
        groups: Vec::new(),
        notes: Vec::new(),
    };
    for (gi, g) in groups.iter().enumerate() {
        let mut c = g.sum.clone();
        normalize(&mut c);
        let angle = cosine(&c, &ay).atan2(cosine(&c, &ax));
        let first = &g.members[0].0.id;
        let radius = 0.12 + 0.26 * (fnv(first) % 1000) as f32 / 1000.0;
        let (cx, cy) = (0.5 + radius * angle.cos(), 0.5 + radius * angle.sin());
        out.groups.push(Group {
            label: label(g.members.iter().map(|(n, _)| n.body.as_str())),
            scope: g.scope,
            x: r4(cx),
            y: r4(cy),
            count: g.members.len(),
        });
        for (n, v) in &g.members {
            let d: Vec<f32> = v.iter().zip(&c).map(|(a, b)| a - b).collect();
            let (mut dx, mut dy) = (cosine(&d, &ax), cosine(&d, &ay));
            // Every note a little apart from the centre, the same way each time.
            let h = fnv(&n.id);
            dx += ((h % 97) as f32 / 97.0 - 0.5) * 0.04;
            dy += (((h >> 8) % 89) as f32 / 89.0 - 0.5) * 0.04;
            let len = (dx * dx + dy * dy).sqrt();
            let k = if len > 0.08 { 0.08 / len } else { 1.0 };
            out.notes.push(Placed {
                scope: n.scope,
                id: n.id.clone(),
                x: r4(cx + dx * k),
                y: r4(cy + dy * k),
                group: gi,
            });
        }
    }
    out
}

/// A group's short label: its two commonest content words, as written ("staging and database").
pub fn label<'a>(texts: impl Iterator<Item = &'a str>) -> String {
    // stem → (count, first seen, the word as most often written)
    let mut seen: BTreeMap<String, (usize, usize, BTreeMap<String, usize>)> = BTreeMap::new();
    let mut order = 0;
    for t in texts {
        for w in t
            .split(|c: char| !(c.is_alphanumeric() || c == '\''))
            .map(|w| w.trim_matches('\'').to_lowercase())
        {
            let stems = crate::memvec::stems(&w);
            let Some(stem) = stems.first() else { continue };
            if w.chars().all(|c| c.is_ascii_digit()) {
                continue;
            }
            let e = seen
                .entry(stem.clone())
                .or_insert((0, order, BTreeMap::new()));
            e.0 += 1;
            *e.2.entry(w).or_insert(0) += 1;
            order += 1;
        }
    }
    let mut top: Vec<(usize, usize, String)> = seen
        .into_values()
        .map(|(n, first, forms)| {
            let word = forms
                .into_iter()
                .max_by(|a, b| a.1.cmp(&b.1).then_with(|| b.0.cmp(&a.0)))
                .map(|(w, _)| w)
                .unwrap_or_default();
            (n, first, word)
        })
        .collect();
    top.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    let words: Vec<String> = top.into_iter().take(2).map(|t| t.2).collect();
    match words.as_slice() {
        [] => "notes".into(),
        [one] => one.clone(),
        [a, b] => format!("{a} and {b}"),
        _ => unreachable!(),
    }
}

/// Not used in a turn (or, never used, not written) in [`STALE_DAYS`].
pub fn stale(note: &Note, last_used: Option<&str>, now: i64) -> bool {
    let at = last_used
        .map(ts)
        .filter(|t| *t > 0)
        .unwrap_or(ts(&note.created));
    at > 0 && now - at > STALE_DAYS * 86_400
}

/// Why two notes were flagged.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PairKind {
    /// They say the same thing.
    Duplicate,
    /// Same subject, and one denies or changes what the other says.
    Disagree,
}

impl PairKind {
    pub fn label(self) -> &'static str {
        match self {
            Self::Duplicate => "duplicate",
            Self::Disagree => "disagree",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Pair {
    /// The older note, then the newer.
    pub older: (Scope, String),
    pub newer: (Scope, String),
    pub kind: PairKind,
    /// Stable key for the pair (`p:id|g:id`, sorted), what "show both" records.
    pub key: String,
}

pub fn pair_key(a: (Scope, &str), b: (Scope, &str)) -> String {
    let k = |(s, id): (Scope, &str)| format!("{}:{id}", if s == Scope::Global { "g" } else { "p" });
    let (mut x, mut y) = (k(a), k(b));
    if y < x {
        std::mem::swap(&mut x, &mut y);
    }
    format!("{x}|{y}")
}

const NEGATIONS: &[&str] = &[
    "not", "never", "no", "don't", "dont", "doesn't", "isn't", "aren't", "instead", "avoid",
    "stop", "without", "nor",
];

fn negated(text: &str) -> bool {
    text.to_lowercase()
        .split(|c: char| !(c.is_alphanumeric() || c == '\''))
        .any(|w| NEGATIONS.contains(&w))
}

fn numbers(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_ascii_digit())
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect()
}

/// Pairs that likely duplicate or disagree, newest pairs first, leaving out the `settled` ones
/// ("show both"). Flagging only: nothing is deleted here.
pub fn pairs(notes: &[Note], index: &Index, settled: &[String]) -> Vec<Pair> {
    let ordered = written_order(notes);
    let mut out = Vec::new();
    for (i, a) in ordered.iter().enumerate() {
        let Some(va) = index.get(a.scope, &a.id) else {
            continue;
        };
        for b in &ordered[i + 1..] {
            let Some(vb) = index.get(b.scope, &b.id) else {
                continue;
            };
            let key = pair_key((a.scope, &a.id), (b.scope, &b.id));
            if settled.contains(&key) {
                continue;
            }
            let s = cosine(&va.v, &vb.v);
            let same_text = a.body.trim().eq_ignore_ascii_case(b.body.trim());
            let kind = if same_text || s >= DUPLICATE {
                // Near-identical words that one negates aren't the same note.
                if negated(&a.body) != negated(&b.body) {
                    Some(PairKind::Disagree)
                } else {
                    Some(PairKind::Duplicate)
                }
            } else if s >= SAME_SUBJECT {
                let (na, nb) = (numbers(&a.body), numbers(&b.body));
                let numbers_differ = !na.is_empty() && !nb.is_empty() && na != nb;
                (negated(&a.body) != negated(&b.body) || numbers_differ)
                    .then_some(PairKind::Disagree)
            } else {
                None
            };
            if let Some(kind) = kind {
                out.push(Pair {
                    older: (a.scope, a.id.clone()),
                    newer: (b.scope, b.id.clone()),
                    kind,
                    key,
                });
            }
        }
    }
    out.reverse();
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn note(id: &str, created: &str, body: &str) -> Note {
        Note {
            id: id.into(),
            created: created.into(),
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
    fn labels_read_as_words() {
        assert_eq!(
            label(
                [
                    "Tests live in spec/, one file per module.",
                    "Run the tests with pnpm test.",
                    "Each module's tests build their own rows."
                ]
                .into_iter()
            ),
            "tests and module"
        );
        assert_eq!(label(["", "the and"].into_iter()), "notes");
    }

    #[test]
    fn disagreeing_and_duplicate_pairs_are_flagged_not_settled_ones() {
        let notes = vec![
            note("a", "2026-10-28T10:00:00+00:00", "This project uses npm."),
            note("b", "2026-11-16T10:00:00+00:00", "Use pnpm, never npm."),
            note(
                "c",
                "2026-11-01T10:00:00+00:00",
                "The sidecar listens on port 8912.",
            ),
            note(
                "d",
                "2026-11-02T10:00:00+00:00",
                "The sidecar listens on port 8913.",
            ),
            note(
                "e",
                "2026-11-03T10:00:00+00:00",
                "Release notes lead with fixes.",
            ),
            note(
                "f",
                "2026-11-04T10:00:00+00:00",
                "Release notes lead with fixes!",
            ),
            note(
                "g",
                "2026-11-05T10:00:00+00:00",
                "Icons are drawn at 16 points.",
            ),
        ];
        let dir = std::env::temp_dir().join(format!("frog-memmap-{}", crate::session::new_id()));
        std::fs::create_dir_all(dir.join("repo/.git")).unwrap();
        let store = crate::memory::Store::new(&dir.join("memory"), Some(&dir.join("repo")));
        let idx = Index::sync(&store, &notes).unwrap();
        let got = pairs(&notes, &idx, &[]);
        let find = |x: &str, y: &str| {
            got.iter()
                .find(|p| p.older.1 == x && p.newer.1 == y)
                .map(|p| p.kind)
        };
        assert_eq!(find("a", "b"), Some(PairKind::Disagree), "{got:?}");
        assert_eq!(find("c", "d"), Some(PairKind::Disagree), "{got:?}");
        assert_eq!(find("e", "f"), Some(PairKind::Duplicate), "{got:?}");
        assert!(got.iter().all(|p| p.older.1 != "g" && p.newer.1 != "g"));
        let key = pair_key((Scope::Project, "a"), (Scope::Project, "b"));
        assert!(pairs(&notes, &idx, &[key]).iter().all(|p| p.older.1 != "a"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn staleness_counts_from_last_use_or_writing() {
        let now = ts("2026-11-19T00:00:00+00:00");
        let n = note("a", "2026-08-01T00:00:00+00:00", "x y z");
        assert!(stale(&n, None, now));
        assert!(!stale(&n, Some("2026-11-01T00:00:00+00:00"), now));
        assert!(!stale(
            &note("b", "2026-11-01T00:00:00+00:00", "x"),
            None,
            now
        ));
    }
}
