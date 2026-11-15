//! Panes: what the agent can see of what it builds.
//!
//! A terminal pane is a shell the engine owns (a pty, parsed into a screen grid with `vt100`)
//! that both the model (`Terminal` tool) and the user (`Op::PaneInput`) can type into. A
//! preview pane is a webview the client hosts; the engine asks it to read, click or
//! screenshot through [`Event::PaneRequest`] and hears what it observes through
//! [`Op::PaneReport`]. Pane ops arrive on the router, outside the agent loop, so they work
//! mid-turn; everything here is behind a mutex held only briefly.

use crate::protocol::{Event, Op, PaneAction, PaneKind, ReportKind, ReportLevel};
use crate::provider::ToolSpec;
use crate::tools::{Output, int_arg, str_arg, strip_ansi, truncate_middle};
use anyhow::{Context, Result, bail};
use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};
use tokio::sync::{Notify, oneshot};
use tokio_util::sync::CancellationToken;

pub const TERMINAL: &str = "Terminal";
pub const PREVIEW: &str = "Preview";

/// Reports kept per pane.
const REPORTS: usize = 200;
/// Error reports queued for the model between calls.
const QUEUE: usize = 20;
/// Plain-text scrollback kept per terminal, in bytes.
const LOG_MAX: usize = 200_000;
/// How long the client has to answer a request.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
/// Screen updates are coalesced to one per this interval.
const SCREEN_INTERVAL: Duration = Duration::from_millis(33);

pub fn terminal_spec(read_only: bool) -> ToolSpec {
    let (description, actions) = if read_only {
        (
            "Read the screen and recent scrollback of a terminal pane (a shell the user or the main agent is running).",
            json!(["read"]),
        )
    } else {
        (
            "A persistent shell in a terminal pane the user can see and type into. Unlike Bash, the shell stays alive \
between calls: cd, environment variables and virtualenvs persist, and long-running processes (dev servers, \
watchers, REPLs) keep running while you do other things. Use it for dev servers and for interactive or stateful \
work; use Bash for one-shot commands. Actions: `run` types `command` plus Enter into the shared pane, waits up \
to `wait_ms` for the prompt to return (or output to settle) and returns what was printed; `read` returns the \
current screen and recent scrollback; `type` sends `text` as-is (no Enter added; use \\n, or \\u0003 for ctrl-c) \
for prompts and REPLs; `open` starts another shell in a new pane. If a command is still running in a pane, \
`run` there is refused: read it, interact with `type`, or `open` another pane and pass its `id`.",
            json!(["run", "read", "type", "open"]),
        )
    };
    ToolSpec {
        name: TERMINAL.into(),
        description: description.into(),
        schema: json!({
            "type": "object",
            "properties": {
                "action": { "type": "string", "enum": actions },
                "command": { "type": "string", "description": "For run: the command line" },
                "text": { "type": "string", "description": "For type: raw text to send" },
                "id": { "type": "string", "description": "Pane id (default: the shared terminal pane)" },
                "wait_ms": { "type": "integer", "description": "For run: how long to wait (default 8000, max 60000)" },
                "lines": { "type": "integer", "description": "For read: lines of scrollback to include (default 60)" }
            },
            "required": ["action"]
        }),
    }
}

pub fn preview_spec(read_only: bool) -> ToolSpec {
    let (description, actions) = if read_only {
        (
            "Read a preview pane (a browser view of what's being built): `read` returns the page as structured text; \
`console` returns its recent console messages, failed requests and navigations.",
            json!(["read", "console"]),
        )
    } else {
        (
            "A preview pane: a browser view in the app that shows what you're building and reports what it sees. \
`open` shows `url` in a new pane (a dev server's URL or port, or a path to an .html file or folder in \
the project); `read` returns the page as structured text (an accessibility tree); \
`screenshot` returns a picture of it; `console` returns recent console messages, failed requests and \
navigations; `click` clicks `selector`; `type` types `text` into `selector`; `navigate` goes to `url`; `eval` \
runs `js` in the page and returns the result. Console errors that happen while you work are reported to you \
automatically.",
            json!([
                "open",
                "read",
                "click",
                "type",
                "screenshot",
                "navigate",
                "eval",
                "console"
            ]),
        )
    };
    ToolSpec {
        name: PREVIEW.into(),
        description: description.into(),
        schema: json!({
            "type": "object",
            "properties": {
                "action": { "type": "string", "enum": actions },
                "url": { "type": "string" },
                "selector": { "type": "string", "description": "A CSS selector, or text from `read`" },
                "text": { "type": "string" },
                "js": { "type": "string" },
                "id": { "type": "string", "description": "Pane id (default: the last opened preview)" }
            },
            "required": ["action"]
        }),
    }
}

/// Whether a call only looks (no permission needed) or acts.
pub fn is_read(name: &str, input: &Value) -> bool {
    let action = input["action"].as_str().unwrap_or("");
    match name {
        TERMINAL => matches!(action, "read" | "open"),
        PREVIEW => matches!(action, "open" | "read" | "console" | "screenshot"),
        _ => false,
    }
}

/// What a call does, for the tool card and permission prompts.
pub fn label(name: &str, input: &Value) -> String {
    let s = |k: &str| input[k].as_str().unwrap_or("").trim();
    let action = s("action");
    let detail = match (name, action) {
        (TERMINAL, "run") => s("command").lines().next().unwrap_or("").to_string(),
        (TERMINAL, "type") => format!("{:?}", s("text")),
        (PREVIEW, "open") | (PREVIEW, "navigate") => s("url").to_string(),
        (PREVIEW, "click") => s("selector").to_string(),
        (PREVIEW, "type") => format!("{:?} into {}", s("text"), s("selector")),
        (PREVIEW, "eval") => s("js").lines().next().unwrap_or("").to_string(),
        _ => String::new(),
    };
    let id = s("id");
    let mut out = action.to_string();
    if !id.is_empty() {
        out.push_str(&format!(" {id}"));
    }
    if !detail.is_empty() {
        out.push_str(&format!(": {detail}"));
    }
    out
}

// ---- the screen emulator ----

/// The marker our shell hooks print before each prompt: `ESC ] 133 ; D ; <exit code> BEL`
/// (the semantic-prompt convention). Exact "the command finished", with its status.
static PROMPT_MARK: std::sync::LazyLock<regex::bytes::Regex> =
    std::sync::LazyLock::new(|| regex::bytes::Regex::new(r"\x1b\]133;D(?:;(\d+))?\x07").unwrap());

/// A terminal's screen grid plus a plain-text log of everything it printed.
pub struct Grid {
    parser: vt100::Parser,
    /// Plain text (escapes stripped), bounded; `dropped` bytes fell off the front.
    log: String,
    dropped: usize,
    /// An unfinished escape sequence at the end of the last chunk.
    carry: Vec<u8>,
    /// Bytes received, and when the last arrived.
    received: u64,
    last_output: Option<Instant>,
    /// Prompt markers seen, and where in the log the last one landed.
    prompts: u64,
    prompt_mark: usize,
    /// Exit status carried by the last prompt marker.
    last_status: Option<i32>,
    seq: u64,
    exit: Option<i32>,
}

