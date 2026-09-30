//! The pond: what frog noticed while you were away, and a brief of what's worth your time.
//!
//! Noticing only: senses read, a model writes, nothing is sent or changed on your behalf.
//! A pass reads each sense, folds what it found into the pond (new, still open, or resolved),
//! ranks the open items, and writes a brief with a receipt: what was read, which model wrote
//! it and where it ran, and what left this Mac.
//!
//! The ranking keeps score. Every item shown in a brief is resolved by you (it left the sense:
//! you reviewed the PR, the checks went green) or dismissed. A kind you keep dismissing sinks
//! out of the headline, a kind you act on rises. That's the interruption budget.
//!
//! Everything lives in `~/.local/share/frog/pond/`: `items.json` (the pond) and `brief.json`
//! (the latest brief, which clients read without running a pass).

pub mod background;
pub mod brief;
pub mod calendar;
pub mod github;

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// What kind of thing an item is, which sets how much it matters before you've said anything.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// Someone is waiting on your review.
    Review,
    /// Your PR's checks are failing.
    Failing,
    /// A reviewer asked for changes on your PR.
    ChangesRequested,
    /// Someone mentioned you.
    Mention,
    /// You were assigned something.
    Assigned,
    /// Your PR is approved and green: it can land.
    Ready,
}

impl Kind {
    /// How much this kind matters with no history, 0–1.
    fn weight(self) -> f64 {
        match self {
            Kind::Review => 1.0,
            Kind::Failing => 0.9,
            Kind::ChangesRequested => 0.85,
            Kind::Mention => 0.7,
            Kind::Ready => 0.6,
            Kind::Assigned => 0.5,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Kind::Review => "review requested",
            Kind::Failing => "checks failing",
            Kind::ChangesRequested => "changes requested",
            Kind::Mention => "mentioned you",
            Kind::Assigned => "assigned to you",
            Kind::Ready => "ready to merge",
        }
    }
}

/// One thing a sense found. `id` is stable across passes, so the same PR is the same item.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    pub source: String,
    pub kind: Kind,
    pub title: String,
    pub url: String,
    /// Where it is: a repo, a calendar.
    pub place: String,
    /// Who it's from, when someone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub who: Option<String>,
    pub updated: DateTime<Utc>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Open,
    /// It left the sense (you acted, or it resolved itself).
    Resolved,
    /// You said it wasn't worth your time. It comes back only if it changes.
    Dismissed,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Entry {
    pub item: Item,
    pub state: State,
    pub first_seen: DateTime<Utc>,
    /// When a brief first showed it, if one has.
    #[serde(default)]
    pub shown: Option<DateTime<Utc>>,
}

/// Per kind: of the items a brief showed, how many you acted on and how many you dismissed.
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize)]
pub struct Score {
    pub acted: u32,
    pub dismissed: u32,
}

impl Score {
    /// How often you act on this kind, with a gentle prior of one each way.
    pub fn rate(self) -> f64 {
        (self.acted as f64 + 1.0) / ((self.acted + self.dismissed) as f64 + 2.0)
    }
}

#[derive(Default, Serialize, Deserialize)]
pub struct Pond {
    #[serde(default)]
    pub items: BTreeMap<String, Entry>,
    #[serde(default)]
    pub scores: BTreeMap<Kind, Score>,
}

pub fn dir() -> PathBuf {
    crate::config::data_dir().join("pond")
}

