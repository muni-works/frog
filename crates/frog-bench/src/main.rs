//! `frog-bench`: run a task suite across models and harness configurations.
//!
//! Every harness change should be measured, not guessed. Harness choices move results
//! 40–139x in tokens and up to 30 points in score (arXiv 2607.22585, 2608.08654, 2609.17394).

mod export;
mod report;
mod run;
mod task;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use frog_engine::config::{Config, ToolMode, data_dir};
use frog_engine::harness;
use run::RunResult;
use std::io::Write;
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "frog-bench",
    about = "Benchmark frog across models and harness configurations"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run the task suite.
    Run {
        /// Comma-separated profiles or provider/model specs. Defaults to the configured model.
        #[arg(short, long, value_delimiter = ',')]
        models: Vec<String>,
        /// Comma-separated tool modes: auto, native, text, json.
        #[arg(long, value_delimiter = ',', default_value = "auto")]
        modes: Vec<String>,
        /// Directory of tasks.
        #[arg(long, default_value = "bench/tasks")]
        tasks: PathBuf,
        /// Only tasks whose name contains this.
        #[arg(short, long)]
        filter: Option<String>,
        /// Runs per task × model × mode.
        #[arg(short, long, default_value_t = 1)]
        repeat: u32,
        /// Where results, sessions and workspaces go. Defaults to ~/.local/share/frog/bench/<timestamp>.
        #[arg(short, long)]
        out: Option<PathBuf>,
        /// Override the `thinking` setting: auto, always or never.
        #[arg(long)]
        thinking: Option<String>,
        /// Override `thinking_budget`: most reasoning tokens per call (0 = unlimited). Only
        /// servers that take a budget (tang-llm) apply it.
        #[arg(long)]
        thinking_budget: Option<u32>,
    },
    /// Summarize a results file from an earlier run.
    Report { results: PathBuf },
    /// Write a results file as the public JSON frog.eco/energy reads (no paths or output).
    Export { results: PathBuf },
    /// List the tasks.
    List {
        #[arg(long, default_value = "bench/tasks")]
        tasks: PathBuf,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    frog_engine::config::migrate_from_kiln();
    match Cli::parse().cmd {
        Cmd::Run {
            models,
            modes,
            tasks,
            filter,
            repeat,
            out,
            thinking,
            thinking_budget,
        } => {
            run_suite(
                models,
                modes,
                tasks,
                filter,
                repeat,
                out,
                thinking,
                thinking_budget,
            )
            .await
        }
        Cmd::Report { results } => {
            report::print(&read_results(&results)?);
            Ok(())
        }
        Cmd::Export { results } => {
            println!("{}", export::json(&read_results(&results)?)?);
            Ok(())
        }
        Cmd::List { tasks } => {
            for t in task::load_all(&tasks, None)? {
                println!("{:<24} {}", t.name, t.prompt.lines().next().unwrap_or(""));
            }
            Ok(())
        }
    }
}

fn read_results(path: &std::path::Path) -> Result<Vec<RunResult>> {
    let text = std::fs::read_to_string(path)?;
    Ok(text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(serde_json::from_str)
        .collect::<Result<_, _>>()?)
}

