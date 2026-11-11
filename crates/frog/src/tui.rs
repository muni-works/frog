//! Interactive REPL client.

use crate::complete::{FrogCompleter, Models};
use crate::render::{self, Renderer};
use anyhow::Result;
use crossterm::style::Stylize;
use frog_engine::config::{Config, data_dir};
use frog_engine::protocol::{Answer, TurnUsage};
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

/// What the prompt shows above the input (the line still streaming, then the params or
/// status line), shared with the main loop, which changes it and asks reedline to repaint.
struct FrogPrompt(Arc<Mutex<String>>);

impl Prompt for FrogPrompt {
    fn render_prompt_left(&self) -> Cow<'_, str> {
        Cow::Owned(self.0.lock().unwrap().clone())
    }
    fn render_prompt_right(&self) -> Cow<'_, str> {
        Cow::Borrowed("")
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

/// What a sent message keeps in the scrollback: just `> text`, without the streaming line or
/// status above it (those are redrawn in the next prompt).
struct Sent;

impl Prompt for Sent {
    fn render_prompt_left(&self) -> Cow<'_, str> {
        Cow::Borrowed("\n")
    }
    fn render_prompt_right(&self) -> Cow<'_, str> {
        Cow::Borrowed("")
    }
    fn render_prompt_indicator(&self, _: PromptEditMode) -> Cow<'_, str> {
        Cow::Borrowed("> ")
    }
    fn render_prompt_multiline_indicator(&self) -> Cow<'_, str> {
        Cow::Borrowed("  ")
    }
    fn render_prompt_history_search_indicator(&self, _: PromptHistorySearch) -> Cow<'_, str> {
        Cow::Borrowed("> ")
    }
}

/// ctrl+c as a host command, so the prompt stays where it is rather than being finished
/// off (and left in the scrollback) like a submitted line.
const CTRL_C: &str = "\u{3}";

fn editor(cwd: PathBuf, models: Models) -> Result<Reedline> {
    let newline = || ReedlineEvent::Edit(vec![reedline::EditCommand::InsertNewline]);
    let cycle = || ReedlineEvent::ExecuteHostCommand("/mode".into());
    let mut kb = default_emacs_keybindings();
    kb.add_binding(KeyModifiers::ALT, KeyCode::Enter, newline());
    kb.add_binding(KeyModifiers::SHIFT, KeyCode::Enter, newline());
    kb.add_binding(KeyModifiers::SHIFT, KeyCode::BackTab, cycle());
    kb.add_binding(KeyModifiers::NONE, KeyCode::BackTab, cycle());
    kb.add_binding(
        KeyModifiers::CONTROL,
        KeyCode::Char('c'),
        ReedlineEvent::Multiple(vec![
            ReedlineEvent::Edit(vec![reedline::EditCommand::Clear]),
            ReedlineEvent::ExecuteHostCommand(CTRL_C.into()),
        ]),
    );
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
        .with_transient_prompt(Box::new(Sent))
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
    /// An `Ask` question waiting for an answer from the composer.
    question: Option<Question>,
    /// A ctrl+c at an idle prompt clears it; a second one in a row exits.
    armed: bool,
}

struct Question {
    id: String,
    labels: Vec<String>,
    multi: bool,
    allow_other: bool,
}

impl Question {
    /// What the composer line means as an answer: option numbers (several, with `multi`),
    /// else the user's own words if allowed; empty skips. None when it's neither.
    fn answer(&self, line: &str) -> Option<Answer> {
        if line.is_empty() {
            return Some(Answer::default());
        }
        let picks: Option<Vec<usize>> = line
            .split([',', ' '])
            .filter(|t| !t.is_empty())
            .map(|t| {
                t.parse::<usize>()
                    .ok()
                    .filter(|n| (1..=self.labels.len()).contains(n))
            })
            .collect();
        match picks {
            Some(mut p) if !p.is_empty() => {
                if !self.multi {
                    p.truncate(1);
                }
                p.dedup();
                Some(Answer {
                    choices: p.iter().map(|n| self.labels[n - 1].clone()).collect(),
                    other: None,
                })
            }
            _ if self.allow_other => Some(Answer {
                choices: Vec::new(),
                other: Some(line.to_string()),
            }),
            _ => None,
        }
    }

    /// The line above the input while it's asked.
    fn hint(&self) -> String {
        let n = self.labels.len();
        let mut parts = vec![if self.multi {
            format!("1-{n}, several with commas")
        } else {
            format!("1-{n} to pick")
        }];
        if self.allow_other {
            parts.push("or type an answer".into());
        }
        parts.push("enter skips".into());
        format!("  {}", parts.join(" · ").dark_grey())
    }
}