impl Pond {
    pub fn load(dir: &Path) -> Self {
        std::fs::read(dir.join("items.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        write_atomic(&dir.join("items.json"), &serde_json::to_vec_pretty(self)?)
    }

    /// Fold one sense's current view into the pond. Items it no longer reports are resolved,
    /// and if a brief had shown them, that counts as acting on their kind.
    pub fn fold(&mut self, source: &str, found: Vec<Item>, now: DateTime<Utc>) {
        let ids: std::collections::HashSet<String> = found.iter().map(|i| i.id.clone()).collect();
        for item in found {
            match self.items.get_mut(&item.id) {
                Some(e) => {
                    let changed = item.updated > e.item.updated;
                    let reopen = match e.state {
                        State::Open => false,
                        State::Resolved => true,
                        State::Dismissed => changed,
                    };
                    if reopen {
                        e.state = State::Open;
                        e.shown = None;
                    }
                    e.item = item;
                }
                None => {
                    self.items.insert(
                        item.id.clone(),
                        Entry {
                            item,
                            state: State::Open,
                            first_seen: now,
                            shown: None,
                        },
                    );
                }
            }
        }
        for e in self.items.values_mut() {
            if e.item.source == source && e.state == State::Open && !ids.contains(&e.item.id) {
                e.state = State::Resolved;
                if e.shown.is_some() {
                    self.scores.entry(e.item.kind).or_default().acted += 1;
                }
            }
        }
    }

    /// You said this one isn't worth your time.
    pub fn dismiss(&mut self, id: &str) -> bool {
        let Some(e) = self.items.get_mut(id) else {
            return false;
        };
        if e.state != State::Open {
            return false;
        }
        e.state = State::Dismissed;
        if e.shown.is_some() {
            self.scores.entry(e.item.kind).or_default().dismissed += 1;
        }
        true
    }

    /// How much an open item deserves your attention now: its kind's weight, scaled by how
    /// often you act on that kind, fading over a couple of weeks of no activity.
    pub fn priority(&self, e: &Entry, now: DateTime<Utc>) -> f64 {
        let rate = self.scores.get(&e.item.kind).copied().unwrap_or_default().rate();
        let days = (now - e.item.updated).num_hours().max(0) as f64 / 24.0;
        e.item.kind.weight() * (0.5 + rate) * (1.0 / (1.0 + days / 14.0))
    }

    /// Open items, most deserving first.
    pub fn ranked(&self, now: DateTime<Utc>) -> Vec<(&Entry, f64)> {
        let mut open: Vec<(&Entry, f64)> = self
            .items
            .values()
            .filter(|e| e.state == State::Open)
            .map(|e| (e, self.priority(e, now)))
            .collect();
        open.sort_by(|a, b| b.1.total_cmp(&a.1).then(b.0.item.updated.cmp(&a.0.item.updated)));
        open
    }

    /// Forget resolved and dismissed items nobody has touched in a month.
    pub fn prune(&mut self, now: DateTime<Utc>) {
        self.items.retain(|_, e| {
            e.state == State::Open || now - e.item.updated < chrono::Duration::days(30)
        });
    }
}

/// Where something ran, in the app's colors: this Mac (blue), your own server, or the cloud (green).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Place {
    Mac,
    Server,
    Cloud,
}

impl Place {
    pub fn of(p: &crate::config::Profile) -> Place {
        if crate::policy::is_cloud(p) {
            return Place::Cloud;
        }
        let here = p.sidecar.is_some()
            || p.base_url.as_deref().is_none_or(|u| {
                reqwest::Url::parse(u)
                    .ok()
                    .and_then(|u| u.host_str().map(str::to_owned))
                    .is_some_and(|h| h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]")
            });
        if here { Place::Mac } else { Place::Server }
    }
}

/// What a pass read, which model wrote the brief and where, and what left this Mac.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Receipt {
    pub read: Vec<Read>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<ModelUse>,
    pub sent: Vec<Sent>,
    /// Energy this Mac spent writing the brief, above idle, when measured.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wh: Option<f64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Read {
    pub source: String,
    /// What was read, in words ("12 notifications, 8 pull requests").
    pub what: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelUse {
    pub name: String,
    pub place: Place,
    pub input_tokens: u64,
    pub output_tokens: u64,
}

/// Bytes that left this Mac, where they went and what they were.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Sent {
    pub to: String,
    pub bytes: u64,
    pub what: String,
    /// Whether it carried what the senses read (your data), rather than a query for it.
    pub private: bool,
}

impl Receipt {
    /// Bytes of your data that left this Mac.
    pub fn private_bytes(&self) -> u64 {
        self.sent.iter().filter(|s| s.private).map(|s| s.bytes).sum()
    }
}

/// One pass: read every sense, fold, rank, write the brief, save. Returns the brief.
pub async fn pass(cfg: &crate::config::Config) -> Result<brief::Brief> {
    let dir = dir();
    std::fs::create_dir_all(&dir)?;
    let _lock = Lock::take(&dir)?;
    let now = Utc::now();
    let mut pond = Pond::load(&dir);
    let mut receipt = Receipt::default();
    let mut trouble = Vec::new();

    match github::read().await {
        Ok(g) => {
            receipt.read.push(Read {
                source: "github".into(),
                what: g.what,
            });
            receipt.sent.push(g.sent);
            pond.fold("github", g.items, now);
        }
        // A sense that can't be read leaves its items as they were.
        Err(e) => trouble.push(format!("github: {e:#}")),
    }

    // Read on this Mac from the app's snapshot; nothing to send.
    let today = match calendar::read(&dir, now) {
        Some((events, what)) => {
            receipt.read.push(Read {
                source: "calendar".into(),
                what,
            });
            events
        }
        None => Vec::new(),
    };

    let b = brief::write(cfg, &mut pond, today, receipt, trouble, now).await;
    pond.prune(now);
    pond.save(&dir)?;
    write_atomic(&dir.join("brief.json"), &serde_json::to_vec_pretty(&b)?)?;
    Ok(b)
}

