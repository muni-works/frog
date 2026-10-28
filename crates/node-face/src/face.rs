//! The face as a character: what the face wants (a target) and where it is (springs chasing it).
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

/// The designed emotions. Each is one clear idea: a mouth pose, a pupil size, an entry motion and a blush
/// (settled in the Soft Blocks lab, cortex/face/soft-blocks-lab.html in the rose repo).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mood {
    Idle,
    Listening,
    Thinking,
    Happy,
    Delighted,
    Surprised,
    Annoyed,
    Sad,
    Sleepy,
    Focused,
    Love,
    Done,
    Speaking,
}

/// The mouth's pose: `w` width and `open`ing (screen widths), `curve` (+ smile / - frown), `side` (toward one
/// cheek), `tilt` (one corner lower), `round` (an "o" rather than a lens), `press` (thinner lips); plus `pupil`
/// size, a sad `quiver` and an entry `bounce`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pose {
    pub w: f32,
    pub open: f32,
    pub curve: f32,
    pub side: f32,
    pub tilt: f32,
    pub round: f32,
    pub press: f32,
    pub pupil: f32,
    pub quiver: f32,
    pub bounce: f32,
}

const POSE0: Pose = Pose {
    w: 0.085,
    open: 0.0,
    curve: 0.15,
    side: 0.0,
    tilt: 0.0,
    round: 0.0,
    press: 0.0,
    pupil: 1.0,
    quiver: 0.0,
    bounce: 0.0,
};

impl Mood {
    pub fn pose(self) -> Pose {
        let p = POSE0;
        match self {
            Mood::Idle => p,
            Mood::Listening => Pose {
                w: 0.075,
                open: 0.007,
                curve: 0.1,
                pupil: 1.15,
                ..p
            },
            Mood::Thinking => Pose {
                w: 0.055,
                curve: -0.1,
                side: 0.55,
                tilt: 0.25,
                press: 0.5,
                pupil: 0.95,
                ..p
            },
            Mood::Happy => Pose {
                w: 0.11,
                open: 0.006,
                curve: 0.85,
                pupil: 1.05,
                ..p
            },
            Mood::Delighted => Pose {
                w: 0.12,
                open: 0.03,
                curve: 1.0,
                round: 0.15,
                pupil: 1.1,
                bounce: 1.6,
                ..p
            },
            Mood::Surprised => Pose {
                w: 0.034,
                open: 0.034,
                curve: 0.0,
                round: 1.0,
                pupil: 0.72,
                bounce: 1.0,
                ..p
            },
            Mood::Annoyed => Pose {
                w: 0.07,
                curve: -0.25,
                tilt: -0.6,
                press: 0.8,
                pupil: 0.9,
                ..p
            },
            Mood::Sad => Pose {
                w: 0.06,
                curve: -0.9,
                press: 0.2,
                pupil: 1.08,
                quiver: 1.0,
                ..p
            },
            Mood::Sleepy => Pose {
                w: 0.05,
                open: 0.005,
                curve: 0.0,
                round: 0.5,
                pupil: 0.9,
                ..p
            },
            Mood::Focused => Pose {
                w: 0.06,
                curve: -0.05,
                press: 1.0,
                pupil: 0.92,
                ..p
            },
            Mood::Love => Pose {
                w: 0.07,
                curve: 0.7,
                pupil: 1.2,
                bounce: 0.8,
                ..p
            },
            Mood::Done => Pose {
                w: 0.09,
                curve: 0.75,
                bounce: 0.6,
                ..p
            },
            Mood::Speaking => Pose { curve: 0.3, ..p },
        }
    }

