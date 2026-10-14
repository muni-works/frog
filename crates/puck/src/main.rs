//! puck-sim: the frog puck on your desktop.
//!
//! ```text
//! puck-sim                          # window, talking to `frog --serve` in this directory
//! puck-sim -- -m ollama/qwen3:8b    # arguments after -- go to frog
//! puck-sim --demo                   # window, scripted turn, no model needed
//! puck-sim --shot out.png --at 14   # headless: one frame of the demo
//! puck-sim --gallery out.png        # headless: every screen in a grid
//! ```
//!
//! In the window, typing stands in for speech:
//!   type          talk (Enter or a click on the glass sends it)
//!   click glass   tap: start or send
//!   hold glass    stop what frog is doing
//!   space         the crown button: approve
//!   drag the knob slide to run;   click ✕ to decline;   Esc declines too
//!   ↑             what ran this turn
//!   W             say "hey frog"
//!   right-drag    tilt the puck; the pupils roll downhill. Flick it to shake them.

// Without a window, the frog pipe and the speaker have no caller.
#![cfg_attr(not(feature = "window"), allow(dead_code, unused_imports))]

use anyhow::{Context, Result};
use clap::Parser;
use puck::canvas::{Canvas, hex, lerp};
use puck::demo::{self, Player, Sim};
use puck::model::Mode;
use puck::sound::Cue;
use puck::touch::Touch;
use puck::ui::{Shape, Ui};
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, channel};

/// The window is the glass plus a bezel around it.
const WIN: usize = 540;
const INSET: f32 = (WIN as f32 - puck::SCREEN) / 2.0;

#[derive(Parser)]
#[command(about = "The frog puck on your desktop")]
struct Args {
    /// Play a scripted turn instead of talking to frog.
    #[arg(long)]
    demo: bool,
    /// Render one frame of the demo to this PNG and exit.
    #[arg(long, value_name = "PNG")]
    shot: Option<PathBuf>,
    /// With --shot: render the Apple Watch layout (45 mm) instead of the puck.
    #[arg(long)]
    watch: bool,
    /// Seconds into the demo for --shot.
    #[arg(long, default_value_t = 14.0)]
    at: f64,
    /// Render every screen of the demo into one PNG and exit.
    #[arg(long, value_name = "PNG")]
    gallery: Option<PathBuf>,
    /// The frog binary to run with --serve.
    #[arg(long, default_value = "frog")]
    frog: String,
    /// Arguments passed through to frog.
    #[arg(last = true)]
    frog_args: Vec<String>,
}

/// A sim named for this machine: the working directory and host name show on the glass.
fn new_sim() -> Sim {
    let cwd = std::env::current_dir()
        .ok()
        .map(|d| tilde(&d))
        .unwrap_or_else(|| "~".into());
    let host = std::env::var("HOSTNAME")
        .ok()
        .or_else(hostname)
        .unwrap_or_else(|| "this computer".into());
    Sim::new(&cwd, &host)
}

/// Step the sim and keep the idle clock on wall time.
fn step(sim: &mut Sim, dt: f64) {
    sim.step(dt);
    sim.ui.clock = chrono::Local::now().format("%-I:%M").to_string();
}

/// The glass inside the bezel.
fn draw(sim: &Sim, cv: &mut Canvas) {
    let mut glass = Canvas::new(puck::SCREEN as usize, puck::SCREEN as usize);
    sim.ui.draw(&mut glass, &sim.puck, &sim.eyes, sim.t);
    bezel(cv);
    // Only the circle shows through the case.
    let n = glass.w;
    for y in 0..n {
        for x in 0..n {
            let d = (x as f32 + 0.5 - puck::C).hypot(y as f32 + 0.5 - puck::C);
            let a = (puck::C - d + 0.5).clamp(0.0, 1.0);
            cv.blend(
                x as i32 + INSET as i32,
                y as i32 + INSET as i32,
                glass.px[y * n + x],
                a,
            );
        }
    }
}

