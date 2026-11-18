//! A turn's timeline: what the turn line's strip and the turn panel's waterfall draw
//! (docs/design/transcript/spec.md, "The turn line and the turn panel"). [`segments`] turns one
//! turn's events, as the log keeps them, into segments of thinking, tools, waiting on a person
//! and writing, timed from the turn's start.
//!
//! This is the reference. The Mac reads session logs without an engine and the web folds the
//! events it's sent, so each app computes segments itself from the events it holds;
//! `docs/design/transcript/timeline.json` holds the cases all three must agree on.
//!
//! What it reads:
//! - `item_started` / `item_completed` (`created` on each): a reasoning item is thinking from
//!   its start for its `think_ms` (older logs: until it completed, which overstates it, since
//!   it completes only when the whole reply is in); a message is writing; a tool call is a tool.
//! - `permission_resolved` / `question_resolved` with `asked` and `item`: waiting, from `asked`
//!   to the event's `created`. The wait is cut out of its tool's segment, so one item's
//!   segments never overlap; different items' segments can (tools that ran together).
//! - `items_discarded`: those items' segments are dropped (a retried call's partial reply).
//! - An item still open at the end (a cancelled turn, or a live one) ends at the turn's end:
//!   `turn_ended`'s `created`, or the last event's.

use crate::protocol::{Envelope, Event, Item, ItemKind};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(
    Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum SegmentKind {
    Thinking,
    Tool,
    Waiting,
    Writing,
}

/// One stretch of a turn, in ms from the turn's start (`turn_started`'s `created`).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, JsonSchema)]
pub struct Segment {
    pub kind: SegmentKind,
    pub start_ms: u64,
    pub end_ms: u64,
    /// The item it belongs to: the reasoning, message or tool call (for waiting, the tool
    /// call that asked). Absent only for a wait from an older engine that didn't say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
}

/// The segments of one turn, given its events from `turn_started` on (anything before is
/// ignored), sorted by start, then kind, then item.
pub fn segments(events: &[Envelope]) -> Vec<Segment> {
    let Some(begin) = events
        .iter()
        .position(|e| matches!(e.event, Event::TurnStarted { .. }))
    else {
        return Vec::new();
    };
    let events = &events[begin..];
    let t0 = events[0].created;
    let end = events
        .iter()
        .find(|e| matches!(e.event, Event::TurnEnded { .. }))
        .or(events.last())
        .map_or(t0, |e| e.created);
    let at = |t: i64| (t.clamp(t0, end.max(t0)) - t0) as u64;

    let mut open: HashMap<&str, (SegmentKind, i64)> = HashMap::new();
    let mut out: Vec<Segment> = Vec::new();
    let mut waits: Vec<Segment> = Vec::new();
    let mut discarded: Vec<&str> = Vec::new();
    for e in events {
        match &e.event {
            Event::ItemStarted { id, kind } => {
                let kind = match kind {
                    ItemKind::Reasoning => SegmentKind::Thinking,
                    ItemKind::Message => SegmentKind::Writing,
                    ItemKind::ToolCall { .. } => SegmentKind::Tool,
                };
                open.insert(id, (kind, e.created));
            }
            Event::ItemCompleted { id, item } => {
                let Some((kind, start)) = open.remove(id.as_str()) else {
                    continue;
                };
                let stop = match item {
                    Item::Reasoning {
                        think_ms: Some(ms), ..
                    } => (start + *ms as i64).min(e.created),
                    _ => e.created,
                };
                out.push(Segment {
                    kind,
                    start_ms: at(start),
                    end_ms: at(stop),
                    item: Some(id.clone()),
                });
            }
            Event::PermissionResolved { item, asked, .. }
            | Event::QuestionResolved { item, asked, .. } => {
                if let Some(asked) = asked {
                    waits.push(Segment {
                        kind: SegmentKind::Waiting,
                        start_ms: at(*asked),
                        end_ms: at(e.created),
                        item: item.clone(),
                    });
                }
            }
            Event::ItemsDiscarded { ids } => discarded.extend(ids.iter().map(String::as_str)),
            Event::TurnEnded { .. } => break,
            _ => {}
        }
    }
    // Still open at the end.
    let mut rest: Vec<_> = open.into_iter().collect();
    rest.sort_by_key(|(id, (_, start))| (*start, id.to_string()));
    for (id, (kind, start)) in rest {
        out.push(Segment {
            kind,
            start_ms: at(start),
            end_ms: at(end),
            item: Some(id.to_string()),
        });
    }
    out.retain(|s| !s.item.as_deref().is_some_and(|i| discarded.contains(&i)));
    // Cut each wait out of its own tool's segment.
    let mut cut = Vec::with_capacity(out.len());
    for s in out {
        if s.kind != SegmentKind::Tool {
            cut.push(s);
            continue;
        }
        let mut pieces = vec![(s.start_ms, s.end_ms)];
        for w in waits.iter().filter(|w| w.item == s.item) {
            pieces = pieces
                .into_iter()
                .flat_map(|(a, b)| {
                    [(a, w.start_ms.min(b)), (w.end_ms.max(a), b)]
                        .into_iter()
                        .filter(|(x, y)| x < y)
                })
                .collect();
        }
        cut.extend(pieces.into_iter().map(|(a, b)| Segment {
            start_ms: a,
            end_ms: b,
            ..s.clone()
        }));
    }
    cut.extend(waits);
    cut.sort_by(|a, b| {
        (a.start_ms, a.kind, &a.item, a.end_ms).cmp(&(b.start_ms, b.kind, &b.item, b.end_ms))
    });
    cut
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const CASES: &str = include_str!("../../../docs/design/transcript/timeline.json");

    #[test]
    fn timeline_cases() {
        let all: Value = serde_json::from_str(CASES).unwrap();
        let cases = all["cases"].as_array().unwrap();
        assert!(cases.len() >= 8);
        for c in cases {
            let name = c["name"].as_str().unwrap();
            let events: Vec<Envelope> = serde_json::from_value(c["events"].clone())
                .unwrap_or_else(|e| panic!("{name}: events don't parse: {e}"));
            let want: Vec<Segment> = serde_json::from_value(c["segments"].clone()).unwrap();
            assert_eq!(segments(&events), want, "{name}");
        }
    }
}