impl Grid {
    pub fn new(cols: u16, rows: u16) -> Self {
        Self {
            parser: vt100::Parser::new(rows, cols, 0),
            log: String::new(),
            dropped: 0,
            carry: Vec::new(),
            received: 0,
            last_output: None,
            prompts: 0,
            prompt_mark: 0,
            last_status: None,
            seq: 0,
            exit: None,
        }
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        self.parser.process(bytes);
        self.received += bytes.len() as u64;
        self.last_output = Some(Instant::now());
        self.seq += 1;

        let mut buf = std::mem::take(&mut self.carry);
        buf.extend_from_slice(bytes);
        // Hold back a trailing unfinished escape for the next chunk.
        let cut = match buf.iter().rposition(|b| *b == 0x1b) {
            Some(i) if incomplete(&buf[i..]) => i,
            _ => buf.len(),
        };
        self.carry = buf.split_off(cut);
        let mut at = 0;
        for m in PROMPT_MARK.captures_iter(&buf) {
            let whole = m.get(0).unwrap();
            self.append(&buf[at..whole.start()]);
            self.prompts += 1;
            self.prompt_mark = self.mark();
            self.last_status = m
                .get(1)
                .and_then(|c| std::str::from_utf8(c.as_bytes()).ok())
                .and_then(|c| c.parse().ok());
            at = whole.end();
        }
        self.append(&buf[at..]);
    }

    fn append(&mut self, raw: &[u8]) {
        if raw.is_empty() {
            return;
        }
        let text = strip_ansi(&String::from_utf8_lossy(raw));
        self.log.extend(
            text.chars()
                .filter(|c| !c.is_control() || matches!(c, '\n' | '\t')),
        );
        if self.log.len() > LOG_MAX {
            let cut = self.log.floor_char_boundary(self.log.len() - LOG_MAX / 2);
            self.log.drain(..cut);
            self.dropped += cut;
        }
    }

    /// A position in the log to read back from later.
    pub fn mark(&self) -> usize {
        self.dropped + self.log.len()
    }

    /// Everything logged since `mark` (up to `until`, if given).
    pub fn since(&self, mark: usize, until: Option<usize>) -> &str {
        let end = until.unwrap_or(self.dropped + self.log.len());
        let start = mark.saturating_sub(self.dropped).min(self.log.len());
        let end = end
            .saturating_sub(self.dropped)
            .clamp(start, self.log.len());
        &self.log[self.log.floor_char_boundary(start)..self.log.floor_char_boundary(end)]
    }

    /// The last `n` lines of the log.
    pub fn tail(&self, n: usize) -> String {
        let lines: Vec<&str> = self.log.lines().collect();
        let from = lines.len().saturating_sub(n);
        lines[from..].join("\n")
    }

    pub fn resize(&mut self, cols: u16, rows: u16) {
        self.parser.screen_mut().set_size(rows, cols);
        self.seq += 1;
    }

    pub fn size(&self) -> (u16, u16) {
        let (rows, cols) = self.parser.screen().size();
        (cols, rows)
    }

    pub fn lines(&self) -> Vec<String> {
        let (_, cols) = self.parser.screen().size();
        self.parser.screen().rows(0, cols).collect()
    }

    /// The visible screen as text, trailing blank lines dropped.
    pub fn text(&self) -> String {
        let mut lines = self.lines();
        while lines.last().is_some_and(|l| l.trim().is_empty()) {
            lines.pop();
        }
        lines.join("\n")
    }

    pub fn screen_event(&self, id: &str) -> Event {
        let (rows, cols) = self.parser.screen().size();
        let (r, c) = self.parser.screen().cursor_position();
        Event::PaneScreen {
            id: id.to_string(),
            cols,
            rows,
            lines: self.lines(),
            cursor: [r, c],
            screen_seq: self.seq,
        }
    }

    fn quiet_for(&self) -> Duration {
        self.last_output.map(|t| t.elapsed()).unwrap_or_default()
    }
}

/// Whether `esc` (starting with ESC) is cut off before its final byte.
fn incomplete(esc: &[u8]) -> bool {
    match esc.get(1) {
        None => true,
        Some(b'[') => !esc[2..].iter().any(|b| (0x40..=0x7e).contains(b)),
        Some(b']') => !esc.contains(&0x07) && !esc.windows(2).any(|w| w == b"\x1b\\"),
        Some(b'(') | Some(b')') => esc.len() < 3,
        Some(_) => false,
    }
}

// ---- terminal panes ----

struct Term {
    grid: Arc<Mutex<Grid>>,
    notify: Arc<Notify>,
    writer: Box<dyn Write + Send>,
    master: Box<dyn MasterPty + Send>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    pid: Option<u32>,
    stop: CancellationToken,
    /// The user has typed something not yet followed by Enter.
    user_typing: bool,
    /// `prompts` when the last command line was sent; a later prompt means it finished.
    sent_at: u64,
    /// Keeps the shell hook files alive.
    _rc: Option<tempdir::Dir>,
}

impl Term {
    fn spawn(cwd: &Path, cols: u16, rows: u16) -> Result<Self> {
        let pty = portable_pty::native_pty_system()
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("opening a pty")?;
        let shell = login_shell(std::env::var("SHELL").ok());
        let (mut cmd, rc) = shell_command(&shell)?;
        cmd.cwd(cwd);
        cmd.env("TERM", "xterm-256color");
        cmd.env("FROG", "1");
        cmd.env("PAGER", "cat");
        cmd.env("GIT_PAGER", "cat");
        let mut child = pty
            .slave
            .spawn_command(cmd)
            .with_context(|| format!("starting {shell}"))?;
        drop(pty.slave);
        let killer = child.clone_killer();
        let pid = child.process_id();
        let mut reader = pty.master.try_clone_reader()?;
        let writer = pty.master.take_writer()?;
        let grid = Arc::new(Mutex::new(Grid::new(cols, rows)));
        let notify = Arc::new(Notify::new());
        {
            let (grid, notify) = (grid.clone(), notify.clone());
            std::thread::spawn(move || {
                let mut buf = [0u8; 8192];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            grid.lock().unwrap().feed(&buf[..n]);
                            notify.notify_one();
                        }
                    }
                }
                let code = child.wait().map(|s| s.exit_code() as i32).unwrap_or(-1);
                grid.lock().unwrap().exit = Some(code);
                notify.notify_one();
            });
        }
        Ok(Self {
            grid,
            notify,
            writer,
            master: pty.master,
            killer,
            pid,
            stop: CancellationToken::new(),
            user_typing: false,
            sent_at: 0,
            _rc: rc,
        })
    }

    fn write(&mut self, data: &[u8]) -> Result<()> {
        self.writer.write_all(data)?;
        self.writer.flush()?;
        Ok(())
    }

    fn kill(&mut self) {
        self.stop.cancel();
        // The shell is a session leader: its whole group (a dev server it started) goes too.
        if let Some(pid) = self.pid {
            unsafe {
                libc::killpg(pid as i32, libc::SIGHUP);
            }
        }
        let _ = self.killer.kill();
    }

    /// A prompt has appeared since the last command line was sent (or the shell doesn't
    /// mark prompts, so we can't tell).
    fn idle(&self) -> bool {
        let g = self.grid.lock().unwrap();
        g.prompts == 0 || g.prompts > self.sent_at
    }
}

