//! The screens, drawn from a [`Puck`] and the [`Eyes`].
//!
//! Rules from the mockup: the rim light says what frog is doing, the eyes do the acting, and the
//! glass carries one sentence at a time. Text stays inside the middle ~330px so the circle never
//! clips it.

use crate::canvas::{Canvas, Rgb, hex, lerp};
use crate::eyes::Eyes;
use crate::model::{BOOT_SECS, DONE_SECS, Mode, Puck, Status};
use crate::text::{Anchor, Face, Fonts};
use crate::{C, SCREEN};

const WHITE: Rgb = hex(0xf2f5f3);
const BLACK: Rgb = [0.0; 3];
const GREEN: Rgb = hex(0x8be37a);
const AMBER: Rgb = hex(0xffbf5c);
const RED: Rgb = hex(0xff6b6b);
const FROG: Rgb = hex(0x5fb84f);
/// Widest a line of text may be.
const LINE: f32 = 320.0;

/// A blurred light around the rim.
struct Glow {
    from: Rgb,
    to: Rgb,
    /// Fraction of the rim lit, and where the lit arc starts, in turns clockwise from the top.
    arc: f32,
    start: f32,
    /// Seconds per lap (0 = still) and seconds per breath (0 = steady).
    spin: f32,
    breathe: f32,
    strength: f32,
}

impl Glow {
    const fn ring(from: Rgb, to: Rgb) -> Self {
        Self {
            from,
            to,
            arc: 1.0,
            start: 0.0,
            spin: 0.0,
            breathe: 0.0,
            strength: 1.0,
        }
    }
}

fn draw_glow(cv: &mut Canvas, g: &Glow, t: f32) {
    let start = g.start + if g.spin > 0.0 { t / g.spin } else { 0.0 };
    let pulse = if g.breathe > 0.0 {
        0.675 + 0.325 * (t * std::f32::consts::TAU / g.breathe).cos()
    } else {
        1.0
    };
    let k = g.strength * pulse;
    if k <= 0.0 {
        return;
    }
    let feather = (g.arc / 3.0).min(0.12);
    let smooth = |e: f32| {
        let x = (e / feather).clamp(0.0, 1.0);
        x * x * (3.0 - 2.0 * x)
    };
    for y in 0..SCREEN as i32 {
        for x in 0..SCREEN as i32 {
            let (dx, dy) = (x as f32 + 0.5 - C, y as f32 + 0.5 - C);
            let d = dx.hypot(dy);
            if !(150.0..=C).contains(&d) {
                continue;
            }
            let radial = (-((d - 218.0) / 24.0).powi(2)).exp();
            // Turns clockwise from the top.
            let turn = (dx.atan2(-dy) / std::f32::consts::TAU).rem_euclid(1.0);
            let u = (turn - start).rem_euclid(1.0);
            let (w, along) = if g.arc >= 1.0 {
                (1.0, 0.5 - 0.5 * (u * std::f32::consts::TAU).cos())
            } else if u > g.arc {
                (0.0, 0.0)
            } else {
                (smooth(u) * smooth(g.arc - u), u / g.arc)
            };
            if w > 0.0 {
                cv.add(x, y, lerp(g.from, g.to, along), k * radial * w);
            }
        }
    }
}

/// How the frog looks right now. Pupil positions come from the physics.
#[derive(Clone, Copy)]
pub struct Look {
    /// 0 open … 1 shut.
    pub lid: f32,
    pub squint: bool,
    pub dead: bool,
    pub tint: Rgb,
    /// How far the head is pushed down (positive) from its resting place.
    pub sink: f32,
    pub scale: f32,
    pub dx: f32,
}

impl Default for Look {
    fn default() -> Self {
        Self {
            lid: 0.0,
            squint: false,
            dead: false,
            tint: FROG,
            sink: 0.0,
            scale: 1.0,
            dx: 0.0,
        }
    }
}

