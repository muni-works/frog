//! Non-interactive clients: `-p` print mode and `--serve` JSONL.

use anyhow::Result;
use kiln_engine::{EndReason, Event, Handle, Item, ItemKind, Level, Op, ToolOutcome};
use std::io::Write;
use tokio::io::{AsyncBufReadExt, BufReader};

/// Run one prompt. Assistant text goes to stdout, everything else to stderr.
/// With `json`, every event envelope is printed as a JSON line instead.
/// Returns false if the turn didn't complete.
pub async fn print(mut h: Handle, prompt: String, json: bool) -> Result<bool> {
    h.ops.send(Op::Submit { text: prompt })?;
    h.ops.send(Op::Shutdown)?;
    let mut ok = false;
    loop {
        let env = tokio::select! {
            env = h.events.recv() => env,
            _ = tokio::signal::ctrl_c() => {
                let _ = h.ops.send(Op::Interrupt);
                continue;
            }
        };
        let Some(env) = env else { break };
        if let Event::TurnEnded { reason, .. } = &env.event {
            ok = *reason == EndReason::Complete;
        }
        if json {
            println!("{}", serde_json::to_string(&env)?);
            continue;
        }
        match env.event {
            Event::ItemDelta {
                delta: kiln_engine::Delta::Text { text },
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