/// The shell a terminal pane runs: `$SHELL` when it's set and exists, else the first of zsh,
/// bash and sh that does. A container (Frog Cloud's sandbox) often has no `$SHELL` and no zsh.
fn login_shell(env: Option<String>) -> String {
    env.into_iter()
        .filter(|s| !s.is_empty())
        .chain(["/bin/zsh", "/bin/bash", "/bin/sh"].map(String::from))
        .find(|s| std::path::Path::new(s).exists())
        .unwrap_or_else(|| "/bin/sh".into())
}

/// The shell with hooks that print a prompt marker, so a finished command is a fact rather
/// than a guess. zsh takes them through `ZDOTDIR` (its rc files source the user's own);
/// bash through `--rcfile`. Other shells run plain and fall back to output settling.
///
/// Pane shells don't run under Bash's seatbelt profile: an interactive login shell loads the
/// user's real rc files, which write dotfiles (`~/.zcompdump`, history) and exec tools the
/// profile blocks, so it never reaches a prompt. `Terminal.run` asks like an unsandboxed
/// command instead (see `engine::permit`).
fn shell_command(shell: &str) -> Result<(CommandBuilder, Option<tempdir::Dir>)> {
    let name = Path::new(shell)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(shell);
    let mut argv: Vec<String> = vec![shell.to_string()];
    let mut rc = None;
    match name {
        "zsh" => {
            let dir = tempdir::Dir::new("frog-zdot")?;
            let hook = "__frog_precmd() { printf '\\e]133;D;%s\\a' \"$?\"; }\nprecmd_functions+=(__frog_precmd)\n";
            for f in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
                let mut body = format!("[ -f \"$HOME/{f}\" ] && source \"$HOME/{f}\"\n");
                if f == ".zshrc" {
                    body = format!("ZDOTDIR=\"$HOME\"\n{body}{hook}");
                }
                std::fs::write(dir.path().join(f), body)?;
            }
            argv.push("-l".into());
            let mut cmd = CommandBuilder::from_argv(argv.into_iter().map(Into::into).collect());
            cmd.env("ZDOTDIR", dir.path());
            rc = Some(dir);
            return Ok((cmd, rc));
        }
        "bash" => {
            let dir = tempdir::Dir::new("frog-bashrc")?;
            let file = dir.path().join("rc");
            std::fs::write(
                &file,
                "for f in \"$HOME/.bash_profile\" \"$HOME/.bash_login\" \"$HOME/.profile\"; do [ -f \"$f\" ] && { source \"$f\"; break; }; done\n\
[ -f \"$HOME/.bashrc\" ] && source \"$HOME/.bashrc\"\n\
__frog_precmd() { printf '\\e]133;D;%s\\a' \"$?\"; }\n\
PROMPT_COMMAND=\"__frog_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}\"\n",
            )?;
            argv.push("--rcfile".into());
            argv.push(file.display().to_string());
            argv.push("-i".into());
            rc = Some(dir);
        }
        _ => argv.push("-l".into()),
    }
    Ok((
        CommandBuilder::from_argv(argv.into_iter().map(Into::into).collect()),
        rc,
    ))
}

/// A temp directory removed on drop (the shell hook files).
mod tempdir {
    pub struct Dir(std::path::PathBuf);

    impl Dir {
        pub fn new(prefix: &str) -> std::io::Result<Self> {
            let p = std::env::temp_dir().join(format!(
                "{prefix}-{}-{}",
                std::process::id(),
                crate::session::new_id()
            ));
            std::fs::create_dir_all(&p)?;
            Ok(Self(p))
        }

