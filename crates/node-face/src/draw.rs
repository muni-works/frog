//! Drawing the face into the panel's framebuffer.
//!
//! Faces are laid out in unit coordinates (1 = the panel's width); on the portrait panel the unit
//! square sits a little above centre. There is no text: under the eyes one small light says what's
//! happening (a breathing dot, your voice as dots, a thinking bob, its own voice as a waveform). Each eye is a
//! 64-point outline: a soft superellipse with its lids and cheek pressed in, which can morph point
//! for point into a glyph. The glow is the frame itself, blurred and added back.

use crate::face::{Face, Glyph};
use puck::canvas::{Canvas, Rgb, hex};
use std::f32::consts::{PI, TAU};

const N: usize = 64;
pub const BG: Rgb = [5.0 / 255.0, 7.0 / 255.0, 10.0 / 255.0];
pub const MINT: Rgb = hex(0xb8e8d2);
const BLUSH: Rgb = hex(0xff8ca5);

/// The look that was settled in the lab.
#[derive(Clone, Copy, Debug)]
pub struct Style {
    pub color: Rgb,
    pub size: f32,
    pub spacing: f32,
    pub round: f32,
    pub glow: bool,
}

impl Default for Style {
    fn default() -> Self {
        Self {
            color: MINT,
            size: 1.0,
            spacing: 0.18,
            round: 0.38,
            glow: true,
        }
    }
}

type Pts = [(f32, f32); N];

/// A closed polygon resampled to `N` points by arc length, wound the same way and starting at
/// the point straight above its centroid, so any two outlines morph point for point.
fn resample(pts: &[(f32, f32)]) -> Pts {
    let mut p: Vec<(f32, f32)> = pts.to_vec();
    let area: f32 = (0..p.len())
        .map(|i| {
            let (a, b) = (p[i], p[(i + 1) % p.len()]);
            a.0 * b.1 - b.0 * a.1
        })
        .sum();
    if area < 0.0 {
        p.reverse();
    }
    let n = p.len() as f32;
    let (cx, cy) = p
        .iter()
        .fold((0.0, 0.0), |s, q| (s.0 + q.0 / n, s.1 + q.1 / n));
    let start = (0..p.len())
        .min_by(|&i, &j| {
            let up = |k: usize| ((p[k].1 - cy).atan2(p[k].0 - cx) + PI / 2.0).abs();
            up(i).total_cmp(&up(j))
        })
        .unwrap_or(0);
    p.rotate_left(start);
    let mut len = vec![0.0f32];
    for i in 1..=p.len() {
        let (a, b) = (p[i - 1], p[i % p.len()]);
        len.push(len[i - 1] + (b.0 - a.0).hypot(b.1 - a.1));
    }
    let total = len[p.len()];
    let mut out = [(0.0, 0.0); N];
    let mut j = 0;
    for (k, o) in out.iter_mut().enumerate() {
        let d = total * k as f32 / N as f32;
        while len[j + 1] < d {
            j += 1;
        }
        let f = (d - len[j]) / (len[j + 1] - len[j]).max(1e-9);
        let (a, b) = (p[j], p[(j + 1) % p.len()]);
        *o = (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f);
    }
    out
}

/// The eye body: a soft superellipse, a touch narrower across the top. `round` 0.15 (n 3.4) ..
/// 0.5 (n 2, an oval).
fn squircle(w: f32, h: f32, round: f32) -> Vec<(f32, f32)> {
    let n = 3.4 - (round - 0.15) / 0.35 * 1.4;
    (0..160)
        .map(|i| {
            let t = TAU * i as f32 / 160.0;
            let (c, s) = (t.cos(), t.sin());
            let y = h / 2.0 * s.signum() * s.abs().powf(2.0 / n);
            let x = w / 2.0 * c.signum() * c.abs().powf(2.0 / n) * (1.0 - 0.05 * (0.5 - y / h));
            (x, y)
        })
        .collect()
}

