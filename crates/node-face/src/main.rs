//! node-face: The face on the frog node's screen, driven by `frog --serve`.
//!
//! ```text
//! node-face                           # the mini head's 720×720 panel, talking to frog in this directory
//! node-face --panel full              # the full head's 600×1024 portrait panel
//! node-face --fullscreen              # borderless, for the panel itself
//! node-face -- -m ollama/qwen3:8b     # arguments after -- go to frog
//! node-face --demo                    # a scripted turn, no model needed
//! node-face --voice                   # voice only: hear listens, ribt speaks (--features voice)
//! node-face --sheet out.png           # headless: the face through a whole turn, one PNG
//! ```
//!
//! With --voice it's voice only: say "hey frog" and it listens; pause and it answers
//! out loud, and you can answer back without the wake word for a few seconds. When it asks
//! to run something, say yes or no; while it works, "stop" stops it. Until the stereo camera can
//! say where you are, the face looks at the pointer while listening.

#![cfg_attr(not(feature = "window"), allow(dead_code, unused_imports))]

use anyhow::{Context, Result};
use clap::{Parser, ValueEnum};
use node_face::Panel;
use node_face::draw::{self, Style};
use node_face::face::Face;
use puck::canvas::Canvas;
use puck::demo::{self, Player, Sim};
use puck::model::{Mode, Puck};
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
#[command(about = "The face on the frog node's screen")]
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
    /// Speak with ribt (needs the `voice` feature; see RIBT_* in src/voice.rs for model paths).
    #[arg(long)]
    voice: bool,
    /// The hear binary (default: $HEAR_BIN, else hear on PATH).
    #[arg(long, value_name = "PATH")]
    hear: Option<String>,
    /// The ribt-tts binary (default: $RIBT_TTS, else ribt-tts on PATH).
    #[arg(long, value_name = "PATH")]
    ribt: Option<String>,
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
    let (mut sim, mut face, mut player) = (new_sim(), Face::new(), Player::new(demo::script()));
    let mut cv = Canvas::new(w, h);
    let dt = 1.0 / 60.0;
    for (i, &at) in times.iter().enumerate() {
        while sim.t < at {
            player.run(&mut sim);
            sim.step(dt);
            face.step(&sim.puck, sim.t, dt, None);
        }
        draw::draw(&mut cv, &face, &Style::default(), sim.t);
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
    use minifb::{MouseMode, Window, WindowOptions};
    use node_face::ears::Ears;
    use std::time::Instant;

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
    let (mut sim, mut face, style) = (new_sim(), Face::new(), Style::default());
    let (mut cv, mut buf) = (Canvas::new(w, h), Vec::new());

    let opts = WindowOptions {
        borderless: args.fullscreen,
        title: !args.fullscreen,
        ..WindowOptions::default()
    };
    let mut voice = voice(args)?;
    let ears = if args.voice && !args.demo {
        Some(Ears::spawn(args.hear.as_deref())?)
    } else {
        None
    };
    // Your loudness at the mic, for the listening dots (hear has the mic for the words).
    let mic = mic(args);
    let mut win = Window::new("frog node", w, h, opts)?;
    win.set_target_fps(60);
    let mut last = Instant::now();
    // When the face last made a sound: its own voice mustn't be heard as yours.
    let mut spoke = f64::NEG_INFINITY;

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

        if face.voice.is_some() {
            spoke = now;
        }
        if let Some(e) = &ears {
            ops.extend(listen(e, &mut sim.puck, now, spoke));
        }
        face.mic = mic.as_ref().map_or(0.0, |m| m.level());
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
        if let Some(v) = voice.as_mut() {
            if v.feed(&sim.puck).is_err() {
                voice = None; // ribt stopped: carry on silent
            } else {
                face.voice = v.level();
                face.wave = v.wave(96);
            }
        }
        face.voiced = voice.is_some();
        face.step(&sim.puck, sim.t, dt, look);
        draw::draw(&mut cv, &face, &style, sim.t);
        cv.to_u32(&mut buf);
        win.update_with_buffer(&buf, w, h)?;
    }
    Ok(())
}