        pub fn path(&self) -> &std::path::Path {
            &self.0
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

// ---- pane registry ----

struct Pane {
    kind: PaneKind,
    url: Option<String>,
    term: Option<Term>,
    /// What the pane reported, formatted, oldest first.
    reports: VecDeque<String>,
}

#[derive(Default)]
struct State {
    next: u64,
    panes: BTreeMap<String, Pane>,
    /// Error reports waiting for the next model call, newest last.
    queued: Vec<String>,
    /// `@mention` → element context from the preview.
    mentions: HashMap<String, String>,
    root: PathBuf,
}

pub struct Panes {
    emit: Box<dyn Fn(Event) + Send + Sync>,
    state: Mutex<State>,
    /// The client hosts preview panes.
    client: AtomicBool,
    in_turn: AtomicBool,
    pending: Mutex<HashMap<String, oneshot::Sender<std::result::Result<Value, String>>>>,
}

impl Panes {
    pub fn new(emit: impl Fn(Event) + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(Self {
            emit: Box::new(emit),
            state: Mutex::new(State::default()),
            client: AtomicBool::new(false),
            in_turn: AtomicBool::new(false),
            pending: Mutex::new(HashMap::new()),
        })
    }

    /// Where new shells start.
    pub fn configure(&self, root: PathBuf) {
        self.state.lock().unwrap().root = root;
    }

    pub fn set_client(&self, panes: bool) {
        self.client.store(panes, Ordering::Relaxed);
    }

    pub fn client(&self) -> bool {
        self.client.load(Ordering::Relaxed)
    }

    pub fn set_in_turn(&self, on: bool) {
        self.in_turn.store(on, Ordering::Relaxed);
    }

    /// Don't reuse ids from a resumed session's log.
    pub fn seed_ids(&self, used: impl IntoIterator<Item = String>) {
        let max = used
            .into_iter()
            .filter_map(|id| id[1..].parse::<u64>().ok())
            .max()
            .unwrap_or(0);
        let mut s = self.state.lock().unwrap();
        s.next = s.next.max(max);
    }

    fn emit(&self, event: Event) {
        (self.emit)(event);
    }

    /// Pane ops from the router. Returns false for ops that aren't about panes.
    pub fn handle(self: &Arc<Self>, op: &Op) -> bool {
        match op {
            Op::PaneOpen {
                kind,
                cwd,
                url,
                cols,
                rows,
            } => {
                let r = self.open(
                    *kind,
                    cwd.as_deref().map(PathBuf::from),
                    url.clone(),
                    cols.unwrap_or(100),
                    rows.unwrap_or(30),
                );
                if let Err(e) = r {
                    self.emit(Event::Notice {
                        level: crate::protocol::Level::Warn,
                        message: format!("couldn't open a pane: {e:#}"),
                    });
                }
            }
            Op::PaneInput { id, data } => {
                let mut s = self.state.lock().unwrap();
                if let Some(t) = s.panes.get_mut(id).and_then(|p| p.term.as_mut()) {
                    if data.contains(['\r', '\n', '\x03', '\x15']) {
                        t.user_typing = false;
                        if data.contains(['\r', '\n']) {
                            t.sent_at = t.grid.lock().unwrap().prompts;
                        }
                    } else if !data.is_empty() {
                        t.user_typing = true;
                    }
                    let _ = t.write(data.as_bytes());
                }
            }
            Op::PaneResize { id, cols, rows } => {
                let mut s = self.state.lock().unwrap();
                if let Some(t) = s.panes.get_mut(id).and_then(|p| p.term.as_mut()) {
                    let _ = t.master.resize(PtySize {
                        rows: *rows,
                        cols: *cols,
                        pixel_width: 0,
                        pixel_height: 0,
                    });
                    t.grid.lock().unwrap().resize(*cols, *rows);
                    t.notify.notify_one();
                }
            }
            Op::PaneClose { id } => self.close(id, None),
            Op::PaneReport {
                id,
                kind,
                level,
                message,
                url,
                status,
            } => self.report(
                id,
                *kind,
                level.unwrap_or(ReportLevel::Info),
                message,
                url.as_deref(),
                *status,
            ),
            Op::PaneReply {
                call,
                result,
                error,
            } => {
                if let Some(tx) = self.pending.lock().unwrap().remove(call) {
                    let _ = tx.send(match error {
                        Some(e) => Err(e.clone()),
                        None => Ok(result.clone().unwrap_or(Value::Null)),
                    });
                }
            }
            Op::PaneMention {
                mention, context, ..
            } => {
                let mut s = self.state.lock().unwrap();
                match context {
                    Some(c) => {
                        s.mentions.insert(mention.clone(), c.clone());
                    }
                    None => {
                        s.mentions.remove(mention);
                    }
                }
            }
            _ => return false,
        }
        true
    }

    /// Open a pane and announce it. Terminal panes start a shell; preview panes are the
    /// client's to create once it sees `PaneOpened`.
    pub fn open(
        self: &Arc<Self>,
        kind: PaneKind,
        cwd: Option<PathBuf>,
        url: Option<String>,
        cols: u16,
        rows: u16,
    ) -> Result<String> {
        if kind == PaneKind::Preview && !self.client() {
            bail!("preview panes need a client that hosts them (the Frog app)");
        }
        let (id, title, cwd) = {
            let mut s = self.state.lock().unwrap();
            s.next += 1;
            let prefix = match kind {
                PaneKind::Terminal => "t",
                PaneKind::Preview => "p",
            };
            let id = format!("{prefix}{}", s.next);
            let cwd = cwd.or_else(|| (kind == PaneKind::Terminal).then(|| s.root.clone()));
            let term = match kind {
                PaneKind::Terminal => {
                    let dir = cwd.clone().unwrap_or_else(|| s.root.clone());
                    Some(Term::spawn(&dir, cols, rows)?)
                }
                PaneKind::Preview => None,
            };
            let title = match kind {
                PaneKind::Terminal => cwd
                    .as_ref()
                    .and_then(|c| c.file_name())
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "shell".into()),
                PaneKind::Preview => url.clone().unwrap_or_else(|| "preview".into()),
            };
            if let Some(t) = &term {
                self.watch(&id, t);
            }
            s.panes.insert(
                id.clone(),
                Pane {
                    kind,
                    url: url.clone(),
                    term,
                    reports: VecDeque::new(),
                },
            );
            (id, title, cwd)
        };
        self.emit(Event::PaneOpened {
            id: id.clone(),
            kind,
            title,
            cwd: cwd.map(|c| c.display().to_string()),
            url,
        });
        Ok(id)
    }

    /// Stream a terminal's screen, coalesced; close the pane when its shell exits.
    fn watch(self: &Arc<Self>, id: &str, term: &Term) {
        let (grid, notify, stop) = (term.grid.clone(), term.notify.clone(), term.stop.clone());
        let (weak, id): (Weak<Self>, String) = (Arc::downgrade(self), id.to_string());
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = notify.notified() => {}
                    _ = stop.cancelled() => break,
                }
                tokio::time::sleep(SCREEN_INTERVAL).await;
                let Some(panes) = weak.upgrade() else { break };
                let (event, exit) = {
                    let g = grid.lock().unwrap();
                    (g.screen_event(&id), g.exit)
                };
                panes.emit(event);
                if let Some(code) = exit {
                    panes.close(&id, Some(code));
                    break;
                }
            }
        });
    }

    pub fn close(&self, id: &str, exit: Option<i32>) {
        let pane = self.state.lock().unwrap().panes.remove(id);
        let Some(mut pane) = pane else { return };
        if let Some(t) = pane.term.as_mut() {
            if exit.is_none() {
                t.kill();
            }
            t.stop.cancel();
        }
        self.emit(Event::PaneClosed {
            id: id.to_string(),
            exit,
        });
    }

    pub fn shutdown(&self) {
        let ids: Vec<String> = self.state.lock().unwrap().panes.keys().cloned().collect();
        for id in ids {
            self.close(&id, None);
        }
    }

    fn report(
        &self,
        id: &str,
        kind: ReportKind,
        level: ReportLevel,
        message: &str,
        url: Option<&str>,
        status: Option<u16>,
    ) {
        let mut text = match kind {
            ReportKind::Console => format!("console {}: {message}", level_name(level)),
            ReportKind::Network => format!(
                "request failed{}: {message}",
                status.map(|s| format!(" ({s})")).unwrap_or_default()
            ),
            ReportKind::Error => format!("error: {message}"),
            ReportKind::Navigated => format!("navigated to {}", url.unwrap_or(message)),
            ReportKind::Title => format!("title: {message}"),
        };
        if let (Some(u), ReportKind::Console | ReportKind::Network | ReportKind::Error) =
            (url, kind)
            && !text.contains(u)
        {
            text.push_str(&format!(" [{u}]"));
        }
        let text = truncate_middle(&text, 1_000);
        let mut s = self.state.lock().unwrap();
        let Some(pane) = s.panes.get_mut(id) else {
            return;
        };
        if pane.reports.len() >= REPORTS {
            pane.reports.pop_front();
        }
        pane.reports.push_back(text.clone());
        if kind == ReportKind::Navigated {
            pane.url = url.map(String::from).or_else(|| Some(message.to_string()));
        }
        if level != ReportLevel::Error || !self.in_turn.load(Ordering::Relaxed) {
            return;
        }
        let line = format!("[preview {id}] {text}");
        if !s.queued.contains(&line) {
            if s.queued.len() >= QUEUE {
                s.queued.remove(0);
            }
            s.queued.push(line);
        }
        drop(s);
        self.emit(Event::PaneNotice {
            id: id.to_string(),
            level,
            message: text,
        });
    }

    /// Error reports gathered during the turn, for the next model call.
    pub fn take_queued(&self) -> Vec<String> {
        std::mem::take(&mut self.state.lock().unwrap().queued)
    }

    /// Element context the user attached to `@mention` in a preview, if any.
    pub fn mention(&self, mention: &str) -> Option<String> {
        self.state.lock().unwrap().mentions.get(mention).cloned()
    }

    fn preview_ids(&self) -> Vec<String> {
        let s = self.state.lock().unwrap();
        s.panes
            .iter()
            .filter(|(_, p)| p.kind == PaneKind::Preview)
            .map(|(id, _)| id.clone())
            .collect()
    }

    fn terminal_ids(&self) -> Vec<String> {
        let s = self.state.lock().unwrap();
        s.panes
            .iter()
            .filter(|(_, p)| p.kind == PaneKind::Terminal)
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// Ask the client's preview pane to do something and wait for its answer.
    pub async fn request(
        &self,
        id: &str,
        action: PaneAction,
        args: Value,
        timeout: Duration,
    ) -> Result<Value> {
        if !self.state.lock().unwrap().panes.contains_key(id) {
            bail!("no pane {id}");
        }
        let call = crate::provider::new_id();
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(call.clone(), tx);
        self.emit(Event::PaneRequest {
            call: call.clone(),
            id: id.to_string(),
            action,
            args,
        });
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(Ok(v))) => Ok(v),
            Ok(Ok(Err(e))) => bail!("the preview pane reported: {e}"),
            Ok(Err(_)) => bail!("the client went away"),
            Err(_) => {
                self.pending.lock().unwrap().remove(&call);
                bail!(
                    "the preview pane didn't answer within {}s",
                    timeout.as_secs()
                )
            }
        }
    }

    /// With a turn's checkpoint: save a screenshot of the (first) preview pane under
    /// `dir/<session>/panes/turn-<n>.png`, off the turn's critical path.
    pub fn checkpoint(self: &Arc<Self>, session: &str, turn: u64, dir: &Path) {
        let Some(id) = self.preview_ids().into_iter().next() else {
            return;
        };
        let rel = format!("panes/turn-{turn}.png");
        let path = dir.join(session).join(&rel);
        let panes = self.clone();
        tokio::spawn(async move {
            let args = json!({ "for": "checkpoint", "turn": turn });
            let Ok(v) = panes
                .request(&id, PaneAction::Screenshot, args, Duration::from_secs(3))
                .await
            else {
                return;
            };
            let Some(png) = image_bytes(&v) else { return };
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if std::fs::write(&path, png).is_ok() {
                panes.emit(Event::PaneCheckpoint {
                    id,
                    turn,
                    path: rel,
                });
            }
        });
    }

    // ---- the tools ----

    pub async fn terminal(self: &Arc<Self>, input: &Value, read_only: bool) -> Result<Output> {
        let action = str_arg(input, "action")?;
        if read_only && action != "read" {
            bail!("subagents can only `read` terminal panes");
        }
        let id = input["id"].as_str().map(String::from);
        match action {
            "open" => {
                let cwd = input["cwd"].as_str().map(PathBuf::from);
                let id = self.open(PaneKind::Terminal, cwd, None, 100, 30)?;
                Ok(Output::text(format!(
                    "Opened terminal pane {id}. Pass id: \"{id}\" to run commands in it."
                )))
            }
            "read" => {
                let id = self.pick_terminal(id)?;
                let lines = int_arg(input, "lines").unwrap_or(60).min(2_000) as usize;
                let (screen, tail, exited) = {
                    let s = self.state.lock().unwrap();
                    let t = s.panes[&id].term.as_ref().context("not a terminal pane")?;
                    let g = t.grid.lock().unwrap();
                    (g.text(), g.tail(lines), g.exit)
                };
                let mut out = format!("[{id}] screen:\n{screen}");
                if !tail.is_empty() && tail.lines().count() > screen.lines().count() {
                    out = format!("[{id}] recent output:\n{tail}\n\n[{id}] screen:\n{screen}");
                }
                if let Some(code) = exited {
                    out.push_str(&format!("\n[shell exited with {code}]"));
                }
                Ok(Output::text(truncate_middle(&out, 30_000)))
            }
            "type" => {
                let text = str_arg(input, "text")?;
                let id = self.pick_terminal(id)?;
                {
                    let mut s = self.state.lock().unwrap();
                    let t = s
                        .panes
                        .get_mut(&id)
                        .and_then(|p| p.term.as_mut())
                        .context("not a terminal pane")?;
                    if t.user_typing {
                        bail!("the user is typing in {id}; read it instead of typing over them");
                    }
                    if text.contains(['\r', '\n']) {
                        t.sent_at = t.grid.lock().unwrap().prompts;
                    }
                    t.write(text.as_bytes())?;
                }
                tokio::time::sleep(Duration::from_millis(300)).await;
                let screen = self.screen_of(&id);
                Ok(Output::text(format!("Sent. [{id}] screen:\n{screen}")))
            }
            "run" => {
                let command = str_arg(input, "command")?
                    .trim_end_matches(['\r', '\n'])
                    .to_string();
                if command.trim().is_empty() {
                    bail!("`command` is empty");
                }
                let wait = Duration::from_millis(
                    int_arg(input, "wait_ms")
                        .unwrap_or(8_000)
                        .clamp(100, 60_000),
                );
                let id = match id {
                    Some(id) => id,
                    None => match self.terminal_ids().into_iter().next() {
                        Some(id) => id,
                        None => self.open(PaneKind::Terminal, None, None, 100, 30)?,
                    },
                };
                self.run(&id, &command, wait).await
            }
            other => bail!("unknown action `{other}`; use run, read, type or open"),
        }
    }

    fn pick_terminal(&self, id: Option<String>) -> Result<String> {
        let s = self.state.lock().unwrap();
        match id {
            Some(id) => match s.panes.get(&id) {
                Some(p) if p.kind == PaneKind::Terminal => Ok(id),
                Some(_) => bail!("{id} is not a terminal pane"),
                None => bail!("no pane {id}"),
            },
            None => s
                .panes
                .iter()
                .find(|(_, p)| p.kind == PaneKind::Terminal)
                .map(|(id, _)| id.clone())
                .context("no terminal pane is open; use action \"run\" or \"open\" to start one"),
        }
    }

    fn screen_of(&self, id: &str) -> String {
        let s = self.state.lock().unwrap();
        s.panes
            .get(id)
            .and_then(|p| p.term.as_ref())
            .map(|t| t.grid.lock().unwrap().text())
            .unwrap_or_default()
    }

    /// Wait for a fresh shell to show its first prompt (its rc files can take a moment), so a
    /// command isn't typed into the startup noise. Shells without markers get a settle wait.
    /// The marker comes before the prompt is drawn, so then wait for the drawing to stop too:
    /// typed before the line editor starts, a command is echoed twice.
    async fn wait_ready(&self, id: &str) {
        let grid = {
            let s = self.state.lock().unwrap();
            let Some(t) = s.panes.get(id).and_then(|p| p.term.as_ref()) else {
                return;
            };
            t.grid.clone()
        };
        let started = Instant::now();
        while started.elapsed() < Duration::from_secs(5) {
            {
                let g = grid.lock().unwrap();
                if g.exit.is_some() {
                    return;
                }
                if g.prompts > 0 && g.quiet_for() > Duration::from_millis(120) {
                    return;
                }
                if g.received > 0 && g.quiet_for() > Duration::from_millis(700) {
                    return;
                }
            }
            tokio::time::sleep(Duration::from_millis(40)).await;
        }
    }

    async fn run(&self, id: &str, command: &str, wait: Duration) -> Result<Output> {
        self.wait_ready(id).await;
        let (grid, mark) = {
            let mut s = self.state.lock().unwrap();
            let t = s
                .panes
                .get_mut(id)
                .and_then(|p| p.term.as_mut())
                .with_context(|| format!("no terminal pane {id}"))?;
            if t.user_typing {
                bail!(
                    "the user is typing in {id}; read it instead of running a command over them.\n[{id}] screen:\n{}",
                    t.grid.lock().unwrap().text()
                );
            }
            if !t.idle() {
                bail!(
                    "a command is still running in {id}. Read it, interact with `type` (\\u0003 for ctrl-c), or `open` another pane.\n[{id}] screen:\n{}",
                    t.grid.lock().unwrap().text()
                );
            }
            let grid = t.grid.clone();
            let g = grid.lock().unwrap();
            if g.exit.is_some() {
                bail!("the shell in {id} has exited; `open` a new pane");
            }
            let (mark, prompts) = (g.mark(), g.prompts);
            drop(g);
            t.sent_at = prompts;
            t.write(format!("{command}\n").as_bytes())?;
            (grid, (mark, prompts))
        };
        let (mark, sent_at) = mark;
        let started = Instant::now();
        // Done when the shell marks its next prompt; without markers, when output settles.
        let (finished, status) = loop {
            tokio::time::sleep(Duration::from_millis(40)).await;
            let g = grid.lock().unwrap();
            if g.exit.is_some() {
                break (true, None);
            }
            if g.prompts > sent_at {
                break (true, g.last_status);
            }
            let received = g.received;
            let quiet = g.quiet_for();
            drop(g);
            if sent_at == 0 && received > 0 && quiet > Duration::from_millis(700) {
                break (true, None);
            }
            if started.elapsed() >= wait {
                break (false, None);
            }
        };
        let (mut text, exited) = {
            let g = grid.lock().unwrap();
            let until = (g.prompts > sent_at).then_some(g.prompt_mark);
            (g.since(mark, until).to_string(), g.exit)
        };
        // Drop the echoed command line (everything before the first newline: the line editor
        // redraws it in ways that don't match `command`), and zsh's `%` + padding that marks a
        // missing final newline.
        text = text
            .split_once('\n')
            .map(|(_, rest)| rest.to_string())
            .unwrap_or_default();
        let trimmed = text.trim_end();
        let text = match trimmed.strip_suffix('%') {
            Some(t) if text.len() - trimmed.len() >= 10 => t,
            _ => trimmed,
        };
        let mut out = truncate_middle(text, 30_000);
        if out.trim().is_empty() {
            out = "(no output)".into();
        }
        if let Some(code) = exited {
            out.push_str(&format!("\n[shell exited with {code}]"));
        } else if !finished {
            out.push_str(&format!(
                "\n[still running after {}s in {id}; the pane stays open. Terminal.read to check on it, Terminal.type to interact, or open another pane for other commands.]",
                wait.as_secs()
            ));
        } else if let Some(code) = status.filter(|c| *c != 0) {
            out.push_str(&format!("\n[exit code {code}]"));
        }
        Ok(Output::text(out))
    }

    pub async fn preview(self: &Arc<Self>, input: &Value, read_only: bool) -> Result<Output> {
        let action = str_arg(input, "action")?;
        if read_only && !matches!(action, "read" | "console") {
            bail!("subagents can only `read` and `console` preview panes");
        }
        let root = self.state.lock().unwrap().root.clone();
        if action == "open" {
            let url = resolve_url(str_arg(input, "url")?, &root)?;
            let id = self.open(PaneKind::Preview, None, Some(url.clone()), 0, 0)?;
            // Wait for the page, so a dead dev server or a 404 is the answer rather than "open".
            let args = json!({ "url": url, "wait": true });
            return match self
                .request(&id, PaneAction::Navigate, args, REQUEST_TIMEOUT)
                .await
            {
                Ok(v) if v["loaded"] == false => Ok(Output::text(format!(
                    "Opened preview pane {id} at {url}; it's still loading."
                ))),
                Ok(v) => {
                    let title = v["title"].as_str().filter(|t| !t.is_empty());
                    Ok(Output::text(format!(
                        "Opened preview pane {id} at {url}{}.",
                        title.map(|t| format!(" (\"{t}\")")).unwrap_or_default()
                    )))
                }
                Err(e) => bail!(
                    "preview pane {id} couldn't load {url}: {e}. If it's a dev server, is it running (check Terminal)?"
                ),
            };
        }
        let id = match input["id"].as_str() {
            Some(id) => id.to_string(),
            None => self
                .preview_ids()
                .pop()
                .context("no preview pane is open; use action \"open\" with a url first")?,
        };
        if action == "console" {
            let s = self.state.lock().unwrap();
            let pane = s.panes.get(&id).with_context(|| format!("no pane {id}"))?;
            let text: Vec<&str> = pane.reports.iter().map(String::as_str).collect();
            let url = pane.url.clone().unwrap_or_default();
            return Ok(Output::text(if text.is_empty() {
                format!("[{id}] {url}: nothing reported yet")
            } else {
                truncate_middle(&format!("[{id}] {url}:\n{}", text.join("\n")), 30_000)
            }));
        }
        let action =
            PaneAction::parse(action).with_context(|| format!("unknown action `{action}`"))?;
        let mut args = serde_json::Map::new();
        for k in ["url", "selector", "text", "js"] {
            if let Some(v) = input[k].as_str() {
                let v = if k == "url" {
                    resolve_url(v, &root)?
                } else {
                    v.to_string()
                };
                args.insert(k.into(), Value::String(v));
            }
        }
        let v = self
            .request(&id, action, Value::Object(args), REQUEST_TIMEOUT)
            .await?;
        if action == PaneAction::Screenshot {
            let Some(data) = v["data"].as_str().or_else(|| v.as_str()) else {
                bail!("the preview pane returned no image");
            };
            let mime = v["mime"].as_str().unwrap_or("image/png").to_string();
            return Ok(Output {
                content: format!("[screenshot of {id}]"),
                images: vec![crate::protocol::Image {
                    mime,
                    data: data.to_string(),
                }],
                ..Default::default()
            });
        }
        Ok(Output::text(truncate_middle(&result_text(&v), 30_000)))
    }
}

