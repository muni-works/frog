mod headless;
mod render;
mod replay;
mod tui;

use anyhow::{Context, Result};
use clap::Parser;
use kiln_engine::config::{Config, ToolMode};
use kiln_engine::session;
use kiln_engine::{Mode, Options};
use std::io::Read;

#[derive(Parser)]
#[command(
    name = "kiln",
    version,
    about = "A local-first coding agent for your terminal"
)]
struct Cli {
    /// Initial prompt. With -p, run it non-interactively and exit.
    prompt: Vec<String>,
    /// Print mode: run the prompt (or stdin) and exit.
    #[arg(short, long)]
    print: bool,
    /// JSON output: with -p, every engine event as a JSON line; with --sessions or --models, a JSON array.
    #[arg(long)]
    json: bool,
    /// Speak the engine protocol over stdio (Op JSON lines in, Event JSON lines out).
    #[arg(long, conflicts_with = "print")]
    serve: bool,
    /// Profile name from config.toml, or provider/model (e.g. ollama/qwen3, lmstudio/qwen3-coder, anthropic/claude-sonnet-5)
    #[arg(short, long)]
    model: Option<String>,
    /// Override the provider's base URL.
    #[arg(long)]
    base_url: Option<String>,
    /// Continue the most recent session in this directory.
    #[arg(short = 'c', long = "continue")]
    cont: bool,
    /// Resume a session by id.
    #[arg(short, long, conflicts_with = "cont")]
    resume: Option<String>,
    /// Fork a session into a new one and continue there: `<id>`, or `<id>@<turn>` to cut right after that turn.
    #[arg(long, conflicts_with_all = ["cont", "resume"])]
    fork: Option<String>,
    /// Confine file writes (including shell commands, on macOS) to the working directory.
    #[arg(long)]
    sandbox: bool,
    /// Undo a turn and everything after it: restore the files kiln edited and branch the
    /// conversation from just before `<id>@<turn>`. With --json, print the result and exit.
    #[arg(long, value_name = "ID@TURN", conflicts_with_all = ["cont", "resume", "fork"])]
    rewind: Option<String>,
    /// Create N worktrees for parallel attempts, all starting from the current working tree
    /// (uncommitted changes included). Prints {"base", "dirs"} as JSON.
    #[arg(long, value_name = "N")]
    attempts: Option<usize>,
    /// Apply an attempt worktree's changes (since --base) to this working tree. Prints the files.
    #[arg(long, value_name = "DIR", requires = "base")]
    apply_attempt: Option<std::path::PathBuf>,
    /// The attempts' base commit (from --attempts).
    #[arg(long)]
    base: Option<String>,
    /// Remove attempt worktrees.
    #[arg(long, value_name = "DIR")]
    discard_attempt: Vec<std::path::PathBuf>,
    /// Play a recorded session (id or .jsonl path) over the serve protocol, for UI work.
    #[arg(long, value_name = "SESSION")]
    replay: Option<String>,
    /// Replay speed multiplier.
    #[arg(long, default_value_t = 2.0, requires = "replay")]
    speed: f64,
    /// During replay, stop at each edit or command for a permission answer.
    #[arg(long, requires = "replay")]
    replay_ask: bool,
    /// List sessions started in this directory and exit.
    #[arg(long)]
    sessions: bool,
    /// List available models (configured profiles and installed ollama models) and exit.
    #[arg(long)]
    models: bool,
    /// Never ask for permission.
    #[arg(long)]
    yolo: bool,
    /// Allow file edits without asking.
    #[arg(long)]
    accept_edits: bool,
    /// Describe tools in the prompt instead of using native tool calling.
    #[arg(long, conflicts_with = "tool_mode")]
    text_tools: bool,
    /// How tool calls are made: auto (profile the model), native, text, or json (grammar-constrained).
    #[arg(long, value_parser = ["auto", "native", "text", "json"])]
    tool_mode: Option<String>,
    /// Profile the model's tool-calling abilities, print them, cache them, and exit.
    #[arg(long)]
    probe: bool,
}

#[tokio::main]
async fn main() {
    match run().await {
        Ok(true) => {}
        Ok(false) => std::process::exit(1),
        Err(e) => {
            render::error(&format!("{e:#}"));
            std::process::exit(1);
        }
    }
}

