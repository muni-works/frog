//! `frog-bench export`: a results file as the public JSON frog.eco/energy reads. Everything a
//! reader needs to check the numbers, nothing about the machine's owner (no paths, no output).

use crate::run::RunResult;
use anyhow::Result;
use frog_engine::energy::cloud;
use serde::Serialize;
use std::collections::BTreeMap;
use std::process::Command;

/// The task suite's name, changed whenever tasks are added, removed or edited, so numbers from
/// different suites are never compared.
pub const SUITE: &str = "v1";

/// Grams of CO2e per kWh: the world's average electricity in 2025 (Ember, Global Electricity
/// Review 2026). Used for both a Mac's grid and a data center's.
pub const GRID_G_PER_KWH: f64 = 458.0;

#[derive(Serialize)]
struct Export {
    suite: &'static str,
    date: String,
    machine: Machine,
    method: Method,
    models: Vec<Summary>,
    runs: Vec<Run>,
    /// The per-model data center estimates hosted models get, with their sources.
    remote_estimates: Vec<RemoteEstimate>,
}

#[derive(Serialize)]
struct RemoteEstimate {
    model: String,
    active_b: Option<f64>,
    wh_per_input_token: f64,
    wh_per_output_token: f64,
    basis: String,
    source: &'static str,
}

#[derive(Serialize)]
struct Machine {
    chip: String,
    memory_gb: u64,
    macos: String,
}

#[derive(Serialize)]
struct Method {
    local: &'static str,
    remote: &'static str,
    remote_wh_per_input_token: f64,
    remote_wh_per_output_token: f64,
    grid_g_per_kwh: f64,
    grid_basis: &'static str,
}

#[derive(Serialize)]
struct Summary {
    model: String,
    runs: usize,
    passed: usize,
    /// Every run's energy, failures included, per task passed.
    wh_per_solve: Option<f64>,
    local_wh_per_solve: Option<f64>,
    remote_wh_per_solve: Option<f64>,
    estimated: bool,
    g_co2e_per_solve: Option<f64>,
    secs_per_run: f64,
    idle_w: Option<f64>,
}

#[derive(Serialize)]
struct Run {
    task: String,
    model: String,
    rep: u32,
    pass: bool,
    end: String,
    secs: f64,
    input_tokens: u64,
    output_tokens: u64,
    model_calls: u32,
    local_wh: Option<f64>,
    system_wh: Option<f64>,
    idle_w: Option<f64>,
    gpu_wh: Option<f64>,
    ane_wh: Option<f64>,
    remote_wh: Option<f64>,
}

fn sh(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default()
}

fn round(x: f64, places: i32) -> f64 {
    let m = 10f64.powi(places);
    (x * m).round() / m
}

pub fn json(results: &[RunResult]) -> Result<String> {
    let mut by_model: BTreeMap<&str, Vec<&RunResult>> = BTreeMap::new();
    for r in results {
        by_model.entry(&r.model).or_default().push(r);
    }
    let models = by_model
        .iter()
        .map(|(model, runs)| {
            let passed = runs.iter().filter(|r| r.pass).count();
            let energy: Vec<_> = runs.iter().filter_map(|r| r.energy.as_ref()).collect();
            let complete = passed > 0 && energy.len() == runs.len();
            let per = |f: &dyn Fn(&crate::run::RunEnergy) -> f64| {
                complete.then(|| round(energy.iter().map(|e| f(e)).sum::<f64>() / passed as f64, 3))
            };
            let wh = per(&|e| e.total_wh());
            let estimated = energy.iter().any(|e| e.remote_wh.is_some());
            Summary {
                model: model.to_string(),
                runs: runs.len(),
                passed,
                wh_per_solve: wh,
                local_wh_per_solve: per(&|e| e.local_wh),
                remote_wh_per_solve: if estimated {
                    per(&|e| e.remote_wh.unwrap_or(0.0))
                } else {
                    None
                },
                estimated,
                g_co2e_per_solve: wh.map(|w| round(w / 1000.0 * GRID_G_PER_KWH, 3)),
                secs_per_run: round(
                    runs.iter().map(|r| r.secs).sum::<f64>() / runs.len() as f64,
                    1,
                ),
                // Measured before every run; the mean of those.
                idle_w: (!energy.is_empty()).then(|| {
                    round(
                        energy.iter().map(|e| e.idle_w).sum::<f64>() / energy.len() as f64,
                        1,
                    )
                }),
            }
        })
        .collect();
    let runs = results
        .iter()
        .map(|r| {
            let e = r.energy.as_ref();
            Run {
                task: r.task.clone(),
                model: r.model.clone(),
                rep: r.rep,
                pass: r.pass,
                end: r.end.clone(),
                secs: round(r.secs, 1),
                input_tokens: r.input_tokens,
                output_tokens: r.output_tokens,
                model_calls: r.model_calls,
                local_wh: e.map(|e| round(e.local_wh, 4)),
                system_wh: e.map(|e| round(e.system_wh, 4)),
                idle_w: e.map(|e| round(e.idle_w, 2)),
                gpu_wh: e.map(|e| round(e.gpu_wh, 4)),
                ane_wh: e.map(|e| round(e.ane_wh, 4)),
                remote_wh: e.and_then(|e| e.remote_wh).map(|w| round(w, 4)),
            }
        })
        .collect();
    let export = Export {
        suite: SUITE,
        date: chrono::Local::now().format("%Y-%m-%d").to_string(),
        machine: Machine {
            chip: sh("sysctl", &["-n", "machdep.cpu.brand_string"]),
            memory_gb: sh("sysctl", &["-n", "hw.memsize"])
                .parse::<u64>()
                .unwrap_or(0)
                >> 30,
            macos: sh("sw_vers", &["-productVersion"]),
        },
        method: Method {
            local: "SMC system power (PSTR), 10 Hz, integrated over the engine's turn, less the idle power measured for 5 s just before the run, with the model loaded",
            remote: "per model: open-weight models scale Epoch AI's GPT-4o estimate by their active parameters; closed models use it as is",
            remote_wh_per_input_token: cloud::WH_PER_INPUT_TOKEN,
            remote_wh_per_output_token: cloud::WH_PER_OUTPUT_TOKEN,
            grid_g_per_kwh: GRID_G_PER_KWH,
            grid_basis: "Ember, Global Electricity Review 2026 (2025 world average)",
        },
        models,
        runs,
        remote_estimates: cloud::table()
            .into_iter()
            .map(|(model, active_b, e)| RemoteEstimate {
                model,
                active_b,
                wh_per_input_token: e.wh_per_input_token,
                wh_per_output_token: e.wh_per_output_token,
                basis: e.basis,
                source: e.source,
            })
            .collect(),
    };
    Ok(serde_json::to_string_pretty(&export)?)
}
