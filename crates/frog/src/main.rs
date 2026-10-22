mod acp;
mod complete;
mod headless;
mod listen;
mod render;
mod replay;
mod tui;

use anyhow::{Context, Result};
use clap::Parser;
use frog_engine::config::{Config, ToolMode};
use frog_engine::session;
use frog_engine::{Mode, Options};
use std::io::Read;

#[derive(Parser)]
#[command(
    name = "frog",
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
    /// Answer one turn per HTTP request on ADDR (e.g. a Tailscale IP:8915), for the iOS app and
    /// Siri. Needs FROG_LISTEN_TOKEN (the bearer token). See docs/ios-siri.md.
    #[arg(long, value_name = "ADDR", conflicts_with_all = ["print", "serve", "acp"])]
    listen: Option<String>,
    /// With --serve: the client can answer MCP elicitations and host MCP Apps.
    #[arg(long, requires = "serve", hide = true)]
    rich: bool,
    /// Profile name from config.toml, or provider/model (e.g. local/qwen3-4b, cloud/qwen3-coder-next, ollama/qwen3, anthropic/claude-sonnet-5)
    #[arg(short, long)]
    model: Option<String>,
    /// Load an alternate config file (useful for isolated setups and testing).
    #[arg(long)]
    config: Option<std::path::PathBuf>,
    /// Override the provider's base URL.
    #[arg(long)]
    base_url: Option<String>,
    /// Continue the most recent session in this directory.
    #[arg(short = 'c', long = "continue")]
    cont: bool,
    /// Resume a session by id.
    #[arg(short, long, conflicts_with = "cont")]
    resume: Option<String>,
    /// With `--resume`: if another frog process holds the session, wait up to this many
    /// seconds for it to exit, then fail rather than start a new session.
    #[arg(long, value_name = "SECS", requires = "resume")]
    wait_lock: Option<u64>,
    /// Fork a session into a new one and continue there: `<id>`, or `<id>@<turn>` to cut right after that turn.
    #[arg(long, conflicts_with_all = ["cont", "resume"])]
    fork: Option<String>,
    /// Confine file writes (including shell commands, on macOS) to the working directory.
    #[arg(long)]
    sandbox: bool,
    /// Speak the Agent Client Protocol on stdio, for editors (Zed, JetBrains, Neovim).
    #[arg(long, conflicts_with_all = ["print", "serve"])]
    acp: bool,
    /// Don't sandbox shell commands; every command asks instead (unless allowed or --yolo).
    #[arg(long)]
    no_shell_sandbox: bool,
    /// Measure each turn's energy from the Mac's power sensor, and report it with the turn.
    #[arg(long)]
    energy: bool,
    /// A plain chat, not tied to a project: no file or shell tools.
    #[arg(long)]
    chat: bool,
    /// List the Agent Skills this folder sees (with --json for JSON).
    #[arg(long)]
    skills: bool,
    /// Let the agent see and drive macOS apps (computer use, via the frog-desktop sidecar).
    #[arg(long)]
    computer_use: bool,
    /// Undo a turn and everything after it: restore the files frog edited and branch the
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
    /// With --sessions: every folder's sessions, not just this directory's.
    #[arg(long, requires = "sessions")]
    all: bool,
    /// Name a session that isn't open: --rename <ID> <TITLE>.
    #[arg(long, num_args = 2, value_names = ["ID", "TITLE"])]
    rename: Option<Vec<String>>,
    /// List sessions started in this directory and exit.
    #[arg(long)]
    sessions: bool,
    /// Draw this directory's sessions and their forks as a diagram (JSON with --json) and exit.
    #[arg(long)]
    session_tree: bool,
    /// Connect the configured MCP servers (config.toml and ./.mcp.json), list their tools, and
    /// exit (JSON with --json).
    #[arg(long)]
    mcp: bool,
    /// Read Mermaid from stdin, lay it out, and print the diagram (JSON with --json) and exit.
    #[arg(long)]
    mermaid: bool,
    /// Map this project's (or a subdirectory's) structure from its code and print it (JSON with
    /// --json) and exit.
    #[arg(long, value_name = "DIR", num_args = 0..=1, default_missing_value = ".")]
    map: Option<String>,
    /// List available models (configured profiles and installed ollama models) and exit.
    #[arg(long)]
    models: bool,
    /// List providers (presets and servers you added) and whether each is connected, and exit.
    #[arg(long)]
    providers: bool,
    /// List every model the connected providers offer, and which are on, and exit.
    #[arg(long)]
    catalog: bool,
    /// With --catalog: fetch fresh lists instead of using cached ones.
    #[arg(long, requires = "catalog")]
    refresh: bool,
    /// Show these provider/model specs in the model list.
    #[arg(long, value_name = "SPEC", num_args = 1..)]
    enable_model: Vec<String>,
    /// Stop showing these specs in the model list.
    #[arg(long, value_name = "SPEC", num_args = 1..)]
    disable_model: Vec<String>,
    /// Store a provider's API key in the Keychain, read from stdin (empty removes it). Web
    /// search keys go here too: brave, exa, tavily.
    #[arg(long, value_name = "PROVIDER")]
    set_key: Option<String>,
    /// Add a server as a provider: --add-provider <ID> <URL> (e.g. gpu http://box:11434).
    #[arg(long, num_args = 2, value_names = ["ID", "URL"])]
    add_provider: Option<Vec<String>>,
    /// With --add-provider: "ollama" or "openai" (any OpenAI-compatible server; the default).
    #[arg(long, requires = "add_provider", default_value = "openai")]
    provider_kind: String,
    /// With --add-provider: a display name.
    #[arg(long, requires = "add_provider")]
    provider_name: Option<String>,
    /// Remove a server you added.
    #[arg(long, value_name = "ID")]
    remove_provider: Option<String>,
    /// What frog found on this Mac for this folder (instruction files, skills, rules, keys in the
    /// environment, Claude Code's MCP servers), as JSON with --json, and exit.
    #[arg(long)]
    setup: bool,
    /// Read Claude Code's MCP servers (from ~/.claude.json): on or off; then exit.
    #[arg(long, value_name = "ON|OFF")]
    use_claude_mcp: Option<String>,
    /// Whether this folder's code may go to cloud models: allow, deny (keep it on your
    /// devices), or ask (forget the answer). Without a value, print the answer; then exit.
    #[arg(long, value_name = "ANSWER", num_args = 0..=1, default_missing_value = "")]
    cloud_policy: Option<String>,
    /// Look around (GitHub for now), write the brief of what needs you, print it and exit.
    /// Reads only: nothing is sent or changed on your behalf.
    #[arg(long)]
    brief: bool,
    /// With --brief: print the last brief without looking again.
    #[arg(long, requires = "brief")]
    cached: bool,
    /// Keep the brief fresh: look again every N minutes (default 15), until stopped.
    #[arg(long, value_name = "MINUTES", num_args = 0..=1, default_missing_value = "15")]
    watch: Option<u64>,
    /// Keep the brief fresh while frog is closed, from login on (a LaunchAgent running --watch):
    /// on or off. Without a value, say whether it's on.
    #[arg(long, value_name = "ON|OFF", num_args = 0..=1, default_missing_value = "")]
    background: Option<String>,
    /// Print a prompt for a conversation about an item in the brief, with what GitHub says
    /// about it (JSON with --json: {"prompt", "repo"}).
    #[arg(long, value_name = "ID")]
    ask: Option<String>,
    /// You looked at the brief: what's in it is no longer new.
    #[arg(long)]
    seen: bool,
    /// The morning notice, when one is due (after 7, once a day, only for something new):
    /// print it (JSON with --json, `null` when none) and count today as notified.
    #[arg(long)]
    morning: bool,
    /// Take an item out of the brief: it isn't worth your time. It comes back if it changes.
    #[arg(long, value_name = "ID")]
    dismiss: Option<String>,
    /// Never ask for permission.
    #[arg(long)]
    yolo: bool,
    /// Allow file edits without asking.
    #[arg(long)]
    accept_edits: bool,
    /// Auto mode: a local classifier approves steps that plainly serve your request.
    #[arg(long, conflicts_with_all = ["yolo", "accept_edits"])]
    auto: bool,
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
    // `frog setup [MODEL]`: install tang-llm and download the default model's weights.
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("setup") {
        let model = args.get(2).map(|m| {
            let m = m.strip_prefix("local/").unwrap_or(m);
            frog_engine::providers::local_repo(m)
        });
        frog_engine::setup::run(model).await?;
        return Ok(true);
    }
    // `frog account [--json]`: frog cloud's key and where it goes. Local only, no network.
    if args.get(1).map(String::as_str) == Some("account") {
        let a = frog_engine::providers::Account::read();
        if args.iter().skip(2).any(|x| x == "--json") {
            println!("{}", serde_json::to_string(&a)?);
        } else {
            print!("{}", a.render());
        }
        return Ok(true);
    }
    let cli = Cli::parse();
    if cli.attempts.is_some() || cli.apply_attempt.is_some() || !cli.discard_attempt.is_empty() {
        return attempts(&cli);
    }
    if let Some(spec) = &cli.replay {
        replay::run(spec, cli.speed, cli.replay_ask).await?;
        return Ok(true);
    }
    let mut cfg = match &cli.config {
        Some(path) => Config::load_from(path)?,
        None => Config::load()?,
    };
    cfg.computer_use |= cli.computer_use;
    cfg.energy |= cli.energy;
    // The engine log is stderr, which only a client like the Mac app keeps.
    cfg.log_calls |= cli.serve;
    if cli.no_shell_sandbox {
        cfg.sandbox_shell = false;
    }
    if cli.models {
        return list_models(&cfg, cli.json).await;
    }
    if let Some(done) = manage_providers(&cli).await? {
        return Ok(done);
    }
    if let Some(v) = &cli.use_claude_mcp {
        match v.as_str() {
            "on" => frog_engine::imports::set_claude_mcp(true)?,
            "off" => frog_engine::imports::set_claude_mcp(false)?,
            other => anyhow::bail!("--use-claude-mcp takes on or off, not `{other}`"),
        }
        return Ok(true);
    }
    if cli.setup {
        let found = frog_engine::imports::report(&cfg, &std::env::current_dir()?);
        if cli.json {
            println!("{}", serde_json::to_string(&found)?);
        } else {
            println!("{found:#?}");
        }
        return Ok(true);
    }
    if let Some(answer) = &cli.cloud_policy {
        use frog_engine::policy::{self, Cloud};
        let here = std::env::current_dir()?;
        let set = match answer.as_str() {
            "" => None,
            "allow" => Some(Cloud::Allow),
            "deny" => Some(Cloud::Deny),
            "ask" => Some(Cloud::Ask),
            other => anyhow::bail!("--cloud-policy takes allow, deny or ask, not `{other}`"),
        };
        if let Some(c) = set {
            policy::set_cloud(&here, c)?;
        }
        let c = serde_json::to_value(policy::cloud(&here))?;
        if cli.json {
            println!("{}", serde_json::json!({ "cloud": c }));
        } else {
            println!("{}", c.as_str().unwrap_or("ask"));
        }
        return Ok(true);
    }
    if let Some(done) = pond(&cli, &cfg).await? {
        return Ok(done);
    }
    // Reopening a conversation keeps the model it was running, not whatever the default is
    // now: the app relaunches engines with `-r <id>` and no `-m`.
    let reopened = cli.resume.as_deref().or(cli.fork.as_deref().map(|f| f.split('@').next().unwrap_or(f)));
    let chosen = match &cli.model {
        Some(m) => Some(m.clone()),
        None if reopened.and_then(session_model).is_some() => reopened.and_then(session_model),
        None if std::env::var_os("FROG_MODEL").is_some() || cfg.default_model.is_some() => None,
        None => match frog_engine::models::last_used() {
            Some(m) => Some(m),
            None => match frog_engine::models::pick_default().await {
                Some((m, _)) => Some(m),
                None => {
                    eprintln!("{NO_MODEL}");
                    return Ok(false);
                }
            },
        },
    };
    let (profile_name, mut profile) = cfg.resolve(chosen.as_deref())?;
    if let Some(b) = cli.base_url {
        // A saved frog cloud or OpenAI key goes only to its own service: a --base-url
        // elsewhere gets an env key or none.
        let prov = profile_name.split_once('/').map(|(p, _)| p);
        if let Some(prov @ ("cloud" | "openai")) = prov {
            let own = prov == "cloud" && frog_engine::providers::on_cloud_origin(&b);
            if !own && frog_engine::providers::key_source(prov) != Some("env") {
                profile.api_key = None;
            }
        }
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
    if let Some(r) = &cli.rename {
        session::retitle(&store, &r[0], &r[1])?;
        return Ok(true);
    }
    if cli.sessions {
        list_sessions(&store, &cwd, cli.all, cli.json)?;
        return Ok(true);
    }
    if cli.session_tree {
        print_diagram(session_tree(&store, &cwd)?, &cwd, cli.json)?;
        return Ok(true);
    }
    if cli.skills {
        let skills = frog_engine::skills::discover(&cwd);
        if cli.json {
            println!(
                "{}",
                serde_json::to_string(&skills.values().collect::<Vec<_>>())?
            );
        } else if skills.is_empty() {
            println!(
                "no skills (add <name>/SKILL.md under .agents/skills here, or ~/.config/frog/skills)"
            );
        } else {
            for s in skills.values() {
                let first = s
                    .description
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ");
                let first: String = first.chars().take(90).collect();
                println!(
                    "{}{}  {first}",
                    s.name,
                    if s.project { " (project)" } else { "" }
                );
            }
            println!(
                "\n{} skills; catalog is {} chars",
                skills.len(),
                frog_engine::skills::catalog(&skills).len()
            );
        }
        return Ok(true);
    }
    if cli.mcp {
        let servers = frog_engine::mcp::configured(&cfg, &cwd);
        let hub =
            frog_engine::mcp::Hub::connect(servers, frog_engine::mcp::Host::headless(&cwd)).await;
        let status = hub.status();
        if cli.json {
            println!("{}", serde_json::to_string(&status)?);
        } else if status.is_empty() {
            println!(
                "no MCP servers configured (add [mcp_servers.<name>] to config.toml, or a .mcp.json here)"
            );
        }
        if !cli.json {
            for st in &status {
                match &st.error {
                    Some(e) => println!("✗ {}  {e}", st.name),
                    None => println!(
                        "✓ {}  {} tools: {}",
                        st.name,
                        st.tools.len(),
                        st.tools.join(", ")
                    ),
                }
                for q in &st.quarantined {
                    println!("  ⚠ withheld {}: its description {}", q.tool, q.reason);
                }
            }
        }
        hub.shutdown();
        return Ok(true);
    }
    if let Some(dir) = &cli.map {
        let focus = (dir != ".").then(|| std::path::PathBuf::from(dir));
        let opts = frog_engine::codemap::Options {
            focus,
            ..Default::default()
        };
        let (d, summary) = frog_engine::codemap::map_with_summary(&cwd, &opts);
        if cli.json || d.nodes.len() <= 12 {
            print_diagram(d, &cwd, cli.json)?;
        } else {
            print!("{summary}");
        }
        return Ok(true);
    }
    if cli.mermaid {
        let mut src = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin(), &mut src)?;
        let d = frog_engine::diagram::Diagram::from_mermaid(&src)
            .context("not a Mermaid flowchart or sequence diagram frog can draw")?;
        print_diagram(d, &cwd, cli.json)?;
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
    let resume = match (resume, cli.wait_lock) {
        // Resuming after a relaunch: the old engine may still be on its way out. Wait for it,
        // and never quietly fork the conversation into a new session.
        (Some(id), Some(secs)) => {
            if !session::Log::wait_free(&store, &id, std::time::Duration::from_secs(secs)) {
                anyhow::bail!("session {id} is still open in another frog process after {secs}s");
            }
            Some(id)
        }
        (r, _) => r,
    };
    // A client (the app, say) that opens a session another frog process is running follows it
    // live instead of getting a blank new one.
    if let Some(id) = resume
        .as_ref()
        .filter(|id| cli.wait_lock.is_none() && cli.serve && session::Log::in_use(&store, id))
    {
        eprintln!("session {id} is open in another frog process; following it");
        headless::serve(frog_engine::follow(store.clone(), id.clone())).await?;
        return Ok(true);
    }
    let mode = match (cli.yolo, cli.accept_edits, cli.auto) {
        (true, _, _) => Mode::Yolo,
        (_, true, _) => Mode::AcceptEdits,
        (_, _, true) => Mode::Auto,
        _ => Mode::Default,
    };
    if cli.acp {
        acp::serve(cfg.clone(), profile_name, profile, store, cli.sandbox).await?;
        return Ok(true);
    }
    if let Some(addr) = &cli.listen {
        let token = std::env::var("FROG_LISTEN_TOKEN").unwrap_or_default();
        let (cfg, sandbox, chat, dir) = (cfg.clone(), cli.sandbox, cli.chat, store.clone());
        let make = move |resume, model: Option<String>| -> Result<Options> {
            let (profile_name, profile) = match model {
                Some(m) => cfg.resolve(Some(&m))?,
                None => (profile_name.clone(), profile.clone()),
            };
            Ok(Options {
                cfg: cfg.clone(),
                profile_name,
                profile,
                cwd: cwd.clone(),
                mode,
                can_ask: false,
                resume,
                store: Some(dir.clone()),
                sandbox,
                rich: false,
                subagent: false,
                chat,
            })
        };
        let template = listen::Template {
            store: store.clone(),
            make: Box::new(make),
        };
        listen::run(addr, token, template).await?;
        return Ok(true);
    }
    let handle = frog_engine::spawn(Options {
        cfg: cfg.clone(),
        profile_name,
        profile,
        cwd,
        mode,
        can_ask: !cli.print,
        resume,
        store: Some(store),
        sandbox: cli.sandbox,
        rich: cli.rich,
        subagent: false,
        chat: cli.chat,
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

/// Provider and model-list commands (`--providers`, `--catalog`, `--set-key`, ...); None if
/// the command line has none.
async fn manage_providers(cli: &Cli) -> Result<Option<bool>> {
    use frog_engine::providers::{self, Custom, State};
    if let Some(id) = &cli.set_key {
        let mut key = String::new();
        std::io::Read::read_to_string(&mut std::io::stdin(), &mut key)?;
        providers::set_key(id, &key)?;
        return Ok(Some(true));
    }
    if let Some(a) = &cli.add_provider {
        let kind = match cli.provider_kind.as_str() {
            "ollama" => frog_engine::config::ProviderKind::Ollama,
            "openai" => frog_engine::config::ProviderKind::Openai,
            other => anyhow::bail!("--provider-kind is ollama or openai, not `{other}`"),
        };
        let mut state = State::load();
        let custom = Custom {
            name: cli.provider_name.clone().unwrap_or_else(|| a[0].clone()),
            kind,
            base_url: a[1].trim_end_matches('/').to_string(),
        };
        providers::add_custom(&mut state, &a[0], custom)?;
        state.save()?;
        return Ok(Some(true));
    }
    if let Some(id) = &cli.remove_provider {
        providers::removable(id)?;
        let mut state = State::load();
        state.custom.remove(id);
        state.enabled.retain(|s| !s.starts_with(&format!("{id}/")));
        state.save()?;
        let _ = providers::set_key(id, "");
        return Ok(Some(true));
    }
    if !cli.enable_model.is_empty() || !cli.disable_model.is_empty() {
        let mut state = State::load();
        state.enabled.extend(cli.enable_model.iter().cloned());
        for s in &cli.disable_model {
            state.enabled.remove(s);
        }
        state.save()?;
        return Ok(Some(true));
    }
    if cli.providers {
        let list = providers::list(&State::load());
        if cli.json {
            println!("{}", serde_json::to_string(&list)?);
        } else {
            for p in list {
                let status = match (p.connected, p.local) {
                    (true, _) => "connected",
                    (false, true) => "not installed",
                    (false, false) => "no key",
                };
                println!("{:<12} {:<20} {:<10} {}", p.id, p.name, status, p.base_url);
            }
        }
        return Ok(Some(true));
    }
    if cli.catalog {
        let state = State::load();
        let models = frog_engine::catalog::all(cli.refresh).await;
        if cli.json {
            #[derive(serde::Serialize)]
            struct Row<'a> {
                #[serde(flatten)]
                model: &'a frog_engine::catalog::Model,
                enabled: bool,
            }
            let rows: Vec<Row> = models
                .iter()
                .map(|m| Row {
                    model: m,
                    enabled: state.enabled.contains(&m.spec),
                })
                .collect();
            println!("{}", serde_json::to_string(&rows)?);
        } else {
            for (provider, list) in frog_engine::catalog::by_provider(&models) {
                println!("{provider} ({} models)", list.len());
                for m in list {
                    let on = if state.enabled.contains(&m.spec) {
                        "●"
                    } else {
                        " "
                    };
                    let ctx = m
                        .context
                        .map(|c| format!("{}k", c / 1000))
                        .unwrap_or_default();
                    println!("  {on} {:<56} {ctx:>6}", m.spec);
                }
            }
        }
        return Ok(Some(true));
    }
    Ok(None)
}

const NO_MODEL: &str = "\
frog didn't find a model to talk to. Any one of these works:

  frog setup                       install frog's own engine and Qwen3 4B (Apple silicon)
  ollama pull qwen3-coder:30b      then run frog again
  LM Studio                        load a model and start its server
  export ANTHROPIC_API_KEY=…       use Claude
  frog -m provider/model           anything else (frog --models lists what's here)";

async fn list_models(cfg: &Config, json: bool) -> Result<bool> {
    let models = frog_engine::models::list(cfg).await;
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
        let label = if m.provider == frog_engine::config::ProviderKind::Codex {
            "Codex (ChatGPT plan)"
        } else {
            ""
        };
        println!(
            "{:<32} {:<8} {:?} tier{profiled} {label}",
            m.spec, mode, m.tier
        );
    }
    Ok(true)
}

fn print_diagram(
    mut d: frog_engine::diagram::Diagram,
    cwd: &std::path::Path,
    json: bool,
) -> Result<()> {
    d.finish(cwd);
    if json {
        println!("{}", serde_json::to_string(&d)?);
    } else {
        println!("{}", d.to_ascii());
    }
    Ok(())
}

/// Sessions as a tree: each fork hangs off the session it branched from.
fn session_tree(
    store: &std::path::Path,
    cwd: &std::path::Path,
) -> Result<frog_engine::diagram::Diagram> {
    use frog_engine::diagram::{Diagram, Edge, Node, Shape};
    let mut sessions = session::list(store, Some(cwd))?;
    sessions.sort_by_key(|s| s.header.created);
    let ids: std::collections::HashSet<&str> = sessions.iter().map(|s| s.id.as_str()).collect();
    let mut d = Diagram {
        title: "Sessions".into(),
        ..Default::default()
    };
    for s in &sessions {
        let label = s
            .title
            .clone()
            .or_else(|| s.first_input.clone())
            .unwrap_or_else(|| "New session".into());
        let when = chrono::DateTime::<chrono::Local>::from(s.modified).format("%b %d %H:%M");
        d.nodes.push(Node {
            id: s.id.clone(),
            label: label.lines().next().unwrap_or("").to_string(),
            shape: if s.header.forked_from.is_some() {
                Shape::Rounded
            } else {
                Shape::Box
            },
            detail: Some(format!("{} · {when}", s.header.model)),
            ..Default::default()
        });
        if let Some(f) = &s.header.forked_from
            && ids.contains(f.session.as_str())
        {
            d.edges.push(Edge {
                from: f.session.clone(),
                to: s.id.clone(),
                ..Default::default()
            });
        }
    }
    Ok(d)
}

/// `--brief`, `--watch` and `--dismiss`: the pond.
async fn pond(cli: &Cli, cfg: &Config) -> Result<Option<bool>> {
    use frog_engine::pond;
    if let Some(v) = &cli.background {
        use frog_engine::pond::background;
        match v.as_str() {
            "on" => background::on(&std::env::current_exe()?.canonicalize()?)?,
            "off" => background::off()?,
            "" => {}
            other => anyhow::bail!("--background takes on or off, not `{other}`"),
        }
        let bin = background::status();
        if cli.json {
            println!(
                "{}",
                serde_json::json!({ "on": bin.is_some(), "binary": bin })
            );
        } else {
            match bin {
                Some(b) => println!("on: {} looks every 15 minutes", b.display()),
                None => println!("off"),
            }
        }
        return Ok(Some(true));
    }
    if cli.seen {
        pond::seen()?;
        return Ok(Some(true));
    }
    if cli.morning {
        let notice = pond::morning::check(cfg).await?;
        if cli.json {
            println!("{}", serde_json::to_string(&notice)?);
        } else if let Some(n) = notice {
            println!("{}\n{}", n.title, n.body);
        }
        return Ok(Some(true));
    }
    if let Some(id) = &cli.ask {
        let (prompt, repo) = pond::ask::prompt(id).await?;
        if cli.json {
            println!("{}", serde_json::json!({ "prompt": prompt, "repo": repo }));
        } else {
            println!("{prompt}");
        }
        return Ok(Some(true));
    }
    if let Some(id) = &cli.dismiss {
        if !pond::dismiss(id)? {
            anyhow::bail!("nothing open in the pond is called `{id}`");
        }
        return Ok(Some(true));
    }
    if let Some(minutes) = cli.watch {
        let every = std::time::Duration::from_secs(minutes.max(1) * 60);
        loop {
            match pond::pass(cfg).await {
                Ok(b) => {
                    eprintln!(
                        "{} brief: {}",
                        b.at.with_timezone(&chrono::Local).format("%H:%M"),
                        b.headline
                    );
                    if let Err(e) = pond::morning::wake_app(&b) {
                        eprintln!("couldn't wake Frog for the morning notice: {e:#}");
                    }
                }
                Err(e) => eprintln!("pond pass failed: {e:#}"),
            }
            tokio::time::sleep(every).await;
        }
    }
    if !cli.brief {
        return Ok(None);
    }
    let b = if cli.cached {
        pond::latest().context("no brief yet: run frog --brief")?
    } else {
        pond::pass(cfg).await?
    };
    if cli.json {
        println!("{}", serde_json::to_string(&b)?);
    } else {
        print_brief(&b);
    }
    Ok(Some(true))
}

fn print_brief(b: &frog_engine::pond::brief::Brief) {
    use frog_engine::pond::Place;
    println!("\n  {}\n", b.headline);
    if !b.today.is_empty() {
        use frog_engine::pond::calendar::clock;
        let day: Vec<String> = b
            .today
            .iter()
            .map(|e| {
                if e.all_day {
                    e.title.clone()
                } else {
                    format!("{} {}", clock(e.start), e.title)
                }
            })
            .collect();
        println!("  \x1b[2mtoday\x1b[0m  {}\n", day.join(" · "));
    }
    for l in &b.items {
        let dot = if l.new { "●" } else { "○" };
        println!("  {dot} {}  \x1b[2m{}\x1b[0m", l.title, l.place);
        println!("    {}", l.note);
        println!("    \x1b[2m{}\x1b[0m", l.url);
    }
    if !b.also.is_empty() {
        println!(
            "\n  \x1b[2malso: {} quieter thing{}\x1b[0m",
            b.also.len(),
            if b.also.len() == 1 { "" } else { "s" }
        );
    }
    for t in &b.trouble {
        println!("\n  \x1b[33m! {t}\x1b[0m");
    }
    let r = &b.receipt;
    let read: Vec<String> = r
        .read
        .iter()
        .map(|x| format!("{} ({})", x.source, x.what))
        .collect();
    let model = match &r.model {
        Some(m) => format!(
            "{} {}",
            m.name,
            match m.place {
                Place::Mac => "on this Mac",
                Place::Server => "on your server",
                Place::Cloud => "in the cloud",
            }
        ),
        None => "templates, no model".into(),
    };
    let private = r.private_bytes();
    let left = if private == 0 {
        "none of your data left this Mac".to_string()
    } else {
        format!("{} of your data left this Mac", bytes(private))
    };
    let wh =
        r.wh.filter(|w| *w >= 0.005)
            .map(|w| format!(" · {w:.2} Wh"))
            .unwrap_or_default();
    println!(
        "\n  \x1b[2mread {} · wrote with {model} · {left}{wh}\x1b[0m\n",
        read.join(", ")
    );
}

fn bytes(n: u64) -> String {
    match n {
        0..1_000 => format!("{n} B"),
        1_000..1_000_000 => format!("{:.1} KB", n as f64 / 1e3),
        _ => format!("{:.1} MB", n as f64 / 1e6),
    }
}

fn list_sessions(
    store: &std::path::Path,
    cwd: &std::path::Path,
    all: bool,
    json: bool,
) -> Result<()> {
    let sessions = session::list(store, (!all).then_some(cwd))?;
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
                    "cwd": s.header.cwd,
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

async fn probe(name: &str, profile: &frog_engine::config::Profile) -> Result<bool> {
    use frog_engine::harness;
    frog_engine::sidecar::ensure(profile).await?;
    let provider = frog_engine::provider::Provider::new(profile)?;
    eprintln!("probing {name}…");
    let caps = harness::probe(
        &provider,
        &frog_engine::tools::specs(),
        |label, completed, total| {
            eprintln!("{label} ({completed}/{total})");
        },
    )
    .await?;
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
    use frog_engine::checkpoint;
    let cwd = std::env::current_dir()?;
    let root = checkpoint::repo_root(&cwd).context("parallel attempts need a git repository")?;
    if let Some(n) = cli.attempts {
        let name = format!(
            "{}-{}",
            root.file_name().and_then(|s| s.to_str()).unwrap_or("repo"),
            session::new_id()
        );
        let parent = frog_engine::config::data_dir().join("attempts");
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

/// The model a saved session last ran a turn on, from its log.
fn session_model(id: &str) -> Option<String> {
    let text = std::fs::read_to_string(session::default_dir().join(format!("{id}.jsonl"))).ok()?;
    text.lines().rev().find_map(|line| {
        let v: serde_json::Value = serde_json::from_str(line).ok()?;
        let ev = &v["env"];
        (ev["event"] == "turn_ended")
            .then(|| ev["usage"]["model"].as_str().map(str::to_owned))
            .flatten()
    })
    .or_else(|| {
        // No finished turn yet: the model it was created with.
        let head: serde_json::Value = serde_json::from_str(text.lines().next()?).ok()?;
        head["model"].as_str().map(str::to_owned)
    })
}