    /// How much it blushes: love most, then delight, happiness, a job done; never the rest.
    pub fn blush(self) -> f32 {
        match self {
            Mood::Love => 1.0,
            Mood::Delighted => 0.8,
            Mood::Happy => 0.55,
            Mood::Done => 0.35,
            _ => 0.0,
        }
    }
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
    pub mood: Mood,
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
            mood: Mood::Idle,
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
            mood: if age < 1.6 { Mood::Sleepy } else { Mood::Idle },
            ..Target::at(0.05, if age < 1.6 { -1.0 } else { 0.0 })
        },
        Mode::Idle => Target::at(0.0, 0.0),
        Mode::Listening => Target {
            listen: true,
            gaze: Some(look.unwrap_or((0.0, 0.0))),
            mood: Mood::Listening,
            ..Target::at(0.2, 0.5)
        },
        Mode::Thinking => Target {
            think: 1.0,
            gaze: Some((0.55, -0.6)),
            mood: Mood::Thinking,
            ..Target::at(0.0, 0.2)
        },
        // Running a command: focused, looking down at the work, still a little busy.
        Mode::Running => Target {
            think: 0.35,
            gaze: Some((0.0, 0.75)),
            mood: Mood::Focused,
            ..Target::at(0.0, -0.2)
        },
        // Asking to run something: attentive, at the person.
        Mode::Ask => Target {
            gaze: Some(look.unwrap_or((0.0, 0.0))),
            mood: Mood::Listening,
            ..Target::at(0.2, 0.75)
        },
        Mode::Done => Target {
            glyph: if age < CHECK_SECS {
                Glyph::Check
            } else {
                Glyph::None
            },
            mood: if age < CHECK_SECS {
                Mood::Done
            } else {
                Mood::Happy
            },
            ..Target::at(0.9, 0.45)
        },
        Mode::Error => Target {
            gaze: Some((0.0, 0.6)),
            mood: Mood::Sad,
            ..Target::at(-0.75, -0.4)
        },
    };
    if talking && !matches!(p.mode, Mode::Listening | Mode::Ask) {
        // Words are streaming: warm, open, at the person.
        t = Target {
            gaze: Some(look.unwrap_or((0.0, 0.0))),
            mood: Mood::Speaking,
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
    /// The loudness (0..1) of its own voice playing right now, set by the host each frame when
    /// it speaks with ribt. `None` while silent.
    pub voice: Option<f32>,
    /// The host has a voice: talking follows the audio rather than the words arriving.
    pub voiced: bool,
    /// The last few tens of milliseconds of its voice under the playhead (-1..1), for the waveform.
    pub wave: Vec<f32>,
    /// How loud you are right now (0..1), from the microphone.
    pub mic: f32,
    /// How open the mouth is (0..1): the voice's loudness, snapping open on syllables and easing
    /// shut.
    pub mouth: f32,
    /// The shape the voice calls for now (hiss, dark), set by the host each frame; eased here.
    pub sound: Option<(f32, f32)>,
    /// The phoneme about to be heard (ribt's IPA), set by the host each frame; when known it shapes the lips
    /// exactly, and `sound` is the fallback.
    pub phone: Option<char>,
    /// The lips' eased speaking shape: see [`Viseme`].
    vis: Viseme,
    /// The emotion now, and its pose eased toward (pupil size included).
    pub mood: Mood,
    pub pose: Pose,
    /// Blush, 0..1: blooms in quickly, fades slowly.
    pub blush: f32,
    /// The liquid lips: upper and lower, each a chain of droplets (relative to the mouth's centre, screen widths).
    pub lips: [[Droplet; LIPS]; 2],
    /// A kick to the lips' surface: a syllable onset, or an emotion arriving with a bounce.
    pub pulse: f32,
    prev_mouth: f32,
    vv: f32,
    va: f32,
    vg: f32,
    vl: f32,
    vt: f32,
    // idle life
    saccade: (f32, f32),
    next_saccade: f64,
    /// Where the person was last seen, and when: the eyes keep coming back to it after they look away.
    person: Option<(f32, f32)>,
    seen_at: f64,
    /// Thinking breaks eye contact: where the eyes are off to, when they move on, and a quick glance back.
    away: (f32, f32),
    next_away: f64,
    peek_until: f64,
    /// On the person, the eyes never quite hold still: tiny flicks, as between someone's two eyes.
    micro: (f32, f32),
    next_micro: f64,
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
            voice: None,
            voiced: false,
            wave: Vec::new(),
            mic: 0.0,
            mouth: 0.0,
            sound: None,
            phone: None,
            vis: Viseme::REST,
            mood: Mood::Idle,
            pose: POSE0,
            blush: 0.0,
            lips: [[Droplet::default(); LIPS]; 2],
            pulse: 0.0,
            prev_mouth: 0.0,
            vv: 0.0,
            va: 0.0,
            vg: 0.0,
            vl: 0.0,
            vt: 0.0,
            saccade: (0.0, 0.0),
            next_saccade: 0.0,
            person: None,
            seen_at: f64::NEG_INFINITY,
            away: (0.5, -0.55),
            next_away: 0.0,
            peek_until: 0.0,
            micro: (0.0, 0.0),
            next_micro: 0.0,
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
        let talking = if self.voiced {
            self.voice.is_some()
        } else {
            now - self.last_word < TALK_SECS
        };
        // Remember where the person is: a voice or a face is there for a moment, and the eyes return to it.
        if let Some(l) = look {
            (self.person, self.seen_at) = (Some(l), now);
        } else if now - self.seen_at > PERSON_SECS {
            self.person = None;
        }
        let mut t = target(p, now, talking, self.person);
        self.gaze_life(p, now, &mut t);

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
        // Without a voice engine (the demo), a stand-in syllable rhythm while words arrive.
        let open = if self.voiced {
            self.voice.unwrap_or(0.0)
        } else {
            self.talk * (0.35 + 0.35 * ((now * 9.0).sin() * (now * 3.7).sin()).abs() as f32)
        };
        let rate = if open > self.mouth { 30.0 } else { 9.0 };
        self.mouth += (open - self.mouth) * (dt32 * rate).min(1.0);

        // the emotion: ease the pose in, bounce on arrival, bloom or fade the blush
        if t.mood != self.mood {
            self.mood = t.mood;
            self.pulse = self.pulse.max(t.mood.pose().bounce);
        }
        let want = t.mood.pose();
        let e = 1.0 - (-dt32 * 5.5).exp();
        let p = &mut self.pose;
        for (cur, to) in [
            (&mut p.w, want.w),
            (&mut p.open, want.open),
            (&mut p.curve, want.curve),
            (&mut p.side, want.side),
            (&mut p.tilt, want.tilt),
            (&mut p.round, want.round),
            (&mut p.press, want.press),
            (&mut p.pupil, want.pupil),
            (&mut p.quiver, want.quiver),
        ] {
            *cur += (to - *cur) * e;
        }
        let bt = t.mood.blush();
        self.blush += (bt - self.blush) * (dt32 * if bt > self.blush { 4.0 } else { 1.2 }).min(1.0);
        // the sound's shape, eased fast: a mouth moves quickly between sounds, never instantly
        let want = self.viseme();
        // closing for m, b, p is quick (it's a stop); everything else blends into its neighbours
        let s = (dt32
            * if want.shut > self.vis.shut {
                30.0
            } else {
                16.0
            })
        .min(1.0);
        self.vis.ease(want, s);
        self.step_lips(now, dt32);
    }
}

