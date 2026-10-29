//! The approvals roll-up (docs/design/delegation.md): what the delegation
//! pipeline did — what the classifier and the second pass allowed, what the
//! chief decided, what still blocked. One counter per path, each call counted
//! once. A session's counters are advisory (in memory, lost on crash); the
//! durable roll-up across sessions ([`rollup`], `frog approvals`) reads the
//! `PermissionDecision` events in the session logs. The daily notice fires at
//! most once per day across every session sharing a store ([`claim_daily`]),
//! at the first card after midnight, so days with no cards stay silent.

use std::path::Path;
#[cfg(test)]
use std::sync::LazyLock;

/// The day's counters.
#[derive(Default, Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Counts {
    /// Calls the first classifier allowed.
    pub auto_allowed: u32,
    /// Calls the second pass upgraded to allow.
    pub second_pass: u32,
    /// Calls the chief approved.
    pub delegated_chief: u32,
    /// Calls the chief was asked about but couldn't decide (they carded).
    pub chief_fallback: u32,
    /// Calls blocked: carded the user with no chief route (never-delegable,
    /// ungranted classes), or declined by the chief.
    pub blocked: u32,
    /// Of `blocked`, the never-delegable ones.
    pub never_delegable: u32,
}

impl Counts {
    fn total(&self) -> u32 {
        self.auto_allowed + self.second_pass + self.delegated_chief + self.chief_fallback + self.blocked
    }

    /// The roll-up line: the app notice, `Op::ApprovalDigest`, `frog approvals`.
    pub fn render(&self, when: &str) -> String {
        format!(
            "approvals {when}: {} auto-allowed, {} second-pass upgrades, {} chief-approved, {} chief fallbacks, {} blocked ({} never-delegable) ({} calls total)",
            self.auto_allowed,
            self.second_pass,
            self.delegated_chief,
            self.chief_fallback,
            self.blocked,
            self.never_delegable,
            self.total()
        )
    }

    fn bump(&mut self, which: Which) {
        match which {
            Which::AutoAllowed => self.auto_allowed += 1,
            Which::SecondPass => self.second_pass += 1,
            Which::DelegatedChief => self.delegated_chief += 1,
            Which::ChiefFallback => self.chief_fallback += 1,
            Which::Blocked => self.blocked += 1,
            Which::NeverDelegable => {
                self.blocked += 1;
                self.never_delegable += 1;
            }
        }
    }
}

/// The digest: today's counters plus the day the notice last fired.
pub struct Digest {
    day: String,
    counts: Counts,
    noticed: Option<String>,
}

fn ymd() -> String {
    #[cfg(test)]
    if let Some(d) = test_ymd_override() {
        return d;
    }
    // Days since the epoch, UTC, as the key; midnight rollover by compare.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{}", secs / 86_400)
}

impl Default for Digest {
    fn default() -> Self {
        Self {
            day: ymd(),
            counts: Counts::default(),
            noticed: None,
        }
    }
}

impl Digest {
    fn roll(&mut self) {
        let today = ymd();
        if self.day != today {
            self.day = today;
            self.counts = Counts::default();
            self.noticed = None;
        }
    }

    pub fn count(&mut self, which: Which) {
        self.roll();
        self.counts.bump(which);
    }

    /// Whether today's notice hasn't fired yet in this session (the caller also
    /// claims the day across sessions, fires it, then marks).
    pub fn needs_daily_notice(&mut self) -> bool {
        self.roll();
        self.noticed.is_none() && self.counts.blocked + self.counts.chief_fallback > 0
    }

    pub fn mark_noticed(&mut self) {
        self.noticed = Some(self.day.clone());
    }

    /// Today's day key (days since the epoch, UTC).
    pub fn day(&mut self) -> String {
        self.roll();
        self.day.clone()
    }

    /// This session's roll-up line (`Op::ApprovalDigest`).
    pub fn summary(&mut self) -> String {
        self.roll();
        self.counts.render("today")
    }
}