fn glyph_pts(g: Glyph) -> Option<Pts> {
    let dense = |f: &dyn Fn(f32) -> (f32, f32)| {
        (0..240)
            .map(|i| f(TAU * i as f32 / 240.0))
            .collect::<Vec<_>>()
    };
    Some(match g {
        Glyph::None => return None,
        Glyph::Heart => resample(&dense(&|t| {
            (
                0.5 * t.sin().powi(3),
                -(13.0 * t.cos() - 5.0 * (2.0 * t).cos() - 2.0 * (3.0 * t).cos() - (4.0 * t).cos())
                    / 32.0
                    - 0.02,
            )
        })),
        Glyph::Star => resample(
            &(0..10)
                .map(|i| {
                    let (a, r) = (
                        -PI / 2.0 + i as f32 * PI / 5.0,
                        if i % 2 == 1 { 0.21 } else { 0.52 },
                    );
                    (r * a.cos(), r * a.sin() + 0.04)
                })
                .collect::<Vec<_>>(),
        ),
        Glyph::Check => resample(&[
            (-0.44, 0.02),
            (-0.3, -0.12),
            (-0.1, 0.08),
            (0.3, -0.36),
            (0.44, -0.22),
            (-0.1, 0.34),
        ]),
        Glyph::Cross => resample(&[
            (-0.34, -0.44),
            (0.0, -0.1),
            (0.34, -0.44),
            (0.44, -0.34),
            (0.1, 0.0),
            (0.44, 0.34),
            (0.34, 0.44),
            (0.0, 0.1),
            (-0.34, 0.44),
            (-0.44, 0.34),
            (-0.1, 0.0),
            (-0.44, -0.34),
        ]),
        Glyph::Diamond => resample(&[(0.0, -0.5), (0.36, 0.0), (0.0, 0.5), (-0.36, 0.0)]),
    })
}

fn sat(x: f32) -> f32 {
    x.clamp(0.0, 1.0)
}
fn pos(x: f32) -> f32 {
    x.max(0.0)
}

/// Emotion to eye numbers. One function, so every point of the space is a face.
struct Eye {
    w: f32,
    h: f32,
    lid_in: f32,
    lid_out: f32,
    cheek: f32,
}

fn eye_params(v: f32, a: f32) -> Eye {
    let sleep = pos(-a).powf(1.6) * 0.82; // both lids fall as arousal drops
    Eye {
        w: 0.215 - 0.02 * pos(a) + 0.01 * pos(v),
        h: 0.34 + 0.07 * pos(a) - 0.05 * pos(-v) * pos(-a),
        lid_in: sat(sleep + pos(-v) * pos(a) * 0.75), // annoyed: inner corners cut down
        lid_out: sat(sleep + pos(-v) * pos(0.4 - a) * 0.55), // sad: outer corners droop
        cheek: sat(pos(v) * (0.32 + 0.3 * pos(a)) - 0.08), // happy: a cheek pushes up into a crescent
    }
}

#[allow(clippy::too_many_arguments)]
fn outline(
    e: &Eye,
    cx: f32,
    cy: f32,
    side: f32,
    st: &Style,
    g: f32,
    glyph: Glyph,
    sx: f32,
    sy: f32,
) -> Pts {
    let (w, h) = (e.w * st.size * sx, e.h * st.size * sy);
    let mut p = resample(&squircle(w, h, st.round)).map(|(x, y)| (x + cx, y + cy));
    let (x0, y0) = (cx - w / 2.0, cy - h / 2.0);
    let inner = if side < 0.0 { x0 + w } else { x0 };
    let lid = |x: f32| y0 + h * (e.lid_in + (e.lid_out - e.lid_in) * (x - inner).abs() / w) * 0.97;
    for q in p.iter_mut() {
        q.1 = q.1.max(lid(q.0));
    }
    if e.cheek > 0.01 {
        let r = w * 0.75;
        let ccy = y0 + h + r - h * e.cheek;
        for q in p.iter_mut() {
            let dx = q.0 - cx;
            if dx.abs() < r {
                q.1 = q.1.min(ccy - (r * r - dx * dx).sqrt());
            }
        }
    }
    if g > 0.001
        && let Some(gp) = glyph_pts(glyph)
    {
        let s = e.w.max(e.h) * st.size * 1.05;
        for (q, t) in p.iter_mut().zip(gp) {
            q.0 += (cx + t.0 * s - q.0) * g;
            q.1 += (cy + t.1 * s - q.1) * g;
        }
    }
    p
}