/// What a sound asks of the lips while speaking.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Viseme {
    /// spread wide and flat ("ee", "s")
    pub wide: f32,
    /// narrow and round ("oo", "w")
    pub round: f32,
    /// pressed shut (m, b, p) or tucked (f, v)
    pub shut: f32,
    /// how far the jaw drops, relative to loudness ("ah" 1.5, "s" 0.25)
    pub gape: f32,
}

impl Viseme {
    const REST: Self = Self::new(0.0, 0.0, 0.0, 1.0);

    const fn new(wide: f32, round: f32, shut: f32, gape: f32) -> Self {
        Self {
            wide,
            round,
            shut,
            gape,
        }
    }

    fn ease(&mut self, to: Self, s: f32) {
        self.wide += (to.wide - self.wide) * s;
        self.round += (to.round - self.round) * s;
        self.shut += (to.shut - self.shut) * s;
        self.gape += (to.gape - self.gape) * s;
    }

    /// The lips for one of ribt's phonemes (lilt's IPA, with capitals for diphthongs: O "oh", W "ow", I "eye",
    /// A "ay", Y "oy"). `None` for marks that only stretch the sound before them.
    pub fn of(c: char) -> Option<Self> {
        let v = |w, r, s, g| Some(Self::new(w, r, s, g));
        match c {
            'ˈ' | 'ˌ' | 'ː' => None,
            'p' | 'b' | 'm' => v(0.1, 0.0, 1.0, 0.0),
            'f' | 'v' => v(0.3, 0.0, 0.8, 0.0),
            'u' | 'w' => v(0.0, 1.0, 0.0, 0.55),
            'ʊ' => v(0.0, 0.7, 0.0, 0.8),
            'O' => v(0.0, 0.8, 0.0, 0.95),
            'ɔ' | 'Y' => v(0.0, 0.5, 0.0, 1.1),
            'W' => v(0.0, 0.3, 0.0, 1.3),
            'ɹ' | 'ɚ' | 'ɜ' => v(0.0, 0.45, 0.0, 0.75),
            'ʃ' | 'ʒ' => v(0.1, 0.55, 0.0, 0.45),
            'i' => v(1.0, 0.0, 0.0, 0.55),
            'j' => v(0.8, 0.0, 0.0, 0.5),
            'ɪ' => v(0.7, 0.0, 0.0, 0.8),
            'A' | 'e' => v(0.6, 0.0, 0.0, 0.95),
            's' | 'z' => v(0.9, 0.0, 0.0, 0.25),
            't' | 'd' | 'n' | 'l' => v(0.4, 0.0, 0.0, 0.6),
            'θ' | 'ð' => v(0.4, 0.0, 0.0, 0.5),
            'ɑ' | 'a' => v(0.0, 0.0, 0.0, 1.5),
            'æ' => v(0.4, 0.0, 0.0, 1.4),
            'ʌ' => v(0.1, 0.0, 0.0, 1.2),
            'I' => v(0.2, 0.0, 0.0, 1.4),
            'k' | 'ɡ' | 'ŋ' | 'h' => v(0.2, 0.0, 0.0, 0.8),
            c if c.is_whitespace() || c.is_ascii_punctuation() => v(0.0, 0.0, 0.6, 0.3),
            _ => v(0.2, 0.0, 0.0, 1.0),
        }
    }
}

