//! The face's voice: ribt, streaming.
//!
//! `ribt-tts stream --stdin --pcm -` stays running for the whole session (its model compiles once,
//! a few seconds). Frog's reply goes in word by word as it streams, an empty line ends the turn, and
//! 24 kHz s16le mono comes back on stdout a chunk at a time, about 15 ms after the words. A reader
//! thread queues each chunk on the speaker and notes its loudness every 20 ms, and a counter in the
//! playback path says where the speaker is, so the eyes move with what you actually hear.

use anyhow::{Context, Result};
use puck::model::{Mode, Puck};
use rodio::{OutputStream, Sink, Source};
use std::io::{BufRead, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const SR: u32 = 24_000;
/// Loudness is noted per block of this many samples (20 ms).
const BLOCK: usize = 480;

/// Which ribt voice, and where its checkpoints are. The default is the face's voice: RIBT-2's af_heart
/// speaker with the Minnesota accent, laid out as the Claude Code announce hook keeps it
/// (`~/.claude/voice/run2`). Each piece can be overridden with an environment variable.
pub struct Paths {
    pub bin: String,
    pub run: PathBuf,
    pub ckpt: String,
    pub voc: PathBuf,
    pub flow: PathBuf,
    /// A reference clip of the speaker to sound like.
    pub r#ref: PathBuf,
    pub pitch: String,
    pub accent: String,
}

impl Paths {
    pub fn from_env(bin: Option<&str>) -> Self {
        let home = PathBuf::from(std::env::var("HOME").unwrap_or_default());
        let var = |k: &str| std::env::var(k).ok();
        let run = var("RIBT_RUN")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".claude/voice/run2"));
        let path =
            |k: &str, file: &str| var(k).map(PathBuf::from).unwrap_or_else(|| run.join(file));
        Self {
            bin: bin
                .map(str::to_string)
                .or_else(|| var("RIBT_TTS"))
                .unwrap_or_else(|| "ribt-tts".into()),
            ckpt: var("RIBT_CKPT").unwrap_or_else(|| "acoustic_af_bon.safetensors".into()),
            voc: path("RIBT_VOC", "vocoder_vocos_import.safetensors"),
            flow: path("RIBT_FLOW", "flow_student_af.safetensors"),
            r#ref: path("RIBT_REF", "ref_afheart.wav"),
            pitch: var("RIBT_PITCH").unwrap_or_else(|| "1".into()),
            accent: var("RIBT_ACCENT").unwrap_or_else(|| "minnesota".into()),
            run,
        }
    }
}

/// Samples as they play, counted, so the face knows where the speaker is.
struct Counted {
    samples: std::vec::IntoIter<i16>,
    played: Arc<AtomicUsize>,
}

impl Iterator for Counted {
    type Item = i16;
    fn next(&mut self) -> Option<i16> {
        let s = self.samples.next()?;
        self.played.fetch_add(1, Ordering::Relaxed);
        Some(s)
    }
}

impl Source for Counted {
    fn current_frame_len(&self) -> Option<usize> {
        None
    }
    fn channels(&self) -> u16 {
        1
    }
    fn sample_rate(&self) -> u32 {
        SR
    }
    fn total_duration(&self) -> Option<Duration> {
        None
    }
}

pub struct Voice {
    child: Child,
    stdin: ChildStdin,
    _stream: OutputStream,
    /// Short sounds (the wake chirp), on their own sink so they don't move the voice's counters.
    cues: Sink,
    /// Samples handed to the speaker, and the loudness of each 20 ms block of them.
    queued: Arc<AtomicUsize>,
    played: Arc<AtomicUsize>,
    levels: Arc<Mutex<Vec<f32>>>,
    /// Per 20 ms block, the mouth shape the sound calls for: (hiss, dark) -- see `shape_of`.
    shapes: Arc<Mutex<Vec<(f32, f32)>>>,
    /// ribt's phonemes as it commits them, each with the sample it starts on (in the same count as `queued`).
    phones: Arc<Mutex<Vec<(usize, char)>>>,
    /// The samples themselves, from absolute sample `.0` on, for the waveform.
    pcm: Arc<Mutex<(usize, Vec<i16>)>>,
    /// How much of this turn's reply has been sent, and whether the turn is still open.
    sent: usize,
    /// The speaker, shared with the reader thread, and whether it's been cut off (interrupted):
    /// audio still arriving for that reply is dropped.
    sink: Arc<Sink>,
    hush: Arc<AtomicBool>,
    open: bool,
}

