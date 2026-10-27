//! node-face: Pip's face on the frog node's screen, driven by `frog --serve`.
//!
//! ```text
//! node-face                           # the mini head's 720×720 panel, talking to frog in this directory
//! node-face --panel full              # the full head's 600×1024 portrait panel
//! node-face --fullscreen              # borderless, for the panel itself
//! node-face -- -m ollama/qwen3:8b     # arguments after -- go to frog
//! node-face --demo                    # a scripted turn, no model needed
//! node-face --sheet out.png           # headless: the face through a whole turn, one PNG
//! ```
//!
//! Until the head has its microphone and camera wired in, the keyboard and pointer stand in:
//!   type          talk (Enter sends)        W     say "hey frog"
//!   space         approve a command         Esc   decline / stop
//!   pointer       where you are: Pip looks at it while listening

#![cfg_attr(not(feature = "window"), allow(dead_code, unused_imports))]

use anyhow::{Context, Result};
use clap::{Parser, ValueEnum};
use node_face::Panel;
use node_face::draw::{self, Style};
use node_face::face::Face;
use puck::canvas::Canvas;
use puck::demo::{self, Player, Sim};
use puck::model::{Mode, Puck};
use puck::text::Fonts;
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, channel};

#[derive(Clone, Copy, ValueEnum)]
enum PanelArg {
    Mini,
    Full,
}

#[derive(Parser)]
#[command(about = "Pip's face on the frog node's screen")]
struct Args {
    /// Which head's panel to draw for.
    #[arg(long, value_enum, default_value = "mini")]
    panel: PanelArg,
    /// Borderless window, for the head's own panel.
    #[arg(long)]
    fullscreen: bool,
    /// Play a scripted turn instead of talking to frog.
    #[arg(long)]
    demo: bool,
    /// Render the demo turn as a contact sheet to this PNG and exit.
    #[arg(long, value_name = "PNG")]
    sheet: Option<PathBuf>,
    /// The frog binary to run with --serve.
    #[arg(long, default_value = "frog")]
    frog: String,
    /// Arguments passed through to frog.
    #[arg(last = true)]
    frog_args: Vec<String>,
}

impl Args {
    fn panel(&self) -> Panel {
        match self.panel {
            PanelArg::Mini => Panel::Mini,
            PanelArg::Full => Panel::Full,
        }
    }
}

/// One line for the portrait panel's lower third.
fn status(p: &Puck) -> String {
    // The reply's last sentence, with its own punctuation.
    let last = |s: &str| {
        let s = s.trim();
        let body = s.trim_end_matches(['.', '!', '?']);
        let start = body.rfind(['.', '!', '?']).map_or(0, |i| i + 1);
        s[start..].trim().to_string()
    };
    match p.mode {
        Mode::Boot => String::new(),
        Mode::Idle => p
            .cwd
            .rsplit('/')
            .find(|s| !s.is_empty())
            .unwrap_or("")
            .to_string(),
        Mode::Listening if p.draft.is_empty() => "listening…".into(),
        Mode::Listening => p.draft.clone(),
        Mode::Thinking if !p.reply.is_empty() => last(&p.reply),
        Mode::Thinking => "thinking…".into(),
        Mode::Running => p.command.clone(),
        Mode::Ask => p
            .ask
            .as_ref()
            .map(|a| format!("ok to run {}?", a.arg))
            .unwrap_or_default(),
        Mode::Done => last(&p.reply),
        Mode::Error => p.error.clone(),
    }
}

fn new_sim() -> Sim {
    let cwd = std::env::current_dir()
        .map(|d| d.display().to_string())
        .unwrap_or_default();
    Sim::new(&cwd, "this node")
}

/// The face through the demo turn, every 1.5 s, six across.
fn sheet(path: &Path, panel: Panel) -> Result<()> {
    let (w, h) = panel.size();
    let (scale, cols, times) = (
        3usize,
        6usize,
        (0..24).map(|i| 0.5 + i as f64 * 1.5).collect::<Vec<_>>(),
    );
    let (tw, th) = (w / scale, h / scale);
    let rows = times.len().div_ceil(cols);
    let mut out = Canvas::new(tw * cols, th * rows);
    let fonts = Fonts::new();
    let (mut sim, mut face, mut player) = (new_sim(), Face::new(), Player::new(demo::script()));
    let mut cv = Canvas::new(w, h);
    let dt = 1.0 / 60.0;
    for (i, &at) in times.iter().enumerate() {
        while sim.t < at {
            player.run(&mut sim);
            sim.step(dt);
            face.step(&sim.puck, sim.t, dt, None);
        }
        draw::draw(
            &mut cv,
            &face,
            &Style::default(),
            sim.t,
            &status(&sim.puck),
            &fonts,
        );
        let (ox, oy) = ((i % cols) * tw, (i / cols) * th);
        for y in 0..th {
            for x in 0..tw {
                // box-filter the frame down
                let mut s = [0.0f32; 3];
                for dy in 0..scale {
                    for dx in 0..scale {
                        let p = cv.px[(y * scale + dy) * w + x * scale + dx];
                        for c in 0..3 {
                            s[c] += p[c] / (scale * scale) as f32;
                        }
                    }
                }
                out.px[(oy + y) * out.w + ox + x] = s;
            }
        }
    }
    out.save_png(path)
}

