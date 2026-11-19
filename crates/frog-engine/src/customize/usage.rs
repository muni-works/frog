//! The use log: when a skill was loaded and when a connection's tool was called, for
//! Customize's 30-day strip, count and "last used". One JSON line per use in
//! `~/.local/share/frog/usage.jsonl`, appended (several engines write at once, and an append
//! never loses another's line). Old lines fold into one line per item per day, and anything
//! older than [`KEEP_DAYS`] goes, so the file stays small. Nothing here leaves the machine.

use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Days of history kept.
pub const KEEP_DAYS: i64 = 90;
/// Days in the strip the apps draw.
pub const STRIP_DAYS: usize = 30;
/// Past this size the file is folded on the next write.
const FOLD_OVER: u64 = 256 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// Keyed by the skill's id (its `SKILL.md` path, or `frog-builtin:<name>`).
    Skill,
    /// Keyed by the tool's exposed name, `mcp__<server>__<tool>`.
    Tool,
}

/// One line: a use, or (after folding) `n` uses on the day of `at`.
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Line {
    /// Unix milliseconds.
    at: i64,
    kind: Kind,
    key: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    session: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    title: String,
    #[serde(default = "one", skip_serializing_if = "is_one")]
    n: u32,
}

fn one() -> u32 {
    1
}

fn is_one(n: &u32) -> bool {
    *n == 1
}

/// The last use of an item, and where.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Last {
    /// RFC 3339, local time.
    pub at: String,
    pub session: Option<String>,
    pub title: Option<String>,
}

/// What the apps draw for one item.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Use {
    /// Uses in the last [`STRIP_DAYS`] days.
    pub count: u32,
    /// [`STRIP_DAYS`] counts, oldest first; the last is today.
    pub days: Vec<u32>,
    pub last: Option<Last>,
}

impl Default for Use {
    fn default() -> Self {
        Self {
            count: 0,
            days: vec![0; STRIP_DAYS],
            last: None,
        }
    }
}

impl Use {
    /// Several items as one (a connection's tools together).
    pub fn sum<'a>(uses: impl IntoIterator<Item = &'a Use>) -> Use {
        let mut out = Use::default();
        for u in uses {
            out.count += u.count;
            for (a, b) in out.days.iter_mut().zip(&u.days) {
                *a += b;
            }
            if u.last.as_ref().map(|l| &l.at) > out.last.as_ref().map(|l| &l.at) {
                out.last = u.last.clone();
            }
        }
        out
    }
}

fn path() -> PathBuf {
    if cfg!(test) {
        // Tests never touch your real log.
        return std::env::temp_dir().join(format!("frog-usage-test-{}.jsonl", std::process::id()));
    }
    crate::config::data_dir().join("usage.jsonl")
}

/// Log one use now. Never fails the caller: a use that can't be written is just not counted.
pub fn record(kind: Kind, key: &str, session: &str, title: &str) {
    record_in(&path(), Local::now(), kind, key, session, title);
}

pub(crate) fn record_in(
    file: &Path,
    now: DateTime<Local>,
    kind: Kind,
    key: &str,
    session: &str,
    title: &str,
) {
    use std::io::Write;
    let line = Line {
        at: now.timestamp_millis(),
        kind,
        key: key.to_string(),
        session: session.to_string(),
        title: title.chars().take(80).collect(),
        n: 1,
    };
    let Ok(text) = serde_json::to_string(&line) else {
        return;
    };
    if let Some(dir) = file.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let big = std::fs::metadata(file).is_ok_and(|m| m.len() > FOLD_OVER);
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(file)
    {
        let _ = writeln!(f, "{text}");
    }
    if big || oldest_too_old(file, now) {
        fold_in(file, now);
    }
}