/// The crown of the frog's head rising from the bottom edge of the glass, two eyes on top.
pub fn draw_frog(cv: &mut Canvas, look: &Look, pupils: [(f32, f32); 2], blink: f32) {
    let s = look.scale;
    let (hx, hy) = (C + look.dx, 448.0 + look.sink + (1.0 - s) * 60.0);
    cv.ellipse(hx, hy, 190.0 * s, 110.0 * s, look.tint, 1.0);
    cv.ellipse(hx, hy - 60.0 * s, 150.0 * s, 40.0 * s, WHITE, 0.06);
    let lid = look.lid.max(blink);
    for (i, side) in [-1.0f32, 1.0].into_iter().enumerate() {
        let (ex, ey, r) = (hx + side * 72.0 * s, hy - 92.0 * s, 36.0 * s);
        cv.circle(ex, ey, r + 9.0 * s, look.tint, 1.0);
        cv.circle(ex, ey, r, hex(0xf6f8f2), 1.0);
        if look.dead {
            let k = 11.0 * s;
            cv.line(ex - k, ey - k, ex + k, ey + k, 7.0 * s, hex(0x111111), 1.0);
            cv.line(ex - k, ey + k, ex + k, ey - k, 7.0 * s, hex(0x111111), 1.0);
        } else {
            let pr = if look.squint { 11.0 } else { 15.0 } * s;
            let (px, py) = (
                ex + pupils[i].0 * (r - pr - 3.0 * s),
                ey + pupils[i].1 * (r - pr - 3.0 * s),
            );
            cv.circle(px, py, pr, hex(0x0a0a0a), 1.0);
            cv.circle(px + 5.0 * s, py - 6.0 * s, 4.5 * s, WHITE, 1.0);
        }
        // The lid comes down from the top, clipped to the eye.
        if lid > 0.0 {
            let edge = ey - r + lid * 2.0 * r;
            cv.fill_sdf(ex - r, ey - r, ex + r, edge, look.tint, 1.0, |x, y| {
                ((x - ex).hypot(y - ey) - r - 1.0).max(y - edge)
            });
        }
    }
}

/// A blink every few seconds, at slightly irregular intervals.
fn blink_at(t: f32) -> f32 {
    let period = 5.3;
    let n = (t / period).floor();
    let jitter = ((n * 12.9898).sin() * 43758.547).fract().abs() * 1.6;
    let phase = t - n * period - (period - 0.4 - jitter);
    if (0.0..0.22).contains(&phase) {
        1.0 - ((phase / 0.11) - 1.0).abs()
    } else {
        0.0
    }
}

/// Where the frog wants to look in each mode. Feeds the eye springs.
pub fn gaze(p: &Puck, t: f64) -> (f64, f64) {
    match p.mode {
        Mode::Boot | Mode::Idle => ((t * 0.3).sin() * 0.25, -0.1),
        Mode::Listening => ((t * 1.3).sin() * 0.15, 0.55),
        Mode::Thinking => (0.6, 0.7),
        Mode::Running => (0.0, -0.3),
        Mode::Ask => (0.0, 0.8),
        Mode::Done => (0.0, -0.5),
        Mode::Error => (0.0, 0.0),
    }
}

pub struct Ui {
    pub fonts: Fonts,
    /// Wall-clock text for Idle, set by the host.
    pub clock: String,
}

