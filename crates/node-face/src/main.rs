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
    /// The 8-bit look: draw the face with pixels this many screen pixels wide (24 if bare), in a few hard shades.
    #[arg(long, value_name = "N", num_args = 0..=1, default_missing_value = "24")]
    pixel: Option<usize>,
    /// Log what the ears hear and what the face does, on stderr.
    #[arg(long)]
    verbose: bool,
    /// Follow ipse's broca (its speech center, run with `--face ADDR`) instead of running frog, ears and a voice
    /// here: the face listens on this UDP address (127.0.0.1:47210 if bare).
    #[arg(long, value_name = "ADDR", num_args = 0..=1, default_missing_value = "127.0.0.1:47210")]
    broca: Option<String>,
    /// Find the person with a webcam (this index, 0 if bare; needs the `camera` feature). Without it the pointer
    /// stands in for them, in a window only.
    #[arg(long, value_name = "INDEX", num_args = 0..=1, default_missing_value = "0")]
    camera: Option<u32>,
    /// Also show what the camera sees, the faces boxed (the person's in green), in a window of its own.
    #[arg(long)]
    camera_preview: bool,
    /// SeetaFace's frontal model for --camera (default: ~/.local/share/node-face/seeta_fd_frontal_v1.0.bin).
    #[arg(long, value_name = "PATH")]
    face_model: Option<PathBuf>,
    /// A wake-word model from ipse's `wake` (default: $WAKE_MODEL). It wakes on either the model or
    /// the word in hear's text, whichever hears it first.
    #[arg(long, value_name = "PATH")]
    wake_model: Option<String>,
    /// The wake binary (default: $WAKE_BIN, else wake on PATH).
    #[arg(long, value_name = "PATH")]
    wake_bin: Option<String>,
    /// How sure the wake model must be (0..1).
    #[arg(long, default_value_t = 0.9)]
    wake_th: f32,
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

/// --verbose: say what's heard and what the face does, on stderr.
static VERBOSE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

macro_rules! log {
    ($($t:tt)*) => {
        if VERBOSE.load(std::sync::atomic::Ordering::Relaxed) {
            eprintln!($($t)*);
        }
    };
}

// ---- frog ----

/// What frog is told when its replies are spoken rather than read.
const SPOKEN: &str = "\
This session is a voice conversation. You are the voice of a frog node: a small robot head on the \
user's desk with a screen for a face (two glowing eyes and a mouth of light), a microphone and a \
speaker. The user talks to you out loud and hears your replies spoken; nothing you write is shown \
to them as text, and they aren't at a keyboard.

How you hear them:
- Their words come from speech recognition, so expect missing punctuation, lowercase, misheard or \
dropped words and homophones. Read for what they most likely meant; if something that matters is \
unclear (a name, a path, a number), ask a short question rather than guess.
- They start a turn by saying \"frog\", and can answer you without it for a few seconds after you \
finish speaking. A pause ends their turn, so a message may be cut short; if it seems unfinished, \
ask them to go on.
- While you're working they can say \"stop\" to interrupt you.

How you speak:
- Talk the way a person would in conversation: usually a sentence or two, longer only when the \
question really needs it. Lead with the answer.
- Never use Markdown, lists, headings, tables, code blocks, emoji or links. Don't read out code, \
paths, URLs, hashes or command lines; describe them (\"the config file in your home folder\", \
\"a one-line change to the wrap function\"). Say numbers, units and symbols the way you'd say them.
- Don't refer to anything visual (\"as shown above\", \"here's a table\", \"click\"); there's \
nothing for them to look at. If they need something precise to read later, offer to put it in a \
file and say where.
- When you used tools, say what you found or did, not how.

Doing things:
- You still have your tools and the working folder. Before something that will take a while, say \
so in a few words, then do it.
- When you need permission to run a command, the user hears a request and answers by voice, yes or \
no. Say plainly what you want to do and why, in a sentence, without reading the command out.";

/// `frog --serve` as a child process, one JSON line each way.
struct Frog {
    child: Child,
    stdin: ChildStdin,
    events: Receiver<Value>,
}

