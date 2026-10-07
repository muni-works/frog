//! Interactive REPL client.

use crate::complete::{FrogCompleter, Models};
use crate::render::{self, Renderer};
use anyhow::Result;
use crossterm::style::Stylize;
use frog_engine::config::{Config, data_dir};
use frog_engine::protocol::TurnUsage;
use frog_engine::tools::todo;
use frog_engine::{Decision, EndReason, Event, Handle, Mode, Op, Status};
use reedline::{
    DescriptionMode, Emacs, FileBackedHistory, IdeMenu, KeyCode, KeyModifiers, MenuBuilder, Prompt,
    PromptEditMode, PromptHistorySearch, Reedline, ReedlineEvent, ReedlineMenu, Signal,
    default_emacs_keybindings,
};
use std::borrow::Cow;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// What the prompt shows, shared with the main loop, which changes it and asks reedline to
/// repaint. `top` is a line above the input (empty for a one-line prompt), `right` sits at
/// the end of the input line.
#[derive(Default)]
struct Shown {
    top: String,
    right: String,
    /// Bumped each time reedline paints a one-line prompt, so the main loop knows it's safe to
    /// print above it.
    short_paints: u64,
}

struct FrogPrompt(Arc<Mutex<Shown>>);

impl Prompt for FrogPrompt {
    fn render_prompt_left(&self) -> Cow<'_, str> {
        let mut s = self.0.lock().unwrap();
        if s.top.is_empty() {
            s.short_paints += 1;
            Cow::Borrowed("")
        } else {
            Cow::Owned(format!("\n{}\n", s.top))
        }
    }
    fn render_prompt_right(&self) -> Cow<'_, str> {
        Cow::Owned(self.0.lock().unwrap().right.clone())
    }
    fn render_prompt_indicator(&self, _: PromptEditMode) -> Cow<'_, str> {
        Cow::Borrowed("> ")
    }
    fn render_prompt_multiline_indicator(&self) -> Cow<'_, str> {
        Cow::Borrowed("  ")
    }
    fn render_prompt_history_search_indicator(&self, s: PromptHistorySearch) -> Cow<'_, str> {
        Cow::Owned(format!("(search: {}) ", s.term))
    }
    fn get_prompt_right_color(&self) -> reedline::Color {
        reedline::Color::DarkGray
    }
}

fn editor(cwd: PathBuf, models: Models) -> Result<Reedline> {
    let newline = || ReedlineEvent::Edit(vec![reedline::EditCommand::InsertNewline]);
    let cycle = || ReedlineEvent::ExecuteHostCommand("/mode".into());
    let mut kb = default_emacs_keybindings();
    kb.add_binding(KeyModifiers::ALT, KeyCode::Enter, newline());
    kb.add_binding(KeyModifiers::SHIFT, KeyCode::Enter, newline());
    kb.add_binding(KeyModifiers::SHIFT, KeyCode::BackTab, cycle());
    kb.add_binding(KeyModifiers::NONE, KeyCode::BackTab, cycle());
    kb.add_binding(
        KeyModifiers::NONE,
        KeyCode::Tab,
        ReedlineEvent::UntilFound(vec![
            ReedlineEvent::Menu("completion".into()),
            ReedlineEvent::MenuNext,
        ]),
    );
    let menu = IdeMenu::default()
        .with_name("completion")
        .with_marker("> ")
        .with_default_border()
        .with_description_mode(DescriptionMode::PreferRight)
        .with_max_completion_height(12);
    std::fs::create_dir_all(data_dir())?;
    let history = FileBackedHistory::with_file(5000, data_dir().join("history.txt"))?;
    Ok(Reedline::create()
        .with_poll_interval(Duration::from_millis(30))
        .with_edit_mode(Box::new(Emacs::new(kb)))
        .with_history(Box::new(history))
        .with_completer(Box::new(FrogCompleter::new(cwd, models)))
        .with_menu(ReedlineMenu::EngineCompleter(Box::new(menu)))
        .with_quick_completions(true)
        .with_partial_completions(true))
}

const HELP: &str = "\
  /model [name]     switch model (profile or provider/model); no arg lists profiles
  /mode [mode]      default | accept-edits | yolo (shift+tab cycles)
  /compact [focus]  summarize the conversation to free context
  /clear            start a fresh conversation
  /context          show context usage
  /todos            show the todo list
  /remember <note>  keep a note for this project (--global for every project)
  /forget <id|text> delete a note
  /memory           list notes
  /recall <words>   search notes and past sessions (file:<path> by file touched)
  /exit             quit
  !<cmd>            run a shell command; output goes to the model with your next message
  @<path>           attach a file to your message";

