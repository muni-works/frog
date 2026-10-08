//! What the puck shows, folded from frog's `--serve` event stream and the user's taps.
//!
//! Events are read as JSON values rather than `frog_engine::protocol` types: the firmware can't
//! link the engine, and the puck only needs a handful of fields.

use crate::sound::Cue;
use serde_json::{Value, json};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// The frog surfacing on first power-on.
    Boot,
    Idle,
    Listening,
    Thinking,
    Running,
    Ask,
    Done,
    Error,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Running,
    Waiting,
    Ok,
    Failed,
}

#[derive(Clone, Debug)]
pub struct Ran {
    pub id: String,
    pub arg: String,
    pub status: Status,
}

#[derive(Clone, Debug)]
pub struct Ask {
    pub id: String,
    pub arg: String,
    pub reason: Option<String>,
}

/// How long Boot lasts, and how long Done stays up before settling back to Idle.
pub const BOOT_SECS: f64 = 3.2;
pub const DONE_SECS: f64 = 20.0;

pub struct Puck {
    pub mode: Mode,
    /// When `mode` was entered, in seconds since start.
    pub since: f64,
    /// The words heard so far while listening.
    pub draft: String,
    /// What was asked this turn.
    pub input: String,
    /// The command running now, and the newest line of its output.
    pub command: String,
    pub tail: String,
    /// Commands run this turn, in order.
    pub ran: Vec<Ran>,
    pub ask: Option<Ask>,
    /// The assistant's reply, as it streams.
    pub reply: String,
    pub error: String,
    /// Which folder this frog works in, shown on Idle.
    pub cwd: String,
    /// Which machine it talks to, shown when it can't.
    pub host: String,
    /// The "what ran" sheet is pulled up over the current screen.
    pub sheet: bool,
    /// Where the slide-to-run knob is, 0..=1.
    pub slide: f32,
    cues: Vec<Cue>,
}

impl Puck {
    pub fn new(cwd: &str, host: &str) -> Self {
        Self {
            mode: Mode::Boot,
            since: 0.0,
            draft: String::new(),
            input: String::new(),
            command: String::new(),
            tail: String::new(),
            ran: Vec::new(),
            ask: None,
            reply: String::new(),
            error: String::new(),
            cwd: cwd.into(),
            host: host.into(),
            sheet: false,
            slide: 0.0,
            cues: vec![Cue::Boot],
        }
    }

    fn enter(&mut self, mode: Mode, now: f64) {
        if self.mode != mode {
            self.mode = mode;
            self.since = now;
        }
    }

    /// Sounds to play, oldest first.
    pub fn take_cues(&mut self) -> Vec<Cue> {
        std::mem::take(&mut self.cues)
    }

    /// Time-driven transitions.
    pub fn tick(&mut self, now: f64) {
        let age = now - self.since;
        match self.mode {
            Mode::Boot if age > BOOT_SECS => self.enter(Mode::Idle, now),
            Mode::Done if age > DONE_SECS && !self.sheet => self.enter(Mode::Idle, now),
            _ => {}
        }
    }

    pub fn busy(&self) -> bool {
        matches!(self.mode, Mode::Thinking | Mode::Running | Mode::Ask)
    }

    // ---- the user ----

    /// A tap on the glass: start listening, or send what was heard. Returns an op to send.
    pub fn tap(&mut self, now: f64) -> Option<Value> {
        match self.mode {
            Mode::Idle | Mode::Done | Mode::Error | Mode::Boot => {
                self.sheet = false;
                self.draft.clear();
                self.cues.push(Cue::ListenStart);
                self.enter(Mode::Listening, now);
                None
            }
            Mode::Listening => self.submit(now),
            _ => None,
        }
    }

    /// The wake word: like a tap, with the frog's own chirp.
    pub fn wake(&mut self, now: f64) {
        if !self.busy() && self.mode != Mode::Listening {
            self.cues.push(Cue::Wake);
            self.tap(now);
            self.cues.retain(|c| *c != Cue::ListenStart);
        }
    }

    /// Words arriving from speech recognition (the simulator types them).
    pub fn hear(&mut self, text: &str, now: f64) {
        if self.mode != Mode::Listening {
            if self.busy() {
                return;
            }
            self.tap(now);
        }
        self.draft.push_str(text);
    }

    pub fn unhear(&mut self) {
        if self.mode == Mode::Listening {
            self.draft.pop();
        }
    }

