//! The morning notice: at most once a day, the first time you're at your Mac after 7, and only
//! when the brief has something you haven't seen. Everything else stays quiet in the pond.
//!
//! Deciding marks the day, so however many clients ask (the app on wake, on launch, every
//! half hour), you get one.

use super::brief::Brief;
use super::{Lock, Pond};
use anyhow::Result;
use chrono::{Local, NaiveDate, NaiveTime, Utc};
use serde::Serialize;

/// Not before this, local time.
const FROM: (u32, u32) = (7, 0);

/// A brief older than this is refreshed before deciding.
const FRESH_MINUTES: i64 = 15;

#[derive(Debug, PartialEq, Serialize)]
pub struct Notice {
    pub title: String,
    pub body: String,
}

/// The notice, when one is due; marks today as notified.
pub async fn check(cfg: &crate::config::Config) -> Result<Option<Notice>> {
    let now = Utc::now();
    if !after_start(now.with_timezone(&Local).time()) {
        return Ok(None);
    }
    let today = now.with_timezone(&Local).date_naive();
    let dir = super::dir();
    if Pond::load(&dir).notified_on == Some(today) {
        return Ok(None);
    }
    let brief = match super::latest() {
        Some(b) if now - b.at < chrono::Duration::minutes(FRESH_MINUTES) => b,
        _ => super::pass(cfg).await?,
    };
    let _lock = Lock::take(&dir)?;
    let mut pond = Pond::load(&dir);
    let Some(notice) = decide(&brief, pond.notified_on, today) else {
        return Ok(None);
    };
    pond.notified_on = Some(today);
    pond.save(&dir)?;
    Ok(Some(notice))
}

fn after_start(t: NaiveTime) -> bool {
    t >= NaiveTime::from_hms_opt(FROM.0, FROM.1, 0).unwrap()
}

/// One notice a day, and only for something new in the headline: the headline as the title,
/// what's new as the body.
fn decide(brief: &Brief, notified_on: Option<NaiveDate>, today: NaiveDate) -> Option<Notice> {
    if notified_on == Some(today) {
        return None;
    }
    let new: Vec<String> = brief
        .items
        .iter()
        .filter(|l| l.new)
        .map(|l| super::brief::short_title(&l.title))
        .collect();
    if new.is_empty() {
        return None;
    }
    let mut body = new[..new.len().min(2)].join(" · ");
    if new.len() > 2 {
        body.push_str(&format!(" · {} more", new.len() - 2));
    }
    if let Some(e) = brief.today.iter().find(|e| !e.all_day && e.start > brief.at) {
        body.push_str(&format!("\n{} at {}", e.title, super::calendar::clock(e.start)));
    }
    Some(Notice {
        title: brief.headline.clone(),
        body,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pond::Receipt;
    use crate::pond::brief::Line;
    use crate::pond::Kind;

    fn line(title: &str, new: bool) -> Line {
        Line {
            id: title.into(),
            kind: Kind::Review,
            title: title.into(),
            url: String::new(),
            place: "o/r".into(),
            who: None,
            updated: "2026-09-30T00:00:00Z".parse().unwrap(),
            note: String::new(),
            new,
        }
    }

    fn brief(items: Vec<Line>) -> Brief {
        Brief {
            at: "2026-09-30T11:00:00Z".parse().unwrap(),
            headline: "Review “a”".into(),
            items,
            also: vec![],
            today: vec![],
            receipt: Receipt::default(),
            trouble: vec![],
        }
    }

    #[test]
    fn once_a_day_and_only_for_something_new() {
        let today = NaiveDate::from_ymd_opt(2026, 9, 30).unwrap();
        let yesterday = today.pred_opt().unwrap();
        let b = brief(vec![line("a", true), line("b", false), line("c", true), line("d", true)]);
        let n = decide(&b, Some(yesterday), today).unwrap();
        assert_eq!(n.title, "Review “a”");
        assert_eq!(n.body, "a · c · 1 more");
        assert!(decide(&b, Some(today), today).is_none());
        assert!(decide(&brief(vec![line("old", false)]), None, today).is_none());
        assert!(decide(&brief(vec![]), None, today).is_none());
    }

    #[test]
    fn not_before_seven() {
        assert!(!after_start(NaiveTime::from_hms_opt(6, 59, 0).unwrap()));
        assert!(after_start(NaiveTime::from_hms_opt(7, 0, 0).unwrap()));
    }
}
