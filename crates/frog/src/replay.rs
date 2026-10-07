//! `frog --serve --replay <session>`: a fake engine that plays a recorded session back over the
//! serve protocol with realistic timing.
//!
//! Session logs keep only durable events, so this synthesizes the live ones a client would have
//! seen: progress, token-by-token deltas for messages and reasoning, questions, status, idle.
//! With `ask`, it stops at each edit or command for a permission answer, and at each question
//! for the user's. It exists so UI work can be done
//! against the same session every time, without a model in the loop.

use anyhow::{Context, Result};
use frog_engine::config::ToolMode;
use frog_engine::harness::Tier;
use frog_engine::protocol::{Answer, TurnUsage};
use frog_engine::session;
use frog_engine::{EndReason, Envelope, Event, Item, ItemKind, Mode, Op, Status};
use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::mpsc;

struct Player {
    session: String,
    seq: u64,
    speed: f64,
    status: Status,
    ops: mpsc::UnboundedReceiver<Op>,
}

enum Interrupted {
    Stop,
    Quit,
}

impl Player {
    fn emit(&mut self, event: Event) {
        self.seq += 1;
        let env = Envelope {
            seq: self.seq,
            session: self.session.clone(),
            created: chrono::Utc::now().timestamp_millis(),
            event,
        };
        if let Ok(line) = serde_json::to_string(&env) {
            println!("{line}");
        }
    }

    /// Sleep, scaled by speed, while watching for interrupts.
    async fn wait(&mut self, ms: f64) -> Result<(), Interrupted> {
        let dur = Duration::from_secs_f64((ms / self.speed).max(0.0) / 1000.0);
        let sleep = tokio::time::sleep(dur);
        tokio::pin!(sleep);
        loop {
            tokio::select! {
                _ = &mut sleep => return Ok(()),
                op = self.ops.recv() => match op {
                    None | Some(Op::Shutdown) => return Err(Interrupted::Quit),
                    Some(Op::Interrupt) => return Err(Interrupted::Stop),
                    Some(Op::SetMode { mode }) => self.status.mode = mode,
                    Some(_) => {}
                },
            }
        }
    }

    /// Block until the client answers a permission request.
    async fn answer(&mut self) -> Result<(), Interrupted> {
        loop {
            match self.ops.recv().await {
                None | Some(Op::Shutdown) => return Err(Interrupted::Quit),
                Some(Op::Interrupt) => return Err(Interrupted::Stop),
                Some(Op::Permission { .. }) => return Ok(()),
                Some(_) => {}
            }
        }
    }

    /// Block until the client answers a question.
    async fn answer_question(&mut self) -> Result<Answer, Interrupted> {
        loop {
            match self.ops.recv().await {
                None | Some(Op::Shutdown) => return Err(Interrupted::Quit),
                Some(Op::Interrupt) => return Err(Interrupted::Stop),
                Some(Op::Answer { answer, .. }) => return Ok(answer),
                Some(_) => {}
            }
        }
    }

    fn idle(&mut self) {
        let status = self.status.clone();
        self.emit(Event::Status(status));
        self.emit(Event::Idle);
    }
}

fn load(spec: &str) -> Result<(session::Header, Vec<Envelope>)> {
    let path = Path::new(spec);
    let (dir, id) = if path.is_file() {
        let dir = path.parent().unwrap_or(Path::new("."));
        let id = path
            .file_stem()
            .and_then(|s| s.to_str())
            .context("bad session path")?;
        (dir.to_path_buf(), id.to_string())
    } else {
        (session::default_dir(), spec.to_string())
    };
    let loaded = session::load(&dir, &id)?;
    Ok((loaded.header, loaded.events))
}

/// Split text into small chunks that look like streamed tokens.
fn chunks(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for (i, word) in text.split_inclusive(' ').enumerate() {
        cur.push_str(word);
        if i % 2 == 1 || word.contains('\n') {
            out.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

pub async fn run(spec: &str, speed: f64, ask: bool) -> Result<()> {
    let (header, events) = load(spec)?;
    let (tx, ops) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Ok(op) = serde_json::from_str::<Op>(&line)
                && tx.send(op).is_err()
            {
                break;
            }
        }
    });

    let mut p = Player {
        session: header.id.clone(),
        seq: 0,
        speed: speed.max(0.1),
        status: Status {
            model: header.model.clone(),
            mode: Mode::Default,
            cwd: header.cwd.clone(),
            messages: 0,
            context_tokens: None,
            context_window: 32_768,
            tool_mode: ToolMode::Native,
            tier: Tier::Medium,
            tokens_per_sec: None,
            todos: Vec::new(),
            vision: false,
        },
        ops,
    };
    p.idle();

    match play(&mut p, &events, ask).await {
        Err(Interrupted::Quit) => return Ok(()),
        Err(Interrupted::Stop) => {
            p.emit(Event::Notice {
                level: frog_engine::Level::Info,
                message: "replay stopped".into(),
            });
            p.idle();
        }
        Ok(()) => {}
    }
    // Stay up like a real engine until the client leaves.
    while let Some(op) = p.ops.recv().await {
        if let Op::Shutdown = op {
            break;
        }
    }
    Ok(())
}

