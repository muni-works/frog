//! Non-interactive clients: `-p` print mode and `--serve` JSONL.

use anyhow::Result;
use frog_engine::{EndReason, Event, Handle, Item, ItemKind, Level, Op, ToolOutcome};
use std::io::{IsTerminal, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, BufReader};

/// A one-line status on stderr ("loading model… 42s", "thinking… 3s") while nothing else is
/// showing, so a slow cold start isn't silent. Only when stderr is a terminal; never stdout.
struct Status(Option<Arc<Mutex<Option<(String, Instant)>>>>);

impl Status {
    fn new() -> Self {
        if !std::io::stderr().is_terminal() {
            return Self(None);
        }
        let state: Arc<Mutex<Option<(String, Instant)>>> = Default::default();
        let s = Arc::downgrade(&state);
        std::thread::spawn(move || {
            while let Some(state) = s.upgrade() {
                if let Some((label, t0)) = &*state.lock().unwrap() {
                    eprint!("\r\x1b[2K{label} {}s", t0.elapsed().as_secs());
                }
                drop(state);
                std::thread::sleep(Duration::from_millis(250));
            }
        });
        Self(Some(state))
    }

    /// Show `label`, timing from now.
    fn show(&self, label: &str) {
        if let Some(state) = &self.0 {
            let label = match label {
                l if l.starts_with("loading ") => "loading model…".to_string(),
                l if l.ends_with('…') => l.to_string(),
                l => format!("{l}…"),
            };
            let mut s = state.lock().unwrap();
            if s.as_ref().map(|(l, _)| l) != Some(&label) {
                *s = Some((label, Instant::now()));
            }
        }
    }

    /// Erase the line before anything else is written.
    fn clear(&self) {
        if let Some(state) = &self.0
            && state.lock().unwrap().take().is_some()
        {
            eprint!("\r\x1b[2K");
        }
    }
}

/// Run one prompt. Assistant text goes to stdout, everything else to stderr.
/// With `json`, every event envelope is printed as a JSON line instead.
/// Returns false if the turn didn't complete.
pub async fn print(mut h: Handle, prompt: String, json: bool) -> Result<bool> {
    h.ops.send(Op::Submit {
        text: prompt,
        images: Vec::new(),
        more: Vec::new(),
    })?;
    // No Shutdown here: the router cancels the running turn on it, and Shutdown sent
    // right after Submit races the turn into a cancel-at-birth. The turn ends on its
    // own and the engine exits when the handle drops (or on the Shutdown below).
    let mut ok = false;
    let status = (!json).then(Status::new);
    loop {
        let env = tokio::select! {
            env = h.events.recv() => env,
            _ = tokio::signal::ctrl_c() => {
                let _ = h.ops.send(Op::Interrupt);
                continue;
            }
        };
        let Some(env) = env else { break };
        let mut done = false;
        if let Event::TurnEnded { reason, .. } = &env.event {
            ok = *reason == EndReason::Complete;
            done = true;
        }
        if matches!(env.event, Event::Error { .. }) {
            done = true;
        }
        if json {
            println!("{}", serde_json::to_string(&env)?);
            // Same ending as text mode: without this, `-p --json` printed turn_ended and then
            // waited forever for the engine to go away.
            if done {
                let _ = h.ops.send(Op::Shutdown);
                break;
            }
            continue;
        }
        // Everything that prints below clears the status line first; reasoning doesn't print,
        // so it keeps "thinking…" up. A turn, and each model call after a tool, starts with
        // "thinking…", unless a model is loading.
        let status = status.as_ref().expect("text mode");
        let mut then_thinking = false;
        match &env.event {
            Event::Progress { label, .. } => status.show(label),
            Event::TurnStarted { .. }
            | Event::ItemStarted {
                kind: ItemKind::Reasoning,
                ..
            }
            | Event::ItemDelta {
                delta: frog_engine::Delta::Reasoning { .. },
                ..
            } => status.show("thinking"),
            Event::ItemCompleted {
                item: Item::ToolCall { .. },
                ..
            } => {
                status.clear();
                then_thinking = true;
            }
            Event::ItemDelta {
                delta: frog_engine::Delta::Text { .. },
                ..
            }
            | Event::ItemStarted {
                kind: ItemKind::ToolCall { .. },
                ..
            }
            | Event::Notice {
                level: Level::Warn, ..
            }
            | Event::Error { .. }
            | Event::TurnEnded { .. } => status.clear(),
            _ => {}
        }
        match env.event {
            Event::ItemDelta {
                delta: frog_engine::Delta::Text { text },
                ..
            } => {
                print!("{text}");
                let _ = std::io::stdout().flush();
            }
            Event::ItemStarted {
                kind: ItemKind::ToolCall { name, arg },
                ..
            } => eprintln!("[{name}] {arg}"),
            Event::ItemCompleted {
                item: Item::ToolCall {
                    outcome, output, ..
                },
                ..
            } if outcome != ToolOutcome::Ok => {
                let first = output.lines().next().unwrap_or("");
                eprintln!("  {}", first.strip_prefix("Error: ").unwrap_or(first))
            }
            Event::Notice {
                level: Level::Warn,
                message,
            } => eprintln!("{message}"),
            Event::Error { error } => eprintln!("error: {error}"),
            Event::TurnEnded { reason, .. } => match reason {
                EndReason::Complete => {}
                EndReason::Error { error } => eprintln!("error: {error}"),
                other => eprintln!("turn ended: {other:?}"),
            },
            _ => {}
        }
        if then_thinking {
            status.show("thinking");
        }
        if done {
            // The turn is over (or failed): shut down cleanly, after it, never during it.
            let _ = h.ops.send(Op::Shutdown);
            break;
        }
    }
    if let Some(s) = &status {
        s.clear();
    }
    if !json {
        println!();
    }
    Ok(ok)
}

/// Speak the engine protocol over stdio: `Op` JSON lines in, event envelopes out.
pub async fn serve(mut h: Handle) -> Result<()> {
    let ops = h.ops.clone();
    drop(h.ops);
    tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str::<Op>(&line) {
                Ok(op) => {
                    if ops.send(op).is_err() {
                        break;
                    }
                }
                Err(e) => eprintln!("invalid op: {e}"),
            }
        }
        let _ = ops.send(Op::Shutdown);
    });
    while let Some(env) = h.events.recv().await {
        println!("{}", serde_json::to_string(&env)?);
    }
    Ok(())
}
