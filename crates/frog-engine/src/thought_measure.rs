//! Measures the thought line on real reasoning (see `tests::measure`). Session logs keep only
//! completed reasoning, not its deltas, so each item is replayed as a stream at an even pace
//! over the time from its `item_started` to its `item_completed`, in 16-byte chunks.

use super::*;
use serde_json::Value;
use std::collections::BTreeMap;

struct Item {
    text: String,
    ms: u64,
    /// `ms` is the call's measured `think_ms`, not started → completed.
    timed: bool,
}

#[derive(Default)]
struct Stats {
    items: usize,
    timed: usize,
    secs: f64,
    /// Items over 5 s with no line for their first 5 s.
    long: usize,
    empty_5s: usize,
    /// Items with one line held (or none shown) for over 10 s.
    stale_10s: usize,
    longest_hold_ms: u64,
    shown: usize,
    short: usize,
    over_120: usize,
    cut: usize,
    samples: Vec<String>,
}

fn models(dir: &str) -> BTreeMap<String, Vec<Item>> {
    let mut out: BTreeMap<String, Vec<Item>> = BTreeMap::new();
    let mut paths: Vec<_> = std::fs::read_dir(dir)
        .expect("FROG_THOUGHT_LOGS is a directory")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
        .collect();
    paths.sort();
    for path in paths {
        let Ok(body) = std::fs::read_to_string(&path) else {
            continue;
        };
        let mut model = String::new();
        let mut starts: BTreeMap<String, i64> = BTreeMap::new();
        let mut pending: Vec<Item> = Vec::new();
        for l in body.lines() {
            let Ok(o) = serde_json::from_str::<Value>(l) else {
                continue;
            };
            if o["type"] == "header" {
                model = o["model"].as_str().unwrap_or("").into();
                continue;
            }
            let e = &o["env"];
            match e["event"].as_str() {
                Some("model_changed") => model = e["model"].as_str().unwrap_or("").into(),
                Some("item_started") if e["kind"]["type"] == "reasoning" => {
                    starts.insert(
                        e["id"].as_str().unwrap_or("").into(),
                        e["created"].as_i64().unwrap_or(0),
                    );
                }
                Some("item_completed") if e["item"]["type"] == "reasoning" => {
                    let id = e["id"].as_str().unwrap_or("");
                    let Some(&s) = starts.get(id) else { continue };
                    let ms = (e["created"].as_i64().unwrap_or(s) - s).max(0) as u64;
                    pending.push(Item {
                        text: e["item"]["text"].as_str().unwrap_or("").into(),
                        ms,
                        timed: false,
                    });
                }
                Some("turn_ended") => {
                    // A reasoning item completes only when its whole reply is in, so
                    // started → completed overstates the thinking. When the turn's calls that
                    // thought line up one to one with its reasoning items, use their think_ms.
                    let thinks: Vec<u64> = e["usage"]["timing"]["calls"]
                        .as_array()
                        .map(|calls| {
                            calls
                                .iter()
                                .filter(|c| c["compact"] != true)
                                .filter_map(|c| c["think_ms"].as_u64())
                                .filter(|&t| t > 0)
                                .collect()
                        })
                        .unwrap_or_default();
                    if thinks.len() == pending.len() {
                        for (it, t) in pending.iter_mut().zip(thinks) {
                            it.ms = t;
                            it.timed = true;
                        }
                    }
                    let m = e["usage"]["model"]
                        .as_str()
                        .map(str::to_string)
                        .unwrap_or(model.clone());
                    out.entry(m).or_default().append(&mut pending);
                }
                _ => {}
            }
        }
    }
    out
}

fn measure(items: &[Item], samples: bool) -> Stats {
    let mut st = Stats::default();
    let mut lines: Vec<String> = Vec::new();
    for it in items {
        if it.text.is_empty() || it.ms == 0 {
            continue;
        }
        st.items += 1;
        st.timed += it.timed as usize;
        st.secs += it.ms as f64 / 1000.0;
        let mut t = Thoughts::default();
        let bytes = it.text.len();
        let mut changes: Vec<u64> = Vec::new();
        let mut i = 0;
        while i < bytes {
            let mut j = (i + 16).min(bytes);
            while !it.text.is_char_boundary(j) {
                j += 1;
            }
            let at = it.ms * j as u64 / bytes as u64;
            if let Some(l) = t.push(&it.text[i..j], at) {
                changes.push(at);
                st.shown += 1;
                if words(&l) < 3 {
                    st.short += 1;
                    if samples {
                        println!("    short: {l}");
                    }
                }
                if l.chars().count() > MAX_CHARS {
                    st.over_120 += 1;
                }
                if l.ends_with('…') {
                    st.cut += 1;
                }
                lines.push(l);
            }
            i = j;
        }
        if it.ms > 5000 {
            st.long += 1;
            if changes.first().is_none_or(|&c| c > 5000) {
                st.empty_5s += 1;
            }
        }
        let mut prev = 0;
        let mut hold = 0;
        for &c in changes.iter().chain(std::iter::once(&it.ms)) {
            hold = hold.max(c - prev);
            prev = c;
        }
        st.longest_hold_ms = st.longest_hold_ms.max(hold);
        if hold > 10_000 {
            st.stale_10s += 1;
        }
    }
    if samples && !lines.is_empty() {
        let step = (lines.len() / 20).max(1);
        st.samples = lines.iter().step_by(step).take(20).cloned().collect();
    }
    st
}

pub fn run() {
    let Ok(dir) = std::env::var("FROG_THOUGHT_LOGS") else {
        eprintln!("set FROG_THOUGHT_LOGS to a sessions directory");
        return;
    };
    let samples = std::env::var("FROG_THOUGHT_SAMPLES").is_ok();
    println!(
        "| model | items | timed by think_ms | reasoning s | >5 s items empty for first 5 s | items held >10 s | longest hold s | lines shown | <3 words | >120 chars | cut with … |"
    );
    println!("|---|---|---|---|---|---|---|---|---|---|---|");
    for (model, items) in models(&dir) {
        let st = measure(&items, samples);
        if st.items < 5 {
            continue;
        }
        println!(
            "| {model} | {} | {:.0}% | {:.0} | {}/{} ({:.0}%) | {} ({:.0}%) | {:.0} | {} | {} | {} | {} |",
            st.items,
            100.0 * st.timed as f64 / st.items as f64,
            st.secs,
            st.empty_5s,
            st.long,
            100.0 * st.empty_5s as f64 / st.long.max(1) as f64,
            st.stale_10s,
            100.0 * st.stale_10s as f64 / st.items as f64,
            st.longest_hold_ms as f64 / 1000.0,
            st.shown,
            st.short,
            st.over_120,
            st.cut,
        );
        for s in &st.samples {
            println!("    {model}: {s}");
        }
    }
}
