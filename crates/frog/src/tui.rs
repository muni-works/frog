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

/// The line above the input: context, model and mode.
struct FrogPrompt(String);

impl Prompt for FrogPrompt {
    fn render_prompt_left(&self) -> Cow<'_, str> {
        Cow::Borrowed(&self.0)
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
    /// The last finished turn, for the status bar.
    last: Option<TurnUsage>,
}

impl Tui {
    fn send(&self, op: Op) {
        let _ = self.h.ops.send(op);
    }

    /// Render events until the engine is idle again. Returns false if the engine is gone.
    async fn drain(&mut self) -> bool {
        self.drain_with(false).await
    }

    /// With `replay`, past turns are being re-rendered: echo inputs, skip footers.
    async fn drain_with(&mut self, replay: bool) -> bool {
        let mut r = Renderer::new(self.cfg.show_thinking, replay);
        let mut started = false;
        let mut finished = None;
        loop {
            let env = tokio::select! {
                env = self.h.events.recv() => env,
                _ = tokio::signal::ctrl_c() => {
                    self.send(Op::Interrupt);
                    continue;
                }
            };
            let Some(env) = env else { return false };
            self.session = env.session;
            match env.event {
                Event::Idle => {
                    r.idle();
                    r.bar = None;
                    if let Some(u) = finished {
                        render::turn_summary(&u);
                        self.last = Some(u);
                    }
                    return true;
                }
                Event::Status(s) => {
                    if let Some(b) = &r.bar {
                        b.status(s.clone());
                    }
                    self.status = Some(s);
                }
                Event::TurnStarted { .. } if !replay && !started => {
                    started = true;
                    r.bar = self.status.clone().and_then(render::LiveBar::start);
                }
                Event::PermissionRequest {
                    id,
                    always,
                    preview,
                    ..
                } => {
                    r.idle();
                    if let Some(diff) = &preview {
                        render::preview(diff);
                    }
                    match render::ask_permission(&always).await {
                        Some(decision) => self.send(Op::Permission { id, decision }),
                        None => {
                            self.send(Op::Permission {
                                id,
                                decision: Decision::Deny,
                            });
                            self.send(Op::Interrupt);
                        }
                    }
                }
                Event::TurnEnded {
                    reason: EndReason::Complete,
                    usage,
                    ..
                } if !replay => {
                    r.idle();
                    finished = Some(usage);
                }
                ev => r.event(ev),
            }
        }
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
    async fn command(&mut self, cmd: &str) -> bool {
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
                    Some(t) if !t.is_empty() => println!("{}", todo::render(t)),
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
        let switching = matches!(op, Op::SetModel { .. });
        let before = self.status.as_ref().map(|s| s.model.clone());
        self.send(op);
        let alive = self.drain().await;
        // A bare `frog` starts where you left off.
        if let Some(now) = self.status.as_ref().map(|s| &s.model)
            && switching
            && before.as_ref() != Some(now)
        {
            frog_engine::models::remember_last_used(now);
        }
        alive
    }
}

/// Put the terminal back in cooked mode if something (a killed program) left it raw: output
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

pub async fn run(h: Handle, cfg: Config, mut queued: Option<String>) -> Result<()> {
    restore_cooked();
    let mut tui = Tui {
        h,
        cfg,
        status: None,
        session: String::new(),
        last: None,
    };
    if !tui.drain().await {
        return Ok(());
    }
    tui.banner();
    if tui.status.as_ref().is_some_and(|s| s.messages > 0) {
        tui.send(Op::Subscribe { after: 0 });
        if !tui.drain_with(true).await {
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
    let mut ed = editor(cwd, models)?;
    // A ctrl+c at the prompt clears it; a second one in a row exits.
    let mut armed = false;
    loop {
        let line = match queued.take() {
            Some(q) => {
                println!("> {q}");
                q
            }
            None => {
                let top = if armed {
                    "  press ctrl+c again to exit".dark_grey().to_string()
                } else {
                    tui.status
                        .as_ref()
                        .map(|s| format!("  {}", render::composer_line(s)))
                        .unwrap_or_default()
                };
                let signal = tokio::task::block_in_place(|| {
                    ed.read_line(&FrogPrompt(format!("\n{top}\n")))
                })?;
                match signal {
                    Signal::CtrlC if armed => break,
                    Signal::CtrlC => {
                        armed = true;
                        continue;
                    }
                    Signal::CtrlD => break,
                    Signal::Success(s) | Signal::HostCommand(s) => {
                        armed = false;
                        s
                    }
                    _ => continue,
                }
            }
        };
        let line = line.trim();
        let alive = if line.is_empty() {
            true
        } else if let Some(cmd) = line.strip_prefix('/') {
            if !tui.command(cmd).await {
                break;
            }
            true
        } else if let Some(cmd) = line.strip_prefix('!') {
            tui.send(Op::Shell {
                command: cmd.trim().into(),
            });
            tui.drain().await
        } else {
            tui.send(Op::Submit {
                text: line.into(),
                images: Vec::new(),
            });
            tui.drain().await
        };
        if !alive {
            break;
        }
    }
    // Let the engine save before exiting.
    tui.send(Op::Shutdown);
    while tui.h.events.recv().await.is_some() {}
    Ok(())
}