async fn play(p: &mut Player, events: &[Envelope], ask: bool) -> Result<(), Interrupted> {
    let texts: HashMap<&str, &str> = events
        .iter()
        .filter_map(|e| match &e.event {
            Event::ItemCompleted {
                id,
                item: Item::Message { text } | Item::Reasoning { text },
            } => Some((id.as_str(), text.as_str())),
            _ => None,
        })
        .collect();
    // Recorded command output, re-streamed line by line while the tool "runs".
    let outputs: HashMap<&str, &str> = events
        .iter()
        .filter_map(|e| match &e.event {
            Event::ItemCompleted {
                id,
                item:
                    Item::ToolCall {
                        name,
                        output,
                        display,
                        ..
                    },
            } if name == "Bash" || name == "!" => {
                Some((id.as_str(), display.as_deref().unwrap_or(output.as_str())))
            }
            _ => None,
        })
        .collect();

    // The recorded diff doubles as the permission preview.
    let diffs: HashMap<&str, &frog_engine::protocol::FileDiff> = events
        .iter()
        .filter_map(|e| match &e.event {
            Event::ItemCompleted {
                id,
                item: Item::ToolCall { diff: Some(d), .. },
            } => Some((id.as_str(), d)),
            _ => None,
        })
        .collect();

    // What each `Ask` asked, to put the question again.
    let asks: HashMap<&str, frog_engine::ask::Question> = events
        .iter()
        .filter_map(|e| match &e.event {
            Event::ItemCompleted {
                id,
                item: Item::ToolCall { name, input, .. },
            } if name == frog_engine::ask::TOOL => {
                Some((id.as_str(), frog_engine::ask::parse(input).ok()?))
            }
            _ => None,
        })
        .collect();

    p.wait(600.0).await?;
    let mut prev = events.first().map(|e| e.created).unwrap_or(0);
    let mut turn = 0;
    let mut open = false;
    for env in events {
        let gap = ((env.created - prev) as f64).clamp(0.0, 1500.0);
        prev = env.created;
        match &env.event {
            Event::TurnStarted { turn: n, .. } => {
                turn = *n;
                open = true;
                p.emit(env.event.clone());
                p.emit(Event::Progress {
                    label: "thinking".into(),
                });
            }
            Event::ItemStarted {
                id,
                kind: kind @ (ItemKind::Message | ItemKind::Reasoning),
            } => {
                p.wait(gap).await?;
                p.emit(env.event.clone());
                let reasoning = *kind == ItemKind::Reasoning;
                for chunk in chunks(texts.get(id.as_str()).copied().unwrap_or("")) {
                    let delta = if reasoning {
                        frog_engine::Delta::Reasoning { text: chunk }
                    } else {
                        frog_engine::Delta::Text { text: chunk }
                    };
                    p.emit(Event::ItemDelta {
                        id: id.clone(),
                        delta,
                    });
                    p.wait(if reasoning { 12.0 } else { 28.0 }).await?;
                }
            }
            Event::ItemStarted {
                id,
                kind: ItemKind::ToolCall { name, arg },
            } => {
                p.wait(gap).await?;
                p.emit(env.event.clone());
                let gated = matches!(name.as_str(), "Edit" | "Write" | "Bash")
                    && p.status.mode != Mode::Yolo;
                if ask && gated {
                    let always = if name == "Bash" {
                        format!(
                            "always allow `{}` this session",
                            arg.split_whitespace().next().unwrap_or("")
                        )
                    } else {
                        "allow all edits this session".into()
                    };
                    p.emit(Event::PermissionRequest {
                        id: format!("perm-{id}"),
                        item: id.clone(),
                        name: name.clone(),
                        arg: arg.clone(),
                        always,
                        preview: diffs.get(id.as_str()).map(|d| (*d).clone()),
                        reason: None,
                    });
                    p.answer().await?;
                }
                if let Some(q) = asks.get(id.as_str()) {
                    let qid = format!("ask-{id}");
                    p.emit(Event::Question {
                        id: qid.clone(),
                        item: id.clone(),
                        question: q.question.clone(),
                        options: q.options.clone(),
                        multi: q.multi,
                        allow_other: q.allow_other,
                    });
                    // Without `ask`, the question shows for a moment and the recorded answer
                    // (in the tool's result) follows.
                    let answer = if ask {
                        p.answer_question().await?
                    } else {
                        p.wait(2000.0).await?;
                        Answer::default()
                    };
                    p.emit(Event::QuestionResolved { id: qid, answer });
                }
                if let Some(out) = outputs.get(id.as_str()) {
                    for line in out.split_inclusive('\n') {
                        p.emit(Event::ItemDelta {
                            id: id.clone(),
                            delta: frog_engine::Delta::Output {
                                text: line.to_string(),
                            },
                        });
                        p.wait(60.0).await?;
                    }
                }
            }
            Event::ItemDelta {
                delta: frog_engine::Delta::ImagePreview { .. },
                ..
            } => {
                p.wait(gap).await?;
                p.emit(env.event.clone());
            }
            Event::ItemCompleted { .. } => {
                p.wait(gap.min(900.0)).await?;
                p.emit(env.event.clone());
                p.emit(Event::Progress {
                    label: "thinking".into(),
                });
            }
            Event::TurnEnded { usage, .. } => {
                open = false;
                p.wait(300.0).await?;
                p.emit(env.event.clone());
                p.status.context_tokens = usage.context_tokens;
                p.status.tokens_per_sec = usage.tokens_per_sec;
                p.status.messages += 2;
                p.idle();
                p.wait(1500.0).await?;
            }
            // Ask mode synthesizes its own permission flow.
            Event::PermissionResolved { .. } if ask => {}
            // Questions are put again above, under their own ids.
            Event::QuestionResolved { .. } => {}
            _ => p.emit(env.event.clone()),
        }
    }
    // A log that ends mid-turn (crash or timeout) still ends cleanly for the client.
    if open {
        p.emit(Event::TurnEnded {
            turn,
            reason: EndReason::Cancelled,
            usage: TurnUsage::default(),
        });
        p.idle();
    }
    Ok(())
}