impl Frog {
    fn spawn(bin: &str, args: &[String], instructions: Option<&str>) -> Result<Self> {
        let mut cmd = Command::new(bin);
        if let Some(i) = instructions {
            cmd.env("FROG_INSTRUCTIONS", i);
        }
        let mut child = cmd
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
    let mut broca = args
        .broca
        .as_deref()
        .map(node_face::broca::Broca::spawn)
        .transpose()?;
    let mut frog = if args.demo || broca.is_some() {
        None
    } else {
        Some(Frog::spawn(
            &args.frog,
            &args.frog_args,
            args.voice.then_some(SPOKEN),
        )?)
    };
    let mut player = Player::new(if args.demo {
        demo::script()
    } else {
        Vec::new()
    });
    let (mut sim, mut face, mut style) = (new_sim(), Face::new(), Style::default());
    let pixel = args.pixel.filter(|&n| n > 1);
    if pixel.is_some() {
        style.glow = false; // a soft halo has no place on a pixel grid
    }
    // Frames are drawn on their own thread while the last one is shown: on the Jetson drawing and showing are each
    // most of a 60 Hz frame, so done one after the other they'd halve the rate. Costs one frame of latency.
    let (job_tx, job_rx) = std::sync::mpsc::sync_channel::<(Face, f64, Vec<u32>)>(1);
    let (frame_tx, frame_rx) = std::sync::mpsc::sync_channel::<Vec<u32>>(1);
    std::thread::spawn(move || {
        let n = pixel.unwrap_or(1);
        let mut cv = Canvas::new(w.div_ceil(n), h.div_ceil(n));
        for (face, t, mut buf) in job_rx {
            draw::draw(&mut cv, &face, &style, t);
            match pixel {
                Some(n) => draw::to_u32_pixel(&cv, n, style.color, (w, h), &mut buf),
                None => draw::to_u32(&cv, &mut buf),
            }
            if frame_tx.send(buf).is_err() {
                break;
            }
        }
    });
    let (mut spare, mut ready): (Option<Vec<u32>>, Option<Vec<u32>>) = (None, None);

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
    let (wake, mic) = mic(args)?;
    let eyes = eyes(args)?;
    #[cfg(feature = "camera")]
    let mut preview = match (&eyes, args.camera_preview) {
        (Some(_), true) => Some((
            Window::new("frog sees", 640, 360, WindowOptions::default())?,
            Vec::new(),
        )),
        _ => None,
    };
    let mut win = Window::new("frog node", w, h, opts)?;
    win.set_target_fps(60);
    if args.fullscreen {
        win.set_cursor_visibility(false); // the head's own panel: nothing to point at
    }
    let mut last = Instant::now();
    // When the face last made a sound: its own voice mustn't be heard as yours.
    let mut spoke = f64::NEG_INFINITY;
    let mut turn_end: Option<f64> = None;
    let mut wake_after = false;
    let (mut last_mode, mut last_mic_log) = (sim.puck.mode, 0.0f64);
    // frames drawn since the last rate report, and the slowest frame among them
    let (mut frames, mut worst, mut since) = (0u32, 0.0f64, Instant::now());

    while win.is_open() {
        let dt = last.elapsed().as_secs_f64().min(0.1);
        last = Instant::now();
        frames += 1;
        worst = worst.max(dt);
        if since.elapsed().as_secs_f64() >= 5.0 {
            log!(
                "fps {:.1} (slowest frame {:.0} ms)",
                frames as f64 / since.elapsed().as_secs_f64(),
                worst * 1e3
            );
            (frames, worst, since) = (0, 0.0, Instant::now());
        }
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
        if let Some(b) = broca.as_mut() {
            for l in b.apply(&mut sim.puck, now) {
                if !l.starts_with("reply ") {
                    log!("broca: {l}");
                }
            }
        }
        player.run(&mut sim);

        if face.voice.is_some() {
            spoke = now;
        }
        if let Some(e) = &ears {
            let mut barge = false;
            let kws = wake.as_ref().map(|w| w.heard());
            ops.extend(listen(
                e,
                &mut sim.puck,
                now,
                spoke,
                &mut turn_end,
                &mut barge,
                &mut wake_after,
                kws,
            ));
            if barge {
                if let Some(v) = voice.as_mut() {
                    let _ = v.stop();
                }
                face.voice = None;
                spoke = f64::NEG_INFINITY; // stop hearing its own voice now it's quiet
            }
        }
        face.mic = mic.as_ref().map_or(0.0, |m| m.level());
        if sim.puck.mode != last_mode {
            log!("{:?} -> {:?}", last_mode, sim.puck.mode);
            last_mode = sim.puck.mode;
        }
        if now - last_mic_log > 2.0 && VERBOSE.load(std::sync::atomic::Ordering::Relaxed) {
            last_mic_log = now;
            log!("mic {:.2}", face.mic);
        }
        // The puck model's cues: on the face, only the wake chirp, so you know it's listening.
        for c in sim.puck.take_cues() {
            if c == puck::sound::Cue::Wake
                && let Some(v) = voice.as_ref()
            {
                v.cue(c.wav());
            }
        }
        for op in ops {
            if let Some(f) = frog.as_mut()
                && f.send(&op).is_err()
            {
                sim.puck.disconnected("frog stopped", now);
            }
        }

        // Where the person is: the camera's nearest face, else the pointer in a window (on the head's own panel a
        // parked pointer isn't anybody).
        let look = match &eyes {
            Some(e) => {
                face.near = e.near();
                e.person()
            }
            None if args.fullscreen => None,
            None => win
                .get_mouse_pos(MouseMode::Pass)
                .map(|(x, y)| (((x / w as f32) - 0.5) * 2.4, ((y / w as f32) - 0.45) * 2.4))
                .map(|(x, y)| (x.clamp(-1.0, 1.0), y.clamp(-1.0, 1.0))),
        };
        sim.step(dt);
        if let Some(v) = voice.as_mut() {
            if v.feed(&sim.puck).is_err() {
                voice = None; // ribt stopped: carry on silent
            } else {
                let was = face.voice.is_some();
                face.voice = v.level();
                face.sound = v.shape();
                face.phone = v.phone();
                if face.voice.is_some() != was {
                    log!("{}", if was { "voice: done" } else { "voice: playing" });
                }
                face.wave = v.wave(96);
            }
        }
        if let Some(b) = broca.as_mut() {
            let v = b.voice();
            let was = face.voice.is_some();
            face.voice = v.map(|v| v.0);
            face.sound = v.map(|v| v.1);
            face.phone = None;
            if face.voice.is_some() != was {
                log!("{}", if was { "voice: done" } else { "voice: playing" });
            }
        }
        face.voiced = voice.is_some() || broca.is_some();
        face.step(&sim.puck, sim.t, dt, look);
        // hand this frame to the drawing thread, show the one it finished last time while it draws, then take it
        job_tx.send((face.clone(), sim.t, spare.take().unwrap_or_default()))?;
        if let Some(buf) = ready.take() {
            win.update_with_buffer(&buf, w, h)?;
            spare = Some(buf);
        }
        ready = frame_rx.recv().ok();
        #[cfg(feature = "camera")]
        if let (Some((pw, pbuf)), Some(e)) = (preview.as_mut(), &eyes) {
            let (w, h) = e.shot().paint(2, pbuf);
            pw.update_with_buffer(pbuf, w, h)?;
        }
    }
    Ok(())
}

/// After the face stops making sound, how long its ears stay shut (the room's echo of its voice).
const MUTE_SECS: f64 = 0.6;
/// Smart Turn in hear decides when you're done (`[turn end]`); a pause this long ends the turn
/// anyway, in case it never says so (a trailing "um", a noisy room).
const PAUSE_SECS: f64 = 3.0;
/// After the face finishes speaking you can answer without the wake word for this long.
const FOLLOW_SECS: f64 = 6.0;
/// After Smart Turn's `[turn end]`, wait this long for the last word to finish decoding.
const END_GRACE_SECS: f64 = 0.4;
/// Words that stop it while it talks or works (besides the wake word).
const STOP: &[&str] = &["stop", "wait", "cancel", "hold"];
/// After waking with nothing said yet, how long it keeps paying attention.
const ATTENTION_SECS: f64 = 8.0;
/// The wake word.
const WAKE: &str = "frog";

/// Is `w` the wake word, as speech recognition tends to spell it? Anything containing it ("frogs",
/// "cafrog" for a run-together "okay frog") or one letter off ("fro" when it's said alone, "frok").
fn is_wake(w: &str) -> bool {
    let w: String = w
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect::<String>()
        .to_lowercase();
    if w.contains(WAKE) || NEAR_MISSES.iter().any(|m| w.starts_with(m)) {
        return w.contains(WAKE);
    }
    let close = |s: &str| s.len() >= 3 && edit_distance(s, WAKE) <= 1;
    // The whole word, or the wake word run together with its neighbour ("fragos" for "frog what's"):
    // its first or last four letters.
    let n = w.len();
    close(&w)
        || (n > 4 && w.is_char_boundary(4) && close(&w[..4]))
        || (n > 4 && w.is_char_boundary(n - 4) && close(&w[n - 4..]))
}

/// Everyday words (and word starts) one letter from the wake word: too common to wake on.
const NEAR_MISSES: &[&str] = &[
    "from", "fog", "front", "frost", "froth", "frock", "fram", "frig",
];

fn edit_distance(a: &str, b: &str) -> usize {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut prev = row[0];
        row[0] = i;
        for j in 1..=b.len() {
            let cur = row[j];
            row[j] = (prev + (a[i - 1] != b[j - 1]) as usize)
                .min(row[j] + 1)
                .min(row[j - 1] + 1);
            prev = cur;
        }
    }
    row[b.len()]
}