/// What the model passed as a preview URL, made loadable: a port or `localhost:3000` gets
/// `http://`; a path (relative to the project, or `file://`) must exist, and a folder opens
/// its `index.html`. A missing file is an error that lists the pages there are, rather than
/// a blank pane the model would call open.
fn resolve_url(raw: &str, root: &Path) -> Result<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        bail!("`url` is empty");
    }
    if raw.chars().all(|c| c.is_ascii_digit()) {
        return Ok(format!("http://localhost:{raw}"));
    }
    let local = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"];
    if local.iter().any(|h| raw.starts_with(h)) {
        return Ok(format!("http://{raw}"));
    }
    let path = if let Some(p) = raw.strip_prefix("file://") {
        PathBuf::from(p)
    } else if raw.contains("://") || raw.starts_with("about:") || raw.starts_with("data:") {
        return Ok(raw.to_string());
    } else {
        let p = PathBuf::from(raw.strip_prefix("~/").map_or(raw.to_string(), |rest| {
            dirs::home_dir()
                .unwrap_or_default()
                .join(rest)
                .display()
                .to_string()
        }));
        if p.is_absolute() { p } else { root.join(p) }
    };
    let path = if path.is_dir() {
        path.join("index.html")
    } else {
        path
    };
    if !path.is_file() {
        let pages = html_files(root, 12);
        let hint = if pages.is_empty() {
            "There are no .html files in the project; if it has a dev server, start it in Terminal and open its URL.".to_string()
        } else {
            format!("Pages in the project:\n{}", pages.join("\n"))
        };
        bail!("no file at {}. {hint}", path.display());
    }
    Ok(format!("file://{}", path.display()))
}