/// Signed distance to a polygon in pixels (negative inside).
fn poly_sdf(p: &[(f32, f32)], x: f32, y: f32) -> f32 {
    let mut d = f32::MAX;
    let mut inside = false;
    for i in 0..p.len() {
        let (a, b) = (p[i], p[(i + 1) % p.len()]);
        let (ex, ey) = (b.0 - a.0, b.1 - a.1);
        let t = (((x - a.0) * ex + (y - a.1) * ey) / (ex * ex + ey * ey).max(1e-9)).clamp(0.0, 1.0);
        d = d.min((x - a.0 - ex * t).hypot(y - a.1 - ey * t));
        if (a.1 > y) != (b.1 > y) && x < a.0 + (y - a.1) * ex / ey {
            inside = !inside;
        }
    }
    if inside { -d } else { d }
}

fn bounds(p: &[(f32, f32)]) -> (f32, f32, f32, f32) {
    p.iter()
        .fold((f32::MAX, f32::MAX, f32::MIN, f32::MIN), |b, q| {
            (b.0.min(q.0), b.1.min(q.1), b.2.max(q.0), b.3.max(q.1))
        })
}

fn voice(t: f64) -> f32 {
    (0.5 + 0.5 * ((t * 1000.0 / 95.0).sin() * (t * 1000.0 / 233.0).sin()).abs()) as f32
}

fn blink(t: f64) -> f32 {
    let p = t % 4.4;
    if p < 0.16 {
        (p / 0.16 * std::f64::consts::PI).sin() as f32
    } else {
        0.0
    }
}