impl Face {
    /// Where the eyes go beyond the mode's plain target. Thinking looks up and away from the person, the way people
    /// break eye contact to think, moving on every second or few and now and then glancing back; on the person
    /// (listening, asking, answering, done) the gaze flicks a little, never fixed like a stare.
    fn gaze_life(&mut self, p: &Puck, now: f64, t: &mut Target) {
        if p.mode == Mode::Thinking && t.mood == Mood::Thinking {
            if now > self.next_away {
                // away from the person's side (or either, with nobody known)
                let coin = if self.rand() < 0.5 { -1.0 } else { 1.0 };
                let side = match self.person {
                    Some((x, _)) if x.abs() > 0.1 => -x.signum(),
                    _ => coin,
                };
                self.away = (side * (0.4 + 0.3 * self.rand()), -0.45 - 0.3 * self.rand());
                self.next_away = now + 1.0 + 2.0 * self.rand() as f64;
                if self.person.is_some() && self.rand() < 0.3 {
                    self.peek_until = now + 0.35;
                }
            }
            t.gaze = Some(if now < self.peek_until {
                self.person.unwrap_or((0.0, 0.0))
            } else {
                self.away
            });
            return;
        }
        let Some((x, y)) = self.person else { return };
        if t.gaze != Some((x, y)) && t.mood != Mood::Done && t.mood != Mood::Happy {
            return;
        }
        if now > self.next_micro {
            self.micro = ((self.rand() - 0.5) * 0.1, (self.rand() - 0.5) * 0.06);
            self.next_micro = now + 0.3 + 0.6 * self.rand() as f64;
        }
        t.gaze = Some((x + self.micro.0, y + self.micro.1));
    }
}

/// How long the eyes remember where the person was after they stop being seen or heard.
const PERSON_SECS: f64 = 45.0;

impl Face {
    /// The shape speech wants right now: the phoneme if the host knows it, else a guess from the sound.
    fn viseme(&self) -> Viseme {
        if self.talk <= 0.05 {
            return Viseme::REST;
        }
        if let Some(v) = self.phone.and_then(Viseme::of) {
            return v;
        }
        let (hiss, dark) = self.sound.unwrap_or((0.0, 0.0));
        Viseme::new(hiss, dark, 0.0, 1.0)
    }
}

/// Droplets per lip.
pub const LIPS: usize = 9;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Droplet {
    pub x: f32,
    pub y: f32,
    vx: f32,
    vy: f32,
}

impl Face {
    /// Where droplet `i` of a lip wants to be, relative to the mouth's centre: the lips bow apart in the middle (a
    /// lens, or toward an ellipse when round) and meet at the corners, which carry the curve and the tilt.
    pub fn lip_target(&self, i: usize, lower: bool, now: f64) -> (f32, f32) {
        let p = &self.pose;
        let tt = now as f32;
        let speaking = self.talk > 0.05;
        let breath = if speaking {
            0.0
        } else {
            0.004 * (tt * 1.3).sin() * (1.0 - self.listen)
        };
        let drift = self.think * 0.25 * (tt * 0.9).sin();
        let quiver =
            p.quiver * ((tt * 23.0).sin() * 0.5 + 0.5) * (tt * 0.7).sin().max(0.0).powi(8) * 0.003;
        // speaking: loudness opens the jaw, scaled by the sound's gape; wide sounds spread the lips flat and nearly
        // shut, round ones pull them narrow; m, b, p press them closed
        let vis = &self.vis;
        let w = if speaking {
            p.w.max(0.055 + 0.04 * self.mouth) * (1.0 + 0.32 * vis.wide - 0.38 * vis.round)
        } else {
            p.w * (1.0 + breath * 3.0)
        };
        let open = if speaking {
            ((0.004 + 0.05 * self.mouth)
                * (1.0 - 0.55 * vis.wide)
                * (1.0 + 0.2 * vis.round)
                * vis.gape
                + p.open * 0.5)
                * (1.0 - vis.shut)
        } else {
            p.open
        };
        let round = if speaking {
            p.round.max(vis.round * 0.9)
        } else {
            p.round
        };
        let f = i as f32 / (LIPS - 1) as f32 - 0.5;
        let bell = (1.0 - round) * (f * std::f32::consts::PI).cos()
            + round * (1.0 - 4.0 * f * f).max(0.0).sqrt();
        let corner = -(p.curve * 0.022) * (4.0 * f * f)
            + p.tilt * 0.012 * f
            + quiver * f.signum() * 4.0 * f * f;
        let sgn = if lower { 1.0 } else { -1.0 };
        // a jaw: the lower lip carries most of an opening, the upper barely moves
        let gap = if lower { 1.45 } else { 0.55 };
        let y = corner
            + sgn * gap * open / 2.0 * bell
            + sgn * 0.004 * (1.0 - bell * 0.5) * (1.0 - 0.6 * p.press);
        ((p.side + drift) * 0.02 + f * w, y)
    }