/// The latest brief, without running a pass.
pub fn latest() -> Option<brief::Brief> {
    std::fs::read(dir().join("brief.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
}

/// Dismiss an item and rewrite the saved brief without it.
pub fn dismiss(id: &str) -> Result<bool> {
    let dir = dir();
    let _lock = Lock::take(&dir)?;
    let mut pond = Pond::load(&dir);
    if !pond.dismiss(id) {
        return Ok(false);
    }
    pond.save(&dir)?;
    if let Some(mut b) = latest() {
        b.items.retain(|i| i.id != id);
        b.also.retain(|i| i.id != id);
        write_atomic(&dir.join("brief.json"), &serde_json::to_vec_pretty(&b)?)?;
    }
    Ok(true)
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(tmp, path)?;
    Ok(())
}

/// One pass at a time: the app and a background watcher may both start one.
struct Lock(std::fs::File);

impl Lock {
    fn take(dir: &Path) -> Result<Lock> {
        use std::os::fd::AsRawFd;
        std::fs::create_dir_all(dir)?;
        let f = std::fs::File::create(dir.join("lock"))?;
        if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX) } != 0 {
            anyhow::bail!("couldn't lock the pond");
        }
        Ok(Lock(f))
    }
}

impl Drop for Lock {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, kind: Kind, updated: &str) -> Item {
        Item {
            id: id.into(),
            source: "github".into(),
            kind,
            title: id.into(),
            url: String::new(),
            place: "ecto/frog".into(),
            who: None,
            updated: updated.parse().unwrap(),
        }
    }

    fn at(s: &str) -> DateTime<Utc> {
        s.parse().unwrap()
    }

    #[test]
    fn items_that_leave_the_sense_resolve_and_count_as_acted_when_shown() {
        let mut p = Pond::default();
        let now = at("2026-09-30T08:00:00Z");
        p.fold("github", vec![item("a", Kind::Review, "2026-09-29T00:00:00Z"), item("b", Kind::Review, "2026-09-29T00:00:00Z")], now);
        p.items.get_mut("a").unwrap().shown = Some(now);
        p.fold("github", vec![], now);
        assert_eq!(p.items["a"].state, State::Resolved);
        assert_eq!(p.items["b"].state, State::Resolved);
        // Only the shown one says anything about you.
        assert_eq!(p.scores[&Kind::Review].acted, 1);
    }

    #[test]
    fn dismissed_items_stay_down_until_they_change() {
        let mut p = Pond::default();
        let now = at("2026-09-30T08:00:00Z");
        p.fold("github", vec![item("a", Kind::Mention, "2026-09-29T00:00:00Z")], now);
        p.items.get_mut("a").unwrap().shown = Some(now);
        assert!(p.dismiss("a"));
        assert_eq!(p.scores[&Kind::Mention].dismissed, 1);
        p.fold("github", vec![item("a", Kind::Mention, "2026-09-29T00:00:00Z")], now);
        assert_eq!(p.items["a"].state, State::Dismissed);
        p.fold("github", vec![item("a", Kind::Mention, "2026-09-30T07:00:00Z")], now);
        assert_eq!(p.items["a"].state, State::Open);
        assert!(p.items["a"].shown.is_none());
    }

    #[test]
    fn a_kind_you_keep_dismissing_sinks() {
        let mut p = Pond::default();
        let now = at("2026-09-30T08:00:00Z");
        p.fold("github", vec![item("m", Kind::Mention, "2026-09-30T00:00:00Z"), item("r", Kind::Ready, "2026-09-30T00:00:00Z")], now);
        assert_eq!(p.ranked(now)[0].0.item.id, "m");
        p.scores.insert(Kind::Mention, Score { acted: 0, dismissed: 6 });
        assert_eq!(p.ranked(now)[0].0.item.id, "r");
    }

    #[test]
    fn stale_items_fade() {
        let p = Pond::default();
        let now = at("2026-09-30T08:00:00Z");
        let fresh = Entry { item: item("a", Kind::Review, "2026-09-30T00:00:00Z"), state: State::Open, first_seen: now, shown: None };
        let old = Entry { item: item("b", Kind::Review, "2026-08-30T00:00:00Z"), state: State::Open, first_seen: now, shown: None };
        assert!(p.priority(&fresh, now) > 2.0 * p.priority(&old, now));
    }
}