    pub fn submit(&mut self, now: f64) -> Option<Value> {
        if self.mode != Mode::Listening {
            return None;
        }
        let text = self.draft.trim().to_string();
        if text.is_empty() {
            self.enter(Mode::Idle, now);
            return None;
        }
        self.cues.push(Cue::ListenEnd);
        self.input = text.clone();
        self.enter(Mode::Thinking, now);
        Some(json!({"op": "submit", "text": text}))
    }

    /// The crown button, or the slide reaching the end.
    pub fn approve(&mut self) -> Option<Value> {
        let ask = self.ask.take().filter(|_| self.mode == Mode::Ask)?;
        self.cues.push(Cue::Approve);
        self.slide = 0.0;
        Some(json!({"op": "permission", "id": ask.id, "decision": "allow"}))
    }

    pub fn deny(&mut self) -> Option<Value> {
        let ask = self.ask.take().filter(|_| self.mode == Mode::Ask)?;
        self.cues.push(Cue::Deny);
        self.slide = 0.0;
        Some(json!({"op": "permission", "id": ask.id, "decision": "deny"}))
    }

    /// Holding the glass while frog works.
    pub fn interrupt(&mut self) -> Option<Value> {
        self.busy().then(|| json!({"op": "interrupt"}))
    }

    pub fn toggle_sheet(&mut self) {
        self.sheet = !self.sheet && !self.ran.is_empty();
    }

    /// The bridge couldn't reach frog.
    pub fn disconnected(&mut self, why: &str, now: f64) {
        self.error = why.into();
        self.cues.push(Cue::Error);
        self.enter(Mode::Error, now);
    }

    // ---- the engine ----

    pub fn event(&mut self, ev: &Value, now: f64) {
        let s = |v: &Value, k: &str| {
            v.get(k)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string()
        };
        match ev.get("event").and_then(Value::as_str).unwrap_or_default() {
            "turn_started" => {
                self.input = s(ev, "input");
                self.ran.clear();
                self.reply.clear();
                self.command.clear();
                self.tail.clear();
                self.sheet = false;
                self.enter(Mode::Thinking, now);
            }
            "item_started" => {
                let kind = &ev["kind"];
                if kind["type"] == "tool_call" {
                    self.command = s(kind, "arg");
                    if self.command.is_empty() {
                        self.command = s(kind, "name");
                    }
                    self.tail.clear();
                    self.ran.push(Ran {
                        id: s(ev, "id"),
                        arg: self.command.clone(),
                        status: Status::Running,
                    });
                    self.cues.push(Cue::Tick);
                    self.enter(Mode::Running, now);
                } else if kind["type"] == "message" {
                    self.reply.clear();
                }
            }
            "item_delta" => {
                let d = &ev["delta"];
                match d["type"].as_str() {
                    Some("output") => {
                        if let Some(line) = strip_ansi(&s(d, "text"))
                            .lines()
                            .rev()
                            .find(|l| !l.trim().is_empty())
                        {
                            self.tail = line.trim().to_string();
                        }
                    }
                    Some("text") => self.reply.push_str(&s(d, "text")),
                    _ => {}
                }
            }
            "item_completed" => {
                let item = &ev["item"];
                match item["type"].as_str() {
                    Some("tool_call") => {
                        let id = s(ev, "id");
                        if let Some(r) = self.ran.iter_mut().find(|r| r.id == id) {
                            r.status = if item["outcome"] == "ok" {
                                Status::Ok
                            } else {
                                Status::Failed
                            };
                        }
                        if self.mode == Mode::Running {
                            self.enter(Mode::Thinking, now);
                        }
                    }
                    Some("message") => self.reply = s(item, "text"),
                    _ => {}
                }
            }
            "permission_request" => {
                let item = s(ev, "item");
                if let Some(r) = self.ran.iter_mut().find(|r| r.id == item) {
                    r.status = Status::Waiting;
                }
                let arg = s(ev, "arg");
                self.ask = Some(Ask {
                    id: s(ev, "id"),
                    arg: if arg.is_empty() { s(ev, "name") } else { arg },
                    reason: ev.get("reason").and_then(Value::as_str).map(str::to_string),
                });
                self.slide = 0.0;
                self.cues.push(Cue::Ask);
                self.enter(Mode::Ask, now);
            }
            "permission_resolved" => {
                self.ask = None;
                for r in self.ran.iter_mut().filter(|r| r.status == Status::Waiting) {
                    r.status = Status::Running;
                }
                if self.mode == Mode::Ask {
                    self.enter(Mode::Running, now);
                }
            }
            "turn_ended" => {
                let reason = &ev["reason"];
                self.ask = None;
                match reason["type"].as_str().unwrap_or_default() {
                    "error" => {
                        let e = &reason["error"];
                        self.error =
                            e["message"]
                                .as_str()
                                .map(str::to_string)
                                .unwrap_or_else(|| {
                                    e["type"]
                                        .as_str()
                                        .unwrap_or("Something went wrong")
                                        .replace('_', " ")
                                });
                        self.cues.push(Cue::Error);
                        self.enter(Mode::Error, now);
                    }
                    "cancelled" => {
                        self.reply = "Stopped.".into();
                        self.enter(Mode::Done, now);
                    }
                    "denied" => {
                        self.reply = "Okay, I didn't run it.".into();
                        self.enter(Mode::Done, now);
                    }
                    _ => {
                        self.cues.push(Cue::Done);
                        self.enter(Mode::Done, now);
                    }
                }
            }
            _ => {}
        }
    }