fn read(file: &Path) -> Vec<Line> {
    std::fs::read_to_string(file)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

fn cutoff(now: DateTime<Local>) -> i64 {
    (now - Duration::days(KEEP_DAYS)).timestamp_millis()
}

/// Whether the first line has aged out: a cheap check, reading one line.
fn oldest_too_old(file: &Path, now: DateTime<Local>) -> bool {
    use std::io::BufRead;
    let Ok(f) = std::fs::File::open(file) else {
        return false;
    };
    let mut first = String::new();
    let _ = std::io::BufReader::new(f).read_line(&mut first);
    serde_json::from_str::<Line>(&first).is_ok_and(|l| l.at < cutoff(now))
}

fn day_of(at: i64) -> Option<NaiveDate> {
    Local
        .timestamp_millis_opt(at)
        .single()
        .map(|t| t.date_naive())
}

/// Rewrite the log as one line per item per day, dropping days past [`KEEP_DAYS`]. Each kept
/// line is that day's latest use, so "last used" and its session survive. Written through a
/// temp file and a rename; a use appended by another engine during the rewrite can be lost,
/// which is why it runs rarely (a big file, or an aged-out first line).
pub(crate) fn fold_in(file: &Path, now: DateTime<Local>) {
    let cut = cutoff(now);
    let mut days: BTreeMap<(Kind, String, NaiveDate), Line> = BTreeMap::new();
    for l in read(file).into_iter().filter(|l| l.at >= cut) {
        let Some(day) = day_of(l.at) else { continue };
        days.entry((l.kind, l.key.clone(), day))
            .and_modify(|d| {
                let n = d.n + l.n;
                if l.at >= d.at {
                    *d = l.clone();
                }
                d.n = n;
            })
            .or_insert(l);
    }
    let mut lines: Vec<Line> = days.into_values().collect();
    lines.sort_by_key(|l| l.at);
    let text: String = lines
        .iter()
        .filter_map(|l| serde_json::to_string(l).ok())
        .map(|s| s + "\n")
        .collect();
    let tmp = file.with_extension("jsonl.tmp");
    if std::fs::write(&tmp, text).is_ok() {
        let _ = std::fs::rename(&tmp, file);
    }
}

/// Every item's use, by kind and key.
pub fn summary() -> BTreeMap<(Kind, String), Use> {
    summary_in(&path(), Local::now())
}

pub(crate) fn summary_in(file: &Path, now: DateTime<Local>) -> BTreeMap<(Kind, String), Use> {
    let today = now.date_naive();
    let cut = cutoff(now);
    let mut out: BTreeMap<(Kind, String), (Use, i64)> = BTreeMap::new();
    for l in read(file).into_iter().filter(|l| l.at >= cut) {
        let (u, last_at) = out
            .entry((l.kind, l.key.clone()))
            .or_insert_with(|| (Use::default(), i64::MIN));
        if let Some(day) = day_of(l.at) {
            let ago = (today - day).num_days();
            if (0..STRIP_DAYS as i64).contains(&ago) {
                u.days[STRIP_DAYS - 1 - ago as usize] += l.n;
                u.count += l.n;
            }
        }
        if l.at >= *last_at {
            *last_at = l.at;
            u.last = Local.timestamp_millis_opt(l.at).single().map(|t| Last {
                at: t.format("%Y-%m-%dT%H:%M:%S%:z").to_string(),
                session: (!l.session.is_empty()).then(|| l.session.clone()),
                title: (!l.title.is_empty()).then(|| l.title.clone()),
            });
        }
    }
    out.into_iter().map(|(k, (u, _))| (k, u)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("frog-usage-{name}-{}", crate::session::new_id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("usage.jsonl")
    }

    fn at(days_ago: i64) -> DateTime<Local> {
        Local::now() - Duration::days(days_ago)
    }

    #[test]
    fn counts_uses_per_day_with_the_last_session() {
        let f = scratch("count");
        let now = Local::now();
        record_in(&f, at(3), Kind::Skill, "s", "old", "older one");
        record_in(&f, at(0), Kind::Skill, "s", "s1", "release notes");
        record_in(&f, at(0), Kind::Skill, "s", "s2", "0.7.1 notes");
        record_in(
            &f,
            at(0),
            Kind::Tool,
            "mcp__gh__issues",
            "s2",
            "0.7.1 notes",
        );
        let all = summary_in(&f, now);
        let s = &all[&(Kind::Skill, "s".to_string())];
        assert_eq!(s.count, 3);
        assert_eq!(s.days.len(), STRIP_DAYS);
        assert_eq!(s.days[STRIP_DAYS - 1], 2);
        assert_eq!(s.days[STRIP_DAYS - 4], 1);
        let last = s.last.as_ref().unwrap();
        assert_eq!(last.session.as_deref(), Some("s2"));
        assert_eq!(last.title.as_deref(), Some("0.7.1 notes"));
        assert_eq!(all[&(Kind::Tool, "mcp__gh__issues".to_string())].count, 1);
    }

    #[test]
    fn strip_shows_thirty_days_but_last_used_reaches_further() {
        let f = scratch("strip");
        record_in(&f, at(45), Kind::Skill, "s", "long-ago", "");
        let s = &summary_in(&f, Local::now())[&(Kind::Skill, "s".to_string())];
        assert_eq!(s.count, 0);
        assert!(s.days.iter().all(|d| *d == 0));
        assert_eq!(
            s.last.as_ref().unwrap().session.as_deref(),
            Some("long-ago")
        );
    }

    #[test]
    fn rolls_off_after_ninety_days_and_folds_to_one_line_a_day() {
        let f = scratch("roll");
        // Written by hand: an aged-out line first, then many uses today.
        let old = Line {
            at: at(KEEP_DAYS + 5).timestamp_millis(),
            kind: Kind::Skill,
            key: "gone".into(),
            session: String::new(),
            title: String::new(),
            n: 1,
        };
        std::fs::write(&f, serde_json::to_string(&old).unwrap() + "\n").unwrap();
        for i in 0..5 {
            record_in(
                &f,
                Local::now(),
                Kind::Tool,
                "mcp__a__b",
                &format!("s{i}"),
                "",
            );
        }
        // The first write saw the aged-out line and folded: it's gone, and today's uses are
        // one line however many there were.
        fold_in(&f, Local::now());
        let text = std::fs::read_to_string(&f).unwrap();
        assert!(!text.contains("\"gone\""));
        assert_eq!(text.lines().count(), 1);
        let all = summary_in(&f, Local::now());
        assert!(!all.contains_key(&(Kind::Skill, "gone".to_string())));
        let u = &all[&(Kind::Tool, "mcp__a__b".to_string())];
        assert_eq!(u.count, 5);
        assert_eq!(u.last.as_ref().unwrap().session.as_deref(), Some("s4"));
    }

    #[test]
    fn a_missing_log_is_no_use_at_all() {
        let f = scratch("missing");
        assert!(summary_in(&f, Local::now()).is_empty());
        let s = Use::sum([&Use::default(), &Use::default()]);
        assert_eq!(s, Use::default());
    }
}