/// After the face stops making sound, how long its ears stay shut (the room's echo of its voice).
const MUTE_SECS: f64 = 0.6;
/// A pause this long after some words ends your turn. hear only finishes a word when the next one
/// starts, so this has to cover the pause and the last word's tail.
const PAUSE_SECS: f64 = 1.8;
/// After the face finishes speaking you can answer without the wake word for this long.
const FOLLOW_SECS: f64 = 6.0;
/// Words that wake the face ("hey frog").
const WAKE: &[&str] = &["frog"];

/// What you said, into frog. While the face is idle only the wake word starts a turn (or anything, just
/// after it spoke); then words go into the turn and a pause sends it. Yes / no answers a request to
/// run something, "stop" stops it working. `spoke` is when the face last made a sound. Returns ops.
#[cfg(feature = "window")]
fn listen(e: &node_face::ears::Ears, p: &mut Puck, now: f64, spoke: f64) -> Vec<Value> {
    use node_face::ears::Heard;
    let mut ops = Vec::new();
    let heard = e.poll();
    if now - spoke < MUTE_SECS {
        e.take_partial(); // its own voice
        return ops;
    }
    let bare = |w: &str| {
        w.trim_matches(|c: char| !c.is_alphanumeric())
            .to_lowercase()
    };
    let is = |w: &str, set: &[&str]| set.contains(&bare(w).as_str());
    for h in heard {
        let Heard::Word(w) = h else {
            if p.mode == Mode::Listening {
                ops.extend(p.submit(now));
            }
            continue;
        };
        match p.mode {
            Mode::Ask
                if is(
                    &w,
                    &["yes", "yeah", "yep", "sure", "okay", "ok", "go", "do"],
                ) =>
            {
                ops.extend(p.approve())
            }
            Mode::Ask if is(&w, &["no", "nope", "don't", "stop", "cancel"]) => ops.extend(p.deny()),
            Mode::Thinking | Mode::Running if is(&w, &["stop", "wait", "cancel"]) => {
                ops.extend(p.interrupt())
            }
            Mode::Thinking | Mode::Running | Mode::Ask => {}
            Mode::Listening => p.hear(&format!("{w} "), now),
            // idle: the wake word, or a follow-up right after the face spoke
            _ if is(&w, WAKE) => p.wake(now),
            _ if now - spoke < FOLLOW_SECS => p.hear(&format!("{w} "), now),
            _ => {}
        }
    }
    let (partial, quiet) = e.partial();
    if p.mode == Mode::Listening && quiet > PAUSE_SECS {
        if !partial.is_empty() {
            p.hear(&e.take_partial(), now);
        }
        if !p.draft.trim().is_empty() {
            ops.extend(p.submit(now));
        }
    }
    ops
}

#[cfg(feature = "voice")]
fn mic(args: &Args) -> Option<node_face::voice::Mic> {
    (args.voice && !args.demo)
        .then(node_face::voice::Mic::open)
        .and_then(Result::ok)
}

#[cfg(all(feature = "window", not(feature = "voice")))]
fn mic(_: &Args) -> Option<NoMic> {
    None
}

#[cfg(all(feature = "window", not(feature = "voice")))]
struct NoMic;
#[cfg(all(feature = "window", not(feature = "voice")))]
impl NoMic {
    fn level(&self) -> f32 {
        0.0
    }
}

#[cfg(feature = "voice")]
fn voice(args: &Args) -> Result<Option<node_face::voice::Voice>> {
    use node_face::voice::{Paths, Voice};
    Ok(if args.voice {
        Some(Voice::spawn(&Paths::from_env(args.ribt.as_deref()))?)
    } else {
        None
    })
}

#[cfg(all(feature = "window", not(feature = "voice")))]
fn voice(args: &Args) -> Result<Option<Silent>> {
    if args.voice {
        anyhow::bail!("this build has no voice; rebuild with `--features voice`");
    }
    Ok(None)
}

/// Stands in for the voice in builds without it.
#[cfg(all(feature = "window", not(feature = "voice")))]
struct Silent;
#[cfg(all(feature = "window", not(feature = "voice")))]
impl Silent {
    fn feed(&mut self, _: &Puck) -> Result<()> {
        Ok(())
    }
    fn wave(&self, _: usize) -> Vec<f32> {
        Vec::new()
    }
    fn level(&self) -> Option<f32> {
        None
    }
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