/// What you said, into frog. While the face is idle only the wake word starts a turn (or anything, just
/// after it spoke); then words go into the turn and a pause sends it. Yes / no answers a request to
/// run something, "stop" stops it working. `spoke` is when the face last made a sound. Returns ops.
#[cfg(feature = "window")]
#[allow(clippy::too_many_arguments)]
fn listen(
    e: &node_face::ears::Ears,
    p: &mut Puck,
    now: f64,
    spoke: f64,
    end: &mut Option<f64>,
    barge: &mut bool,
    wake_after: &mut bool,
    // With a wake model: whether it heard the wake word this frame (Some(None) = a model, no wake).
    kws: Option<Option<f32>>,
) -> Vec<Value> {
    use node_face::ears::Heard;
    let mut ops = Vec::new();
    let heard = e.poll();
    let bare = |w: &str| {
        w.trim_matches(|c: char| !c.is_alphanumeric())
            .to_lowercase()
    };
    let is = |w: &str, set: &[&str]| set.contains(&bare(w).as_str());
    let idle = matches!(p.mode, Mode::Idle | Mode::Done | Mode::Error | Mode::Boot);
    if *wake_after && idle {
        // frog has stopped after an interruption: listen for what they wanted instead
        *wake_after = false;
        p.wake(now);
    }

    // Interruption. While it talks (its ears hear its own voice) or works, only "frog" or "stop"
    // get through, and not if it's saying that word itself right now.
    let talking = now - spoke < MUTE_SECS;
    let busy = matches!(p.mode, Mode::Thinking | Mode::Running);
    if talking || busy {
        let own: std::collections::HashSet<String> = p.reply.split_whitespace().map(bare).collect();
        let partial = e.partial().0;
        let cut = heard
            .iter()
            .filter_map(|h| match h {
                Heard::Word(w) => Some(w.as_str()),
                Heard::TurnEnd => None,
            })
            .chain(std::iter::once(partial.as_str()))
            .find(|w| (is_wake(w) || is(w, STOP)) && !own.contains(&bare(w)))
            .map(str::to_string)
            .or_else(|| kws.flatten().map(|p| format!("the wake word (p {p:.2})")));
        if let Some(w) = cut {
            log!("interrupted by {w:?} ({:?}, talking {talking})", p.mode);
            *barge = true;
            e.take_partial();
            *end = None;
            if busy {
                ops.extend(p.interrupt());
                *wake_after = true; // listen once frog has stopped
            } else {
                p.wake(now);
            }
            return ops;
        }
        if talking {
            e.take_partial(); // its own voice
            return ops;
        }
    }
    // Wake on the word while it's still being heard: hear only finishes a word when the next one
    // starts, and "frog" is often the last thing said before a pause.
    if idle && kws.flatten().is_some() {
        log!("wake (model)");
        p.wake(now);
    }
    if idle && is_wake(&e.partial().0) {
        log!("wake (partial {:?})", e.partial().0);
        e.take_partial();
        p.wake(now);
    }
    for h in heard {
        match &h {
            node_face::ears::Heard::Word(w) => log!("heard {w:?} ({:?})", p.mode),
            node_face::ears::Heard::TurnEnd => log!("turn end ({:?})", p.mode),
        }
        let Heard::Word(w) = h else {
            // Smart Turn says you're done; the decoder may still be finishing the last word. Not
            // before anything's been said: that was the pause after the wake word.
            if p.mode == Mode::Listening && !p.draft.trim().is_empty() {
                end.get_or_insert(now);
            }
            continue;
        };
        // Still talking: whatever ended the turn a moment ago was a pause, not the end.
        if end.take().is_some() {
            log!("turn end cancelled: still talking");
        }
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
            Mode::Thinking | Mode::Running | Mode::Ask => {}
            // the wake phrase itself, finished by hear just after the model woke: not part of the request
            Mode::Listening
                if now - p.since < 2.0
                    && (is_wake(&w) || is(&w, &["hey", "hi", "okay", "ok", "hay"])) => {}
            Mode::Listening => p.hear(&format!("{w} "), now),
            // idle: the wake word, or a follow-up right after the face spoke
            _ if is_wake(&w) => {
                log!("wake ({w:?})");
                p.wake(now)
            }
            _ if now - spoke < FOLLOW_SECS => p.hear(&format!("{w} "), now),
            _ => {}
        }
    }
    let (partial, quiet) = e.partial();
    // Woken but nothing said: keep listening a while, then let it go.
    if p.mode == Mode::Listening
        && p.draft.trim().is_empty()
        && partial.is_empty()
        && now - p.since > ATTENTION_SECS
    {
        log!("nothing said after waking; back to idle");
        ops.extend(p.submit(now));
    }
    if p.mode != Mode::Listening {
        *end = None;
    }
    if p.mode == Mode::Listening
        && (quiet > PAUSE_SECS || end.is_some_and(|t| now - t > END_GRACE_SECS))
    {
        *end = None;
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
fn mic(args: &Args) -> Result<(Option<node_face::ears::Wake>, Option<node_face::voice::Mic>)> {
    if !args.voice || args.demo {
        return Ok((None, None));
    }
    let model = args
        .wake_model
        .clone()
        .or_else(|| std::env::var("WAKE_MODEL").ok());
    let (wake, tap) = match model {
        Some(m) => {
            let (w, tap) =
                node_face::ears::Wake::spawn(args.wake_bin.as_deref(), &m, args.wake_th)?;
            log!("wake word: model {m}");
            (Some(w), Some(tap))
        }
        None => (None, None),
    };
    Ok((wake, node_face::voice::Mic::open(tap).ok()))
}

#[cfg(all(feature = "window", not(feature = "voice")))]
fn mic(_: &Args) -> Result<(Option<NoWake>, Option<NoMic>)> {
    Ok((None, None))
}

#[cfg(all(feature = "window", not(feature = "voice")))]
struct NoWake;
#[cfg(all(feature = "window", not(feature = "voice")))]
impl NoWake {
    fn heard(&self) -> Option<f32> {
        None
    }
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
    fn cue(&self, _: &[u8]) {}
    fn stop(&mut self) -> Result<()> {
        Ok(())
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
    VERBOSE.store(args.verbose, std::sync::atomic::Ordering::Relaxed);
    if let Some(p) = &args.sheet {
        return sheet(p, args.panel());
    }
    run(&args)
}

#[cfg(feature = "camera")]
type Eyes = node_face::camera::Eyes;
/// Built without the camera: never anyone to see.
#[cfg(not(feature = "camera"))]
struct Eyes;
#[cfg(not(feature = "camera"))]
impl Eyes {
    fn person(&self) -> Option<(f32, f32)> {
        None
    }
}

/// The webcam watching for the person, if --camera asked for one.
#[cfg(feature = "camera")]
fn eyes(args: &Args) -> anyhow::Result<Option<Eyes>> {
    let Some(i) = args.camera.or(args.camera_preview.then_some(0)) else {
        return Ok(None);
    };
    let model = args
        .face_model
        .clone()
        .unwrap_or_else(node_face::camera::default_model);
    log!("camera {i}: watching for faces");
    Eyes::spawn(i, model).map(Some)
}

#[cfg(not(feature = "camera"))]
fn eyes(args: &Args) -> anyhow::Result<Option<Eyes>> {
    anyhow::ensure!(
        args.camera.is_none() && !args.camera_preview,
        "--camera needs node-face built with the `camera` feature"
    );
    Ok(None)
}

#[cfg(test)]
mod tests {
    #[test]
    fn wake_word_as_heard() {
        for w in [
            "frog", "Frog,", "frogs", "fro", "frok", "cafrog", "hayfrog", "fragos", "frag",
            "heyfrag",
        ] {
            assert!(super::is_wake(w), "{w}");
        }
        for w in [
            "from", "for", "fog", "free", "front", "frost", "frosty", "frame", "f", "dog", "a",
            "prague",
        ] {
            assert!(!super::is_wake(w), "{w}");
        }
    }
}
