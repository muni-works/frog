//! Pip as a character: what the face wants (a target) and where it is (springs chasing it).
//!
//! Every face is a point in one continuous emotion space, valence (unhappy..happy) by arousal
//! (calm..excited), plus a gaze, a glyph the eyes may morph into, and three levels that make the
//! states loud: listening (eye contact, wide, dilated), thinking (scanning pupils, orbiting motes,
//! pulsing glow) and talking (the eyes bounce with the words).

use puck::model::{Mode, Puck};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Glyph {
    None,
    Heart,
    Star,
    Check,
    Cross,
    Diamond,
}

/// What the face is heading for.
#[derive(Clone, Copy, Debug)]
pub struct Target {
    pub v: f32,
    pub a: f32,
    /// Where to look, -1..1 each way; `None` lets the eyes wander.
    pub gaze: Option<(f32, f32)>,
    pub glyph: Glyph,
    pub listen: bool,
    pub think: f32,
}

impl Target {
    const fn at(v: f32, a: f32) -> Self {
        Self {
            v,
            a,
            gaze: None,
            glyph: Glyph::None,
            listen: false,
            think: 0.0,
        }
    }
}

/// How long a just-finished turn shows its check before settling into plain happy.
const CHECK_SECS: f64 = 1.6;
/// Words that arrived this recently still make the eyes talk.
const TALK_SECS: f64 = 0.7;

/// The face for what frog is doing. `look` is where the person is, from the camera (or the
/// pointer in the simulator); listening looks straight at them, or straight out when unknown.
pub fn target(p: &Puck, now: f64, talking: bool, look: Option<(f32, f32)>) -> Target {
    let age = now - p.since;
    let mut t = match p.mode {
        Mode::Boot => Target {
            gaze: Some((0.0, 0.3)),
            ..Target::at(0.05, if age < 1.6 { -1.0 } else { 0.0 })
        },
        Mode::Idle => Target::at(0.0, 0.0),
        Mode::Listening => Target {
            listen: true,
            gaze: Some(look.unwrap_or((0.0, 0.0))),
            ..Target::at(0.2, 0.5)
        },
        Mode::Thinking => Target {
            think: 1.0,
            gaze: Some((0.55, -0.6)),
            ..Target::at(0.0, 0.2)
        },
        // Running a command: focused, looking down at the work, still a little busy.
        Mode::Running => Target {
            think: 0.35,
            gaze: Some((0.0, 0.75)),
            ..Target::at(0.0, -0.2)
        },
        // Asking to run something: attentive, at the person.
        Mode::Ask => Target {
            gaze: Some(look.unwrap_or((0.0, 0.0))),
            ..Target::at(0.2, 0.75)
        },
        Mode::Done => Target {
            glyph: if age < CHECK_SECS {
                Glyph::Check
            } else {
                Glyph::None
            },
            ..Target::at(0.9, 0.45)
        },
        Mode::Error => Target {
            gaze: Some((0.0, 0.6)),
            ..Target::at(-0.75, -0.4)
        },
    };
    if talking && !matches!(p.mode, Mode::Listening | Mode::Ask) {
        // Words are streaming: warm, open, at the person.
        t = Target {
            gaze: Some(look.unwrap_or((0.0, 0.0))),
            ..Target::at(0.35, 0.25)
        };
    }
    t
}

/// A critically-damped-ish spring: `k` stiffness, `d` damping.
fn spring(x: &mut f32, v: &mut f32, to: f32, dt: f32, k: f32, d: f32) {
    let a = k * (to - *x) - d * *v;
    *v += a * dt;
    *x += *v * dt;
}

/// Where the face is now.
#[derive(Clone, Debug)]
pub struct Face {
    pub v: f32,
    pub a: f32,
    pub gx: f32,
    pub gy: f32,
    /// Gaze velocity: the eyes squash along a saccade.
    pub vgx: f32,
    pub vgy: f32,
    /// 0 = eyes, 1 = fully the glyph.
    pub g: f32,
    pub glyph: Glyph,
    pub listen: f32,
    pub think: f32,
    pub talk: f32,
    /// A flash of attention when a word is heard.
    pub hear: f32,
    vv: f32,
    va: f32,
    vg: f32,
    vl: f32,
    vt: f32,
    // idle life
    saccade: (f32, f32),
    next_saccade: f64,
    rng: u64,
    // what the puck model said last frame
    draft_len: usize,
    reply_len: usize,
    last_word: f64,
}

impl Default for Face {
    fn default() -> Self {
        Self::new()
    }
}

