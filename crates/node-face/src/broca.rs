//! `--broca ADDR`: the face follows ipse's speech center instead of running its own ears, voice and frog.
//!
//! broca (ipse `crates/broca`, `--face ADDR`) sends one line per UDP datagram: what it heard, when the person's turn
//! ended, tool calls, the reply as it's written, and every 20 ms block of its own voice with when it will be heard
//! (see broca's `src/face.rs` for the lines). Here they become the frog events the puck model already understands,
//! so every mood carries over, and the voice blocks drive the lips at the moment each one plays.

use puck::model::Puck;
use serde_json::json;
use std::collections::VecDeque;
use std::net::UdpSocket;
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// A voice block: when it's heard, its loudness, and the (hiss, dark) shape it asks of the lips.
type Block = (Instant, f32, (f32, f32));

pub struct Broca {
    lines: Receiver<String>,
    blocks: Arc<Mutex<VecDeque<Block>>>,
    /// The block sounding now, if any.
    now: Option<Block>,
    /// Which tool call is running, so its end can be matched.
    tools: u32,
}

impl Broca {
    pub fn spawn(addr: &str) -> anyhow::Result<Self> {
        let sock = UdpSocket::bind(addr)?;
        let (tx, lines) = channel();
        let blocks = Arc::new(Mutex::new(VecDeque::new()));
        let q = blocks.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; 2048];
            while let Ok(n) = sock.recv(&mut buf) {
                let line = String::from_utf8_lossy(&buf[..n]).into_owned();
                if let Some(rest) = line.strip_prefix("mouth ") {
                    let v: Vec<f32> = rest.split(' ').filter_map(|s| s.parse().ok()).collect();
                    if let [ms, level, hiss, dark] = v[..] {
                        let at = Instant::now() + Duration::from_secs_f32(ms.max(0.0) / 1e3);
                        q.lock().unwrap().push_back((at, level, (hiss, dark)));
                    }
                } else if tx.send(line).is_err() {
                    break;
                }
            }
        });
        Ok(Self {
            lines,
            blocks,
            now: None,
            tools: 0,
        })
    }

    /// What broca said since last time, into the puck model. Returns each line, for the log.
    pub fn apply(&mut self, p: &mut Puck, now: f64) -> Vec<String> {
        let lines: Vec<String> = self.lines.try_iter().collect();
        for line in &lines {
            let (tag, rest) = line.split_once(' ').unwrap_or((line.as_str(), ""));
            match tag {
                // a word piece from the person: a new word gets its space
                "piece" => {
                    let (new_word, text) = rest.split_once(' ').unwrap_or(("0", rest));
                    p.hear(&format!("{}{text}", if new_word == "1" { " " } else { "" }), now);
                }
                "turn" => {
                    p.submit(now);
                }
                "tool" => {
                    self.tools += 1;
                    let id = format!("t{}", self.tools);
                    p.event(
                        &json!({"event": "item_started", "id": id, "kind": {"type": "tool_call", "name": rest}}),
                        now,
                    );
                }
                "tool-done" => {
                    let id = format!("t{}", self.tools);
                    p.event(
                        &json!({"event": "item_completed", "id": id, "item": {"type": "tool_call", "outcome": "ok"}}),
                        now,
                    );
                }
                "reply" => p.event(
                    &json!({"event": "item_delta", "delta": {"type": "text", "text": rest}}),
                    now,
                ),
                "done" => p.event(&json!({"event": "turn_ended", "reason": {"type": "completed"}}), now),
                "error" => p.event(
                    &json!({"event": "turn_ended", "reason": {"type": "error", "error": {"message": rest}}}),
                    now,
                ),
                // cut off: what's queued of our voice will never play
                "cut" => {
                    self.blocks.lock().unwrap().clear();
                    self.now = None;
                    p.event(&json!({"event": "turn_ended", "reason": {"type": "cancelled"}}), now);
                }
                _ => {}
            }
        }
        lines
    }

    /// The voice sounding now: its loudness and lip shape, or `None` in silence.
    pub fn voice(&mut self) -> Option<(f32, (f32, f32))> {
        let t = Instant::now();
        let mut q = self.blocks.lock().unwrap();
        while q.front().is_some_and(|b| b.0 <= t) {
            self.now = q.pop_front();
        }
        // a block lasts 20 ms; a little longer covers jitter between them
        self.now
            .filter(|b| t.duration_since(b.0) < Duration::from_millis(45))
            .map(|(_, level, shape)| (level, shape))
    }
}
