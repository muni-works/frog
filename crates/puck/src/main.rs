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
use puck::eyes::Eyes;
use puck::model::{Mode, Puck};
use puck::sound::Cue;
use puck::ui::{self, Ui};
use serde_json::{Value, json};
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

/// The puck and everything that moves it.
struct Sim {
    puck: Puck,
    eyes: Eyes,
    ui: Ui,
    t: f64,
    /// Which way is down, in the device frame; and the hand's acceleration, in g.
    down: [f64; 3],
    shake: [f64; 3],
}

impl Sim {
    fn new() -> Self {
        let cwd = std::env::current_dir()
            .ok()
            .map(|d| tilde(&d))
            .unwrap_or_else(|| "~".into());
        let host = std::env::var("HOSTNAME")
            .ok()
            .or_else(hostname)
            .unwrap_or_else(|| "this computer".into());
        Self {
            puck: Puck::new(&cwd, &host),
            eyes: Eyes::new(),
            ui: Ui::new(),
            t: 0.0,
            down: [0.0, 0.0, -1.0],
            shake: [0.0; 3],
        }
    }

    fn step(&mut self, dt: f64) {
        self.t += dt;
        self.puck.tick(self.t);
        self.eyes.gaze = ui::gaze(&self.puck, self.t);
        self.eyes.set_gravity(self.down, self.shake);
        self.eyes.step(dt);
        self.ui.clock = chrono::Local::now().format("%-I:%M").to_string();
    }