/// Draw `face` at time `t` (seconds) over the whole canvas.
pub fn draw(cv: &mut Canvas, face: &Face, st: &Style, t: f64) {
    cv.clear(BG);
    let w = cv.w as f32;
    let yoff = (cv.h as f32 - w) * 0.32;
    let u = |x: f32, y: f32| (x * w, y * w + yoff); // unit -> pixels
    let col = st.color;
    let bl = blink(t);
    let breathe = (t / 2.6).sin() as f32 * 0.006;
    let (spx, spy) = (
        (face.vgx.abs() / 6.0).min(1.0),
        (face.vgy.abs() / 6.0).min(1.0),
    );
    let (sx, sy) = (1.0 + 0.18 * spx - 0.08 * spy, 1.0 - 0.1 * spx + 0.16 * spy); // squash along the saccade
    // The real voice's loudness when the face speaks with ribt, else a stand-in envelope.
    let vl = face.voice.unwrap_or_else(|| voice(t));
    let talk_h = 1.0 + 0.1 * (vl - 0.5) * face.talk;
    let grow = 1.0 + 0.1 * face.listen + 0.05 * face.hear; // listening: the eyes open toward you

    for side in [-1.0f32, 1.0] {
        let mut e = eye_params(face.v, face.a);
        e.h *= talk_h * (1.0 + 0.6 * breathe);
        e.lid_in = sat(e.lid_in + 0.06 * face.think);
        e.lid_out = sat(e.lid_out + 0.06 * face.think);
        let near = 1.0 + 0.06 * face.gx * side;
        let cx = 0.5 + side * st.spacing + face.gx * 0.04;
        let cy = 0.49 + face.gy * 0.035 + breathe - 0.014 * face.talk * vl;
        let p = outline(
            &e,
            cx,
            cy,
            side,
            st,
            face.g,
            face.glyph,
            sx * near * grow,
            sy * near * grow,
        )
        .map(|(x, y)| u(x, y));
        let (x0, y0, x1, y1) = bounds(&p);
        let eye = |x: f32, y: f32| poly_sdf(&p, x, y);
        cv.fill_sdf(x0, y0, x1, y1, col, 1.0, eye);

        // Pupil: a big soft oval that travels further than the eye (that's what reads as looking
        // AT something), dilates while listening and sweeps side to side while thinking.
        let pv = 1.0 - face.g;
        if pv > 0.02 {
            let (ew, eh) = (e.w * st.size * grow * w, e.h * st.size * grow * w);
            let dil = face.pose.pupil * (1.0 + 0.3 * face.listen + 0.15 * face.hear);
            let scan = face.think * ((t * 1000.0 / 260.0) as f32 + side * 0.4).sin() * 0.3;
            let (pw, ph) = (ew * 0.52 * dil, eh * 0.4 * dil);
            let (ecx, ecy) = u(cx, cy);
            let (px, py) = (
                ecx + (face.gx * 0.3 + scan) * ew,
                ecy + face.gy * 0.24 * eh - face.think * 0.12 * eh - e.cheek * 0.28 * eh, // rides up on a happy cheek
            );
            let (hx, hy, r) = (pw / 2.0 - ph / 2.0, 0.0f32, ph / 2.0);
            cv.fill_sdf(
                px - pw / 2.0,
                py - ph / 2.0,
                px + pw / 2.0,
                py + ph / 2.0,
                BG,
                pv,
                |x, y| {
                    let (dx, dy) = (
                        ((x - px).abs() - hx).max(0.0),
                        ((y - py).abs() - hy).max(0.0),
                    );
                    ((dx * dx + dy * dy).sqrt() - r).max(eye(x, y))
                },
            );
        }
        // Blink: a translucent membrane sweeps up from below, frog-style.
        if bl > 0.01 {
            let top = y1 - (y1 - y0) * bl;
            cv.fill_sdf(x0, top, x1, y1, BG, 0.72, |x, y| (top - y).max(eye(x, y)));
        }
    }

    blush(cv, face, &u, w, col, st);
    lips(cv, face, &u, w, col, st.size);

    if st.glow {
        // Louder while listening and thinking: the glow pulses.
        let loud = 1.0
            + face.listen * (0.5 + 0.25 * (t * 1000.0 / 420.0).sin() as f32)
            + face.hear * 0.4
            + face.think * (0.35 + 0.35 * (t * 1000.0 / 260.0).sin() as f32);
        bloom(cv, (0.55 * loud).min(1.0), (w * 0.025) as usize);
    }
}

