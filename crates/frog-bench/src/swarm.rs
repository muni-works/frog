//! `frog-bench swarm`: the "no caps" proof. N agents work a task set in parallel for a fixed
//! wall time, each run in its own git worktree of one repo, each model call placed by the node
//! pool's scheduler. It reports what finished and passed, every stall (a call that waited past
//! the threshold, or a retry storm from a 429/5xx), throughput per node, prefill the cache saved,
//! dollars per passed task, and where calls ran over time. With `--baseline`, the same swarm runs
//! first on the baseline spec (one node, say), and the report checks additivity: no task's median
//! gets worse with more hardware.

use crate::run::{self, RunResult};
use crate::task::{self, Task};
use anyhow::{Context, Result, bail};
use frog_engine::config::{Config, ToolMode};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

pub struct Args {
    pub model: String,
    pub baseline: Option<String>,
    pub agents: usize,
    pub minutes: f64,
    pub tasks: Vec<Task>,
    pub stall_secs: f64,
    pub kwh_usd: f64,
    pub out: PathBuf,
}

/// One run in the swarm.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwarmRun {
    pub worker: usize,
    /// Seconds from the phase's start.
    pub start_s: f64,
    pub end_s: f64,
    /// Calls that waited longer than the stall threshold for their first token.
    pub stalls: u32,
    /// The longest wait for a first token, in seconds.
    pub max_wait_s: f64,
    pub result: RunResult,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct NodeStats {
    pub calls: u64,
    pub runs_mostly_here: u64,
    pub prompt_tokens: u64,
    pub cached_tokens: u64,
    pub output_tokens: u64,
    /// Output tokens over the phase's wall time: what this node added.
    pub tok_s: f64,
    /// Median decode rate of its calls (output ÷ decode time).
    pub decode_tok_s: f64,
    /// Share of the phase's calls.
    pub share: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Summary {
    pub runs: u64,
    pub passed: u64,
    pub stalls: u64,
    pub retries: u64,
    pub max_wait_s: f64,
    pub model_calls: u64,
    pub output_tokens: u64,
    /// Every output token over the phase's wall time.
    pub agg_tok_s: f64,
    pub prompt_tokens: u64,
    /// Prompt tokens the nodes served from KV instead of prefilling.
    pub prefill_saved_tokens: u64,
    /// The same, on each session's first call only: the shared repo head found in KV.
    pub first_call_prompt_tokens: u64,
    pub first_call_cached_tokens: u64,
    pub per_node: BTreeMap<String, NodeStats>,
    /// Median run time of each task, in seconds (passed or not).
    pub task_median_s: BTreeMap<String, f64>,
    pub energy_wh: Option<f64>,
    pub energy_usd: f64,
    pub cloud_usd: f64,
    pub usd_per_pass: Option<f64>,
    /// Watt-hours per passed task (this Mac only; paired nodes don't report power).
    pub wh_per_pass: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Phase {
    pub label: String,
    pub model: String,
    pub wall_s: f64,
    pub summary: Summary,
    pub runs: Vec<SwarmRun>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Additivity {
    pub baseline: String,
    pub pooled: String,
    /// task → (baseline median s, pooled median s)
    pub tasks: BTreeMap<String, (f64, f64)>,
    /// Tasks whose median got worse with the pool (beyond 5% noise).
    pub worse: Vec<String>,
    pub holds: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Report {
    pub started: String,
    pub agents: usize,
    pub minutes: f64,
    pub stall_secs: f64,
    pub kwh_usd: f64,
    pub tasks: Vec<String>,
    pub phases: Vec<Phase>,
    pub additivity: Option<Additivity>,
}

pub async fn swarm(cfg: Config, mut a: Args) -> Result<Report> {
    if a.agents == 0 {
        bail!("--agents must be at least 1");
    }
    if a.tasks.is_empty() {
        bail!("no tasks");
    }
    std::fs::create_dir_all(&a.out)?;
    // Absolute: git runs inside each seeded repo, and a relative worktree path would land
    // there instead, leaving the run in a plain folder of whatever checkout holds it.
    a.out = a.out.canonicalize()?;
    let cfg = Arc::new(cfg);
    let tasks = Arc::new(a.tasks.clone());
    let repos = seed_repos(&tasks, &a.out.join("repos"))?;
    let mut phases = Vec::new();
    let mut specs: Vec<(&str, &str)> = Vec::new();
    if let Some(b) = &a.baseline {
        specs.push(("baseline", b));
    }
    specs.push(("pooled", &a.model));
    for (label, spec) in specs {
        eprintln!(
            "\n== {label}: {spec} · {} agents · {} min ==",
            a.agents, a.minutes
        );
        let p = phase(&cfg, &tasks, &repos, label, spec, &a).await?;
        print_summary(&p);
        std::fs::write(
            a.out.join(format!("{label}.json")),
            serde_json::to_string_pretty(&p)?,
        )?;
        phases.push(p);
    }
    let additivity = (phases.len() == 2).then(|| additivity(&phases[0], &phases[1]));
    Ok(Report {
        started: chrono::Local::now().to_rfc3339(),
        agents: a.agents,
        minutes: a.minutes,
        stall_secs: a.stall_secs,
        kwh_usd: a.kwh_usd,
        tasks: tasks.iter().map(|t| t.name.clone()).collect(),
        phases,
        additivity,
    })
}

/// Each task's files as a git repo, committed once: the runs are worktrees of it.
fn seed_repos(tasks: &[Task], dir: &Path) -> Result<Vec<PathBuf>> {
    tasks
        .iter()
        .map(|t| {
            let repo = dir.join(crate::slug(&t.name));
            if repo.exists() {
                std::fs::remove_dir_all(&repo)?;
            }
            task::seed(t, &repo)?;
            git(&repo, &["init", "-q"])?;
            git(&repo, &["add", "-A"])?;
            git(
                &repo,
                &[
                    "-c",
                    "user.name=frog-bench",
                    "-c",
                    "user.email=bench@frog.local",
                    "commit",
                    "-q",
                    "--allow-empty",
                    "-m",
                    "seed",
                ],
            )?;
            Ok(repo)
        })
        .collect()
}

fn git(dir: &Path, args: &[&str]) -> Result<()> {
    let o = std::process::Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .with_context(|| format!("git {args:?}"))?;
    if !o.status.success() {
        bail!(
            "git {args:?} in {}: {}",
            dir.display(),
            String::from_utf8_lossy(&o.stderr)
        );
    }
    Ok(())
}

async fn phase(
    cfg: &Arc<Config>,
    tasks: &Arc<Vec<Task>>,
    repos: &[PathBuf],
    label: &str,
    spec: &str,
    a: &Args,
) -> Result<Phase> {
    let meter = frog_engine::energy::Meter::new().map(Arc::new);
    let idle_w = match &meter {
        Some(m) => Some(m.idle_watts(5.0).await),
        None => None,
    };
    let mark = meter.as_ref().map(|m| m.mark());
    let started = Instant::now();
    let deadline = started + Duration::from_secs_f64(a.minutes * 60.0);
    let next = Arc::new(AtomicUsize::new(0));
    let sessions = a.out.join(label).join("sessions");
    std::fs::create_dir_all(&sessions)?;
    let results_path = a.out.join(format!("{label}.jsonl"));
    let file = Arc::new(std::sync::Mutex::new(std::fs::File::create(&results_path)?));
    let mut set = tokio::task::JoinSet::new();
    for worker in 0..a.agents {
        let (cfg, tasks, next, file) = (cfg.clone(), tasks.clone(), next.clone(), file.clone());
        let repos = repos.to_vec();
        let spec = spec.to_string();
        let wt_dir = a.out.join(label).join("wt");
        let sessions = sessions.clone();
        let stall_ms = (a.stall_secs * 1000.0) as u64;
        set.spawn(async move {
            let mut done = Vec::new();
            // Stagger the start a little, as people do; all at once is the worst case anyway.
            tokio::time::sleep(Duration::from_millis(250 * worker as u64)).await;
            while Instant::now() < deadline {
                let i = next.fetch_add(1, Ordering::Relaxed);
                let t = &tasks[i % tasks.len()];
                let repo = &repos[i % tasks.len()];
                let wt = wt_dir.join(format!("{i:04}-{}", crate::slug(&t.name)));
                if let Err(e) = git(
                    repo,
                    &["worktree", "add", "-q", "--detach", &wt.to_string_lossy()],
                ) {
                    eprintln!("  worker {worker}: {e:#}");
                    break;
                }
                let start_s = started.elapsed().as_secs_f64();
                let r = run::run(run::Run {
                    cfg: &cfg,
                    model: &spec,
                    mode: ToolMode::Auto,
                    task: t,
                    rep: i as u32,
                    workspace: wt,
                    sessions: &sessions,
                    energy: None,
                })
                .await;
                let end_s = started.elapsed().as_secs_f64();
                let r = match r {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("  worker {worker}: {} errored: {e:#}", t.name);
                        // Don't spin through the task list on a setup error.
                        tokio::time::sleep(Duration::from_secs(5)).await;
                        continue;
                    }
                };
                let stalls = r.calls.iter().filter(|c| c.prefill_ms > stall_ms).count() as u32;
                let max_wait_s = r
                    .calls
                    .iter()
                    .map(|c| c.prefill_ms as f64 / 1000.0)
                    .fold(0.0, f64::max);
                eprintln!(
                    "  [{end_s:6.0}s] w{worker} {:<20} {} {:5.1}s {} calls{}{}",
                    t.name,
                    if r.pass { "pass" } else { "FAIL" },
                    end_s - start_s,
                    r.calls.len(),
                    nodes_line(&r),
                    if stalls > 0 {
                        format!(" · {stalls} stalls")
                    } else {
                        String::new()
                    }
                );
                let run = SwarmRun {
                    worker,
                    start_s,
                    end_s,
                    stalls,
                    max_wait_s,
                    result: r,
                };
                if let Ok(line) = serde_json::to_string(&run) {
                    use std::io::Write;
                    let _ = writeln!(file.lock().unwrap(), "{line}");
                }
                done.push(run);
            }
            done
        });
    }
    let mut runs = Vec::new();
    while let Some(r) = set.join_next().await {
        runs.extend(r?);
    }
    runs.sort_by(|a, b| a.start_s.total_cmp(&b.start_s));
    let wall_s = started.elapsed().as_secs_f64();
    let energy_wh = match (&meter, idle_w, &mark) {
        (Some(m), Some(idle), Some(mark)) => Some(m.since(mark).above_idle_wh(idle)),
        _ => None,
    };
    let summary = summarize(&runs, wall_s, energy_wh, spec, a.kwh_usd);
    Ok(Phase {
        label: label.into(),
        model: spec.into(),
        wall_s,
        summary,
        runs,
    })
}

fn nodes_line(r: &RunResult) -> String {
    let mut by: BTreeMap<&str, u32> = BTreeMap::new();
    for c in &r.calls {
        *by.entry(c.node.as_deref().unwrap_or("?")).or_default() += 1;
    }
    if by.keys().all(|k| *k == "?") {
        return String::new();
    }
    let parts: Vec<String> = by.iter().map(|(k, n)| format!("{k}×{n}")).collect();
    format!(" on {}", parts.join(" "))
}

fn median(mut v: Vec<f64>) -> f64 {
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(f64::total_cmp);
    let n = v.len();
    if n % 2 == 1 {
        v[n / 2]
    } else {
        (v[n / 2 - 1] + v[n / 2]) / 2.0
    }
}

pub fn summarize(
    runs: &[SwarmRun],
    wall_s: f64,
    energy_wh: Option<f64>,
    spec: &str,
    kwh_usd: f64,
) -> Summary {
    let mut s = Summary {
        energy_wh,
        ..Summary::default()
    };
    let mut decode: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut by_task: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut input = 0u64;
    for r in runs {
        let res = &r.result;
        s.runs += 1;
        s.passed += res.pass as u64;
        s.stalls += r.stalls as u64;
        s.retries += res.retries as u64;
        s.max_wait_s = s.max_wait_s.max(r.max_wait_s);
        input += res.input_tokens;
        by_task
            .entry(res.task.clone())
            .or_default()
            .push(r.end_s - r.start_s);
        let mut mostly: BTreeMap<&str, u32> = BTreeMap::new();
        for (i, c) in res.calls.iter().enumerate() {
            s.model_calls += 1;
            s.output_tokens += c.output_tokens;
            s.prompt_tokens += c.prompt_tokens;
            s.prefill_saved_tokens += c.cached_tokens;
            if i == 0 {
                s.first_call_prompt_tokens += c.prompt_tokens;
                s.first_call_cached_tokens += c.cached_tokens;
            }
            let node = c.node.clone().unwrap_or_else(|| "unpooled".into());
            *mostly
                .entry(c.node.as_deref().unwrap_or("unpooled"))
                .or_default() += 1;
            let n = s.per_node.entry(node.clone()).or_default();
            n.calls += 1;
            n.prompt_tokens += c.prompt_tokens;
            n.cached_tokens += c.cached_tokens;
            n.output_tokens += c.output_tokens;
            if c.output_tokens >= 16 && c.decode_ms > 0 {
                decode
                    .entry(node)
                    .or_default()
                    .push(c.output_tokens as f64 * 1000.0 / c.decode_ms as f64);
            }
        }
        if let Some((k, _)) = mostly.iter().max_by_key(|(_, n)| **n) {
            s.per_node
                .entry(k.to_string())
                .or_default()
                .runs_mostly_here += 1;
        }
    }
    let wall = wall_s.max(1e-9);
    s.agg_tok_s = s.output_tokens as f64 / wall;
    for (k, n) in s.per_node.iter_mut() {
        n.tok_s = n.output_tokens as f64 / wall;
        n.share = n.calls as f64 / s.model_calls.max(1) as f64;
        n.decode_tok_s = median(decode.remove(k).unwrap_or_default());
    }
    s.task_median_s = by_task.into_iter().map(|(k, v)| (k, median(v))).collect();
    s.energy_usd = energy_wh.unwrap_or(0.0) / 1000.0 * kwh_usd;
    // Hardware you own costs nothing per token; a hosted model, its catalog price per token.
    if !spec.starts_with("node/")
        && let Some(m) = frog_engine::catalog::cached(spec)
        && let (Some(i), Some(o)) = (m.cost_in, m.cost_out)
    {
        s.cloud_usd = (input as f64 * i + s.output_tokens as f64 * o) / 1e6;
    }
    if s.passed > 0 {
        s.usd_per_pass = Some((s.energy_usd + s.cloud_usd) / s.passed as f64);
        s.wh_per_pass = energy_wh.map(|e| e / s.passed as f64);
    }
    s
}

pub fn additivity(base: &Phase, pooled: &Phase) -> Additivity {
    let mut tasks = BTreeMap::new();
    let mut worse = Vec::new();
    for (t, b) in &base.summary.task_median_s {
        let Some(p) = pooled.summary.task_median_s.get(t) else {
            continue;
        };
        if *p > b * 1.05 {
            worse.push(t.clone());
        }
        tasks.insert(t.clone(), (*b, *p));
    }
    Additivity {
        baseline: base.model.clone(),
        pooled: pooled.model.clone(),
        holds: worse.is_empty() && !tasks.is_empty(),
        tasks,
        worse,
    }
}

fn print_summary(p: &Phase) {
    let s = &p.summary;
    println!(
        "{}: {} runs, {} passed, {} stalls, {} retries, longest wait {:.1}s · {:.1} tok/s over {:.0}s",
        p.label, s.runs, s.passed, s.stalls, s.retries, s.max_wait_s, s.agg_tok_s, p.wall_s
    );
    println!(
        "  prefill saved by cache: {} of {} prompt tokens ({:.0}%), first calls {} of {}",
        s.prefill_saved_tokens,
        s.prompt_tokens,
        100.0 * s.prefill_saved_tokens as f64 / s.prompt_tokens.max(1) as f64,
        s.first_call_cached_tokens,
        s.first_call_prompt_tokens
    );
    for (k, n) in &s.per_node {
        println!(
            "  {k:<12} {:>5} calls ({:>3.0}%) {:>7.1} tok/s added, {:>6.1} tok/s decode",
            n.calls,
            n.share * 100.0,
            n.tok_s,
            n.decode_tok_s
        );
    }
    if let Some(u) = s.usd_per_pass {
        println!("  ${u:.5} per passed task");
    }
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

const PALETTE: [&str; 6] = [
    "#2f7d4f", "#c46b1f", "#3b6fb6", "#8a4fa8", "#b23b3b", "#5d6b78",
];

/// A self-contained HTML page: headline numbers, per node, placement over time, additivity.
pub fn html(r: &Report) -> String {
    let mut nodes: Vec<String> = r
        .phases
        .iter()
        .flat_map(|p| p.summary.per_node.keys().cloned())
        .collect();
    nodes.sort();
    nodes.dedup();
    let color = |n: &str| {
        let i = nodes.iter().position(|x| x == n).unwrap_or(0);
        PALETTE[i % PALETTE.len()]
    };
    let mut h = String::new();
    h.push_str(&format!(
        r#"<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>No caps bench</title><style>
:root{{--bg:#fbfaf7;--fg:#1d1f1c;--mut:#6b6f68;--line:#e2e0d9}}
@media (prefers-color-scheme:dark){{:root{{--bg:#151714;--fg:#e8e6df;--mut:#9a9d95;--line:#2c2f2a}}}}
body{{background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,system-ui,sans-serif;margin:0 auto;max-width:960px;padding:24px 16px}}
h1{{font-size:22px;margin:0 0 4px}} h2{{font-size:16px;margin:28px 0 8px}} .mut{{color:var(--mut)}}
table{{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}} td,th{{padding:5px 8px;border-bottom:1px solid var(--line);text-align:right}}
td:first-child,th:first-child{{text-align:left}} .ok{{color:#2f7d4f}} .bad{{color:#b23b3b}}
.wrap{{overflow-x:auto}} svg text{{fill:var(--mut);font-size:11px}}
</style></head><body>
<h1>No caps: {} agents in parallel</h1>
<p class="mut">{} · {} min per phase · tasks: {} · a stall is a call waiting over {}s for its first token, or a retry storm</p>
"#,
        r.agents,
        esc(&r.started),
        r.minutes,
        esc(&r.tasks.join(", ")),
        r.stall_secs
    ));
    h.push_str("<h2>Headline</h2><div class=wrap><table><tr><th>phase</th><th>model</th><th>runs</th><th>passed</th><th>stalls</th><th>retries</th><th>longest wait</th><th>tok/s</th><th>prefill saved</th><th>$ / pass</th><th>Wh / pass (Mac)</th></tr>");
    for p in &r.phases {
        let s = &p.summary;
        h.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td class={}>{}</td><td>{}</td><td>{:.1}s</td><td>{:.1}</td><td>{:.0}%</td><td>{}</td><td>{}</td></tr>",
            p.label,
            esc(&p.model),
            s.runs,
            s.passed,
            if s.stalls == 0 { "ok" } else { "bad" },
            s.stalls,
            s.retries,
            s.max_wait_s,
            s.agg_tok_s,
            100.0 * s.prefill_saved_tokens as f64 / s.prompt_tokens.max(1) as f64,
            s.usd_per_pass.map_or("–".into(), |u| format!("${u:.5}")),
            s.wh_per_pass.map_or("–".into(), |w| format!("{w:.2}")),
        ));
    }
    h.push_str("</table></div>");
    h.push_str("<h2>Per node</h2><div class=wrap><table><tr><th>phase</th><th>node</th><th>calls</th><th>share</th><th>runs mostly here</th><th>tok/s added</th><th>decode tok/s</th><th>KV hit</th></tr>");
    for p in &r.phases {
        for (k, n) in &p.summary.per_node {
            h.push_str(&format!(
                "<tr><td>{}</td><td><span style=\"color:{}\">■</span> {}</td><td>{}</td><td>{:.0}%</td><td>{}</td><td>{:.1}</td><td>{:.1}</td><td>{:.0}%</td></tr>",
                p.label,
                color(k),
                esc(k),
                n.calls,
                n.share * 100.0,
                n.runs_mostly_here,
                n.tok_s,
                n.decode_tok_s,
                100.0 * n.cached_tokens as f64 / n.prompt_tokens.max(1) as f64
            ));
        }
    }
    h.push_str("</table></div>");
    for p in &r.phases {
        h.push_str(&format!(
            "<h2>Placement over time: {}</h2><p class=mut>One row per agent; each run is a bar split by where its calls ran (calls spread evenly over the run). Hatched: failed check.</p>",
            p.label
        ));
        h.push_str(&timeline(p, r.agents, &color));
    }
    if let Some(a) = &r.additivity {
        h.push_str(&format!(
            "<h2>One node vs more: additivity <span class={}>{}</span></h2><p class=mut>{} vs {}: no task's median may get worse (5% noise band).</p><div class=wrap><table><tr><th>task</th><th>baseline median</th><th>pooled median</th><th>speedup</th></tr>",
            if a.holds { "ok" } else { "bad" },
            if a.holds { "holds" } else { "broken" },
            esc(&a.baseline),
            esc(&a.pooled)
        ));
        for (t, (b, p)) in &a.tasks {
            h.push_str(&format!(
                "<tr><td>{}</td><td>{b:.1}s</td><td class={}>{p:.1}s</td><td>{:.2}×</td></tr>",
                esc(t),
                if a.worse.contains(t) { "bad" } else { "ok" },
                b / p.max(1e-9)
            ));
        }
        h.push_str("</table></div>");
    }
    h.push_str("</body></html>\n");
    h
}

fn timeline(p: &Phase, agents: usize, color: &dyn Fn(&str) -> &'static str) -> String {
    let (w, row, left) = (900.0, 18.0, 40.0);
    let span = p.wall_s.max(1.0);
    let x = |t: f64| left + (t / span) * (w - left - 10.0);
    let height = row * agents as f64 + 24.0;
    let mut s = format!(
        r#"<div class=wrap><svg viewBox="0 0 {w} {height}" width="100%" style="min-width:600px"><defs><pattern id="hatch" width="4" height="4" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="4" stroke="rgba(0,0,0,.35)" stroke-width="1.5"/></pattern></defs>"#
    );
    for a in 0..agents {
        s.push_str(&format!(
            r#"<text x="0" y="{}">a{a}</text>"#,
            row * a as f64 + 13.0
        ));
    }
    for r in &p.runs {
        let y = row * r.worker as f64 + 2.0;
        let calls = &r.result.calls;
        let (x0, x1) = (x(r.start_s), x(r.end_s));
        if calls.is_empty() {
            s.push_str(&format!(
                r##"<rect x="{x0:.1}" y="{y}" width="{:.1}" height="{}" fill="#999"/>"##,
                (x1 - x0).max(0.5),
                row - 4.0
            ));
        }
        let step = (x1 - x0) / calls.len().max(1) as f64;
        for (i, c) in calls.iter().enumerate() {
            s.push_str(&format!(
                r#"<rect x="{:.1}" y="{y}" width="{:.2}" height="{}" fill="{}"><title>{} · {}</title></rect>"#,
                x0 + step * i as f64,
                step.max(0.3),
                row - 4.0,
                color(c.node.as_deref().unwrap_or("unpooled")),
                esc(&r.result.task),
                esc(c.node.as_deref().unwrap_or("unpooled"))
            ));
        }
        if !r.result.pass {
            s.push_str(&format!(
                r#"<rect x="{x0:.1}" y="{y}" width="{:.1}" height="{}" fill="url(#hatch)"/>"#,
                (x1 - x0).max(0.5),
                row - 4.0
            ));
        }
    }
    let base = row * agents as f64 + 16.0;
    for m in 0..=((span / 60.0).ceil() as u64) {
        let t = m as f64 * 60.0;
        if t > span {
            break;
        }
        s.push_str(&format!(
            r#"<text x="{:.1}" y="{base}">{m}m</text>"#,
            x(t) - 6.0
        ));
    }
    s.push_str("</svg></div>");
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cache::Call;

    fn run(
        task: &str,
        worker: usize,
        secs: (f64, f64),
        pass: bool,
        calls: &[(&str, u64, u64, u64)],
    ) -> SwarmRun {
        let mut r: RunResult = serde_json::from_value(serde_json::json!({
            "task": task, "model": "node/x", "mode": "auto", "resolved_mode": null, "tier": null,
            "rep": 0, "pass": pass, "end": "complete", "error": null, "secs": secs.1 - secs.0,
            "model_calls": 0, "input_tokens": 0, "output_tokens": 0, "tool_calls": 0,
            "tool_errors": 0, "refused_repeats": 0, "pruned": 0, "compacted": 0,
            "session": "s", "workspace": "/tmp", "check_output": ""
        }))
        .unwrap();
        r.calls = calls
            .iter()
            .map(|(node, prompt, cached, ttft)| Call {
                prompt_tokens: *prompt,
                cached_tokens: *cached,
                prefill_ms: *ttft,
                output_tokens: 100,
                decode_ms: 1000,
                node: Some(node.to_string()),
                ..Call::default()
            })
            .collect();
        SwarmRun {
            worker,
            start_s: secs.0,
            end_s: secs.1,
            stalls: r.calls.iter().filter(|c| c.prefill_ms > 10_000).count() as u32,
            max_wait_s: 0.0,
            result: r,
        }
    }

    #[test]
    fn summary_counts_width_cache_and_stalls() {
        let runs = vec![
            run(
                "a",
                0,
                (0.0, 10.0),
                true,
                &[("mew", 4000, 0, 500), ("mew", 4200, 4000, 200)],
            ),
            run(
                "a",
                1,
                (0.0, 20.0),
                false,
                &[("this Mac", 4000, 3000, 12_000)],
            ),
        ];
        let s = summarize(&runs, 20.0, Some(2.0), "node/x", 0.15);
        assert_eq!((s.runs, s.passed, s.stalls), (2, 1, 1));
        assert_eq!(s.prefill_saved_tokens, 7000);
        assert_eq!(
            (s.first_call_prompt_tokens, s.first_call_cached_tokens),
            (8000, 3000)
        );
        assert_eq!(s.per_node["mew"].calls, 2);
        assert_eq!(s.per_node["this Mac"].runs_mostly_here, 1);
        assert!((s.agg_tok_s - 15.0).abs() < 1e-9);
        assert!((s.per_node["mew"].decode_tok_s - 100.0).abs() < 1e-9);
        assert_eq!(s.task_median_s["a"], 15.0);
        // Local hardware: only the Mac's energy.
        assert!((s.usd_per_pass.unwrap() - 0.0003).abs() < 1e-9);
    }

    #[test]
    fn additivity_flags_a_task_that_got_slower() {
        let phase = |label: &str, runs: Vec<SwarmRun>| Phase {
            label: label.into(),
            model: label.into(),
            wall_s: 60.0,
            summary: summarize(&runs, 60.0, None, "node/x", 0.0),
            runs,
        };
        let one = phase(
            "one",
            vec![
                run("a", 0, (0.0, 30.0), true, &[]),
                run("b", 0, (0.0, 10.0), true, &[]),
            ],
        );
        let two = phase(
            "two",
            vec![
                run("a", 0, (0.0, 20.0), true, &[]),
                run("b", 0, (0.0, 10.4), true, &[]),
            ],
        );
        let add = additivity(&one, &two);
        assert!(add.holds, "{add:?}");
        let worse = phase(
            "two",
            vec![
                run("a", 0, (0.0, 20.0), true, &[]),
                run("b", 0, (0.0, 12.0), true, &[]),
            ],
        );
        let add = additivity(&one, &worse);
        assert_eq!(add.worse, vec!["b".to_string()]);
        let page = html(&Report {
            started: "now".into(),
            agents: 1,
            minutes: 1.0,
            stall_secs: 10.0,
            kwh_usd: 0.15,
            tasks: vec!["a".into()],
            phases: vec![one, worse],
            additivity: Some(add),
        });
        assert!(page.contains("broken") && page.contains("<svg"));
    }
}