/// Up to `max` .html files under `root`, relative, skipping ignored and build folders.
fn html_files(root: &Path, max: usize) -> Vec<String> {
    let mut out = Vec::new();
    let walk = ignore::WalkBuilder::new(root).max_depth(Some(5)).build();
    for e in walk.flatten() {
        let p = e.path();
        if p.extension().is_some_and(|x| x == "html")
            && !p.components().any(|c| {
                matches!(
                    c.as_os_str().to_str(),
                    Some("node_modules" | "target" | "build" | "dist")
                )
            })
        {
            out.push(p.strip_prefix(root).unwrap_or(p).display().to_string());
            if out.len() >= max {
                break;
            }
        }
    }
    out.sort();
    out
}

fn level_name(l: ReportLevel) -> &'static str {
    match l {
        ReportLevel::Info => "log",
        ReportLevel::Warn => "warning",
        ReportLevel::Error => "error",
    }
}

/// A reply's text: a string as-is, an object's `text`, else the JSON.
fn result_text(v: &Value) -> String {
    match v {
        Value::Null => "ok".into(),
        Value::String(s) => s.clone(),
        Value::Object(o) if o.get("text").is_some_and(Value::is_string) => {
            o["text"].as_str().unwrap_or_default().to_string()
        }
        other => serde_json::to_string_pretty(other).unwrap_or_default(),
    }
}

