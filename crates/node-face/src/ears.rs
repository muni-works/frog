//! Pip's ears: ipse's `hear mic`, streaming speech recognition in tang's tensor IR.
//!
//! `hear mic` prints one recognized word per line as it's heard (`[t | wall] word`, its pieces
//! arriving on that line as the decoder commits them), and `[turn end]` lines when its turn heads
//! are loaded. A reader thread turns that into finished words plus the word still being heard, so
//! the host can end the turn after a pause even when no heads say so.

use anyhow::{Context, Result};
use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::Instant;

pub enum Heard {
    Word(String),
    TurnEnd,
}

pub struct Ears {
    child: Child,
    heard: Receiver<Heard>,
    /// The word on the line now, and when anything last arrived.
    partial: Arc<Mutex<(String, Instant)>>,
    /// A half-heard word the host already took: hear finishes it later, and that copy is dropped.
    taken: Mutex<Option<String>>,
}

impl Ears {
    /// `bin` defaults to $HEAR_BIN, else `hear` on PATH; its model comes from $HEAR_MODEL (default
    /// ~/hear-assets).
    pub fn spawn(bin: Option<&str>) -> Result<Self> {
        let bin = bin
            .map(str::to_string)
            .or_else(|| std::env::var("HEAR_BIN").ok())
            .unwrap_or_else(|| "hear".into());
        let mut child = Command::new(&bin)
            .arg("mic")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("couldn't start `{bin} mic`; set HEAR_BIN to hear's path"))?;
        let mut out = child.stdout.take().context("hear stdout")?;
        let (tx, heard) = channel();
        let partial = Arc::new(Mutex::new((String::new(), Instant::now())));
        let p = partial.clone();
        std::thread::spawn(move || {
            let (mut buf, mut line) = ([0u8; 256], Vec::<u8>::new());
            loop {
                let n = match out.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                for &b in &buf[..n] {
                    if b != b'\n' {
                        line.push(b);
                        continue;
                    }
                    let s = String::from_utf8_lossy(&line).into_owned();
                    line.clear();
                    let msg = if s.contains("[turn end]") {
                        Some(Heard::TurnEnd)
                    } else {
                        word(&s).map(Heard::Word)
                    };
                    if let Some(m) = msg
                        && tx.send(m).is_err()
                    {
                        return;
                    }
                }
                *p.lock().unwrap() = (
                    word(&String::from_utf8_lossy(&line)).unwrap_or_default(),
                    Instant::now(),
                );
            }
        });
        Ok(Self {
            child,
            heard,
            partial,
            taken: Mutex::new(None),
        })
    }

    /// Everything finished since the last call.
    pub fn poll(&self) -> Vec<Heard> {
        let mut taken = self.taken.lock().unwrap();
        self.heard
            .try_iter()
            .filter(|h| match (h, taken.as_deref()) {
                (Heard::Word(w), Some(t)) if w.starts_with(t) => {
                    *taken = None;
                    false
                }
                (Heard::Word(_), _) => {
                    *taken = None;
                    true
                }
                _ => true,
            })
            .collect()
    }

    /// Take the half-heard word now (the speaker paused on it), so it isn't heard again when hear
    /// finishes it.
    pub fn take_partial(&self) -> String {
        let w = std::mem::take(&mut self.partial.lock().unwrap().0);
        if !w.is_empty() {
            *self.taken.lock().unwrap() = Some(w.clone());
        }
        w
    }

    /// The word being heard right now (empty between words), and seconds since hear last printed.
    pub fn partial(&self) -> (String, f64) {
        let p = self.partial.lock().unwrap();
        (p.0.clone(), p.1.elapsed().as_secs_f64())
    }

    /// Forget a half-heard word (Pip's own voice, say).
    pub fn clear(&self) {
        self.partial.lock().unwrap().0.clear();
    }
}

/// The word on a `[t | wall] word` line.
fn word(line: &str) -> Option<String> {
    if line.contains("[turn end]") {
        return None;
    }
    let w = line.rsplit_once("] ").map_or(line, |(_, w)| w).trim();
    (!w.is_empty() && !w.starts_with('[')).then(|| w.to_string())
}

impl Drop for Ears {
    fn drop(&mut self) {
        let _ = self.child.kill();
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn words_from_hear_lines() {
        assert_eq!(
            super::word("[   2.48s |    3.10s] the").as_deref(),
            Some("the")
        );
        assert_eq!(super::word("[   2.48s |    3.10s] "), None);
        assert_eq!(
            super::word("  [turn end] (h 0.71 @ 3.20s, wall 3.90s)"),
            None
        );
    }
}