struct Tui {
    h: Handle,
    cfg: Config,
    status: Option<Status>,
    session: String,
    /// Ops sent that the engine hasn't finished (each ends with `Idle`).
    inflight: usize,
    /// When the engine started on the current batch of ops.
    since: Option<Instant>,
    /// A permission prompt waiting for y / a / n from the composer: its id, and what
    /// "always" would allow.
    asking: Option<(String, String)>,
    /// A ctrl+c at an idle prompt clears it; a second one in a row exits.
    armed: bool,
}

impl Tui {
    fn send(&mut self, op: Op) {
        if !matches!(
            op,
            Op::Interrupt | Op::Permission { .. } | Op::Warm { .. } | Op::Shutdown
        ) {
            if self.inflight == 0 {
                self.since = Some(Instant::now());
            }
            self.inflight += 1;
        }
        let _ = self.h.ops.send(op);
    }

    /// Before the composer is up: render events until the engine is idle. With `replay`, past
    /// turns are being re-rendered. Returns false if the engine is gone.
    async fn drain_startup(&mut self, replay: bool) -> bool {
        let mut r = Renderer::new(self.cfg.show_thinking, replay);
        while let Some(env) = self.h.events.recv().await {
            self.session = env.session;
            match env.event {
                Event::Idle => {
                    r.idle();
                    return true;
                }
                Event::Status(s) => self.status = Some(s),
                Event::TurnEnded { .. } if !replay => {}
                ev => r.event(ev),
            }
        }
        false
    }

    /// While the engine works: what goes at the end of the input line.
    fn working(&self) -> String {
        const FRAMES: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
        let t = self.since.map_or(0, |s| s.elapsed().as_millis());
        let queued = match self.inflight {
            0 | 1 => String::new(),
            n => format!(" · {} queued", n - 1),
        };
        format!(
            "{} {}s{queued} · ctrl+c to interrupt",
            FRAMES[(t / 100) as usize % FRAMES.len()],
            t / 1000
        )
    }

    /// While idle (or asking): the line above the input.
    fn top(&self) -> String {
        if let Some((_, always)) = &self.asking {
            return format!(
                "  {} yes · {} {always} · {} no",
                "y".bold(),
                "a".bold(),
                "n".bold()
            );
        }
        if self.armed {
            return "  press ctrl+c again to exit".dark_grey().to_string();
        }
        self.status
            .as_ref()
            .map(|s| format!("  {}", render::composer_line(s)))
            .unwrap_or_else(|| " ".into())
    }

    fn event(&mut self, r: &mut Renderer, finished: &mut Option<TurnUsage>, event: Event) {
        match event {
            Event::Idle => {
                self.inflight = self.inflight.saturating_sub(1);
                r.idle();
                if let Some(u) = finished.take() {
                    render::turn_summary(&u);
                }
                render::flush_out();
                if self.inflight == 0 {
                    self.since = None;
                } else {
                    self.since = Some(Instant::now());
                }
            }
            Event::Status(s) => self.status = Some(s),
            Event::ModelChanged { model } => {
                // A bare `frog` starts where you left off.
                frog_engine::models::remember_last_used(&model);
                r.event(Event::ModelChanged { model });
            }
            Event::PermissionRequest {
                id,
                name,
                arg,
                always,
                preview,
                reason,
                ..
            } => {
                r.idle();
                if let Some(diff) = &preview {
                    render::preview(diff);
                }
                let why = reason.map(|r| format!(" ({r})")).unwrap_or_default();
                let arg = if arg.is_empty() {
                    String::new()
                } else {
                    format!("({arg})")
                };
                render::say(&format!(
                    "  {} {}{arg}{why}?",
                    "allow".yellow(),
                    name.bold()
                ));
                render::flush_out();
                self.asking = Some((id, always));
            }
            Event::TurnEnded {
                reason: EndReason::Complete,
                usage,
                ..
            } => {
                r.idle();
                *finished = Some(usage);
            }
            ev => r.event(ev),
        }
    }

    /// A line from the composer. Returns false to quit.
    fn input(&mut self, line: &str) -> bool {
        let line = line.trim();
        if let Some((id, _)) = self.asking.take() {
            let decision = match line.to_lowercase().as_str() {
                "" | "y" | "yes" => Decision::Allow,
                "a" | "always" => Decision::AllowAlways,
                _ => Decision::Deny,
            };
            let said = match decision {
                Decision::Allow => "yes".green(),
                Decision::AllowAlways => "always".green(),
                Decision::Deny => "no".red(),
            };
            render::say(&format!("  {said}"));
            self.send(Op::Permission { id, decision });
            // Anything other than an answer is a message: deny, then send it.
            if matches!(
                line.to_lowercase().as_str(),
                "" | "y" | "yes" | "a" | "always" | "n" | "no"
            ) {
                return true;
            }
        }
        if line.is_empty() {
            return true;
        }
        if let Some(cmd) = line.strip_prefix('/') {
            return self.command(cmd);
        }
        if let Some(cmd) = line.strip_prefix('!') {
            self.send(Op::Shell {
                command: cmd.trim().into(),
            });
        } else {
            self.send(Op::Submit {
                text: line.into(),
                images: Vec::new(),
            });
        }
        true
    }

