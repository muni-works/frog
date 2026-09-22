mod headless;
mod render;
mod tui;

use anyhow::Result;
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
    /// With -p, print every engine event as a JSON line.
    #[arg(long, requires = "print")]
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
    /// List sessions started in this directory and exit.
    #[arg(long)]
    sessions: bool,
    /// Never ask for permission.
    #[arg(long)]
    yolo: bool,
    /// Allow file edits without asking.
    #[arg(long)]
    accept_edits: bool,
    /// Describe tools in the prompt instead of using native tool calling.
    #[arg(long)]
    text_tools: bool,
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
    let cfg = Config::load()?;
    let (profile_name, mut profile) = cfg.resolve(cli.model.as_deref())?;
    if let Some(b) = cli.base_url {
        profile.base_url = Some(b);
    }
    if cli.text_tools {
        profile.tool_mode = ToolMode::Text;
    }
    let cwd = std::env::current_dir()?;
    let store = session::default_dir();
    if cli.sessions {
        list_sessions(&store, &cwd)?;
        return Ok(true);
    }
    let resume = if let Some(spec) = &cli.fork {
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

fn list_sessions(store: &std::path::Path, cwd: &std::path::Path) -> Result<()> {
    let sessions = session::list(store, cwd)?;
    if sessions.is_empty() {
        println!("no sessions in {}", cwd.display());
    }
    for s in sessions {
        let when = chrono::DateTime::<chrono::Local>::from(s.modified).format("%b %d %H:%M");
        let first = s.first_input.unwrap_or_default().replace('\n', " ");
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
