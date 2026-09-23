//! `kiln-bench`: run a task suite across models and harness configurations.
//!
//! Every harness change should be measured, not guessed. Harness choices move results
//! 40–139x in tokens and up to 30 points in score (arXiv 2607.22585, 2608.08654, 2609.17394).

mod report;
mod run;
mod task;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use kiln_engine::config::{Config, ToolMode, data_dir};
use kiln_engine::harness;
use run::RunResult;
use std::io::Write;
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "kiln-bench",
    about = "Benchmark kiln across models and harness configurations"
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
        /// Where results, sessions and workspaces go. Defaults to ~/.local/share/kiln/bench/<timestamp>.
        #[arg(short, long)]
        out: Option<PathBuf>,
    },
    /// Summarize a results file from an earlier run.
    Report { results: PathBuf },
    /// List the tasks.
    List {
        #[arg(long, default_value = "bench/tasks")]
        tasks: PathBuf,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    match Cli::parse().cmd {
        Cmd::Run {
            models,
            modes,
            tasks,
            filter,
            repeat,
            out,
        } => run_suite(models, modes, tasks, filter, repeat, out).await,
        Cmd::Report { results } => {
            let text = std::fs::read_to_string(&results)?;
            let rows: Vec<RunResult> = text
                .lines()
                .filter(|l| !l.trim().is_empty())
                .map(serde_json::from_str)
                .collect::<Result<_, _>>()?;
            report::print(&rows);
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

async fn run_suite(
    models: Vec<String>,
    modes: Vec<String>,
    tasks_dir: PathBuf,
    filter: Option<String>,
    repeat: u32,
    out: Option<PathBuf>,
) -> Result<()> {
    let cfg = Config::load()?;
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
            if harness::is_hosted(&profile) || harness::cached(&profile).is_some() {
                continue;
            }
            eprintln!("profiling {m}…");
            kiln_engine::sidecar::ensure(&profile).await?;
            let provider = kiln_engine::provider::Provider::new(&profile)?;
            match harness::probe(&provider, &kiln_engine::tools::specs()).await {
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

    let mut results = Vec::new();
    let mut i = 0;
    for model in &models {
        for &mode in &modes {
            for t in &tasks {
                for rep in 1..=repeat {
                    i += 1;
                    let mode_name = format!("{mode:?}").to_lowercase();
                    eprint!("[{i}/{total}] {} · {model} · {mode_name} … ", t.name);
                    let workspace = out
                        .join("work")
                        .join(slug(&format!("{}-{model}-{mode_name}-{rep}", t.name)));
                    let r = run::run(run::Run {
                        cfg: &cfg,
                        model,
                        mode,
                        task: t,
                        rep,
                        workspace,
                        sessions: &sessions,
                    })
                    .await?;
                    eprintln!(
                        "{} {:.1}s ({}{})",
                        if r.pass { "pass" } else { "FAIL" },
                        r.secs,
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