impl Ui {
    pub fn new() -> Self {
        Self {
            fonts: Fonts::new(),
            clock: String::new(),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn text(&self, cv: &mut Canvas, f: Face, size: f32, y: f32, s: &str, c: Rgb, a: f32) {
        self.fonts
            .draw(cv, f, size, C, y, s, Anchor::Middle, c, a, 0.0);
    }

    /// Draw the glass for `p` at time `t` (seconds since boot) into a 466×466 canvas. The panel
    /// is square; everything outside the inscribed circle is hidden by the case.
    pub fn draw(&self, cv: &mut Canvas, p: &Puck, eyes: &Eyes, t: f64) {
        let t32 = t as f32;
        let age = (t - p.since) as f32;
        let pupils = eyes.pupils();
        let blink = blink_at(t32);
        let mut look = Look::default();

        cv.clear(BLACK);

        if p.sheet {
            return self.draw_sheet(cv, p);
        }

        match p.mode {
            Mode::Boot => {
                // The frog surfaces out of black water, blinks twice, and looks at you.
                let k = (age / 1.4).clamp(0.0, 1.0);
                let ease = 1.0 - (1.0 - k).powi(3);
                look.sink = (1.0 - ease) * 220.0;
                let b = |at: f32| {
                    let ph = age - at;
                    if (0.0..0.22).contains(&ph) {
                        1.0 - ((ph / 0.11) - 1.0).abs()
                    } else {
                        0.0
                    }
                };
                let lid = if age < 1.2 { 1.0 } else { b(1.7).max(b(2.1)) };
                let fade = (1.0 - (age - BOOT_SECS as f32 + 0.6).max(0.0) / 0.6).clamp(0.0, 1.0);
                draw_glow(
                    cv,
                    &Glow {
                        arc: 0.5,
                        start: 0.25,
                        strength: 0.7 * k * fade,
                        ..Glow::ring(BLACK, hex(0x3fae4a))
                    },
                    t32,
                );
                draw_frog(cv, &look, pupils, lid);
            }
            Mode::Idle => {
                draw_glow(
                    cv,
                    &Glow {
                        arc: 0.5,
                        start: 0.25,
                        breathe: 6.0,
                        strength: 0.55,
                        ..Glow::ring(BLACK, hex(0x3fae4a))
                    },
                    t32,
                );
                self.text(cv, Face::Regular, 84.0, 150.0, &self.clock, WHITE, 1.0);
                self.text(cv, Face::Mono, 20.0, 190.0, &p.cwd, WHITE, 0.4);
                look.lid = 0.45;
                draw_frog(cv, &look, pupils, blink);
            }
            Mode::Listening => {
                draw_glow(
                    cv,
                    &Glow {
                        spin: 3.2,
                        breathe: 0.7,
                        ..Glow::ring(hex(0x7cc8ff), hex(0x7b8bff))
                    },
                    t32,
                );
                if p.draft.trim().is_empty() {
                    self.text(cv, Face::Bold, 32.0, 200.0, "Listening", WHITE, 0.45);
                } else {
                    let (size, lines) =
                        self.fonts
                            .fit(Face::Bold, &[32.0, 28.0], &p.draft, LINE, usize::MAX);
                    let shown = &lines[lines.len().saturating_sub(2)..];
                    let top = if shown.len() == 1 { 200.0 } else { 180.0 };
                    for (i, l) in shown.iter().enumerate() {
                        let newest = i + 1 == shown.len();
                        self.text(
                            cv,
                            Face::Bold,
                            size,
                            top + i as f32 * 42.0,
                            l,
                            WHITE,
                            if newest { 1.0 } else { 0.45 },
                        );
                    }
                }
                draw_frog(cv, &look, pupils, blink);
            }
            Mode::Thinking => {
                draw_glow(
                    cv,
                    &Glow {
                        arc: 0.55,
                        spin: 2.4,
                        ..Glow::ring(GREEN, hex(0x2fd1c0))
                    },
                    t32,
                );
                self.text(cv, Face::Bold, 36.0, 196.0, "Thinking", WHITE, 0.9);
                for i in 0..3 {
                    let a = 0.6 + 0.4 * ((t32 * 5.2 - i as f32 * 1.05).sin());
                    cv.circle(
                        C - 20.0 + i as f32 * 20.0,
                        232.0,
                        5.0,
                        WHITE,
                        a.clamp(0.2, 1.0),
                    );
                }
                draw_frog(cv, &look, pupils, blink);
            }
            Mode::Running => {
                draw_glow(
                    cv,
                    &Glow {
                        arc: 0.7,
                        spin: 5.0,
                        strength: 0.85,
                        ..Glow::ring(AMBER, hex(0xff8a3d))
                    },
                    t32,
                );
                let n = p.ran.len();
                let label = if n > 1 {
                    format!("RUNNING · {n}")
                } else {
                    "RUNNING".into()
                };
                self.fonts.draw(
                    cv,
                    Face::Bold,
                    17.0,
                    C,
                    104.0,
                    &label,
                    Anchor::Middle,
                    AMBER,
                    1.0,
                    1.5,
                );
                let (size, lines) =
                    self.fonts
                        .fit(Face::Mono, &[34.0, 28.0, 22.0], &p.command, LINE, 2);
                let lh = size * 1.25;
                for (i, l) in lines.iter().enumerate() {
                    self.text(cv, Face::Mono, size, 160.0 + i as f32 * lh, l, WHITE, 1.0);
                }
                let below = 160.0 + (lines.len() as f32 - 1.0) * lh;
                let (_, tail) = self.fonts.fit(Face::Mono, &[17.0], &p.tail, LINE, 1);
                if let Some(tail) = tail.first() {
                    self.text(cv, Face::Mono, 17.0, below + 42.0, tail, WHITE, 0.45);
                }
                self.text(
                    cv,
                    Face::Mono,
                    16.0,
                    below + 70.0,
                    &format!("{}:{:02}", age as u32 / 60, age as u32 % 60),
                    WHITE,
                    0.3,
                );
                look.lid = 0.3;
                look.squint = true;
                draw_frog(cv, &look, pupils, blink);
            }
            Mode::Ask => {
                draw_glow(
                    cv,
                    &Glow {
                        breathe: 1.6,
                        ..Glow::ring(AMBER, hex(0xff6b3d))
                    },
                    t32,
                );
                self.text(
                    cv,
                    Face::Bold,
                    20.0,
                    100.0,
                    "Frog wants to run",
                    WHITE,
                    0.55,
                );
                let ask = p.ask.as_ref();
                let cmd = ask.map(|a| a.arg.as_str()).unwrap_or_default();
                let (size, lines) = self
                    .fonts
                    .fit(Face::Mono, &[30.0, 25.0, 21.0], cmd, LINE, 3);
                let lh = size * 1.25;
                let top = 150.0 - (lines.len() as f32 - 2.0).max(0.0) * lh * 0.5;
                for (i, l) in lines.iter().enumerate() {
                    self.text(cv, Face::Mono, size, top + i as f32 * lh, l, WHITE, 1.0);
                }
                if let Some(why) = ask.and_then(|a| a.reason.as_deref()) {
                    let (_, w) = self.fonts.fit(Face::Regular, &[16.0], why, LINE, 1);
                    self.text(cv, Face::Regular, 16.0, 234.0, &w[0], WHITE, 0.45);
                }
                // slide to run
                cv.rrect(98.0, 262.0, 270.0, 68.0, 34.0, WHITE, 0.08);
                let kx = 132.0 + p.slide * 202.0;
                let shimmer = (t32 * 1.3).rem_euclid(1.0);
                let label = "slide to run";
                let w = self.fonts.width(Face::Bold, 22.0, label, 0.0);
                let x0 = 250.0 - w / 2.0;
                let mut pen = x0;
                for ch in label.chars() {
                    let cw = self.fonts.width(Face::Bold, 22.0, &ch.to_string(), 0.0);
                    let u = (pen - x0) / w;
                    let a = 0.25 + 0.65 * (-((u - (shimmer * 1.6 - 0.3)) / 0.18).powi(2)).exp();
                    self.fonts.draw(
                        cv,
                        Face::Bold,
                        22.0,
                        pen,
                        304.0,
                        &ch.to_string(),
                        Anchor::Start,
                        WHITE,
                        a * (1.0 - p.slide),
                        0.0,
                    );
                    pen += cw;
                }
                cv.circle(kx, 296.0, 28.0, AMBER, 1.0);
                cv.line(kx - 6.0, 285.0, kx + 6.0, 296.0, 5.0, hex(0x2a1a00), 1.0);
                cv.line(kx + 6.0, 296.0, kx - 6.0, 307.0, 5.0, hex(0x2a1a00), 1.0);
                // decline
                cv.circle(C, 372.0, 22.0, WHITE, 0.07);
                cv.line(C - 7.0, 365.0, C + 7.0, 379.0, 3.0, WHITE, 0.7);
                cv.line(C + 7.0, 365.0, C - 7.0, 379.0, 3.0, WHITE, 0.7);
                look.scale = 0.62;
                look.sink = 30.0;
                draw_frog(cv, &look, pupils, blink);
            }
            Mode::Done => {
                let fade = 1.0 - (age / DONE_SECS as f32).clamp(0.0, 1.0) * 0.7;
                draw_glow(
                    cv,
                    &Glow {
                        arc: 0.6,
                        start: 0.333,
                        strength: 0.9 * fade,
                        ..Glow::ring(GREEN, hex(0xd6ff8a))
                    },
                    t32,
                );
                let (head, rest) = p.verdict();
                let (size, lines) = self
                    .fonts
                    .fit(Face::Bold, &[40.0, 34.0, 28.0], &head, LINE, 2);
                let lh = size * 1.15;
                let top = 166.0 - (lines.len() as f32 - 1.0) * lh;
                for (i, l) in lines.iter().enumerate() {
                    self.text(cv, Face::Bold, size, top + i as f32 * lh, l, WHITE, 1.0);
                }
                let (_, more) = self
                    .fonts
                    .fit(Face::Regular, &[20.0], &rest, LINE - 20.0, 2);
                for (i, l) in more.iter().enumerate() {
                    self.text(
                        cv,
                        Face::Regular,
                        20.0,
                        206.0 + i as f32 * 26.0,
                        l,
                        WHITE,
                        0.5,
                    );
                }
                look.lid = 0.55;
                draw_frog(cv, &look, pupils, blink);
            }
            Mode::Error => {
                draw_glow(
                    cv,
                    &Glow {
                        arc: 0.5,
                        start: 0.25,
                        strength: 0.6,
                        ..Glow::ring(BLACK, hex(0xff5a5a))
                    },
                    t32,
                );
                let (size, lines) = self.fonts.fit(Face::Bold, &[30.0, 24.0], &p.error, LINE, 2);
                for (i, l) in lines.iter().enumerate() {
                    self.text(
                        cv,
                        Face::Bold,
                        size,
                        160.0 + i as f32 * size * 1.2,
                        l,
                        WHITE,
                        1.0,
                    );
                }
                self.text(
                    cv,
                    Face::Mono,
                    18.0,
                    160.0 + lines.len() as f32 * size * 1.2 + 6.0,
                    &p.host,
                    WHITE,
                    0.4,
                );
                self.text(cv, Face::Bold, 18.0, 262.0, "Tap to try again", RED, 1.0);
                look.dead = true;
                look.sink = 36.0;
                look.tint = hex(0x4f8f45);
                draw_frog(cv, &look, pupils, 0.0);
            }
        }
    }

    /// Swipe up: what ran this turn, fading into the curve of the glass at top and bottom.
    fn draw_sheet(&self, cv: &mut Canvas, p: &Puck) {
        self.fonts.draw(
            cv,
            Face::Bold,
            16.0,
            C,
            84.0,
            "THIS TURN",
            Anchor::Middle,
            WHITE,
            0.4,
            1.5,
        );
        let rows: Vec<_> = p
            .ran
            .iter()
            .rev()
            .take(5)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        let top = 142.0;
        if rows.len() > 1 {
            cv.line(
                96.0,
                top - 6.0,
                96.0,
                top - 6.0 + (rows.len() - 1) as f32 * 52.0,
                2.0,
                WHITE,
                0.1,
            );
        }
        for (i, r) in rows.iter().enumerate() {
            let y = top + i as f32 * 52.0;
            let fade = 1.0 - ((y - 230.0).abs() / 200.0).powi(3);
            let c = match r.status {
                Status::Ok => GREEN,
                Status::Failed => RED,
                Status::Waiting | Status::Running => AMBER,
            };
            cv.circle(96.0, y - 6.0, 6.0, c, fade);
            let (_, l) = self.fonts.fit(Face::Mono, &[20.0], &r.arg, 250.0, 1);
            self.fonts.draw(
                cv,
                Face::Mono,
                20.0,
                118.0,
                y,
                &l[0],
                Anchor::Start,
                WHITE,
                fade,
                0.0,
            );
        }
        let ok = p.ran.iter().filter(|r| r.status == Status::Ok).count();
        let bad = p.ran.iter().filter(|r| r.status == Status::Failed).count();
        let mut sum = format!("{ok} done");
        if bad > 0 {
            sum += &format!(" · {bad} failed");
        }
        self.text(cv, Face::Regular, 16.0, 400.0, &sum, WHITE, 0.4);
    }
}

impl Default for Ui {
    fn default() -> Self {
        Self::new()
    }
}