fn slug(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
async fn run_suite(
    models: Vec<String>,
    modes: Vec<String>,
    tasks_dir: PathBuf,
    filter: Option<String>,
    repeat: u32,
    out: Option<PathBuf>,
    thinking: Option<String>,
    thinking_budget: Option<u32>,
) -> Result<()> {
    let mut cfg = Config::load()?;
    // A run measures the harness and the model: none of this machine's own instructions, skills,
    // MCP servers or search backends.
    cfg.hermetic = true;
    cfg.web_search = None;
    cfg.searxng_url = None;
    if let Some(t) = &thinking {
        cfg.thinking = serde_json::from_value(serde_json::json!(t))
            .with_context(|| format!("unknown thinking setting `{t}`"))?;
    }
    if let Some(n) = thinking_budget {
        cfg.thinking_budget = n;
        for p in cfg.models.values_mut() {
            p.thinking_budget = None;
        }
    }
    let tasks = task::load_all(&tasks_dir, filter.as_deref())?;
    let models = if models.is_empty() {
        vec![cfg.resolve(None)?.0]
    } else {
        models
    };
    let modes: Vec<ToolMode> = modes
        .iter()
        .map(|m| {
            serde_json::from_value(serde_json::json!(m))
                .with_context(|| format!("unknown tool mode `{m}`"))
        })
        .collect::<Result<_>>()?;
    if repeat == 0 {
        bail!("--repeat must be at least 1");
    }

    let out = out.unwrap_or_else(|| {
        data_dir()
            .join("bench")
            .join(chrono::Local::now().format("%Y%m%d-%H%M%S").to_string())
    });
    let sessions = out.join("sessions");
    std::fs::create_dir_all(&sessions)?;
    let results_path = out.join("results.jsonl");
    let mut results_file = std::fs::File::create(&results_path)?;

    // Profile models up front so `auto`'s one-time probe doesn't land inside a timed run.
    if modes.contains(&ToolMode::Auto) {
        for m in &models {
            let (_, profile) = cfg.resolve(Some(m))?;
            if harness::is_hosted(&profile) {
                continue;
            }
            if let Some(mut caps) = harness::cached(&profile) {
                // Profiled before frog asked whether thinking can be switched off.
                if caps.thinks && caps.think_off.is_none() {
                    frog_engine::sidecar::ensure(&profile).await?;
                    let provider = frog_engine::provider::Provider::new(&profile)?;
                    caps.think_off = Some(harness::probe_think_off(&provider).await);
                    harness::save(&profile, &caps);
                }
                continue;
            }
            eprintln!("profiling {m}…");
            frog_engine::sidecar::ensure(&profile).await?;
            let provider = frog_engine::provider::Provider::new(&profile)?;
            match harness::probe(&provider, &frog_engine::tools::specs()).await {
                Ok(caps) => harness::save(&profile, &caps),
                Err(e) => eprintln!("  couldn't profile {m}: {e:#}"),
            }
        }
    }

    let total = models.len() * modes.len() * tasks.len() * repeat as usize;
    eprintln!(
        "{total} runs · {} tasks × {} models × {} modes × {repeat}\nresults: {}\n",
        tasks.len(),
        models.len(),
        modes.len(),
        results_path.display()
    );

    // Energy: the whole Mac's power, integrated over each turn, less what it draws at rest.
    let meter = frog_engine::energy::Meter::new();
    if meter.is_none() {
        eprintln!("no power sensor on this machine: energy won't be measured\n");
    }

    let mut results = Vec::new();
    let mut i = 0;
    for model in &models {
        // Load and warm the model first, so idle baselines hold whatever it keeps resident.
        if meter.is_some() {
            let (_, profile) = cfg.resolve(Some(model))?;
            frog_engine::sidecar::ensure(&profile).await?;
        }
        for &mode in &modes {
            for t in &tasks {
                for rep in 1..=repeat {
                    i += 1;
                    let mode_name = format!("{mode:?}").to_lowercase();
                    eprint!("[{i}/{total}] {} · {model} · {mode_name} … ", t.name);
                    // Idle just before this run: what the Mac draws drifts over a suite (other
                    // apps, background work), and one baseline for an hour of runs drifts with it.
                    let idle = match &meter {
                        Some(m) => {
                            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                            Some((m, m.idle_watts(5.0).await))
                        }
                        None => None,
                    };
                    let workspace = out
                        .join("work")
                        .join(slug(&format!("{}-{model}-{mode_name}-{rep}", t.name)));
                    let mut r = run::run(run::Run {
                        cfg: &cfg,
                        model,
                        mode,
                        task: t,
                        rep,
                        workspace,
                        sessions: &sessions,
                        energy: idle,
                    })
                    .await?;
                    r.thinking = thinking.clone();
                    r.thinking_budget = thinking_budget;
                    eprintln!(
                        "{} {:.1}s{} ({}{})",
                        if r.pass { "pass" } else { "FAIL" },
                        r.secs,
                        r.energy
                            .as_ref()
                            .map(|e| format!(
                                " {}{:.2} Wh",
                                if e.remote_wh.is_some() { "~" } else { "" },
                                e.total_wh()
                            ))
                            .unwrap_or_default(),
                        r.end,
                        r.error
                            .as_deref()
                            .map(|e| format!(": {e}"))
                            .unwrap_or_default()
                    );
                    writeln!(results_file, "{}", serde_json::to_string(&r)?)?;
                    results.push(r);
                }
            }
        }
    }
    report::print(&results);
    println!("\nresults: {}", results_path.display());
    Ok(())
}