impl Voice {
    pub fn spawn(p: &Paths) -> Result<Self> {
        let out_dir = std::env::temp_dir().join("node-face-ribt");
        std::fs::create_dir_all(&out_dir)?;
        let mut child = Command::new(&p.bin)
            .args([
                "stream", "--stdin", "--pcm", "-", "--phones", "--nfe", "1", "--temp", "0.3",
            ])
            .arg("--run")
            .arg(&p.run)
            .args(["--ckpt", &p.ckpt])
            .arg("--voc")
            .arg(&p.voc)
            .arg("--flow")
            .arg(&p.flow)
            .arg("--ref")
            .arg(&p.r#ref)
            .args(["--pitch", &p.pitch, "--accent", &p.accent, "--seed", "0"])
            .arg("--out-dir")
            .arg(&out_dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| {
                format!(
                    "couldn't start `{} stream`; set RIBT_TTS to ribt-tts's path",
                    p.bin
                )
            })?;
        let stdin = child.stdin.take().context("ribt stdin")?;
        let mut stdout = child.stdout.take().context("ribt stdout")?;
        let stderr = child.stderr.take().context("ribt stderr")?;
        let phones = Arc::new(Mutex::new(Vec::new()));
        let ph = phones.clone();
        std::thread::spawn(move || {
            for line in std::io::BufReader::new(stderr)
                .lines()
                .map_while(Result::ok)
            {
                let mut f = line.split('\t');
                if let (Some("phone"), Some(at), Some(c)) = (f.next(), f.next(), f.next())
                    && let (Ok(at), Some(c)) = (at.parse(), c.chars().next())
                {
                    ph.lock().unwrap().push((at, c));
                }
            }
        });
        let (stream, handle) = OutputStream::try_default().context("no audio output")?;
        let sink = Arc::new(Sink::try_new(&handle)?);
        let hush = Arc::new(AtomicBool::new(false));
        let (sk, hs) = (sink.clone(), hush.clone());
        let cues = Sink::try_new(&handle)?;
        let (queued, played) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
        let levels = Arc::new(Mutex::new(Vec::new()));
        let shapes = Arc::new(Mutex::new(Vec::new()));
        let sh = shapes.clone();
        let pcm = Arc::new(Mutex::new((0usize, Vec::new())));
        let (q, pl, lv, pc) = (queued.clone(), played.clone(), levels.clone(), pcm.clone());
        std::thread::spawn(move || {
            let mut buf = vec![0u8; BLOCK * 2];
            let mut carry: Vec<i16> = Vec::new();
            let mut bytes: Vec<u8> = Vec::new();
            loop {
                let n = match stdout.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                // A read can end mid-sample: keep the odd byte for the next one.
                bytes.extend_from_slice(&buf[..n]);
                let even = bytes.len() / 2 * 2;
                carry.extend(
                    bytes[..even]
                        .as_chunks::<2>()
                        .0
                        .iter()
                        .map(|b| i16::from_le_bytes(*b)),
                );
                bytes.drain(..even);
                // Whole blocks only, so loudness lines up with the playback counter.
                let whole = carry.len() / BLOCK * BLOCK;
                if whole == 0 {
                    continue;
                }
                let chunk: Vec<i16> = carry.drain(..whole).collect();
                {
                    let mut l = lv.lock().unwrap();
                    for b in chunk.chunks(BLOCK) {
                        let rms = (b.iter().map(|&s| (s as f32 / 32768.0).powi(2)).sum::<f32>()
                            / b.len() as f32)
                            .sqrt();
                        l.push((rms * 6.0).min(1.0));
                    }
                    let mut s = sh.lock().unwrap();
                    for b in chunk.chunks(BLOCK) {
                        s.push(shape_of(b));
                    }
                }
                // The speaker has run dry since the last turn: catch the counter up to the queue,
                // so the gap of silence isn't read as speech.
                if hs.load(Ordering::Relaxed) {
                    // interrupted: drop the rest of that reply, but count it, so sample numbers stay ribt's
                    q.fetch_add(chunk.len(), Ordering::Relaxed);
                    continue;
                }
                if sk.empty() {
                    pl.store(q.load(Ordering::Relaxed), Ordering::Relaxed);
                }
                {
                    // Keep ~10 s behind the playhead for the waveform; drop the rest.
                    let mut p = pc.lock().unwrap();
                    let behind = pl.load(Ordering::Relaxed).saturating_sub(p.0);
                    if behind > 10 * SR as usize {
                        let cut = behind - 5 * SR as usize;
                        let cut = cut.min(p.1.len());
                        p.1.drain(..cut);
                        p.0 += cut;
                    }
                    if p.0 + p.1.len() < q.load(Ordering::Relaxed) {
                        // the counter jumped over a silence: pad, so indices stay absolute
                        let gap = q.load(Ordering::Relaxed) - p.0 - p.1.len();
                        p.1.extend(std::iter::repeat_n(0, gap));
                    }
                    p.1.extend_from_slice(&chunk);
                }
                q.fetch_add(chunk.len(), Ordering::Relaxed);
                sk.append(Counted {
                    samples: chunk.into_iter(),
                    played: pl.clone(),
                });
            }
        });
        Ok(Self {
            child,
            stdin,
            _stream: stream,
            cues,
            queued,
            played,
            levels,
            shapes,
            phones,
            pcm,
            sent: 0,
            sink,
            hush,
            open: false,
        })
    }

    /// Send whatever of frog's reply is new: complete words while it streams, the rest and an end
    /// of utterance when the turn is over.
    pub fn feed(&mut self, p: &Puck) -> Result<()> {
        let reply = p.reply.as_str();
        if reply.len() < self.sent {
            self.sent = 0; // a new turn
            self.hush.store(false, Ordering::Relaxed);
        }
        let streaming = matches!(p.mode, Mode::Thinking | Mode::Running);
        // frog's own placeholders for a turn that was cut short aren't anything to say aloud
        if matches!(reply, "Stopped." | "Okay, I didn't run it.") {
            self.sent = reply.len();
            return Ok(());
        }
        let new = &reply[self.sent..];
        let upto = if streaming {
            new.rfind(char::is_whitespace).map_or(0, |i| i + 1)
        } else {
            new.len()
        };
        let words = speakable(&new[..upto]);
        if !words.is_empty() {
            writeln!(self.stdin, "{words}")?;
            self.open = true;
        }
        self.sent += upto;
        if self.open && !streaming {
            writeln!(self.stdin)?;
            self.open = false;
        }
        Ok(self.stdin.flush()?)
    }

    /// Stop talking now (the user interrupted): silence the speaker, end the utterance in ribt,
    /// and drop whatever of this reply is still on its way.
    pub fn stop(&mut self) -> Result<()> {
        self.hush.store(true, Ordering::Relaxed);
        self.sink.clear();
        self.sink.play();
        self.played
            .store(self.queued.load(Ordering::Relaxed), Ordering::Relaxed);
        if self.open {
            writeln!(self.stdin)?;
            self.open = false;
        }
        Ok(self.stdin.flush()?)
    }

    /// Play a short sound (a WAV) over whatever else is playing.
    pub fn cue(&self, wav: &'static [u8]) {
        if let Ok(d) = rodio::Decoder::new(std::io::Cursor::new(wav)) {
            self.cues.append(d.convert_samples::<f32>());
        }
    }

    /// How loud the face is right now (0..1), or `None` when nothing is playing.
    pub fn level(&self) -> Option<f32> {
        let (q, p) = (
            self.queued.load(Ordering::Relaxed),
            self.played.load(Ordering::Relaxed),
        );
        if p >= q {
            return None;
        }
        self.levels.lock().unwrap().get(p / BLOCK).copied()
    }

    /// The mouth shape for what's about to be heard: (hiss, dark), from the block 40 ms ahead of the
    /// playhead (real mouths shape a sound just before you hear it). `None` when silent.
    pub fn shape(&self) -> Option<(f32, f32)> {
        let (q, p) = (
            self.queued.load(Ordering::Relaxed),
            self.played.load(Ordering::Relaxed),
        );
        if p >= q {
            return None;
        }
        let s = self.shapes.lock().unwrap();
        let i = (p / BLOCK + 2).min(s.len().saturating_sub(1));
        s.get(i).copied()
    }

    /// The phoneme 40 ms ahead of the playhead (stress and length marks skipped: they stretch the one before),
    /// or `None` when silent or ribt hasn't said.
    pub fn phone(&self) -> Option<char> {
        let (q, p) = (
            self.queued.load(Ordering::Relaxed),
            self.played.load(Ordering::Relaxed),
        );
        if p >= q {
            return None;
        }
        let at = p + 2 * BLOCK;
        let ph = self.phones.lock().unwrap();
        let n = ph.partition_point(|&(s, _)| s <= at);
        ph[..n]
            .iter()
            .rev()
            .map(|&(_, c)| c)
            .find(|c| !matches!(c, 'ˈ' | 'ˌ' | 'ː'))
    }
}

/// What a 20 ms block of speech asks of the mouth, from two cheap measures:
/// - hiss: the zero-crossing rate. High for "s", "f", "sh", "t" and the bright "ee": lips wide, flat, nearly shut.
/// - dark: the share of energy below ~800 Hz (a one-pole low-pass). High for "oo", "oh", "w": lips narrow and round.
fn shape_of(b: &[i16]) -> (f32, f32) {
    let x: Vec<f32> = b.iter().map(|&s| s as f32 / 32768.0).collect();
    let e: f32 = x.iter().map(|v| v * v).sum::<f32>() + 1e-9;
    let zc = x
        .windows(2)
        .filter(|w| (w[0] >= 0.0) != (w[1] >= 0.0))
        .count() as f32
        / x.len() as f32;
    let (mut lp, mut low) = (0.0f32, 0.0f32);
    let k = 1.0 - (-2.0 * std::f32::consts::PI * 800.0 / SR as f32).exp();
    for v in &x {
        lp += k * (v - lp);
        low += lp * lp;
    }
    let hiss = ((zc - 0.12) / 0.2).clamp(0.0, 1.0);
    let dark = ((low / e - 0.55) / 0.35).clamp(0.0, 1.0) * (1.0 - hiss);
    (hiss, dark)
}

impl Voice {
    /// `n` points of the voice under the playhead (the last ~40 ms), -1..1; empty when silent.
    pub fn wave(&self, n: usize) -> Vec<f32> {
        const SPAN: usize = 960;
        let played = self.played.load(Ordering::Relaxed);
        if played >= self.queued.load(Ordering::Relaxed) {
            return Vec::new();
        }
        let p = self.pcm.lock().unwrap();
        let end = played.saturating_sub(p.0).min(p.1.len());
        let start = end.saturating_sub(SPAN);
        let s = &p.1[start..end];
        if s.len() < n {
            return Vec::new();
        }
        (0..n)
            .map(|i| s[i * s.len() / n] as f32 / 32768.0)
            .collect()
    }
}

/// How loud the room is at the microphone (the default input), 0..1: fast to rise, slow to fall.
pub struct Mic {
    _stream: rodio::cpal::Stream,
    level: Arc<std::sync::atomic::AtomicU32>,
}

impl Mic {
    /// Open the default input. With `tap`, also write it there as 16 kHz s16le mono (the wake-word
    /// spotter's input).
    pub fn open(mut tap: Option<std::process::ChildStdin>) -> Result<Self> {
        use rodio::cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
        let dev = rodio::cpal::default_host()
            .default_input_device()
            .context("no microphone")?;
        let cfg = dev.default_input_config()?;
        let (rate, ch) = (cfg.sample_rate().0 as f64, cfg.channels() as usize);
        let level = Arc::new(std::sync::atomic::AtomicU32::new(0));
        let l = level.clone();
        // linear-interpolated down to 16 kHz for the tap
        let (mut phase, mut prev, step) = (0.0f64, 0.0f32, rate / 16_000.0);
        let stream = dev.build_input_stream(
            &cfg.into(),
            move |d: &[f32], _: &rodio::cpal::InputCallbackInfo| {
                if let Some(t) = tap.as_mut() {
                    let mut bytes = Vec::with_capacity(d.len() / ch * 2);
                    for f in d.chunks(ch) {
                        let x = f.iter().sum::<f32>() / ch as f32;
                        while phase < 1.0 {
                            let s = prev + (x - prev) * phase as f32;
                            bytes.extend(((s.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
                            phase += step;
                        }
                        phase -= 1.0;
                        prev = x;
                    }
                    if t.write_all(&bytes).is_err() {
                        tap = None; // the spotter went away
                    }
                }
                let rms = (d.iter().map(|x| x * x).sum::<f32>() / d.len().max(1) as f32).sqrt();
                let now = (rms * 8.0).min(1.0);
                let was = f32::from_bits(l.load(Ordering::Relaxed));
                let next = if now > was {
                    now
                } else {
                    was * 0.9 + now * 0.1
                };
                l.store(next.to_bits(), Ordering::Relaxed);
            },
            |_| {},
            None,
        )?;
        stream.play()?;
        Ok(Self {
            _stream: stream,
            level,
        })
    }

    pub fn level(&self) -> f32 {
        f32::from_bits(self.level.load(Ordering::Relaxed))
    }
}

/// Words fit to say: frog is asked not to write Markdown, but anything that slips through
/// (emphasis, headings, bullets, code ticks, table bars, links) is taken out rather than read.
pub fn speakable(text: &str) -> String {
    text.split_whitespace()
        .filter(|w| !matches!(*w, "-" | "*" | "+" | "|" | ">" | "---") && !w.starts_with("http"))
        .map(|w| {
            let w = w.split("](").next().unwrap_or(w); // [text](url) -> text
            w.trim_start_matches('#')
                .replace(['*', '_', '`', '|', '[', ']'], "")
        })
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

impl Drop for Voice {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn markdown_is_not_read_out() {
        assert_eq!(
            super::speakable("## Plan\n- **Run** the `tests` | see [docs](https://x.y) now"),
            "Plan Run the tests see docs now"
        );
    }
}