    /// The reply split for the Done screen: its first sentence, then the rest.
    pub fn verdict(&self) -> (String, String) {
        let r = self.reply.trim();
        if r.is_empty() {
            return ("Done".into(), String::new());
        }
        let cut = r
            .char_indices()
            .find(|&(i, c)| {
                matches!(c, '.' | '!' | '?' | '\n')
                    && r[i + c.len_utf8()..].starts_with([' ', '\n'])
            })
            .map(|(i, c)| i + c.len_utf8());
        match cut {
            Some(i) => (
                r[..i].trim_end_matches('.').trim().to_string(),
                r[i..].trim().to_string(),
            ),
            None => (r.trim_end_matches('.').to_string(), String::new()),
        }
    }
}

fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(v: Value, p: &mut Puck) {
        p.event(&v, 1.0);
    }

    #[test]
    fn a_turn_with_a_permission() {
        let mut p = Puck::new("~/frog", "mac");
        p.tick(5.0);
        assert_eq!(p.mode, Mode::Idle);
        p.hear("run the tests", 5.0);
        assert_eq!(p.mode, Mode::Listening);
        let op = p.tap(6.0).unwrap();
        assert_eq!(op["op"], "submit");
        assert_eq!(op["text"], "run the tests");

        ev(
            json!({"event":"turn_started","turn":1,"input":"run the tests"}),
            &mut p,
        );
        ev(
            json!({"event":"item_started","id":"t1","kind":{"type":"tool_call","name":"Bash","arg":"cargo test"}}),
            &mut p,
        );
        assert_eq!((p.mode, p.command.as_str()), (Mode::Running, "cargo test"));
        ev(
            json!({"event":"item_delta","id":"t1","delta":{"type":"output","text":"test a ... ok\n\u{1b}[31mtest b ... FAILED\u{1b}[0m\n"}}),
            &mut p,
        );
        assert_eq!(p.tail, "test b ... FAILED");
        ev(
            json!({"event":"permission_request","id":"p1","item":"t1","name":"Bash","arg":"cargo test","always":""}),
            &mut p,
        );
        assert_eq!(p.mode, Mode::Ask);
        assert_eq!(p.approve().unwrap()["decision"], "allow");
        ev(
            json!({"event":"permission_resolved","id":"p1","decision":"allow"}),
            &mut p,
        );
        assert_eq!(p.mode, Mode::Running);
        ev(
            json!({"event":"item_completed","id":"t1","item":{"type":"tool_call","outcome":"ok"}}),
            &mut p,
        );
        assert_eq!(p.ran[0].status, Status::Ok);
        ev(
            json!({"event":"item_completed","id":"m1","item":{"type":"message","text":"1 test failing. It's tui::wrap."}}),
            &mut p,
        );
        ev(
            json!({"event":"turn_ended","turn":1,"reason":{"type":"complete"},"usage":{}}),
            &mut p,
        );
        assert_eq!(p.mode, Mode::Done);
        assert_eq!(
            p.verdict(),
            ("1 test failing".into(), "It's tui::wrap.".into())
        );
        assert!(p.take_cues().contains(&Cue::Done));
    }

    #[test]
    fn errors_name_what_broke() {
        let mut p = Puck::new("~", "mac");
        ev(
            json!({"event":"turn_ended","reason":{"type":"error","error":{"type":"provider","status":500,"message":"model not loaded"}}}),
            &mut p,
        );
        assert_eq!(
            (p.mode, p.error.as_str()),
            (Mode::Error, "model not loaded")
        );
    }

    #[test]
    fn verdict_keeps_dotted_names_whole() {
        let mut p = Puck::new("~", "mac");
        p.reply = "Bumped serde to 1.0.229 in Cargo.toml".into();
        assert_eq!(p.verdict().0, "Bumped serde to 1.0.229 in Cargo.toml");
    }
}
