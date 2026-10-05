//! Summaries of bench results.

use crate::cache::{Call, Summary};
use crate::run::RunResult;
use std::collections::BTreeMap;

/// (model, mode)
type Config = (String, String);

fn most_common<'a>(items: impl Iterator<Item = &'a str>) -> String {
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    for i in items {
        *counts.entry(i).or_default() += 1;
    }
    counts
        .into_iter()
        .max_by_key(|(_, n)| *n)
        .map(|(k, _)| k.to_string())
        .unwrap_or_default()
}

fn ends(runs: &[&RunResult]) -> String {
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    for r in runs {
        *counts.entry(r.end.as_str()).or_default() += 1;
    }
    counts
        .into_iter()
        .map(|(k, n)| format!("{k} {n}"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// The tool mode, plus the thinking setting and budget when the run set them.
fn label(r: &RunResult) -> String {
    let mut l = match &r.thinking {
        Some(t) => format!("{}/{t}", r.mode),
        None => r.mode.clone(),
    };
    if let Some(n) = r.thinking_budget {
        l.push_str(&format!("/b{n}"));
    }
    l
}

/// Energy over every run, failures included, per task solved; `~` when part of it is a hosted
/// model's estimate rather than a measurement.
fn wh_per_solve(runs: &[&RunResult]) -> String {
    let passed = runs.iter().filter(|r| r.pass).count();
    let measured: Vec<_> = runs.iter().filter_map(|r| r.energy.as_ref()).collect();
    if passed == 0 || measured.len() < runs.len() {
        return "—".into();
    }
    let wh: f64 = measured.iter().map(|e| e.total_wh()).sum::<f64>() / passed as f64;
    let est = if measured.iter().any(|e| e.remote_wh.is_some()) {
        "~"
    } else {
        ""
    };
    format!("{est}{wh:.2}")
}

/// One row per model × mode, then a task × config pass grid.
pub fn print(results: &[RunResult]) {
    let mut groups: BTreeMap<Config, Vec<&RunResult>> = BTreeMap::new();
    for r in results {
        groups
            .entry((r.model.clone(), label(r)))
            .or_default()
            .push(r);
    }

    println!(
        "\n{:<28} {:<12} {:<9} {:>6} {:>7} {:>6} {:>10} {:>9} {:>7} {:>7} {:>6} {:>6}  ends",
        "model",
        "mode",
        "resolved",
        "pass",
        "avg s",
        "calls",
        "tok/solve",
        "Wh/solve",
        "out tok",
        "think s",
        "tools",
        "errs"
    );
    for ((model, mode), runs) in &groups {
        let n = runs.len();
        let passed = runs.iter().filter(|r| r.pass).count();
        let avg = |f: fn(&RunResult) -> f64| runs.iter().map(|r| f(r)).sum::<f64>() / n as f64;
        let tokens: u64 = runs.iter().map(|r| r.input_tokens + r.output_tokens).sum();
        let per_solve = if passed > 0 {
            format!("{}", tokens / passed as u64)
        } else {
            "—".into()
        };
        let wh_per_solve = wh_per_solve(runs);
        let resolved = most_common(runs.iter().filter_map(|r| r.resolved_mode.as_deref()));
        println!(
            "{:<28} {:<12} {:<9} {:>6} {:>7.1} {:>6.1} {:>10} {:>9} {:>7.0} {:>7.1} {:>6.1} {:>6.1}  {}",
            model,
            mode,
            resolved,
            format!("{passed}/{n}"),
            avg(|r| r.secs),
            avg(|r| r.model_calls as f64),
            per_solve,
            wh_per_solve,
            avg(|r| r.output_tokens as f64),
            avg(|r| r.think_ms as f64 / 1000.0),
            avg(|r| r.tool_calls as f64),
            avg(|r| r.tool_errors as f64),
            ends(runs),
        );
    }

    let configs: Vec<&Config> = groups.keys().collect();
    let mut tasks: BTreeMap<&str, BTreeMap<&Config, (usize, usize)>> = BTreeMap::new();
    for r in results {
        let key = configs
            .iter()
            .find(|k| k.0 == r.model && k.1 == label(r))
            .unwrap();
        let cell = tasks.entry(&r.task).or_default().entry(key).or_default();
        cell.1 += 1;
        if r.pass {
            cell.0 += 1;
        }
    }
    println!();
    print!("{:<24}", "task");
    for (i, _) in configs.iter().enumerate() {
        print!(" {:>6}", format!("[{}]", i + 1));
    }
    println!();
    for (task, cells) in &tasks {
        print!("{task:<24}");
        for c in &configs {
            let (p, n) = cells.get(c).copied().unwrap_or((0, 0));
            print!(
                " {:>6}",
                if n == 0 {
                    "·".into()
                } else {
                    format!("{p}/{n}")
                }
            );
        }
        println!();
    }
    for (i, (model, mode)) in configs.iter().enumerate() {
        println!("  [{}] {model} · {mode}", i + 1);
    }
    print_cache(&groups);
}

fn pct(x: Option<f64>) -> String {
    x.map(|x| format!("{:.0}%", x * 100.0))
        .unwrap_or_else(|| "—".into())
}

fn cache_row(name: &str, s: &Summary) {
    println!(
        "  {:<26} {:>6} {:>6} {:>10} {:>9} {:>5} {:>8} {:>9}",
        name,
        s.calls,
        pct(s.hit_rate()),
        s.prefilled_per_call()
            .map(|n| format!("{n:.0}"))
            .unwrap_or_default(),
        s.prefill_s_per_call()
            .map(|n| format!("{n:.2}"))
            .unwrap_or_default(),
        s.cold,
        s.rewrites,
        if s.reopened > 0 {
            pct(s.reopened_hit_rate())
        } else {
            "·".into()
        },
    );
}

/// How much prefill the server's prompt cache saved, per model × mode and task, and the calls
/// where it should have saved more (see `cache`). Only for runs that recorded calls.
fn print_cache(groups: &BTreeMap<Config, Vec<&RunResult>>) {
    if !groups.values().flatten().any(|r| !r.calls.is_empty()) {
        return;
    }
    println!(
        "\nprompt cache{:<16} {:>6} {:>6} {:>10} {:>9} {:>5} {:>8} {:>9}",
        "", "calls", "hit", "prefill/c", "pf s/c", "cold", "rewrites", "reopened"
    );
    let mut cold = Vec::new();
    for ((model, mode), runs) in groups {
        println!("{model} · {mode}");
        let mut tasks: BTreeMap<&str, Vec<&Call>> = BTreeMap::new();
        for r in runs {
            tasks.entry(&r.task).or_default().extend(&r.calls);
            cold.extend(r.calls.iter().filter(|c| c.cold).map(|c| (*r, c)));
        }
        for (task, calls) in &tasks {
            cache_row(task, &Summary::of(calls.iter().copied()));
        }
        cache_row("all", &Summary::of(runs.iter().flat_map(|r| &r.calls)));
    }
    println!(
        "  hit: cached share of prompt tokens · prefill/c: tokens prefilled per call · cold: calls \
         that only appended to the last request yet prefilled most of it · rewrites: calls frog \
         sent that didn't extend the last · reopened: hit on a resumed or new conversation's \
         first call"
    );
    if cold.is_empty() {
        return;
    }
    println!("\ncold calls (cache busts):");
    for (r, c) in cold.iter().take(12) {
        println!(
            "  {} · {} · rep {} · turn {}: {} prompt tokens, {} cached of ~{} expected, {:.2}s · session {}",
            r.task,
            r.model,
            r.rep,
            c.turn + 1,
            c.prompt_tokens,
            c.cached_tokens,
            c.expected_cached(),
            c.prefill_ms as f64 / 1000.0,
            r.sessions
                .get(c.conversation as usize)
                .unwrap_or(&r.session),
        );
    }
    if cold.len() > 12 {
        println!("  … and {} more", cold.len() - 12);
    }
}