/// Decode a screenshot reply: `{ "data": "<base64>" }` (or a bare base64 string; a data URL
/// prefix is fine).
fn image_bytes(v: &Value) -> Option<Vec<u8>> {
    use base64::Engine;
    let data = v["data"].as_str().or_else(|| v.as_str())?;
    let data = data.rsplit_once(',').map(|(_, d)| d).unwrap_or(data);
    base64::engine::general_purpose::STANDARD
        .decode(data.trim())
        .ok()
}

#[cfg(test)]
mod tests {

    #[test]
    fn a_terminal_finds_a_shell_that_exists() {
        // A missing $SHELL (a container's) falls through to one that's there; /bin/sh always is.
        let s = login_shell(Some("/nonexistent/zsh".into()));
        assert!(std::path::Path::new(&s).exists(), "{s}");
        assert!(std::path::Path::new(&login_shell(None)).exists());
        assert_eq!(login_shell(Some("/bin/sh".into())), "/bin/sh");
    }

    use super::*;

    #[test]
    fn preview_urls_resolve_or_say_what_there_is() {
        let root = std::env::temp_dir().join(format!("frog-preview-{}", std::process::id()));
        std::fs::create_dir_all(root.join("site")).unwrap();
        std::fs::write(root.join("site/index.html"), "<h1>hi</h1>").unwrap();
        assert_eq!(resolve_url("3000", &root).unwrap(), "http://localhost:3000");
        assert_eq!(
            resolve_url("localhost:5173/x", &root).unwrap(),
            "http://localhost:5173/x"
        );
        assert_eq!(
            resolve_url("https://frog.toys", &root).unwrap(),
            "https://frog.toys"
        );
        let index = format!("file://{}", root.join("site/index.html").display());
        assert_eq!(resolve_url("site", &root).unwrap(), index);
        assert_eq!(
            resolve_url(&format!("file://{}", root.join("site").display()), &root).unwrap(),
            index
        );
        let err = resolve_url("docs/README.md", &root)
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("no file at") && err.contains("site/index.html"),
            "{err}"
        );
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn grid_tracks_screen_log_and_prompt_marks() {
        let mut g = Grid::new(20, 4);
        g.feed(b"$ ");
        g.feed(b"ec");
        g.feed(b"ho hi\r\n\x1b[32mhi\x1b[0m\r\n\x1b]133;D;0\x07$ ");
        assert_eq!(g.lines(), ["$ echo hi", "hi", "$ ", ""]);
        assert_eq!(g.text(), "$ echo hi\nhi\n$ ");
        assert_eq!(g.prompts, 1);
        assert_eq!(g.last_status, Some(0));
        // The log is plain text, and the prompt mark sits before the new prompt.
        assert_eq!(g.since(0, Some(g.prompt_mark)), "$ echo hi\nhi\n");
        assert_eq!(g.since(0, None), "$ echo hi\nhi\n$ ");
        let (r, c) = g.parser.screen().cursor_position();
        assert_eq!((r, c), (2, 2));
        assert!(matches!(
            g.screen_event("t1"),
            Event::PaneScreen {
                cursor: [2, 2],
                screen_seq: 3,
                ..
            }
        ));
    }

