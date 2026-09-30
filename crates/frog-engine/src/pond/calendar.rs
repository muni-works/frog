//! The calendar sense: your day's shape, for context. Events aren't things to do, so they
//! never become items or move the scores; the brief shows what's next and the headline can
//! work around it ("an hour free before the design review").
//!
//! The Mac app reads EventKit (the permission is Frog's, and it's opt-in) and leaves the next
//! few days in `pond/senses/calendar.json`; this reads that file. Nothing crosses the network.

use chrono::{DateTime, Duration, Local, Utc};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Event {
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    #[serde(default)]
    pub all_day: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub calendar: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub location: Option<String>,
}

#[derive(Deserialize)]
struct Snapshot {
    at: DateTime<Utc>,
    events: Vec<Event>,
}

/// A snapshot older than this is too old to trust (you may have moved things since).
const FRESH: i64 = 36;

/// What's left of today (or until tomorrow noon, late in the evening), soonest first, and
/// what was read. `None` when there's no fresh snapshot: the calendar sense is off.
pub fn read(dir: &Path, now: DateTime<Utc>) -> Option<(Vec<Event>, String)> {
    let bytes = std::fs::read(dir.join("senses/calendar.json")).ok()?;
    let snap: Snapshot = serde_json::from_slice(&bytes).ok()?;
    if now - snap.at > Duration::hours(FRESH) {
        return None;
    }
    let horizon = horizon(now);
    let mut events: Vec<Event> = snap
        .events
        .into_iter()
        .filter(|e| e.end > now && e.start < horizon)
        .collect();
    events.sort_by_key(|e| (e.all_day, e.start));
    let what = match events.len() {
        0 => "nothing else on today".to_string(),
        1 => "1 event ahead today".to_string(),
        n => format!("{n} events ahead today"),
    };
    Some((events, what))
}

/// The end of today, local time; after 6pm, tomorrow noon, so the evening brief sees the morning.
fn horizon(now: DateTime<Utc>) -> DateTime<Utc> {
    let local = now.with_timezone(&Local);
    let day = local.date_naive();
    let end = if local.time() >= chrono::NaiveTime::from_hms_opt(18, 0, 0).unwrap() {
        day.succ_opt().unwrap_or(day).and_hms_opt(12, 0, 0)
    } else {
        day.succ_opt().unwrap_or(day).and_hms_opt(0, 0, 0)
    };
    end.and_then(|t| t.and_local_timezone(Local).earliest())
        .map(|t| t.with_timezone(&Utc))
        .unwrap_or(now + Duration::hours(12))
}

/// "10:30", in local time.
pub fn clock(t: DateTime<Utc>) -> String {
    t.with_timezone(&Local).format("%-H:%M").to_string()
}

/// The next timed event, for the template headline: "Next: Standup at 10:30."
pub fn next_up(events: &[Event], now: DateTime<Utc>) -> Option<String> {
    let e = events.iter().find(|e| !e.all_day && e.start > now)?;
    Some(format!("Next: {} at {}.", e.title, clock(e.start)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(title: &str, start: DateTime<Utc>, mins: i64) -> Event {
        Event { title: title.into(), start, end: start + Duration::minutes(mins), all_day: false, calendar: None, location: None }
    }

    #[test]
    fn reads_whats_ahead_and_ignores_stale_snapshots() {
        let dir = std::env::temp_dir().join(format!("frog-cal-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("senses")).unwrap();
        let now = Utc::now();
        let snap = serde_json::json!({
            "at": now - Duration::hours(1),
            "events": [
                ev("done", now - Duration::hours(3), 30),
                ev("later", now + Duration::minutes(90), 30),
                ev("soon", now + Duration::minutes(20), 30),
                ev("next week", now + Duration::days(7), 30),
            ],
        });
        std::fs::write(dir.join("senses/calendar.json"), snap.to_string()).unwrap();
        let (events, what) = read(&dir, now).unwrap();
        let titles: Vec<_> = events.iter().map(|e| e.title.as_str()).collect();
        // Both may fall past midnight in some time zones; the ones ahead come soonest first.
        assert!(!titles.contains(&"done") && !titles.contains(&"next week"));
        assert_eq!(titles.first(), (!titles.is_empty()).then_some(&"soon"));
        assert!(what.contains("today"));
        assert!(read(&dir, now + Duration::hours(40)).is_none());
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn next_up_skips_all_day_and_started_events() {
        let now = Utc::now();
        let mut all_day = ev("Holiday", now + Duration::minutes(5), 600);
        all_day.all_day = true;
        let events = [ev("Running", now - Duration::minutes(5), 30), all_day, ev("Standup", now + Duration::minutes(30), 15)];
        assert!(next_up(&events, now).unwrap().starts_with("Next: Standup at "));
    }
}