fn tilde(p: &std::path::Path) -> String {
    match std::env::var_os("HOME").map(PathBuf::from) {
        Some(h) if p.starts_with(&h) => format!("~/{}", p.strip_prefix(&h).unwrap().display())
            .trim_end_matches('/')
            .to_string(),
        _ => p.display().to_string(),
    }
}

fn hostname() -> Option<String> {
    std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Brushed-aluminum ring around the glass, lit from the top left.
fn bezel(cv: &mut Canvas) {
    let c = WIN as f32 / 2.0;
    let (bg, lit, shade) = (hex(0x0c0d0e), hex(0xdfe3e6), hex(0x4d5257));
    for y in 0..WIN as i32 {
        for x in 0..WIN as i32 {
            let (dx, dy) = (x as f32 + 0.5 - c, y as f32 + 0.5 - c);
            let d = dx.hypot(dy);
            let light = (0.5 - 0.5 * ((dx + dy) / d.max(1.0)) * std::f32::consts::FRAC_1_SQRT_2)
                .clamp(0.0, 1.0);
            let metal = lerp(shade, lit, light);
            let ring = (262.0 - d + 0.5).clamp(0.0, 1.0);
            cv.blend(x, y, bg, 1.0);
            cv.blend(x, y, metal, ring);
        }
    }
}

fn demo_until(at: f64) -> Sim {
    let mut sim = new_sim();
    let mut player = Player::new(demo::script());
    while sim.t < at {
        player.run(&mut sim);
        step(&mut sim, 1.0 / 120.0);
    }
    sim
}

// ---- the demo ----

fn shot(path: &std::path::Path, at: f64, watch: bool) -> Result<()> {
    let mut sim = demo_until(at);
    if watch {
        // Just the screen, laid out for the watch; it shows its own clock.
        let shape = Shape::WATCH;
        sim.ui = Ui::with_shape(shape);
        let mut cv = Canvas::new(shape.w, shape.h);
        sim.ui.draw(&mut cv, &sim.puck, &sim.eyes, sim.t);
        return cv.save_png(path);
    }
    let mut cv = Canvas::new(WIN, WIN);
    draw(&sim, &mut cv);
    cv.save_png(path)
}

/// Every screen of the demo, three across.
fn gallery(path: &std::path::Path) -> Result<()> {
    let at = [0.8, 4.6, 7.6, 9.6, 12.4, 15.0, 21.0, 26.0, 34.0];
    let cols = 3;
    let rows = at.len().div_ceil(cols);
    let mut sheet = Canvas::new(WIN * cols, WIN * rows);
    for (i, &t) in at.iter().enumerate() {
        let sim = demo_until(t);
        let mut cv = Canvas::new(WIN, WIN);
        draw(&sim, &mut cv);
        let (ox, oy) = ((i % cols) * WIN, (i / cols) * WIN);
        for y in 0..WIN {
            sheet.px[(oy + y) * sheet.w + ox..(oy + y) * sheet.w + ox + WIN]
                .copy_from_slice(&cv.px[y * WIN..(y + 1) * WIN]);
        }
    }
    sheet.save_png(path)
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

// ---- sound ----

#[cfg(feature = "audio")]
struct Speaker {
    _stream: rodio::OutputStream,
    handle: rodio::OutputStreamHandle,
}

#[cfg(feature = "audio")]
impl Speaker {
    fn new() -> Option<Self> {
        let (_stream, handle) = rodio::OutputStream::try_default().ok()?;
        Some(Self { _stream, handle })
    }
    fn play(&self, c: Cue) {
        use rodio::Source;
        if let Ok(d) = rodio::Decoder::new(std::io::Cursor::new(c.wav())) {
            let _ = self.handle.play_raw(d.convert_samples());
        }
    }
}

#[cfg(not(feature = "audio"))]
struct Speaker;

#[cfg(not(feature = "audio"))]
impl Speaker {
    fn new() -> Option<Self> {
        Some(Self)
    }
    fn play(&self, _c: Cue) {}
}

// ---- the window ----

#[cfg(feature = "window")]
fn run(args: &Args) -> Result<()> {
    use minifb::{Key, KeyRepeat, MouseButton, MouseMode, Window, WindowOptions};
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
    let speaker = Speaker::new();
    let mut sim = new_sim();
    let mut cv = Canvas::new(WIN, WIN);
    let mut buf = Vec::new();

    let mut win = Window::new("frog puck", WIN, WIN, WindowOptions::default())?;
    win.set_target_fps(60);
    let typed = Rc::new(RefCell::new(Vec::new()));
    win.set_input_callback(Box::new(Typed(typed.clone())));

    let mut last = Instant::now();
    let glass = |x: f32, y: f32| (x - INSET, y - INSET);
    let mut touch = Touch::default();
    let mut tilt_v = [0.0f64; 3];

    while win.is_open() {
        let dt = last.elapsed().as_secs_f64().min(0.1);
        last = Instant::now();
        let now = sim.t;
        let mut ops: Vec<Value> = Vec::new();

        // engine
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

        // keyboard
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
                Key::Space if sim.puck.mode != Mode::Listening => ops.extend(sim.puck.approve()),
                Key::Escape => {
                    if sim.puck.sheet {
                        sim.puck.toggle_sheet();
                    } else if sim.puck.mode == Mode::Ask {
                        ops.extend(sim.puck.deny());
                    } else {
                        ops.extend(sim.puck.interrupt());
                    }
                }
                Key::Up => sim.puck.toggle_sheet(),
                Key::W if sim.puck.mode != Mode::Listening => sim.puck.wake(now),
                _ => {}
            }
        }

        // mouse: tap, hold, slide, decline
        let m = win.get_mouse_pos(MouseMode::Pass).map(|(x, y)| glass(x, y));
        let finger = m.filter(|_| win.get_mouse_down(MouseButton::Left));
        ops.extend(touch.update(&mut sim.puck, finger, now));

        // tilt: right-drag leans the puck toward the pointer; let go and it settles flat
        let want = match (win.get_mouse_down(MouseButton::Right), m) {
            (true, Some((x, y))) => {
                let (u, v) = (
                    ((x - puck::C) / puck::C) as f64,
                    ((y - puck::C) / puck::C) as f64,
                );
                let (u, v) = (u.clamp(-1.2, 1.2), v.clamp(-1.2, 1.2));
                [u, -v, -1.0]
            }
            _ => [0.0, 0.0, -1.0],
        };
        let prev = sim.down;
        for (d, w) in sim.down.iter_mut().zip(want) {
            *d += (w - *d) * (dt * 12.0).min(1.0);
        }
        // A hand that jerks the puck pushes the pupils the other way.
        for i in 0..3 {
            let v = (sim.down[i] - prev[i]) / dt.max(1e-3);
            sim.shake[i] = ((v - tilt_v[i]) / dt.max(1e-3) * 0.02).clamp(-3.0, 3.0);
            tilt_v[i] = v;
        }

        for op in ops {
            if let Some(f) = frog.as_mut()
                && f.send(&op).is_err()
            {
                sim.puck.disconnected("frog stopped", now);
            }
        }
        step(&mut sim, dt);
        if let Some(s) = &speaker {
            for c in sim.puck.take_cues() {
                s.play(c);
            }
        }
        draw(&sim, &mut cv);
        cv.to_u32(&mut buf);
        win.update_with_buffer(&buf, WIN, WIN)?;
    }
    Ok(())
}

#[cfg(not(feature = "window"))]
fn run(_: &Args) -> Result<()> {
    anyhow::bail!(
        "this build has no window; rebuild with `cargo run -p puck --features window`, or use --shot / --gallery"
    )
}

fn main() -> Result<()> {
    let args = Args::parse();
    if let Some(p) = &args.gallery {
        return gallery(p);
    }
    if let Some(p) = &args.shot {
        return shot(p, args.at, args.watch);
    }
    run(&args)
}
