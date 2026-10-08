//! The puck and everything that moves it, plus a scripted turn that drives it without a model.
//! Both hosts run this: the simulator's `--demo` and the device firmware.

use crate::eyes::Eyes;
use crate::model::Puck;
use crate::ui::{self, Ui};
use serde_json::{Value, json};

pub struct Sim {
    pub puck: Puck,
    pub eyes: Eyes,
    pub ui: Ui,
    pub t: f64,
    /// Which way is down, in the device frame; and the hand's acceleration, in g.
    pub down: [f64; 3],
    pub shake: [f64; 3],
}

impl Sim {
    pub fn new(cwd: &str, host: &str) -> Self {
        Self {
            puck: Puck::new(cwd, host),
            eyes: Eyes::new(),
            ui: Ui::new(),
            t: 0.0,
            down: [0.0, 0.0, -1.0],
            shake: [0.0; 3],
        }
    }

    /// Advance by `dt` seconds. The host keeps `ui.clock` current.
    pub fn step(&mut self, dt: f64) {
        self.t += dt;
        self.puck.tick(self.t);
        self.eyes.gaze = ui::gaze(&self.puck, self.t);
        self.eyes.set_gravity(self.down, self.shake);
        self.eyes.step(dt);
    }
}

pub enum Step {
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
pub fn script() -> Vec<(f64, Step)> {
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

pub fn apply(sim: &mut Sim, step: &Step) {
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

/// Plays a script against a sim as time passes.
pub struct Player {
    script: Vec<(f64, Step)>,
    next: usize,
}

impl Player {
    pub fn new(script: Vec<(f64, Step)>) -> Self {
        Self { script, next: 0 }
    }

    /// Apply every step that's due by `sim.t`.
    pub fn run(&mut self, sim: &mut Sim) {
        while let Some((at, step)) = self.script.get(self.next)
            && *at <= sim.t
        {
            apply(sim, step);
            self.next += 1;
        }
    }

    pub fn done(&self) -> bool {
        self.next >= self.script.len()
    }
}