impl Face {
    pub fn new() -> Self {
        Self {
            v: 0.0,
            a: -1.0,
            gx: 0.0,
            gy: 0.3,
            vgx: 0.0,
            vgy: 0.0,
            g: 0.0,
            glyph: Glyph::None,
            listen: 0.0,
            think: 0.0,
            talk: 0.0,
            hear: 0.0,
            vv: 0.0,
            va: 0.0,
            vg: 0.0,
            vl: 0.0,
            vt: 0.0,
            saccade: (0.0, 0.0),
            next_saccade: 0.0,
            rng: 0x9e37_79b9_7f4a_7c15,
            draft_len: 0,
            reply_len: 0,
            last_word: f64::NEG_INFINITY,
        }
    }

    fn rand(&mut self) -> f32 {
        // xorshift64*: idle glances only need to look unplanned.
        self.rng ^= self.rng >> 12;
        self.rng ^= self.rng << 25;
        self.rng ^= self.rng >> 27;
        (self.rng.wrapping_mul(0x2545_f491_4f6c_dd1d) >> 40) as f32 / (1u64 << 24) as f32
    }

    /// Advance by `dt` seconds toward what `p` says frog is doing.
    pub fn step(&mut self, p: &Puck, now: f64, dt: f64, look: Option<(f32, f32)>) {
        let dt32 = dt.min(0.04) as f32;
        // Heard a word (the draft grew) or said one (the reply grew)?
        if p.draft.len() > self.draft_len {
            self.hear = 1.0;
        }
        if p.reply.len() > self.reply_len {
            self.last_word = now;
        }
        self.draft_len = p.draft.len();
        self.reply_len = p.reply.len();
        let talking = now - self.last_word < TALK_SECS;
        let t = target(p, now, talking, look);

        if now > self.next_saccade {
            // Idle life: glance somewhere new every 0.8-2.6 s.
            self.saccade = ((self.rand() - 0.5) * 1.1, (self.rand() - 0.5) * 0.6);
            self.next_saccade = now + 0.8 + self.rand() as f64 * 1.8;
        }
        let (gx, gy) = t
            .gaze
            .unwrap_or((self.saccade.0 * (1.0 - 0.6 * t.a.abs()), self.saccade.1));

        spring(&mut self.v, &mut self.vv, t.v, dt32, 90.0, 16.0);
        spring(&mut self.a, &mut self.va, t.a, dt32, 90.0, 16.0);
        // Saccades: fast, with a touch of overshoot.
        spring(&mut self.gx, &mut self.vgx, gx, dt32, 520.0, 38.0);
        spring(&mut self.gy, &mut self.vgy, gy, dt32, 520.0, 38.0);
        spring(
            &mut self.listen,
            &mut self.vl,
            if t.listen { 1.0 } else { 0.0 },
            dt32,
            120.0,
            14.0,
        );
        spring(&mut self.think, &mut self.vt, t.think, dt32, 120.0, 16.0);
        // A new glyph waits for the eyes to morph back to blocks first.
        if t.glyph != Glyph::None && t.glyph != self.glyph && self.g < 0.05 {
            self.glyph = t.glyph;
        }
        let g_to = if t.glyph == Glyph::None || t.glyph != self.glyph {
            0.0
        } else {
            1.0
        };
        spring(&mut self.g, &mut self.vg, g_to, dt32, 140.0, 17.0);
        self.hear = (self.hear - dt32 * 2.5).max(0.0);
        let talk_to = if talking { 1.0 } else { 0.0 };
        self.talk += (talk_to - self.talk) * (dt32 * 8.0).min(1.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn puck_in(mode_ops: impl FnOnce(&mut Puck)) -> Puck {
        let mut p = Puck::new("~/frog", "node");
        mode_ops(&mut p);
        p
    }

    #[test]
    fn listening_looks_at_the_person() {
        let p = puck_in(|p| {
            p.tick(10.0);
            p.tap(10.0);
        });
        assert_eq!(p.mode, Mode::Listening);
        let t = target(&p, 10.5, false, Some((0.4, -0.2)));
        assert!(t.listen);
        assert_eq!(t.gaze, Some((0.4, -0.2)));
        // Nobody seen: straight out, still eye contact rather than wandering.
        assert_eq!(target(&p, 10.5, false, None).gaze, Some((0.0, 0.0)));
    }

    #[test]
    fn thinking_is_loud_and_settles() {
        let mut p = puck_in(|p| {
            p.tick(10.0);
            p.hear("run the tests", 10.0);
        });
        p.submit(10.1);
        assert_eq!(p.mode, Mode::Thinking);
        let mut f = Face::new();
        for i in 0..240 {
            f.step(&p, 10.1 + i as f64 / 60.0, 1.0 / 60.0, None);
        }
        assert!(f.think > 0.9, "think {}", f.think);
        assert!(f.listen < 0.1);
        assert!((f.gx - 0.55).abs() < 0.05 && (f.gy + 0.6).abs() < 0.05);
    }
}