/// Which counter to bump.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Which {
    AutoAllowed,
    SecondPass,
    DelegatedChief,
    ChiefFallback,
    Blocked,
    /// A blocked call in a never-delegable class (counts as blocked too).
    NeverDelegable,
}

/// Claim today's single roll-up notice for every session sharing `store`: true
/// for exactly one caller per day (an exclusive marker file). No store (tests,
/// a headless run without one): the session's own once-a-day check is all there is.
pub fn claim_daily(store: Option<&Path>, day: &str) -> bool {
    let Some(store) = store else { return true };
    let _ = std::fs::create_dir_all(store);
    let mine = format!(".approvals-noticed-{day}");
    let claimed = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(store.join(&mine))
        .is_ok();
    if claimed && let Ok(dir) = std::fs::read_dir(store) {
        // Earlier days' markers are spent.
        for e in dir.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with(".approvals-noticed-") && name != mine {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }
    claimed
}

/// The durable roll-up: every session log in `dir` (`*.jsonl`), each call's
/// `PermissionDecision` events since `since_ms` (unix ms), bucketed by the
/// pipeline layer that decided it. Calls the pipeline never saw (sandbox,
/// rules, session grants) aren't counted.
pub fn rollup(dir: &Path, since_ms: i64) -> Counts {
    let since = std::time::UNIX_EPOCH + std::time::Duration::from_millis(since_ms.max(0) as u64);
    let mut counts = Counts::default();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return counts;
    };
    for e in entries.flatten() {
        let path = e.path();
        if path.extension().and_then(|x| x.to_str()) != Some("jsonl") {
            continue;
        }
        // A log untouched since the cutoff has nothing newer.
        if e.metadata().and_then(|m| m.modified()).is_ok_and(|m| m < since) {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        for which in classify(&text, since_ms) {
            counts.bump(which);
        }
    }
    counts
}

/// One session log's pipeline calls, each as the counter it lands in.
fn classify(log: &str, since_ms: i64) -> Vec<Which> {
    use std::collections::BTreeMap;
    // Per call (session + item): its decisions, in order.
    let mut calls: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
    for line in log.lines() {
        if !line.contains("\"permission_decision\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let env = &v["env"];
        if env["event"] != "permission_decision" || env["created"].as_i64().unwrap_or(0) < since_ms {
            continue;
        }
        let (Some(layer), Some(outcome)) = (env["layer"].as_str(), env["outcome"].as_str()) else {
            continue;
        };
        let key = format!(
            "{}/{}",
            env["session"].as_str().unwrap_or(""),
            env["item"].as_str().unwrap_or("")
        );
        calls
            .entry(key)
            .or_default()
            .push((layer.to_string(), outcome.to_string()));
    }
    calls.values().filter_map(|ds| bucket(ds)).collect()
}

/// Which counter a call's decisions land in. The chief's outcome wins, then a
/// never-delegable flag, then an allow by either pass, then any other pipeline
/// flag (it reached the user).
fn bucket(ds: &[(String, String)]) -> Option<Which> {
    let has = |l: &str, o: &str| ds.iter().any(|(a, b)| a == l && b == o);
    if let Some((_, o)) = ds.iter().rev().find(|(l, _)| l == "delegated") {
        return Some(match o.as_str() {
            "allow" => Which::DelegatedChief,
            "deny" => Which::Blocked,
            _ => Which::ChiefFallback,
        });
    }
    if ds.iter().any(|(l, _)| l == "never-delegable") {
        return Some(Which::NeverDelegable);
    }
    if has("second-pass", "allow") {
        return Some(Which::SecondPass);
    }
    if has("classifier", "allow") {
        return Some(Which::AutoAllowed);
    }
    let pipeline = ["classifier", "second-pass", "fallback"];
    ds.iter()
        .any(|(l, _)| pipeline.contains(&l.as_str()))
        .then_some(Which::Blocked)
}

/// Test-only: freeze the day key so rollover can be driven.
#[cfg(test)]
pub static TEST_DAY: LazyLock<std::sync::Mutex<Option<String>>> =
    LazyLock::new(|| std::sync::Mutex::new(None));

#[cfg(test)]
fn test_ymd_override() -> Option<String> {
    TEST_DAY.lock().unwrap().clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_roll_up_and_roll_over() {
        *TEST_DAY.lock().unwrap() = Some("20000".into());
        let mut d = Digest::default();
        d.count(Which::AutoAllowed);
        d.count(Which::AutoAllowed);
        d.count(Which::SecondPass);
        d.count(Which::DelegatedChief);
        d.count(Which::ChiefFallback);
        d.count(Which::NeverDelegable);
        assert_eq!(
            d.summary(),
            "approvals today: 2 auto-allowed, 1 second-pass upgrades, 1 chief-approved, 1 chief fallbacks, 1 blocked (1 never-delegable) (6 calls total)"
        );
        // Midnight: everything resets, the notice re-arms.
        *TEST_DAY.lock().unwrap() = Some("20001".into());
        assert!(!d.needs_daily_notice(), "no blocked calls today yet");
        d.count(Which::Blocked);
        assert!(d.needs_daily_notice());
        d.mark_noticed();
        assert!(!d.needs_daily_notice());
        *TEST_DAY.lock().unwrap() = None;
    }

    #[test]
    fn the_daily_claim_goes_to_one_session_per_day() {
        let store = std::env::temp_dir().join(format!("digest-claim-{}", crate::session::new_id()));
        assert!(claim_daily(Some(&store), "100"));
        assert!(!claim_daily(Some(&store), "100"), "a second session the same day");
        assert!(claim_daily(Some(&store), "101"), "the next day");
        assert!(!store.join(".approvals-noticed-100").exists(), "yesterday's marker is cleared");
        assert!(claim_daily(None, "100"), "no store: the session decides alone");
        let _ = std::fs::remove_dir_all(&store);
    }

    #[test]
    fn rollup_reads_each_calls_pipeline_layers_from_the_logs() {
        let dir = std::env::temp_dir().join(format!("digest-rollup-{}", crate::session::new_id()));
        std::fs::create_dir_all(&dir).unwrap();
        let d = |seq: u32, created: i64, item: &str, layer: &str, outcome: &str| {
            format!(
                r#"{{"type":"event","env":{{"seq":{seq},"session":"s1","created":{created},"event":"permission_decision","item":"{item}","layer":"{layer}","outcome":"{outcome}","reason":"r"}}}}"#
            )
        };
        let log = [
            r#"{"type":"header","version":1,"id":"s1","cwd":"/tmp","model":"m","created":0}"#.to_string(),
            d(1, 2000, "a", "classifier", "allow"),
            d(2, 2000, "b", "second-pass", "allow"),
            d(3, 2000, "c", "second-pass", "ask"),
            d(4, 2000, "c", "delegated", "allow"),
            d(5, 2000, "e", "second-pass", "ask"),
            d(6, 2000, "e", "delegated", "ask"),
            d(7, 2000, "e", "ask", "ask"),
            d(8, 2000, "f", "never-delegable", "ask"),
            d(9, 2000, "f", "ask", "ask"),
            d(10, 2000, "g", "second-pass", "ask"),
            d(11, 2000, "h", "sandbox", "allow"),
            d(12, 500, "old", "classifier", "allow"),
        ]
        .join("\n");
        std::fs::write(dir.join("s1.jsonl"), log).unwrap();
        std::fs::write(dir.join("notes.json"), "{}").unwrap();
        let c = rollup(&dir, 1000);
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(
            c.render("since 1s"),
            "approvals since 1s: 1 auto-allowed, 1 second-pass upgrades, 1 chief-approved, 1 chief fallbacks, 2 blocked (1 never-delegable) (6 calls total)"
        );
    }
}