    fn draw(&self, cv: &mut Canvas) {
        let mut glass = Canvas::new(puck::SCREEN as usize, puck::SCREEN as usize);
        self.ui.draw(&mut glass, &self.puck, &self.eyes, self.t);
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

// ---- the demo ----

enum Step {
    Event(Value),
    Hear(String),
    Tap,
    Wake,
    Slide(f32),
    Approve,
    Sheet,
    Tilt([f64; 3]),
    Disconnect,
}

/// A whole turn, start to finish. Times are seconds since power-on.
fn demo() -> Vec<(f64, Step)> {
    use Step::*;
    let mut s = vec![
        (3.6, Tilt([0.55, -0.35, -0.75])),
        (5.0, Tilt([0.0, 0.0, -1.0])),
        (6.0, Wake),
    ];
    let said = "run the tests and tell me what broke";
    for (i, ch) in said.chars().enumerate() {
        s.push((6.6 + i as f64 * 0.045, Hear(ch.to_string())));
    }
    s.extend([
        (8.6, Tap),
        (8.8, Event(json!({"event":"turn_started","turn":1,"input":said}))),
        (10.4, Event(json!({"event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Bash","arg":"cargo test"}}))),
        (11.2, Event(json!({"event":"item_delta","id":"t1","delta":{"type":"output","text":"test proto::seq ... ok\n"}}))),
        (12.0, Event(json!({"event":"item_delta","id":"t1","delta":{"type":"output","text":"test tui::wrap ... FAILED\n"}}))),
        (13.0, Event(json!({"event":"item_completed","id":"t1","item":{"type":"tool_call","outcome":"ok"}}))),
        (13.4, Event(json!({"event":"item_started","id":"t2","kind":{"type":"tool_call","name":"Bash","arg":"git push origin claude/fix-wrap"}}))),
        (13.6, Event(json!({"event":"permission_request","id":"p1","item":"t2","name":"Bash","arg":"git push origin claude/fix-wrap","always":"","reason":"uses the network · outside the sandbox"}))),
    ]);
    for i in 0..=20 {
        s.push((16.4 + i as f64 * 0.025, Slide(i as f32 / 20.0)));
    }
    s.extend([
        (16.95, Approve),
        (17.1, Event(json!({"event":"permission_resolved","id":"p1","decision":"allow"}))),
        (17.2, Event(json!({"event":"item_delta","id":"t2","delta":{"type":"output","text":"To github.com:ecto/frog.git\n"}}))),
        (18.4, Event(json!({"event":"item_completed","id":"t2","item":{"type":"tool_call","outcome":"ok"}}))),
        (18.6, Event(json!({"event":"item_started","id":"m1","kind":{"type":"message"}}))),
        (19.6, Event(json!({"event":"item_completed","id":"m1","item":{"type":"message","text":"1 test failing. tui::wrap breaks mid-word at column 40. Want me to fix it?"}}))),
        (19.7, Event(json!({"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{}}))),
        (25.0, Sheet),
        (29.0, Sheet),
        (33.0, Disconnect),
    ]);
    s
}

fn apply(sim: &mut Sim, step: &Step) {
    let now = sim.t;
    let p = &mut sim.puck;
    match step {
        Step::Event(v) => p.event(v, now),
        Step::Hear(s) => p.hear(s, now),
        Step::Tap => {
            p.tap(now);
        }
        Step::Wake => p.wake(now),
        Step::Slide(x) => p.slide = *x,
        Step::Approve => {
            p.approve();
        }
        Step::Sheet => p.toggle_sheet(),
        Step::Tilt(d) => sim.down = *d,
        Step::Disconnect => p.disconnected("Can't reach your Mac", now),
    }
}

/// Run the demo headless up to `until`, then hand back the sim.
fn demo_until(until: f64) -> Sim {
    let script = demo();
    let mut sim = Sim::new();
    let mut next = 0;
    let dt = 1.0 / 120.0;
    while sim.t < until {
        while next < script.len() && script[next].0 <= sim.t {
            apply(&mut sim, &script[next].1);
            next += 1;
        }
        sim.step(dt);
    }
    sim
}

fn shot(path: &std::path::Path, at: f64) -> Result<()> {
    let sim = demo_until(at);
    let mut cv = Canvas::new(WIN, WIN);
    sim.draw(&mut cv);
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
        sim.draw(&mut cv);
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
    let script = if args.demo { demo() } else { Vec::new() };
    let mut next = 0;
    let speaker = Speaker::new();
    let mut sim = Sim::new();
    let mut cv = Canvas::new(WIN, WIN);
    let mut buf = Vec::new();

    let mut win = Window::new("frog puck", WIN, WIN, WindowOptions::default())?;
    win.set_target_fps(60);
    let typed = Rc::new(RefCell::new(Vec::new()));
    win.set_input_callback(Box::new(Typed(typed.clone())));

    let mut last = Instant::now();
    let glass = |x: f32, y: f32| (x - INSET, y - INSET);
    let mut press: Option<(f32, f32, f64, bool)> = None; // where, when, on the knob
    let mut held_fired = false;
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
        while next < script.len() && script[next].0 <= now {
            apply(&mut sim, &script[next].1);
            next += 1;
        }

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
        let down = win.get_mouse_down(MouseButton::Left);
        match (down, press, m) {
            (true, None, Some((x, y))) => {
                let on_knob = sim.puck.mode == Mode::Ask
                    && (x - (132.0 + sim.puck.slide * 202.0)).hypot(y - 296.0) < 34.0;
                press = Some((x, y, now, on_knob));
                held_fired = false;
            }
            (true, Some((_, _, t0, knob)), Some((x, _))) => {
                if knob {
                    sim.puck.slide = ((x - 132.0) / 202.0).clamp(0.0, 1.0);
                } else if now - t0 > 0.6 && !held_fired && sim.puck.busy() {
                    ops.extend(sim.puck.interrupt());
                    held_fired = true;
                }
            }
            (false, Some((x0, y0, _, knob)), _) => {
                if knob {
                    if sim.puck.slide > 0.95 {
                        ops.extend(sim.puck.approve());
                    } else {
                        sim.puck.slide = 0.0;
                    }
                } else if !held_fired {
                    let on_x =
                        sim.puck.mode == Mode::Ask && (x0 - puck::C).hypot(y0 - 372.0) < 26.0;
                    let on_glass = (x0 - puck::C).hypot(y0 - puck::C) < puck::C;
                    if on_x {
                        ops.extend(sim.puck.deny());
                    } else if on_glass {
                        ops.extend(sim.puck.tap(now));
                    }
                }
                press = None;
            }
            _ => {}
        }

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
        sim.step(dt);
        if let Some(s) = &speaker {
            for c in sim.puck.take_cues() {
                s.play(c);
            }
        }
        sim.draw(&mut cv);
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
        return shot(p, args.at);
    }
    run(&args)
}