    /// Returns false to quit.
    fn ctrl_c(&mut self) -> bool {
        if let Some((id, _)) = self.asking.take() {
            self.send(Op::Permission {
                id,
                decision: Decision::Deny,
            });
            self.send(Op::Interrupt);
            return true;
        }
        if self.inflight > 0 {
            self.send(Op::Interrupt);
            return true;
        }
        if self.armed {
            return false;
        }
        self.armed = true;
        true
    }

    fn banner(&self) {
        let Some(s) = &self.status else { return };
        let home = dirs::home_dir().unwrap_or_default().display().to_string();
        let cwd = s.cwd.display().to_string().replacen(&home, "~", 1);
        println!(
            "\n {} {}  {}  {}",
            "✻".dark_yellow(),
            "frog".bold(),
            s.model.clone().cyan(),
            cwd.dark_grey()
        );
        render::info(
            "   /help for commands · shift+tab cycles permission mode · alt+enter for newline",
        );
        if s.messages > 0 {
            render::info(&format!(
                "   resumed session {} ({} messages)\n",
                self.session, s.messages
            ));
        }
    }

    /// Returns false to quit.
    fn command(&mut self, cmd: &str) -> bool {
        let (name, arg) = cmd
            .split_once(' ')
            .map(|(a, b)| (a, b.trim()))
            .unwrap_or((cmd, ""));
        let op = match name {
            "exit" | "quit" | "q" => return false,
            "help" | "?" => {
                render::info(HELP);
                return true;
            }
            "context" => {
                if let Some(s) = &self.status {
                    let usage = frog_engine::protocol::TurnUsage {
                        context_tokens: s.context_tokens,
                        tokens_per_sec: s.tokens_per_sec,
                        ..Default::default()
                    };
                    render::footer(&usage, s.context_window);
                }
                return true;
            }
            "todos" => {
                match self.status.as_ref().map(|s| &s.todos) {
                    Some(t) if !t.is_empty() => render::say(&todo::render(t)),
                    _ => render::info("  no todos"),
                }
                return true;
            }
            "model" if arg.is_empty() => {
                let current = self
                    .status
                    .as_ref()
                    .map(|s| s.model.as_str())
                    .unwrap_or("?");
                render::info(&format!("  current: {current}"));
                for (n, p) in &self.cfg.models {
                    render::info(&format!("  {n:<16} {:?} {}", p.provider, p.model));
                }
                render::info(
                    "  or any provider/model: ollama/…, lmstudio/…, llamacpp/…, openai/…, anthropic/…",
                );
                return true;
            }
            "model" => Op::SetModel { spec: arg.into() },
            "mode" => {
                let current = self
                    .status
                    .as_ref()
                    .map(|s| s.mode)
                    .unwrap_or(Mode::Default);
                let mode = match arg {
                    "" => current.next(),
                    "default" => Mode::Default,
                    "accept-edits" | "edits" => Mode::AcceptEdits,
                    "auto" => Mode::Auto,
                    "yolo" => Mode::Yolo,
                    _ => {
                        render::warn("  modes: default, accept-edits, auto, yolo");
                        return true;
                    }
                };
                render::info(&format!("  mode: {}", mode.label()));
                Op::SetMode { mode }
            }
            "compact" => Op::Compact {
                focus: (!arg.is_empty()).then(|| arg.into()),
            },
            "clear" | "new" => Op::Clear,
            // The engine answers these itself, without the model.
            "remember" | "forget" | "memory" | "recall" => Op::Submit {
                text: format!("/{cmd}"),
                images: Vec::new(),
            },
            _ => {
                render::warn(&format!("  unknown command /{name} — try /help"));
                return true;
            }
        };
        self.send(op);
        true
    }
}

/// Put the terminal back in cooked mode if something (a killed program, or a raw-mode prompt
/// that didn't get to clean up) left it raw: output
/// would otherwise stair-step, every line starting where the last ended.
fn restore_cooked() {
    use std::os::fd::AsRawFd;
    let fd = std::io::stdin().as_raw_fd();
    // SAFETY: tcgetattr/tcsetattr on stdin with a zeroed termios they fill in.
    unsafe {
        let mut t: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(fd, &mut t) != 0 || t.c_oflag & libc::OPOST != 0 {
            return;
        }
        t.c_oflag |= libc::OPOST | libc::ONLCR;
        t.c_lflag |= libc::ICANON | libc::ECHO | libc::ISIG | libc::IEXTEN;
        t.c_iflag |= libc::ICRNL;
        libc::tcsetattr(fd, libc::TCSANOW, &t);
    }
}

