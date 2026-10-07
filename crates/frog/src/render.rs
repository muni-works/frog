//! Inline terminal rendering of engine events, in the style of Claude Code.

use crossterm::event::{self, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::style::Stylize;
use crossterm::terminal;
use frog_engine::protocol::{TurnTiming, TurnUsage};
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
    pub bar: Option<LiveBar>,
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
            bar: None,
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

    fn phase(&self, p: impl Into<String>) {
        if let Some(b) = &self.bar {
            b.phase(p);
        }
    }

    pub fn event(&mut self, ev: Event) {
        match &ev {
            Event::ItemStarted {
                kind: ItemKind::ToolCall { name, .. },
                ..
            } => self.phase(format!("running {name}")),
            Event::ItemCompleted { .. } => self.phase("waiting for the model"),
            Event::ItemDelta { delta, .. } => {
                let (phase, n) = match delta {
                    Delta::Reasoning { text } => ("thinking", text.len()),
                    Delta::Text { text } => ("writing", text.len()),
                    _ => ("", 0),
                };
                if n > 0 {
                    self.phase(phase);
                    if let Some(b) = &self.bar {
                        b.streamed(n);
                    }
                }
            }
            _ => {}
        }
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
    if n >= 1_000_000 {
        let m = format!("{:.1}", n as f64 / 1_000_000.0);
        format!("{}M", m.trim_end_matches(".0"))
    } else if n >= 1000 {
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

/// The line pinned above the prompt:
/// `▰▰▰▱▱▱▱▱▱▱ 38% of 32k · 94% cached · 61 tok/s · prefill 0.3s · accept-edits · strong`.
/// `last` is the most recent finished turn, for what only a turn measures.
pub fn status_bar(s: &frog_engine::Status, last: Option<&TurnUsage>) -> String {
    const CELLS: u64 = 10;
    let window = s.context_window.max(1);
    let mut parts = Vec::new();
    match s.context_tokens {
        Some(c) => {
            let pct = (c * 100 / window).min(100);
            let filled = (c * CELLS).div_ceil(window).min(CELLS) as usize;
            let bar = format!(
                "{}{}",
                "▰".repeat(filled),
                "▱".repeat(CELLS as usize - filled)
            );
            let bar = match pct {
                0..60 => bar.cyan(),
                60..80 => bar.yellow(),
                _ => bar.red(),
            };
            parts.push(format!("{bar} {pct}% of {}", fmt_tokens(window)));
        }
        None => parts.push(format!("ctx ? of {}", fmt_tokens(window))),
    }
    let calls = last
        .and_then(|u| u.timing.as_ref())
        .map(|t| t.calls.as_slice())
        .unwrap_or_default();
    let prompt: u64 = calls.iter().map(|c| c.prompt_tokens).sum();
    let cached: u64 = calls.iter().map(|c| c.cached_tokens).sum();
    // Zero cached usually means the server doesn't report it, not a cold cache.
    if prompt > 0 && cached > 0 {
        parts.push(format!("{}% cached", cached * 100 / prompt));
    }
    if let Some(t) = s.tokens_per_sec {
        parts.push(format!("{t:.0} tok/s"));
    }
    if let Some(c) = calls.last() {
        parts.push(format!("prefill {:.1}s", c.ttft_ms as f64 / 1000.0));
    }
    let mode = s.mode.label().to_lowercase();
    parts.push(match s.mode {
        frog_engine::Mode::Default => mode,
        _ => mode.yellow().to_string(),
    });
    parts.push(format!("{:?} · {:?}", s.tier, s.tool_mode).to_lowercase());
    let sep = " · ".dark_grey().to_string();
    parts.join(&sep)
}

/// After a turn: where its time went (the status bar has the rest).
pub fn turn_time(u: &TurnUsage) {
    if let Some(t) = &u.timing {
        info(&format!("\n  {}", time_split(t).trim_start_matches(" · ")));
    }
}

/// What the live bar shows while a turn runs.
struct Live {
    status: frog_engine::Status,
    started: Instant,
    phase: String,
    /// Reply and reasoning text streamed so far, for a rough speed.
    chars: usize,
    first_token: Option<Instant>,
}

/// The status bar pinned to the terminal's last row while a turn streams. Output scrolls in a
/// region above it; dropping the bar gives the row back.
pub struct LiveBar {
    live: Arc<std::sync::Mutex<Live>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

/// Terminal rows, or None when there's no room for a bar.
fn rows() -> Option<u16> {
    terminal::size().ok().map(|(_, h)| h).filter(|h| *h >= 6)
}

/// Confine scrolling to rows `1..h-1`, keeping the cursor where it was (setting the region
/// moves it home).
fn reserve(h: u16) {
    print!("\x1b7\x1b[1;{}r\x1b8", h - 1);
    flush();
}

impl LiveBar {
    pub fn start(status: frog_engine::Status) -> Option<Self> {
        if !std::io::stdout().is_terminal() || std::env::var_os("FROG_NO_BAR").is_some() {
            return None;
        }
        let h = rows()?;
        // Make sure the cursor isn't on the row the bar takes.
        print!("\n\x1b[1A");
        reserve(h);
        let live = Arc::new(std::sync::Mutex::new(Live {
            status,
            started: Instant::now(),
            phase: "waiting for the model".into(),
            chars: 0,
            first_token: None,
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let (l, s) = (live.clone(), stop.clone());
        let handle = std::thread::spawn(move || {
            let mut height = h;
            while !s.load(Ordering::Relaxed) {
                if let Some(now) = rows() {
                    if now != height {
                        height = now;
                        reserve(height);
                    }
                    let (cols, _) = terminal::size().unwrap_or((80, height));
                    let line = live_line(&l.lock().unwrap(), cols as usize);
                    // One write, so it can't interleave with streamed output.
                    print!("\x1b7\x1b[{height};1H\x1b[2K{line}\x1b8");
                    flush();
                }
                std::thread::park_timeout(Duration::from_millis(250));
            }
            print!("\x1b7\x1b[r\x1b[{height};1H\x1b[2K\x1b8");
            flush();
        });
        Some(Self {
            live,
            stop,
            handle: Some(handle),
        })
    }

    fn with(&self, f: impl FnOnce(&mut Live)) {
        f(&mut self.live.lock().unwrap());
        if let Some(h) = &self.handle {
            h.thread().unpark();
        }
    }

    pub fn status(&self, s: frog_engine::Status) {
        self.with(|l| l.status = s);
    }

    fn phase(&self, p: impl Into<String>) {
        let p = p.into();
        self.with(|l| l.phase = p);
    }

    fn streamed(&self, n: usize) {
        self.with(|l| {
            l.first_token.get_or_insert_with(Instant::now);
            l.chars += n;
        });
    }
}

impl Drop for LiveBar {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            h.thread().unpark();
            let _ = h.join();
        }
    }
}

/// `▰▰▰▱▱▱▱▱▱▱ 31% of 32k · 12s · writing · ~58 tok/s · default · ctrl+c to interrupt`,
/// dropping parts from the end to fit `cols`.
fn live_line(l: &Live, cols: usize) -> String {
    let s = &l.status;
    let mut parts: Vec<(String, String)> = Vec::new();
    if let Some(c) = s.context_tokens {
        let window = s.context_window.max(1);
        let pct = (c * 100 / window).min(100);
        let filled = (c * 10).div_ceil(window).min(10) as usize;
        let bar = format!("{}{}", "▰".repeat(filled), "▱".repeat(10 - filled));
        let styled = match pct {
            0..60 => bar.clone().cyan(),
            60..80 => bar.clone().yellow(),
            _ => bar.clone().red(),
        };
        let tail = format!(" {pct}% of {}", fmt_tokens(window));
        parts.push((
            format!("{bar}{tail}"),
            format!("{styled}{}", tail.dark_grey()),
        ));
    } else {
        let t = format!("{} ctx", fmt_tokens(s.context_window));
        parts.push((t.clone(), t.dark_grey().to_string()));
    }
    let mut plain = |t: String| parts.push((t.clone(), t.dark_grey().to_string()));
    plain(format!("{}s", l.started.elapsed().as_secs()));
    parts.push((l.phase.clone(), l.phase.clone().dark_yellow().to_string()));
    let mut plain = |t: String| parts.push((t.clone(), t.dark_grey().to_string()));
    if let Some(t0) = l.first_token {
        let secs = t0.elapsed().as_secs_f64();
        if secs >= 1.0 {
            plain(format!("~{:.0} tok/s", l.chars as f64 / 4.0 / secs));
        }
    }
    plain(s.mode.label().to_lowercase());
    plain("ctrl+c to interrupt".into());
    let mut width = 0;
    let mut out = Vec::new();
    for (p, styled) in parts {
        let w = p.chars().count() + if out.is_empty() { 0 } else { 3 };
        if width + w > cols {
            break;
        }
        width += w;
        out.push(styled);
    }
    out.join(&" · ".dark_grey().to_string())
}