/// The blush: light, not paint. A wide faint halo, a body and a small warm core, its colour leaning toward the eyes'
/// glow, shaped like a cheek (long, tilted up at the outer end) under each eye, rising with a smiling cheek and
/// following the gaze. `face.blush` blooms in fast and fades slow.
fn blush(
    cv: &mut Canvas,
    face: &Face,
    u: &dyn Fn(f32, f32) -> (f32, f32),
    w: f32,
    col: Rgb,
    st: &Style,
) {
    let b = face.blush;
    if b < 0.01 {
        return;
    }
    let cheek = pos(face.v);
    for side in [-1.0f32, 1.0] {
        let (bx, by) = u(
            0.5 + side * (st.spacing + 0.062) + face.gx * 0.025,
            0.49 + (0.205 - 0.03 * cheek) * st.size + face.gy * 0.02,
        );
        let (rot_c, rot_s) = ((side * 0.16).cos(), (side * 0.16).sin());
        let reach = 0.095 * w;
        for y in (by - reach * 0.6) as i32..=(by + reach * 0.6) as i32 {
            for x in (bx - reach) as i32..=(bx + reach) as i32 {
                let (dx, dy) = (x as f32 + 0.5 - bx, y as f32 + 0.5 - by);
                // into the cheek's frame: rotated, squashed to half height
                let (ex, ey) = (dx * rot_c + dy * rot_s, (-dx * rot_s + dy * rot_c) / 0.5);
                let d = ex.hypot(ey) / w;
                for (r, a, m) in [
                    (0.095f32, 0.16f32, 0.3f32),
                    (0.055, 0.3, 0.12),
                    (0.028, 0.22, 0.0),
                ] {
                    let q = d / r;
                    if q >= 1.0 {
                        continue;
                    }
                    let fall = if q < 0.55 {
                        1.0 - 0.55 * q / 0.55
                    } else {
                        0.45 * (1.0 - q) / 0.45
                    };
                    cv.add(x, y, puck::canvas::lerp(BLUSH, col, m), a * b * fall);
                }
            }
        }
    }
}

/// The mouth: two lips of light, each a chain of droplets (face.lips, moved by springs in face.rs), drawn per pixel
/// as one metaball field: soft anti-aliased edges, a hotter core where it's thickest, a sheen along the top.
fn lips(
    cv: &mut Canvas,
    face: &Face,
    u: &dyn Fn(f32, f32) -> (f32, f32),
    w: f32,
    col: Rgb,
    size: f32,
) {
    let (mx, my) = (0.5, 0.49 + if cv.h > cv.w { 0.43 } else { 0.33 } * size);
    let speaking = face.talk > 0.05;
    let rest = (1.0 - face.talk - face.listen - face.think).clamp(0.0, 1.0);
    let lit = 0.55 + 0.45 * rest.max(face.talk.min(1.0));
    let p = &face.pose;
    let r0 = if speaking { 0.0105 } else { 0.0115 }
        * size
        * (1.0 - 0.32 * p.press)
        * (1.0 - 0.25 * p.round * if speaking { 0.0 } else { 1.0 })
        * w;
    let mut balls: Vec<(f32, f32, f32)> = Vec::with_capacity(2 * crate::face::LIPS);
    for lip in &face.lips {
        for (i, d) in lip.iter().enumerate() {
            let f = i as f32 / (crate::face::LIPS - 1) as f32 - 0.5;
            let r = r0 * (1.0 - 0.7 * f.abs()) * (1.0 + 0.15 * face.mouth);
            let (x, y) = u(mx + d.x * size, my + d.y * size);
            balls.push((x, y, r * r));
        }
    }
    let (x0, x1) = balls
        .iter()
        .fold((f32::MAX, f32::MIN), |b, q| (b.0.min(q.0), b.1.max(q.0)));
    let (y0, y1) = balls
        .iter()
        .fold((f32::MAX, f32::MIN), |b, q| (b.0.min(q.1), b.1.max(q.1)));
    let pad = r0 * 1.8;
    for y in (y0 - pad) as i32..=(y1 + pad) as i32 {
        for x in (x0 - pad) as i32..=(x1 + pad) as i32 {
            let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
            // squared falloff: droplets only fuse where they nearly touch, so parted lips show the dark between them
            let f: f32 = balls
                .iter()
                .map(|&(bx, by, r2)| {
                    let q = r2 / ((px - bx).powi(2) + (py - by).powi(2) + 0.5);
                    q * q
                })
                .sum::<f32>()
                .sqrt();
            if f < 0.55 {
                continue;
            }
            let e = ((f - 0.55) / 0.5).min(1.0);
            let a = e * e * (3.0 - 2.0 * e);
            let core = ((f - 1.2) * 0.35).clamp(0.0, 1.0); // hotter where it's thick
            cv.add(x, y, puck::canvas::lerp(col, [1.0; 3], core), a * lit);
        }
    }
    // the sheen: a soft highlight along the upper lip's top
    let top: Vec<(f32, f32)> = face.lips[0]
        .iter()
        .enumerate()
        .filter(|(i, _)| ((*i as f32 / (crate::face::LIPS - 1) as f32) - 0.5).abs() < 0.36)
        .map(|(_, d)| u(mx + d.x * size, my + d.y * size))
        .map(|(x, y)| (x, y - r0 * 0.55))
        .collect();
    for s in top.windows(2) {
        cv.line(
            s[0].0,
            s[0].1,
            s[1].0,
            s[1].1,
            0.003 * w,
            [1.0; 3],
            0.25 * lit,
        );
    }
}