// ---- frog ----

/// `frog --serve` as a child process, one JSON line each way.
struct Frog {
    child: Child,
    stdin: ChildStdin,
    events: Receiver<Value>,
}

impl Frog {
    fn spawn(bin: &str, args: &[String]) -> Result<Self> {
        let mut child = Command::new(bin)
            .arg("--serve")
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .with_context(|| {
                format!("couldn't start `{bin} --serve`; pass --frog with its path, or try --demo")
            })?;
        let stdin = child.stdin.take().context("frog stdin")?;
        let stdout = child.stdout.take().context("frog stdout")?;
        let (tx, events) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Ok(v) = serde_json::from_str::<Value>(&line)
                    && tx.send(v).is_err()
                {
                    break;
                }
            }
        });
        Ok(Self {
            child,
            stdin,
            events,
        })
    }

    fn send(&mut self, op: &Value) -> Result<()> {
        writeln!(self.stdin, "{op}")?;
        Ok(self.stdin.flush()?)
    }

    fn alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }
}

impl Drop for Frog {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

// ---- the window ----

#[cfg(feature = "window")]
fn run(args: &Args) -> Result<()> {
    use minifb::{Key, KeyRepeat, MouseMode, Window, WindowOptions};
    use std::cell::RefCell;
    use std::rc::Rc;
    use std::time::Instant;

    struct Typed(Rc<RefCell<Vec<char>>>);
    impl minifb::InputCallback for Typed {
        fn add_char(&mut self, c: u32) {
            if let Some(c) = char::from_u32(c) {
                self.0.borrow_mut().push(c);
            }
        }
    }

    let panel = args.panel();
    let (w, h) = panel.size();
    let mut frog = if args.demo {
        None
    } else {
        Some(Frog::spawn(&args.frog, &args.frog_args)?)
    };
    let mut player = Player::new(if args.demo {
        demo::script()
    } else {
        Vec::new()
    });
    let (mut sim, mut face, style, fonts) =
        (new_sim(), Face::new(), Style::default(), Fonts::new());
    let (mut cv, mut buf) = (Canvas::new(w, h), Vec::new());

    let opts = WindowOptions {
        borderless: args.fullscreen,
        title: !args.fullscreen,
        ..WindowOptions::default()
    };
    let mut win = Window::new("frog node", w, h, opts)?;
    win.set_target_fps(60);
    let typed = Rc::new(RefCell::new(Vec::new()));
    win.set_input_callback(Box::new(Typed(typed.clone())));
    let mut last = Instant::now();

    while win.is_open() {
        let dt = last.elapsed().as_secs_f64().min(0.1);
        last = Instant::now();
        let now = sim.t;
        let mut ops: Vec<Value> = Vec::new();

        if let Some(f) = frog.as_mut() {
            while let Ok(ev) = f.events.try_recv() {
                sim.puck.event(&ev, now);
            }
            if !f.alive() && sim.puck.mode != Mode::Error {
                sim.puck.disconnected("frog stopped", now);
                frog = None;
            }
        }
        player.run(&mut sim);

        let listening = sim.puck.mode == Mode::Listening;
        for c in typed.borrow_mut().drain(..) {
            if c.is_control() || (c == ' ' && !listening) {
                continue;
            }
            if listening || c.is_alphanumeric() {
                sim.puck.hear(&c.to_string(), now);
            }
        }
        for k in win.get_keys_pressed(KeyRepeat::Yes) {
            match k {
                Key::Backspace => sim.puck.unhear(),
                Key::Enter | Key::NumPadEnter => ops.extend(sim.puck.tap(now)),
                Key::Space if !listening => ops.extend(sim.puck.approve()),
                Key::Escape if sim.puck.mode == Mode::Ask => ops.extend(sim.puck.deny()),
                Key::Escape => ops.extend(sim.puck.interrupt()),
                Key::W if !listening => sim.puck.wake(now),
                _ => {}
            }
        }
        for op in ops {
            if let Some(f) = frog.as_mut()
                && f.send(&op).is_err()
            {
                sim.puck.disconnected("frog stopped", now);
            }
        }

        // Where the person is: the pointer, until the stereo camera can say.
        let look = win
            .get_mouse_pos(MouseMode::Pass)
            .map(|(x, y)| (((x / w as f32) - 0.5) * 2.4, ((y / w as f32) - 0.45) * 2.4))
            .map(|(x, y)| (x.clamp(-1.0, 1.0), y.clamp(-1.0, 1.0)));
        sim.step(dt);
        face.step(&sim.puck, sim.t, dt, look);
        draw::draw(&mut cv, &face, &style, sim.t, &status(&sim.puck), &fonts);
        cv.to_u32(&mut buf);
        win.update_with_buffer(&buf, w, h)?;
    }
    Ok(())
}

#[cfg(not(feature = "window"))]
fn run(_: &Args) -> Result<()> {
    anyhow::bail!(
        "this build has no window; rebuild with `cargo run -p node-face --features window`, or use --sheet"
    )
}

fn main() -> Result<()> {
    let args = Args::parse();
    if let Some(p) = &args.sheet {
        return sheet(p, args.panel());
    }
    run(&args)
}
