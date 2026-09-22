//! Summaries of bench results.

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

/// One row per model × mode, then a task × config pass grid.
pub fn print(results: &[RunResult]) {
    let mut groups: BTreeMap<Config, Vec<&RunResult>> = BTreeMap::new();
    for r in results {
        groups
            .entry((r.model.clone(), r.mode.clone()))
            .or_default()
            .push(r);
    }

    println!(
        "\n{:<28} {:<7} {:<9} {:>6} {:>7} {:>6} {:>10} {:>6} {:>6}  ends",
        "model", "mode", "resolved", "pass", "avg s", "calls", "tok/solve", "tools", "errs"
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
        let resolved = most_common(runs.iter().filter_map(|r| r.resolved_mode.as_deref()));
        println!(
            "{:<28} {:<7} {:<9} {:>6} {:>7.1} {:>6.1} {:>10} {:>6.1} {:>6.1}  {}",
            model,
            mode,
            resolved,
            format!("{passed}/{n}"),
            avg(|r| r.secs),
            avg(|r| r.model_calls as f64),
            per_solve,
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
            .find(|k| k.0 == r.model && k.1 == r.mode)
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
}
