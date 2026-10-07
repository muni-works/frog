//! Inline terminal rendering of engine events, in the style of Claude Code.

use crossterm::style::Stylize;
use crossterm::terminal;
use frog_engine::protocol::{TurnTiming, TurnUsage};
use frog_engine::{Delta, EndReason, Event, Item, ItemKind, Level, ToolOutcome};
use std::collections::HashSet;
use std::io::{IsTerminal, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// Where rendered output goes once the composer is live: reedline's external printer, which
/// prints whole lines above the prompt while you type. A partial line waits in `buf` (shown
/// live in the prompt) until a newline, or until it would wrap. Before that (startup, replaying a session) output goes
/// straight to stdout.
struct Sink {
    printer: reedline::ExternalPrinter<String>,
    buf: String,
}

static SINK: std::sync::Mutex<Option<Sink>> = std::sync::Mutex::new(None);

pub fn install_sink(printer: reedline::ExternalPrinter<String>) {
    *SINK.lock().unwrap() = Some(Sink {
        printer,
        buf: String::new(),
    });
}

fn sink_active() -> bool {
    SINK.lock().unwrap().is_some()
}

/// The line still streaming, which the TUI shows live above the composer until it's whole.
pub fn partial() -> String {
    SINK.lock()
        .unwrap()
        .as_ref()
        .map(|s| s.buf.clone())
        .unwrap_or_default()
}

/// Byte index where `s` has used `cols` columns on screen (skipping ANSI escapes), or None
/// if it's narrower than that.
fn cut_at(s: &str, cols: usize) -> Option<usize> {
    let mut n = 0;
    let mut esc = false;
    for (i, c) in s.char_indices() {
        match (esc, c) {
            (false, '\x1b') => esc = true,
            (true, c) if c.is_ascii_alphabetic() => esc = false,
            (true, _) => {}
            (false, _) => {
                if n == cols {
                    return Some(i);
                }
                n += 1;
            }
        }
    }
    None
}

fn send_line(sink: &Sink, line: &str) {
    // An empty message prints nothing, so a blank line goes as a space.
    let line = if line.is_empty() { " " } else { line };
    let _ = sink.printer.print(line.to_string());
}

pub fn write_out(s: &str) {
    let mut guard = SINK.lock().unwrap();
    let Some(sink) = guard.as_mut() else {
        print!("{s}");
        return;
    };
    sink.buf.push_str(s);
    let cols = terminal::size().map_or(80, |(c, _)| c as usize).max(20) - 1;
    loop {
        if let Some(i) = sink.buf.find('\n') {
            let line: String = sink.buf.drain(..=i).collect();
            send_line(sink, line.trim_end_matches('\n'));
        } else if let Some(at) = cut_at(&sink.buf, cols) {
            // A long streamed line wraps, at a word if there's one in its second half,
            // continuing indented like the renderer's own wraps.
            let at = match sink.buf[..at].rfind(' ') {
                Some(sp) if sp > at / 2 => sp + 1,
                _ => at,
            };
            let line: String = sink.buf.drain(..at).collect();
            let line = line.trim_end().to_string();
            send_line(sink, &line);
            sink.buf.insert_str(0, "  ");
        } else {
            break;
        }
    }
}

/// Print the partial line that's waiting, if any.
pub fn flush_out() {
    let mut guard = SINK.lock().unwrap();
    if let Some(sink) = guard.as_mut()
        && !sink.buf.is_empty()
    {
        let line = std::mem::take(&mut sink.buf);
        send_line(sink, &line);
    }
}

macro_rules! out {
    ($($t:tt)*) => { $crate::render::write_out(&format!($($t)*)) };
}
macro_rules! outln {
    () => { $crate::render::write_out("\n") };
    ($($t:tt)*) => { $crate::render::write_out(&format!("{}\n", format!($($t)*))) };
}

fn flush() {
    let _ = std::io::stdout().flush();
}

struct Spinner {
    stop: Arc<AtomicBool>,
    handle: JoinHandle<()>,
}

impl Spinner {
    fn start(msg: String) -> Option<Self> {
        if !std::io::stdout().is_terminal() || sink_active() {
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
                out!("\r\x1b[2K{}", line.dark_yellow());
                flush();
                i += 1;
                std::thread::park_timeout(Duration::from_millis(80));
            }
            out!("\r\x1b[2K");
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
            outln!();
            self.state = State::Idle;
        }
    }

    fn enter(&mut self, state: State) {
        if self.state == state {
            return;
        }
        self.idle();
        match state {
            State::Thinking => out!("\n{} ", "✻".dark_grey()),
            State::Text => out!("\n{} ", "⏺".white()),
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
            out!("{}", s.dark_grey().italic())
        } else {
            out!("{s}")
        }
        flush();
    }

    pub fn event(&mut self, ev: Event) {
        match ev {
            Event::TurnStarted { input, .. } if self.replay => {
                self.idle();
                outln!("\n{} {}", ">".dark_grey(), input.dark_grey());
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
                outln!("\n{} {}{}", "⏺".green(), name.bold(), arg);
            }
            Event::AutoApproved { reason, .. } => {
                self.idle();
                outln!("  {} {}", "auto:".dark_grey(), reason.dark_grey());
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
                    outln!(
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
                    Level::Info => info(&format!("  {}", shorten_notice(&message))),
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
                    EndReason::Cancelled => info("  ⎿  interrupted"),
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
    outln!();
    for line in art.lines() {
        outln!("     {}", line.cyan());
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
        outln!("{}{styled}", prefix.dark_grey());
    }
    if lines.is_empty() {
        outln!("{}", "  ⎿  (no output)".dark_grey());
    }
    if lines.len() > max {
        outln!(
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
            outln!("{}", "     ⋮".dark_grey());
        }
        for line in &hunk.lines {
            if shown == 30 {
                outln!("{}", "     …".dark_grey());
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
                LineKind::Add => outln!("  {}", format!("+{text}").green()),
                LineKind::Remove => outln!("  {}", format!("-{text}").red()),
                LineKind::Context => outln!("  {}", format!(" {text}").dark_grey()),
            }
        }
    }
}

pub fn info(s: &str) {
    outln!("{}", s.dark_grey());
}

pub fn warn(s: &str) {
    outln!("{}", s.yellow());
}

pub fn error(s: &str) {
    outln!("\n{} {}", "✗".red(), s.red());
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

/// What sits above the composer: `28% of 32.8k · ollama/qwen3-coder:30b · accept-edits`.
pub fn composer_line(s: &frog_engine::Status) -> String {
    let window = s.context_window.max(1);
    let ctx = match s.context_tokens {
        Some(c) => format!("{}% of {}", (c * 100 / window).min(100), fmt_tokens(window)),
        None => format!("{} context", fmt_tokens(window)),
    }
    .dark_grey();
    let mode = s.mode.label().to_lowercase();
    let mode = match s.mode {
        frog_engine::Mode::Default => mode.dark_grey(),
        _ => mode.yellow(),
    };
    let sep = " · ".dark_grey();
    format!("{ctx}{sep}{}{sep}{mode}", s.model.clone().dark_grey())
}

/// After a response, what it took: `3.1s · ttft 0.4s · tools 1.2s · 9.0k in (94% cached) ·
/// 312 out · 61 tok/s · ~0.4¢ · 0.02 Wh`. Cost needs a catalog price, energy `--energy`.
pub fn turn_summary(u: &TurnUsage) {
    let secs = |ms: u64| format!("{:.1}s", ms as f64 / 1000.0);
    let mut parts = Vec::new();
    if let Some(t) = &u.timing {
        parts.push(secs(t.wall_ms));
        parts.push(format!("ttft {}", secs(t.prefill_ms)));
        if t.tool_ms > 0 {
            parts.push(format!("tools {}", secs(t.tool_ms)));
        }
    }
    let calls = u
        .timing
        .as_ref()
        .map(|t| t.calls.as_slice())
        .unwrap_or_default();
    let cached: u64 = calls.iter().map(|c| c.cached_tokens).sum();
    let prompt: u64 = calls.iter().map(|c| c.prompt_tokens).sum();
    if u.input_tokens > 0 {
        let hit = if cached > 0 && prompt > 0 {
            format!(" ({}% cached)", cached * 100 / prompt)
        } else {
            String::new()
        };
        parts.push(format!("{} in{hit}", fmt_tokens(u.input_tokens)));
        parts.push(format!("{} out", fmt_tokens(u.output_tokens)));
    }
    if let Some(t) = u.tokens_per_sec {
        parts.push(format!("{t:.0} tok/s"));
    }
    if let Some(c) = u.model.as_deref().and_then(|m| cost(m, u)) {
        parts.push(c);
    }
    if let Some(e) = &u.energy {
        let wh = e.local_wh + e.remote_wh.unwrap_or(0.0);
        if wh >= 0.005 {
            parts.push(format!("{wh:.2} Wh"));
        }
    }
    if !parts.is_empty() {
        info(&format!("  {}", parts.join(" · ")));
    }
}

/// `~0.4¢` or `~$1.20`, from the provider catalog's per-million prices.
fn cost(model: &str, u: &TurnUsage) -> Option<String> {
    let m = frog_engine::catalog::cached(model)?;
    let usd = (u.input_tokens as f64 * m.cost_in? + u.output_tokens as f64 * m.cost_out?) / 1e6;
    Some(if usd < 0.995 {
        format!("~{:.1}¢", usd * 100.0)
    } else {
        format!("~${usd:.2}")
    })
}

/// The engine's MCP summary names every server and why; in a terminal, a count is enough.
fn shorten_notice(message: &str) -> String {
    let Some(rest) = message.strip_prefix("Some MCP servers aren't available: ") else {
        return message.to_string();
    };
    // "a couldn't start; b and c need a sign-in …; d isn't running." → a, b, c, d
    let names = rest
        .split("; ")
        .flat_map(|part| {
            let who = part.split(" couldn't").next().unwrap_or(part);
            let who = who.split(" need").next().unwrap_or(who);
            let who = who.split(" isn't").next().unwrap_or(who);
            who.split(" and ").map(str::to_string).collect::<Vec<_>>()
        })
        .count();
    let s = if names == 1 { "" } else { "s" };
    format!("{names} MCP server{s} unavailable · frog --mcp for details")
}

#[cfg(test)]
mod tests {
    #[test]
    fn mcp_summary_becomes_a_count() {
        assert_eq!(
            super::shorten_notice(
                "Some MCP servers aren't available: aws-mcp couldn't start; choji and runpod need a sign-in frog doesn't support yet; fusion isn't running."
            ),
            "4 MCP servers unavailable · frog --mcp for details"
        );
        assert_eq!(super::shorten_notice("hello"), "hello");
    }
}

/// One line of output, above the composer once it's live.
pub fn say(s: &str) {
    write_out(&format!("{s}\n"));
}
