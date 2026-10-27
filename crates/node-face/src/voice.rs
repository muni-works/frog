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
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
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
    /// Samples handed to the speaker, and the loudness of each 20 ms block of them.
    queued: Arc<AtomicUsize>,
    played: Arc<AtomicUsize>,
    levels: Arc<Mutex<Vec<f32>>>,
    /// The samples themselves, from absolute sample `.0` on, for the waveform.
    pcm: Arc<Mutex<(usize, Vec<i16>)>>,
    /// How much of this turn's reply has been sent, and whether the turn is still open.
    sent: usize,
    open: bool,
}

impl Voice {
    pub fn spawn(p: &Paths) -> Result<Self> {
        let out_dir = std::env::temp_dir().join("node-face-ribt");
        std::fs::create_dir_all(&out_dir)?;
        let mut child = Command::new(&p.bin)
            .args([
                "stream", "--stdin", "--pcm", "-", "--nfe", "1", "--temp", "0.3",
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
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| {
                format!(
                    "couldn't start `{} stream`; set RIBT_TTS to ribt-tts's path",
                    p.bin
                )
            })?;
        let stdin = child.stdin.take().context("ribt stdin")?;
        let mut stdout = child.stdout.take().context("ribt stdout")?;
        let (stream, handle) = OutputStream::try_default().context("no audio output")?;
        let sink = Sink::try_new(&handle)?;
        let (queued, played) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
        let levels = Arc::new(Mutex::new(Vec::new()));
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
                }
                // The speaker has run dry since the last turn: catch the counter up to the queue,
                // so the gap of silence isn't read as speech.
                if sink.empty() {
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
                sink.append(Counted {
                    samples: chunk.into_iter(),
                    played: pl.clone(),
                });
            }
        });
        Ok(Self {
            child,
            stdin,
            _stream: stream,
            queued,
            played,
            levels,
            pcm,
            sent: 0,
            open: false,
        })
    }

    /// Send whatever of frog's reply is new: complete words while it streams, the rest and an end
    /// of utterance when the turn is over.
    pub fn feed(&mut self, p: &Puck) -> Result<()> {
        let reply = p.reply.as_str();
        if reply.len() < self.sent {
            self.sent = 0; // a new turn
        }
        let streaming = matches!(p.mode, Mode::Thinking | Mode::Running);
        let new = &reply[self.sent..];
        let upto = if streaming {
            new.rfind(char::is_whitespace).map_or(0, |i| i + 1)
        } else {
            new.len()
        };
        let words = new[..upto].split_whitespace().collect::<Vec<_>>().join(" ");
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
    pub fn open() -> Result<Self> {
        use rodio::cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
        let dev = rodio::cpal::default_host()
            .default_input_device()
            .context("no microphone")?;
        let cfg = dev.default_input_config()?;
        let level = Arc::new(std::sync::atomic::AtomicU32::new(0));
        let l = level.clone();
        let stream = dev.build_input_stream(
            &cfg.into(),
            move |d: &[f32], _: &rodio::cpal::InputCallbackInfo| {
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

impl Drop for Voice {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}
