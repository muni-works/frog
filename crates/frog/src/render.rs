//! Inline terminal rendering of engine events, in the style of Claude Code.

use crossterm::event::{self, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::style::Stylize;
use crossterm::terminal;
use frog_engine::protocol::{Answer, AskOption, TurnTiming, TurnUsage};
use frog_engine::{Decision, Delta, EndReason, Event, Item, ItemKind, Level, ToolOutcome};
use std::collections::HashSet;
use std::io::{IsTerminal, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

fn flush() {
    let _ = std::io::stdout().flush();
}

struct Spinner {
    stop: Arc<AtomicBool>,
    handle: JoinHandle<()>,
}

impl Spinner {
    fn start(msg: String) -> Option<Self> {
        if !std::io::stdout().is_terminal() {
            return None;
        }
        let stop = Arc::new(AtomicBool::new(false));
        let s = stop.clone();
        let handle = std::thread::spawn(move || {
            const FRAMES: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
            let t0 = Instant::now();
            let mut i = 0;
            while !s.load(Ordering::Relaxed) {
                let line = format!(
                    "{} {msg} ({}s · ctrl+c to interrupt)",
                    FRAMES[i % FRAMES.len()],
                    t0.elapsed().as_secs()
                );
                print!("\r\x1b[2K{}", line.dark_yellow());
                flush();
                i += 1;
                std::thread::park_timeout(Duration::from_millis(80));
            }
            print!("\r\x1b[2K");
            flush();
        });
        Some(Self { stop, handle })
    }

    fn stop(self) {
        self.stop.store(true, Ordering::Relaxed);
        self.handle.thread().unpark();
        let _ = self.handle.join();
    }
}

#[derive(PartialEq, Clone, Copy)]
enum State {
    Idle,
    Thinking,
    Text,
}

pub struct Renderer {
    spinner: Option<Spinner>,
    state: State,
    show_thinking: bool,
    /// Strip leading whitespace at the start of a section.
    fresh: bool,
    /// Items whose content already arrived as deltas.
    streamed: HashSet<String>,
    /// Re-rendering a past session: show each turn's input.
    replay: bool,
}

impl Drop for Renderer {
    fn drop(&mut self) {
        self.stop_spinner();
    }
}

impl Renderer {
    pub fn new(show_thinking: bool, replay: bool) -> Self {
        Self {
            spinner: None,
            state: State::Idle,
            show_thinking,
            fresh: true,
            streamed: HashSet::new(),
            replay,
        }
    }

    fn stop_spinner(&mut self) {
        if let Some(s) = self.spinner.take() {
            s.stop();
        }
    }

    /// End any streaming section and clear the spinner.
    pub fn idle(&mut self) {
        self.stop_spinner();
        if self.state != State::Idle {
            println!();
            self.state = State::Idle;
        }
    }

    fn enter(&mut self, state: State) {
        if self.state == state {
            return;
        }
        self.idle();
        match state {
            State::Thinking => print!("\n{} ", "✻".dark_grey()),
            State::Text => print!("\n{} ", "⏺".white()),
            State::Idle => {}
        }
        self.state = state;
        self.fresh = true;
    }

    fn write(&mut self, s: &str, dim: bool) {
        let s = if self.fresh { s.trim_start() } else { s };
        if s.is_empty() {
            return;
        }
        self.fresh = false;
        let s = s.replace('\n', "\n  ");
        if dim {
            print!("{}", s.dark_grey().italic())
        } else {
            print!("{s}")
        }
        flush();
    }

    pub fn event(&mut self, ev: Event) {
        match ev {
            Event::TurnStarted { input, .. } if self.replay => {
                self.idle();
                println!("\n{} {}", ">".dark_grey(), input.dark_grey());
            }
            Event::Progress { label } => {
                self.idle();
                self.spinner = Spinner::start(label);
            }
            Event::ItemStarted {
                kind: ItemKind::ToolCall { name, arg },
                ..
            } => {
                self.idle();
                let arg = if arg.is_empty() {
                    String::new()
                } else {
                    format!("({arg})")
                };
                println!("\n{} {}{}", "⏺".green(), name.bold(), arg);
            }
            Event::AutoApproved { reason, .. } => {
                self.idle();
                println!("  {} {}", "auto:".dark_grey(), reason.dark_grey());
            }
            // A subagent's steps, indented under its Task call; its report arrives as the
            // call's output.
            Event::Subagent { inner, .. } => {
                if let Event::ItemStarted {
                    kind: ItemKind::ToolCall { name, arg },
                    ..
                } = *inner
                {
                    self.idle();
                    println!(
                        "  {} {} {}",
                        "↳".dark_grey(),
                        name.dark_grey(),
                        arg.dark_grey()
                    );
                }
            }
            Event::ItemDelta { id, delta } => {
                self.streamed.insert(id);
                match delta {
                    Delta::Reasoning { text } if self.show_thinking => {
                        self.enter(State::Thinking);
                        self.write(&text, true);
                    }
                    Delta::Reasoning { .. } => {}
                    // The TUI shows tool output when the tool finishes.
                    Delta::Output { .. } | Delta::ImagePreview { .. } => {}
                    Delta::Text { text } => {
                        self.enter(State::Text);
                        self.write(&text, false);
                    }
                }
            }
            Event::ItemCompleted { id, item } => match item {
                Item::ToolCall {
                    diagram: Some(d),
                    outcome: ToolOutcome::Ok,
                    ..
                } => {
                    print_diagram(&d.to_ascii());
                }
                Item::ToolCall {
                    present: Some(p),
                    outcome: ToolOutcome::Ok,
                    ..
                } => {
                    print_diagram(&p.to_text());
                }
                Item::ToolCall {
                    outcome,
                    output,
                    display,
                    ..
                } => {
                    let text = match outcome {
                        ToolOutcome::Denied => "denied".to_string(),
                        ToolOutcome::Skipped => "skipped".to_string(),
                        _ => display.unwrap_or(output),
                    };
                    tool_result(&text, outcome != ToolOutcome::Ok);
                }
                Item::Message { text } => {
                    // Not streamed (non-streaming provider): show it whole.
                    if !self.streamed.contains(&id) {
                        self.enter(State::Text);
                        self.write(&text, false);
                    }
                    // Mermaid blocks get drawn after the message.
                    for src in mermaid_blocks(&text) {
                        if let Some(mut d) = frog_engine::diagram::Diagram::from_mermaid(&src) {
                            d.prepare(std::path::Path::new("."));
                            self.idle();
                            print_diagram(&d.to_ascii());
                        }
                    }
                }
                Item::Reasoning { text } if self.show_thinking && !self.streamed.contains(&id) => {
                    self.enter(State::Thinking);
                    self.write(&text, true);
                }
                _ => {}
            },
            Event::Notice { level, message } => {
                self.idle();
                match level {
                    Level::Info => info(&format!("  {message}")),
                    Level::Warn => warn(&format!("  {message}")),
                }
            }
            // Pane screens are for clients that draw panes; only what a pane reported shows here.
            Event::PaneNotice { id, message, .. } => {
                self.idle();
                warn(&format!("  [{id}] {message}"));
            }
            Event::Error { error: e } => {
                self.idle();
                error(&e.to_string());
            }
            Event::ModelChanged { model } => info(&format!("  model: {model}")),
            Event::ContextPruned {
                results,
                tokens_before,
                tokens_after,
            } => {
                self.idle();
                info(&format!(
                    "  pruned {results} old tool results: ~{} → ~{} tokens",
                    fmt_tokens(tokens_before),
                    fmt_tokens(tokens_after)
                ));
            }
            Event::Compacted {
                tokens_before,
                tokens_after,
            } => {
                self.idle();
                info(&format!(
                    "  compacted {} → {} tokens",
                    fmt_tokens(tokens_before),
                    fmt_tokens(tokens_after)
                ));
            }
            Event::TurnEnded { reason, .. } => {
                self.idle();
                match reason {
                    EndReason::Cancelled => warn("\n  ⎿  interrupted"),
                    EndReason::MaxTokens => warn("\n  ⎿  hit the output token limit"),
                    EndReason::Looping => {
                        warn("\n  ⎿  stopped: the model kept repeating the same tool call")
                    }
                    EndReason::StepLimit => warn(
                        "\n  ⎿  stopped: step limit for one turn reached; say \"continue\" to keep going",
                    ),
                    EndReason::Error { error: e } => error(&e.to_string()),
                    EndReason::Complete | EndReason::Denied => {}
                }
            }
            _ => {}
        }
    }
}

fn print_diagram(art: &str) {
    println!();
    for line in art.lines() {
        println!("     {}", line.cyan());
    }
}

/// The bodies of ```mermaid fenced blocks in a message.
fn mermaid_blocks(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur: Option<String> = None;
    for line in text.lines() {
        let t = line.trim();
        match &mut cur {
            None if t.starts_with("```mermaid") => cur = Some(String::new()),
            Some(body) if t.starts_with("```") => {
                out.push(std::mem::take(body));
                cur = None;
            }
            Some(body) => {
                body.push_str(line);
                body.push('\n');
            }
            None => {}
        }
    }
    out
}

fn tool_result(text: &str, err: bool) {
    let is_diff = text.lines().any(|l| l.starts_with(['+', '-']))
        && text.lines().all(|l| l.starts_with(['+', '-', ' ']));
    let max = if is_diff { 40 } else { 6 };
    let lines: Vec<&str> = text.lines().collect();
    for (i, line) in lines.iter().take(max).enumerate() {
        let prefix = if i == 0 { "  ⎿  " } else { "     " };
        let line: String = line.chars().take(200).collect();
        let styled = if err {
            line.red().to_string()
        } else if is_diff && line.starts_with('+') {
            line.green().to_string()
        } else if is_diff && line.starts_with('-') {
            line.red().to_string()
        } else {
            line.dark_grey().to_string()
        };
        println!("{}{styled}", prefix.dark_grey());
    }
    if lines.is_empty() {
        println!("{}", "  ⎿  (no output)".dark_grey());
    }
    if lines.len() > max {
        println!(
            "{}",
            format!("     … +{} lines", lines.len() - max).dark_grey()
        );
    }
}

/// Show what an edit would change before asking to allow it.
pub fn preview(diff: &frog_engine::protocol::FileDiff) {
    use frog_engine::protocol::LineKind;
    let mut shown = 0;
    for (i, hunk) in diff.hunks.iter().enumerate() {
        if i > 0 {
            println!("{}", "     ⋮".dark_grey());
        }
        for line in &hunk.lines {
            if shown == 30 {
                println!("{}", "     …".dark_grey());
                return;
            }
            shown += 1;
            let n = line
                .new
                .or(line.old)
                .map(|n| n.to_string())
                .unwrap_or_default();
            let text = format!("{n:>5} {}", line.text);
            match line.kind {
                LineKind::Add => println!("  {}", format!("+{text}").green()),
                LineKind::Remove => println!("  {}", format!("-{text}").red()),
                LineKind::Context => println!("  {}", format!(" {text}").dark_grey()),
            }
        }
    }
}

/// Returns `None` if the user hit ctrl+c.
pub async fn ask_permission(always: &str) -> Option<Decision> {
    println!(
        "  {}  {} yes   {} {always}   {} no",
        "Allow?".yellow().bold(),
        "[y]".bold(),
        "[a]".bold(),
        "[n]".bold()
    );
    flush();
    let answer = tokio::task::spawn_blocking(|| {
        if terminal::enable_raw_mode().is_err() {
            return Some(Decision::Deny);
        }
        let r = loop {
            let Ok(event::Event::Key(k)) = event::read() else {
                continue;
            };
            if k.kind != KeyEventKind::Press {
                continue;
            }
            break match k.code {
                KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => None,
                KeyCode::Char('y') | KeyCode::Enter => Some(Decision::Allow),
                KeyCode::Char('a') => Some(Decision::AllowAlways),
                KeyCode::Char('n') | KeyCode::Esc => Some(Decision::Deny),
                _ => continue,
            };
        };
        let _ = terminal::disable_raw_mode();
        r
    })
    .await
    .unwrap_or(Some(Decision::Deny));
    let msg = match answer {
        Some(Decision::Allow) => "yes".green(),
        Some(Decision::AllowAlways) => "always".green(),
        Some(Decision::Deny) => "no".red(),
        None => "interrupted".red(),
    };
    println!("  {msg}");
    answer
}

/// An `Ask` question: number keys pick (toggle, with `multi`, then enter), `o` types an
/// answer, esc dismisses. `None` on ctrl-c.
pub async fn ask_question(
    question: &str,
    options: &[AskOption],
    multi: bool,
    allow_other: bool,
) -> Option<Answer> {
    println!("  {}", question.yellow().bold());
    for (i, o) in options.iter().enumerate() {
        let detail = o
            .detail
            .as_deref()
            .map(|d| format!("  {d}"))
            .unwrap_or_default();
        println!(
            "  {} {}{}",
            format!("[{}]", i + 1).bold(),
            o.label,
            detail.dark_grey()
        );
    }
    let mut keys = Vec::new();
    if multi {
        keys.push("1-9 toggle, enter confirms");
    }
    if allow_other {
        keys.push("[o] type an answer");
    }
    keys.push("esc skips");
    info(&format!("  {}", keys.join(" · ")));
    flush();
    let labels: Vec<String> = options.iter().map(|o| o.label.clone()).collect();
    let picked = tokio::task::spawn_blocking(move || {
        if terminal::enable_raw_mode().is_err() {
            return Some((Vec::new(), false));
        }
        let mut on = vec![false; labels.len()];
        let r = loop {
            let Ok(event::Event::Key(k)) = event::read() else {
                continue;
            };
            if k.kind != KeyEventKind::Press {
                continue;
            }
            match k.code {
                KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => break None,
                KeyCode::Esc => break Some((Vec::new(), false)),
                KeyCode::Char('o') if allow_other => break Some((pick(&labels, &on), true)),
                KeyCode::Enter if multi => break Some((pick(&labels, &on), false)),
                KeyCode::Char(c) => {
                    let Some(i) = c
                        .to_digit(10)
                        .map(|d| d as usize)
                        .filter(|d| (1..=labels.len()).contains(d))
                    else {
                        continue;
                    };
                    if !multi {
                        break Some((vec![labels[i - 1].clone()], false));
                    }
                    on[i - 1] = !on[i - 1];
                }
                _ => {}
            }
        };
        let _ = terminal::disable_raw_mode();
        r
    })
    .await
    .unwrap_or(Some((Vec::new(), false)));
    let (choices, typing) = picked?;
    let other = if typing {
        print!("  {} ", "›".bold());
        flush();
        tokio::task::spawn_blocking(|| {
            let mut line = String::new();
            std::io::stdin().read_line(&mut line).ok()?;
            Some(line.trim().to_string()).filter(|l| !l.is_empty())
        })
        .await
        .ok()
        .flatten()
    } else {
        None
    };
    let answer = Answer { choices, other };
    if answer.dismissed() {
        println!("  {}", "skipped".red());
    } else {
        let mut said = answer.choices.join(", ");
        if let Some(o) = &answer.other {
            if !said.is_empty() {
                said.push_str(" · ");
            }
            said.push_str(o);
        }
        println!("  {}", said.green());
    }
    Some(answer)
}

fn pick(labels: &[String], on: &[bool]) -> Vec<String> {
    labels
        .iter()
        .zip(on)
        .filter(|(_, on)| **on)
        .map(|(l, _)| l.clone())
        .collect()
}

pub fn info(s: &str) {
    println!("{}", s.dark_grey());
}

pub fn warn(s: &str) {
    println!("{}", s.yellow());
}

pub fn error(s: &str) {
    println!("\n{} {}", "✗".red(), s.red());
}

pub fn fmt_tokens(n: u64) -> String {
    if n >= 1000 {
        format!("{:.1}k", n as f64 / 1000.0)
    } else {
        n.to_string()
    }
}

pub fn footer(u: &TurnUsage, window: u64) {
    let speed = u
        .tokens_per_sec
        .map(|t| format!(" · {t:.0} tok/s"))
        .unwrap_or_default();
    let ctx = match u.context_tokens {
        Some(c) => format!(
            "{}/{} ({}%)",
            fmt_tokens(c),
            fmt_tokens(window),
            c * 100 / window.max(1)
        ),
        None => format!("?/{} (provider didn't report usage)", fmt_tokens(window)),
    };
    let time = u.timing.as_ref().map(time_split).unwrap_or_default();
    info(&format!("\n  ctx {ctx}{speed}{time}"));
}

/// ` · model 12.3s (ttft 3.1s) · tools 4.2s`: where the turn's time went.
fn time_split(t: &TurnTiming) -> String {
    let secs = |ms: u64| format!("{:.1}s", ms as f64 / 1000.0);
    let mut out = format!(
        " · model {} (ttft {})",
        secs(t.prefill_ms + t.decode_ms),
        secs(t.prefill_ms)
    );
    if t.tool_ms > 0 {
        out.push_str(&format!(" · tools {}", secs(t.tool_ms)));
    }
    out
}