/// Restores cooked mode however `run` ends, errors included.
struct Cooked;

impl Drop for Cooked {
    fn drop(&mut self) {
        restore_cooked();
    }
}

pub async fn run(h: Handle, cfg: Config, queued: Option<String>) -> Result<()> {
    restore_cooked();
    let _cooked = Cooked;
    let mut tui = Tui {
        h,
        cfg,
        status: None,
        session: String::new(),
        inflight: 0,
        since: None,
        asking: None,
        armed: false,
    };
    if !tui.drain_startup(false).await {
        return Ok(());
    }
    tui.banner();
    if tui.status.as_ref().is_some_and(|s| s.messages > 0) {
        let _ = tui.h.ops.send(Op::Subscribe { after: 0 });
        if !tui.drain_startup(true).await {
            return Ok(());
        }
        println!();
    }
    let models = Models::default();
    {
        let (cfg, models) = (tui.cfg.clone(), models.clone());
        tokio::spawn(async move {
            let list = frog_engine::models::list(&cfg).await;
            *models.lock().unwrap() = list;
        });
    }
    let cwd = tui
        .status
        .as_ref()
        .map(|s| s.cwd.clone())
        .unwrap_or_default();

    // The composer runs on its own thread for the whole session, so you can type while the
    // model answers; output prints above it.
    let printer = reedline::ExternalPrinter::new(4096);
    render::install_sink(printer.clone());
    let mut ed = editor(cwd, models)?.with_external_printer(printer);
    let repaint = ed.repaint_signal();
    let shown = Arc::new(Mutex::new(Shown {
        top: tui.top(),
        ..Default::default()
    }));
    let (tx, mut inputs) = tokio::sync::mpsc::unbounded_channel();
    {
        let prompt = FrogPrompt(shown.clone());
        std::thread::spawn(move || {
            loop {
                let signal = ed.read_line(&prompt);
                let done = matches!(signal, Err(_) | Ok(Signal::CtrlD));
                if tx.send(signal.map_err(|e| e.to_string())).is_err() || done {
                    break;
                }
            }
        });
    }
    if let Some(q) = queued {
        render::say(&format!("> {q}"));
        tui.input(&q);
    }

    let mut r = Renderer::new(tui.cfg.show_thinking, false);
    let mut finished = None;
    let mut tick = tokio::time::interval(Duration::from_millis(50));
    // Short paints seen when the prompt was last made one line; more means it's been drawn.
    let mut shrunk_at: Option<u64> = None;
    loop {
        tokio::select! {
            env = tui.h.events.recv() => {
                let Some(env) = env else { break };
                tui.session = env.session;
                tui.event(&mut r, &mut finished, env.event);
            }
            signal = inputs.recv() => {
                let keep = match signal {
                    None | Some(Err(_)) | Some(Ok(Signal::CtrlD)) => false,
                    Some(Ok(Signal::CtrlC)) => tui.ctrl_c(),
                    Some(Ok(Signal::Success(s) | Signal::HostCommand(s))) => {
                        tui.armed = false;
                        tui.input(&s)
                    }
                    Some(Ok(_)) => true,
                };
                if !keep {
                    break;
                }
            }
            _ = tick.tick() => {}
        }
        // Output only prints above a one-line prompt (see `render::Sink`): shrink the prompt
        // when there's something to print or the engine is working, and let output through
        // once reedline has drawn it short; grow it back when everything has printed.
        let busy = tui.inflight > 0 && tui.asking.is_none();
        let mut s = shown.lock().unwrap();
        if busy || render::sink_held() {
            if !s.top.is_empty() {
                s.top.clear();
                shrunk_at = Some(s.short_paints);
                repaint.request_repaint();
            }
            if shrunk_at.is_some_and(|at| s.short_paints > at) {
                shrunk_at = None;
                render::sink_open(true);
            }
            let right = if busy { tui.working() } else { String::new() };
            if s.right != right {
                s.right = right;
                repaint.request_repaint();
            }
        } else if shrunk_at.is_none() && render::sink_drained() {
            let top = tui.top();
            if s.top != top || !s.right.is_empty() {
                render::sink_open(false);
                s.top = top;
                s.right.clear();
                repaint.request_repaint();
            }
        }
    }
    render::flush_out();
    // Let the engine save before exiting.
    let _ = tui.h.ops.send(Op::Shutdown);
    while tui.h.events.recv().await.is_some() {}
    Ok(())
}