    /// Jump straight to `mood`, settled (pose, blush, lips at rest): for stills and previews.
    pub fn settle(&mut self, mood: Mood, now: f64) {
        self.mood = mood;
        self.pose = mood.pose();
        self.blush = mood.blush();
        self.vis = self.viseme();
        for (l, lower) in [false, true].into_iter().enumerate() {
            for i in 0..LIPS {
                let (x, y) = self.lip_target(i, lower, now);
                self.lips[l][i] = Droplet {
                    x,
                    y,
                    ..Droplet::default()
                };
            }
        }
    }

    /// Damped springs with surface tension: each droplet pulls toward its target and its neighbours, and a syllable
    /// onset (or an emotion's arrival) kicks the surface.
    fn step_lips(&mut self, now: f64, dt: f32) {
        if self.lips[0][0] == Droplet::default() {
            for (l, lip) in [false, true].into_iter().enumerate() {
                for i in 0..LIPS {
                    let (x, y) = self.lip_target(i, lip, now);
                    self.lips[l][i] = Droplet {
                        x,
                        y,
                        ..Droplet::default()
                    };
                }
            }
        }
        if self.mouth - self.prev_mouth > 0.18 {
            self.pulse = self.pulse.max(1.0);
        }
        self.prev_mouth = self.mouth;
        self.pulse *= (-dt * 8.0).exp();
        for (l, lower) in [false, true].into_iter().enumerate() {
            let ys: Vec<f32> = self.lips[l].iter().map(|d| d.y).collect();
            for i in 0..LIPS {
                let (tx, ty) = self.lip_target(i, lower, now);
                let nb = (ys[i.saturating_sub(1)] + ys[(i + 1).min(LIPS - 1)]) / 2.0;
                let kick = self.pulse
                    * if lower { 1.0 } else { -1.0 }
                    * (i as f32 / (LIPS - 1) as f32 * std::f32::consts::PI).sin()
                    * 0.6;
                let d = &mut self.lips[l][i];
                let ay = 260.0 * (ty - d.y) + 90.0 * (nb - d.y) - 9.0 * d.vy + kick * 2.2;
                let ax = 260.0 * (tx - d.x) - 9.0 * d.vx;
                d.vx += ax * dt;
                d.vy += ay * dt;
                d.x += d.vx * dt;
                d.y += d.vy * dt;
            }
        }
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
    fn thinking_looks_away_from_the_person_and_remembers_them() {
        let mut p = puck_in(|p| {
            p.tick(10.0);
            p.hear("what's the weather", 10.0);
        });
        let mut f = Face::new();
        // seen on the viewer's right while asking
        f.step(&p, 10.0, 1.0 / 60.0, Some((0.6, 0.1)));
        p.submit(10.1);
        assert_eq!(p.mode, Mode::Thinking);
        let mut away = 0;
        for i in 0..300 {
            let now = 10.1 + i as f64 / 60.0;
            f.step(&p, now, 1.0 / 60.0, None);
            if f.gx < -0.2 && f.gy < -0.2 {
                away += 1;
            }
        }
        // mostly up and to the other side, with a glance back now and then
        assert!(away > 200, "away {away} of 300 frames");
        // still remembered, with nobody seen for 5 s
        assert_eq!(f.person, Some((0.6, 0.1)));
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
        // up and off to one side, wherever this glance landed
        assert!(f.gx.abs() > 0.3 && f.gy < -0.35, "gaze {} {}", f.gx, f.gy);
    }
}