    #[test]
    fn grid_holds_a_split_escape_and_marker_across_chunks() {
        let mut g = Grid::new(20, 3);
        g.feed(b"a\x1b[3");
        g.feed(b"1mb\x1b[0m\x1b]133;D");
        g.feed(b";1\x07$ ");
        assert_eq!(g.since(0, None), "ab$ ");
        assert_eq!((g.prompts, g.last_status), (1, Some(1)));
        g.feed(b"\x1b]0;title\x07x");
        assert!(g.since(0, None).ends_with("$ x"), "OSC title is stripped");
    }

    #[test]
    fn grid_scrollback_tail_and_resize() {
        let mut g = Grid::new(10, 2);
        for i in 0..50 {
            g.feed(format!("line {i}\r\n").as_bytes());
        }
        assert_eq!(g.tail(2), "line 48\nline 49");
        assert_eq!(g.lines().len(), 2);
        g.resize(10, 5);
        assert_eq!(g.size(), (10, 5));
        assert_eq!(g.lines().len(), 5);
    }

    #[tokio::test]
    async fn request_and_reply_round_trip_with_timeout() {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let panes = Panes::new(move |e| {
            let _ = tx.send(e);
        });
        panes.set_client(true);
        let id = panes
            .open(PaneKind::Preview, None, Some("http://x".into()), 0, 0)
            .unwrap();
        assert_eq!(id, "p1");
        assert!(matches!(
            rx.recv().await,
            Some(Event::PaneOpened {
                kind: PaneKind::Preview,
                ..
            })
        ));

        let p = panes.clone();
        let asked = tokio::spawn(async move {
            p.request(&id, PaneAction::Read, json!({}), Duration::from_secs(5))
                .await
        });
        let Some(Event::PaneRequest { call, action, .. }) = rx.recv().await else {
            panic!("no request")
        };
        assert_eq!(action, PaneAction::Read);
        panes.handle(&Op::PaneReply {
            call,
            result: Some(json!({ "text": "hello" })),
            error: None,
        });
        assert_eq!(asked.await.unwrap().unwrap()["text"], "hello");

        let e = panes
            .request(
                "p1",
                PaneAction::Click,
                json!({}),
                Duration::from_millis(50),
            )
            .await
            .unwrap_err();
        assert!(e.to_string().contains("didn't answer"), "{e}");
        assert!(
            panes
                .request("p9", PaneAction::Read, json!({}), Duration::from_secs(1))
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn error_reports_surface_during_a_turn_and_are_kept_for_console() {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let panes = Panes::new(move |e| {
            let _ = tx.send(e);
        });
        panes.set_client(true);
        panes
            .open(PaneKind::Preview, None, Some("http://x".into()), 0, 0)
            .unwrap();
        let report = |level, msg: &str| Op::PaneReport {
            id: "p1".into(),
            kind: ReportKind::Console,
            level: Some(level),
            message: msg.into(),
            url: None,
            status: None,
        };
        // Outside a turn: kept, not surfaced.
        panes.handle(&report(ReportLevel::Error, "boom"));
        assert!(panes.take_queued().is_empty());
        panes.set_in_turn(true);
        panes.handle(&report(ReportLevel::Info, "fine"));
        panes.handle(&report(ReportLevel::Error, "bad"));
        panes.handle(&report(ReportLevel::Error, "bad"));
        assert_eq!(panes.take_queued(), ["[preview p1] console error: bad"]);
        let notices = std::iter::from_fn(|| rx.try_recv().ok())
            .filter(|e| matches!(e, Event::PaneNotice { .. }))
            .count();
        assert_eq!(notices, 2);
        let out = panes
            .preview(&json!({ "action": "console" }), true)
            .await
            .unwrap();
        assert!(
            out.content.contains("console error: boom")
                && out.content.contains("console log: fine")
        );
        // Subagents can't act.
        assert!(
            panes
                .preview(&json!({ "action": "click", "selector": "a" }), true)
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn terminal_run_waits_for_the_prompt_and_keeps_state() {
        if std::env::var("SHELL").is_ok_and(|s| !s.ends_with("zsh") && !s.ends_with("bash")) {
            return;
        }
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let panes = Panes::new(move |e| {
            let _ = tx.send(e);
        });
        panes.configure(std::env::temp_dir().canonicalize().unwrap());
        let out = panes
            .terminal(
                &json!({ "action": "run", "command": "echo hi-$((20+3))", "wait_ms": 15000 }),
                false,
            )
            .await
            .unwrap();
        assert_eq!(out.content.trim(), "hi-23", "{}", out.content);
        // The shell persisted: cd sticks.
        panes
            .terminal(
                &json!({ "action": "run", "command": "cd / && export FROG_T=1" }),
                false,
            )
            .await
            .unwrap();
        let out = panes
            .terminal(
                &json!({ "action": "run", "command": "pwd; echo $FROG_T; false" }),
                false,
            )
            .await
            .unwrap();
        assert!(out.content.starts_with("/\n1"), "{}", out.content);
        assert!(out.content.contains("[exit code 1]"), "{}", out.content);
        // A running command is reported as such and blocks the next run until it's done.
        let out = panes
            .terminal(
                &json!({ "action": "run", "command": "sleep 2; echo done", "wait_ms": 300 }),
                false,
            )
            .await
            .unwrap();
        assert!(out.content.contains("still running"), "{}", out.content);
        let e = match panes
            .terminal(&json!({ "action": "run", "command": "echo x" }), false)
            .await
        {
            Err(e) => e.to_string(),
            Ok(o) => panic!("ran over a running command: {}", o.content),
        };
        assert!(e.contains("still running"), "{e}");
        tokio::time::sleep(Duration::from_millis(2_500)).await;
        let out = panes
            .terminal(&json!({ "action": "read" }), true)
            .await
            .unwrap();
        assert!(out.content.contains("done"), "{}", out.content);
        // The user mid-command keeps the model from typing over them.
        panes.handle(&Op::PaneInput {
            id: "t1".into(),
            data: "ls".into(),
        });
        assert!(
            panes
                .terminal(&json!({ "action": "run", "command": "echo x" }), false)
                .await
                .is_err()
        );
        panes.handle(&Op::PaneInput {
            id: "t1".into(),
            data: "\x15".into(),
        });
        panes
            .terminal(&json!({ "action": "run", "command": "echo x" }), false)
            .await
            .unwrap();
        let mut seen_screen = false;
        while let Ok(e) = rx.try_recv() {
            seen_screen |= matches!(e, Event::PaneScreen { ref lines, .. } if lines.iter().any(|l| l.contains("hi-23")));
        }
        assert!(seen_screen, "no PaneScreen with the output");
        panes.shutdown();
        assert!(
            std::iter::from_fn(|| rx.try_recv().ok())
                .any(|e| matches!(e, Event::PaneClosed { .. }))
        );
    }
}