async fn run() -> Result<bool> {
    let cli = Cli::parse();
    if cli.attempts.is_some() || cli.apply_attempt.is_some() || !cli.discard_attempt.is_empty() {
        return attempts(&cli);
    }
    if let Some(spec) = &cli.replay {
        replay::run(spec, cli.speed, cli.replay_ask).await?;
        return Ok(true);
    }
    let cfg = Config::load()?;
    if cli.models {
        return list_models(&cfg, cli.json).await;
    }
    let (profile_name, mut profile) = cfg.resolve(cli.model.as_deref())?;
    if let Some(b) = cli.base_url {
        profile.base_url = Some(b);
    }
    if cli.text_tools {
        profile.tool_mode = ToolMode::Text;
    }
    if let Some(m) = &cli.tool_mode {
        profile.tool_mode = serde_json::from_value(serde_json::json!(m))?;
    }
    if cli.probe {
        return probe(&profile_name, &profile).await;
    }
    let cwd = std::env::current_dir()?;
    let store = session::default_dir();
    if cli.sessions {
        list_sessions(&store, &cwd, cli.json)?;
        return Ok(true);
    }
    let resume = if let Some(spec) = &cli.rewind {
        let (id, turn) = spec.split_once('@').context("--rewind takes <id>@<turn>")?;
        let r = session::rewind(&store, id, turn.parse()?)?;
        if cli.json {
            println!("{}", serde_json::to_string(&r)?);
            return Ok(true);
        }
        eprintln!(
            "rewound {id} to before turn {turn} → {} ({} files restored)",
            r.session,
            r.restored.len()
        );
        Some(r.session)
    } else if let Some(spec) = &cli.fork {
        let (id, at) = match spec.split_once('@') {
            Some((id, turn)) => (id, Some(session::turn_end_seq(&store, id, turn.parse()?)?)),
            None => (spec.as_str(), None),
        };
        let new = session::fork(&store, id, at)?;
        eprintln!("forked {id} → {new}");
        Some(new)
    } else if cli.cont {
        Some(session::latest_for(&store, &cwd)?)
    } else {
        cli.resume.clone()
    };
    let mode = match (cli.yolo, cli.accept_edits) {
        (true, _) => Mode::Yolo,
        (_, true) => Mode::AcceptEdits,
        _ => Mode::Default,
    };
    let handle = kiln_engine::spawn(Options {
        cfg: cfg.clone(),
        profile_name,
        profile,
        cwd,
        mode,
        can_ask: !cli.print,
        resume,
        store: Some(store),
        sandbox: cli.sandbox,
    })?;

    let mut prompt = cli.prompt.join(" ");
    if cli.serve {
        headless::serve(handle).await?;
        return Ok(true);
    }
    if cli.print {
        if prompt.is_empty() {
            std::io::stdin().read_to_string(&mut prompt)?;
        }
        return headless::print(handle, prompt, cli.json).await;
    }
    tui::run(handle, cfg, (!prompt.is_empty()).then_some(prompt)).await?;
    Ok(true)
}

async fn list_models(cfg: &Config, json: bool) -> Result<bool> {
    let models = kiln_engine::models::list(cfg).await;
    if json {
        println!("{}", serde_json::to_string(&models)?);
        return Ok(true);
    }
    for m in models {
        let mode = format!("{:?}", m.tool_mode).to_lowercase();
        let profiled = if m.caps.is_some() {
            ""
        } else {
            " (not profiled)"
        };
        println!("{:<32} {:<8} {:?} tier{profiled}", m.spec, mode, m.tier);
    }
    Ok(true)
}

fn list_sessions(store: &std::path::Path, cwd: &std::path::Path, json: bool) -> Result<()> {
    let sessions = session::list(store, cwd)?;
    if json {
        let rows: Vec<serde_json::Value> = sessions
            .iter()
            .map(|s| {
                serde_json::json!({
                    "id": s.id,
                    "modified": chrono::DateTime::<chrono::Utc>::from(s.modified).timestamp_millis(),
                    "created": s.header.created,
                    "model": s.header.model,
                    "first_input": s.first_input,
                    "title": s.title,
                    "forked_from": s.header.forked_from,
                })
            })
            .collect();
        println!("{}", serde_json::to_string(&rows)?);
        return Ok(());
    }
    if sessions.is_empty() {
        println!("no sessions in {}", cwd.display());
    }
    for s in sessions {
        let when = chrono::DateTime::<chrono::Local>::from(s.modified).format("%b %d %H:%M");
        let first = s
            .title
            .or(s.first_input)
            .unwrap_or_default()
            .replace('\n', " ");
        let first: String = first.chars().take(60).collect();
        let fork = s
            .header
            .forked_from
            .map(|f| format!(" (fork of {}@{})", f.session, f.seq))
            .unwrap_or_default();
        println!("{}  {when}  {first}{fork}", s.id);
    }
    Ok(())
}

async fn probe(name: &str, profile: &kiln_engine::config::Profile) -> Result<bool> {
    use kiln_engine::harness;
    kiln_engine::sidecar::ensure(profile).await?;
    let provider = kiln_engine::provider::Provider::new(profile)?;
    eprintln!("probing {name}…");
    let caps = harness::probe(&provider, &kiln_engine::tools::specs()).await?;
    harness::save(profile, &caps);
    let tier = harness::tier(profile, Some(&caps));
    let mut auto = profile.clone();
    auto.tool_mode = ToolMode::Auto;
    let mode = harness::choose_mode(&auto, Some(&caps), tier);
    let yes = |b: bool| if b { "yes" } else { "no" };
    println!("model         {name}");
    println!(
        "parameters    {}",
        caps.params_b
            .map(|b| format!("{b:.1}B"))
            .unwrap_or_else(|| "unknown".into())
    );
    println!("native tools  {}", yes(caps.native_tools));
    println!("text tools    {}", yes(caps.text_tools));
    println!("json mode     {}", yes(caps.json_mode));
    println!("abstains      {}", yes(caps.abstains));
    println!("tier          {tier:?}");
    println!("auto picks    {mode:?}");
    Ok(true)
}

fn attempts(cli: &Cli) -> Result<bool> {
    use kiln_engine::checkpoint;
    let cwd = std::env::current_dir()?;
    let root = checkpoint::repo_root(&cwd).context("parallel attempts need a git repository")?;
    if let Some(n) = cli.attempts {
        let name = format!(
            "{}-{}",
            root.file_name().and_then(|s| s.to_str()).unwrap_or("repo"),
            session::new_id()
        );
        let parent = kiln_engine::config::data_dir().join("attempts");
        let a = checkpoint::create_attempts(&root, &name, n.clamp(1, 8), &parent)?;
        println!("{}", serde_json::to_string(&a)?);
    }
    if let (Some(dir), Some(base)) = (&cli.apply_attempt, &cli.base) {
        let files = checkpoint::apply_attempt(&root, dir, base)?;
        println!("{}", serde_json::json!({ "files": files }));
    }
    if !cli.discard_attempt.is_empty() {
        checkpoint::remove_attempts(&root, &cli.discard_attempt);
    }
    Ok(true)
}