impl Tui {
    fn send(&mut self, op: Op) {
        if !matches!(
            op,
            Op::Interrupt
                | Op::Permission { .. }
                | Op::Answer { .. }
                | Op::Warm { .. }
                | Op::Shutdown
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
                Event::Status(s) => {
                    r.set_model(&s.model);
                    self.status = Some(s)
                }
                Event::TurnEnded { .. } if !replay => {}
                ev => r.event(ev),
            }
        }
        false
    }

    /// While the engine works: the line above the input.
    fn working(&self) -> String {
        const FRAMES: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
        let t = self.since.map_or(0, |s| s.elapsed().as_millis());
        let queued = match self.inflight {
            0 | 1 => String::new(),
            n => format!(" · {} queued", n - 1),
        };
        format!(
            "  {} {}",
            FRAMES[(t / 100) as usize % FRAMES.len()].dark_yellow(),
            format!("{}s{queued} · ctrl+c to interrupt", t / 1000).dark_grey()
        )
    }

    /// While idle (or asking): the line above the input.
    fn idle_top(&self) -> String {
        if let Some(q) = &self.question {
            return q.hint();
        }
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
            Event::Status(s) => {
                r.set_model(&s.model);
                self.status = Some(s)
            }
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
            Event::Question {
                id,
                question,
                options,
                multi,
                allow_other,
                ..
            } => {
                r.idle();
                render::say(&format!("  {}", question.yellow().bold()));
                for (i, o) in options.iter().enumerate() {
                    let detail = o
                        .detail
                        .as_deref()
                        .map(|d| format!("  {d}"))
                        .unwrap_or_default();
                    render::say(&format!(
                        "  {} {}{}",
                        format!("[{}]", i + 1).bold(),
                        o.label,
                        detail.dark_grey()
                    ));
                }
                render::flush_out();
                self.question = Some(Question {
                    id,
                    labels: options.into_iter().map(|o| o.label).collect(),
                    multi,
                    allow_other,
                });
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
            // `n: <note>` (or `no, <note>`): deny and tell the agent why, so it adjusts.
            let lowered = line.to_lowercase();
            if let Some(note) = ["n:", "no:", "n,", "no,"]
                .iter()
                .find_map(|p| lowered.starts_with(p).then(|| line[p.len()..].trim()))
                .filter(|n| !n.is_empty())
            {
                render::say(&format!("  {}", "denied with a note".red()));
                self.send(Op::Permission {
                    id,
                    decision: Decision::Deny,
                    note: Some(note.to_string()),
                });
                return true;
            }
            let (decision, said) = match line.to_lowercase().as_str() {
                "" | "y" | "yes" => (Decision::Allow, "yes".green()),
                "a" | "always" => (Decision::AllowAlways, "always".green()),
                "n" | "no" => (Decision::Deny, "no".red()),
                // Anything other than an answer is a message: deny, then send it.
                _ => (Decision::Deny, "denied · sending your message".red()),
            };
            render::say(&format!("  {said}"));
            self.send(Op::Permission { id, decision, note: None });
            if matches!(
                line.to_lowercase().as_str(),
                "" | "y" | "yes" | "a" | "always" | "n" | "no"
            ) {
                return true;
            }
        }
        if let Some(q) = self.question.take() {
            let Some(answer) = q.answer(line) else {
                render::say(&format!("  {}", q.hint().trim_start()));
                self.question = Some(q);
                return true;
            };
            if answer.dismissed() {
                render::say(&format!("  {}", "skipped".red()));
            } else {
                let mut said = answer.choices.join(", ");
                if let Some(o) = &answer.other {
                    said = if said.is_empty() {
                        o.clone()
                    } else {
                        format!("{said} · {o}")
                    };
                }
                render::say(&format!("  {}", said.green()));
            }
            self.send(Op::Answer { id: q.id, answer });
            return true;
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
                more: Vec::new(),
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
                note: None,
            });
            self.send(Op::Interrupt);
            return true;
        }
        if self.question.take().is_some() || self.inflight > 0 {
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
        // Which model, and whether it's free or billed, before the first prompt.
        if let Ok((spec, p)) = self.cfg.resolve(Some(&s.model)) {
            let runs = frog_engine::model_policy::where_it_runs(&spec, &p);
            render::info(&format!("   {spec} · {runs} · /model to switch"));
        }
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
                more: Vec::new(),
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

/// Above the input: the line the model is still writing, if any, then what the engine is
/// doing or, idle, the params.
fn prompt_left(tui: &Tui) -> String {
    let top = if tui.inflight > 0 && tui.asking.is_none() && tui.question.is_none() {
        tui.working()
    } else {
        tui.idle_top()
    };
    let partial = render::partial();
    if partial.is_empty() {
        format!("\n{top}\n")
    } else {
        format!("{partial}\n\n{top}\n")
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
        question: None,
        armed: false,
    };
    if !tui.drain_startup(false).await {
        return Ok(());
    }
    // Someone's at the keyboard to answer `Ask`. Previews need a client that hosts them.
    // Queued like any op, so it ends with its own `Idle`. The IRC bus stays off in the
    // terminal: it's config-gated and the Mac app declares it.
    let _ = tui.h.ops.send(Op::SetClientCaps {
        panes: false,
        ask: true,
        sessions: false,
        irc: false,
    });
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
    let shown = Arc::new(Mutex::new(prompt_left(&tui)));
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
                    Some(Ok(Signal::HostCommand(c))) if c == CTRL_C => tui.ctrl_c(),
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
        let left = prompt_left(&tui);
        let mut s = shown.lock().unwrap();
        if *s != left {
            *s = left;
            repaint.request_repaint();
        }
    }
    render::flush_out();
    // Let the engine save before exiting.
    let _ = tui.h.ops.send(Op::Shutdown);
    while tui.h.events.recv().await.is_some() {}
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn q(multi: bool, allow_other: bool) -> Question {
        Question {
            id: "q".into(),
            labels: vec!["red".into(), "green".into(), "blue".into()],
            multi,
            allow_other,
        }
    }

    #[test]
    fn numbers_pick_options() {
        assert_eq!(q(false, false).answer("2").unwrap().choices, ["green"]);
        assert_eq!(q(false, false).answer("2, 3").unwrap().choices, ["green"]);
        assert_eq!(
            q(true, false).answer("1,3").unwrap().choices,
            ["red", "blue"]
        );
    }

    #[test]
    fn words_are_an_answer_only_when_allowed() {
        assert!(q(false, false).answer("purple").is_none());
        assert!(q(false, false).answer("7").is_none());
        let a = q(false, true).answer("purple").unwrap();
        assert_eq!((a.choices.len(), a.other.as_deref()), (0, Some("purple")));
    }

    #[test]
    fn empty_skips() {
        assert!(q(true, true).answer("").unwrap().dismissed());
    }
}