/// Add a blurred copy of the frame back onto itself. The blur runs at quarter resolution (three box
/// passes, near enough a gaussian) so a 720×720 frame costs a few milliseconds on the Orin's CPU.
fn bloom(cv: &mut Canvas, amount: f32, radius: usize) {
    const S: usize = 4;
    let (w, h) = (cv.w.div_ceil(S), cv.h.div_ceil(S));
    let mut small = vec![[0.0f32; 3]; w * h];
    for y in 0..cv.h {
        for x in 0..cv.w {
            let (p, q) = (cv.px[y * cv.w + x], &mut small[(y / S) * w + x / S]);
            for c in 0..3 {
                q[c] += (p[c] - BG[c]).max(0.0) / (S * S) as f32;
            }
        }
    }
    let r = (radius / S).max(1);
    let mut tmp = small.clone();
    for _ in 0..3 {
        box_pass(&small, &mut tmp, w, h, r, true);
        box_pass(&tmp, &mut small, w, h, r, false);
    }
    for y in 0..cv.h {
        for x in 0..cv.w {
            let (fx, fy) = (
                (x as f32 + 0.5) / S as f32 - 0.5,
                (y as f32 + 0.5) / S as f32 - 0.5,
            );
            let (ix, iy) = (fx.floor().max(0.0) as usize, fy.floor().max(0.0) as usize);
            let (tx, ty) = (
                (fx - ix as f32).clamp(0.0, 1.0),
                (fy - iy as f32).clamp(0.0, 1.0),
            );
            let at = |x: usize, y: usize| small[y.min(h - 1) * w + x.min(w - 1)];
            let (a, b, c, d) = (
                at(ix, iy),
                at(ix + 1, iy),
                at(ix, iy + 1),
                at(ix + 1, iy + 1),
            );
            let p = &mut cv.px[y * cv.w + x];
            for k in 0..3 {
                let v = (a[k] * (1.0 - tx) + b[k] * tx) * (1.0 - ty)
                    + (c[k] * (1.0 - tx) + d[k] * tx) * ty;
                p[k] = (p[k] + v * amount).min(1.0);
            }
        }
    }
}

fn box_pass(
    src: &[[f32; 3]],
    dst: &mut [[f32; 3]],
    w: usize,
    h: usize,
    r: usize,
    horizontal: bool,
) {
    let (len, lines) = if horizontal { (w, h) } else { (h, w) };
    let idx = |line: usize, i: usize| {
        if horizontal {
            line * w + i
        } else {
            i * w + line
        }
    };
    let norm = 1.0 / (2 * r + 1) as f32;
    for line in 0..lines {
        let mut acc = [0.0f32; 3];
        let at = |i: isize| src[idx(line, i.clamp(0, len as isize - 1) as usize)];
        for i in -(r as isize)..=r as isize {
            let s = at(i);
            for c in 0..3 {
                acc[c] += s[c];
            }
        }
        for i in 0..len {
            dst[idx(line, i)] = acc.map(|a| a * norm);
            let (add, sub) = (at(i as isize + r as isize + 1), at(i as isize - r as isize));
            for c in 0..3 {
                acc[c] += add[c] - sub[c];
            }
        }
    }
}
