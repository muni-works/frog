//! `--style pixel`: the face as hand-placed sprites on a coarse LED grid, like a Tamagotchi.
//!
//! The smooth face drawn small reads as a blurry shape; this is drawn for the grid instead. Each mood has its own
//! eye and mouth sprites, a blink steps through frames, the gaze moves a whole pixel at a time, and the glow is a
//! checkerboard ring of dim pixels. The sprites were settled in a mockup (the pixel face sprite mockup).

use crate::face::{Face, Glyph, Mood};

/// Pixels across the panel: the grid's resolution, whatever the panel's size.
pub const COLS: usize = 32;

/// Shades, darkest first: [empty cell, glow, -, -, lit]. Mint, after the smooth face's color.
pub const MINT: [u32; 5] = [0x0a0d12, 0x17463a, 0x2f8f72, 0x5fe0b4, 0xb8ffe6];
const BG: u32 = 0x05070a;

type Sprite = &'static [&'static str];

const EYE_OPEN: Sprite = &[
    "..####..", ".######.", "########", "########", "########", "########", "########", "########",
    ".######.", "..####..",
];
const EYE_WIDE: Sprite = &[
    ".######.", "########", "########", "########", "########", "########", "########", "########",
    "########", ".######.",
];
const EYE_HALF: Sprite = &[
    "........", "........", "........", ".######.", "########", "########", ".######.", "........",
    "........", "........",
];
const EYE_SHUT: Sprite = &[
    "........", "........", "........", "........", "........", "########", ".######.", "........",
    "........", "........",
];
const EYE_HAPPY: Sprite = &[
    "........", "........", "..####..", ".######.", "###..###", "##....##", "#......#", "........",
    "........", "........",
];
const EYE_THINK: Sprite = &[
    "........", "........", ".######.", "########", "########", "########", ".######.", "........",
    "........", "........",
];
const EYE_SAD: Sprite = &[
    "........", "........", ".....##.", "...####.", ".#######", "########", "########", ".######.",
    "........", "........",
];
const EYE_LOVE: Sprite = &[
    "........", ".##..##.", "########", "########", "########", ".######.", "..####..", "...##...",
    "........", "........",
];
const STAR: Sprite = &[
    "...##...", "...##...", "..####..", "########", ".######.", "..####..", ".##..##.", ".#....#.",
    "........", "........",
];
const CHECK: Sprite = &[
    "........", "........", ".......#", "......##", "#....##.", "##..##..", ".####...", "..##....",
    "........", "........",
];
const CROSS: Sprite = &[
    "........", "##....##", ".##..##.", "..####..", "...##...", "..####..", ".##..##.", "##....##",
    "........", "........",
];
const DIAMOND: Sprite = &[
    "...##...", "..####..", ".######.", "########", "########", ".######.", "..####..", "...##...",
    "........", "........",
];

const MOUTH_REST: Sprite = &[
    "............",
    "............",
    "...######...",
    "............",
];
const MOUTH_SMILE: Sprite = &[
    "............",
    ".#........#.",
    "..########..",
    "............",
];
const MOUTH_FROWN: Sprite = &[
    "............",
    "..########..",
    ".#........#.",
    "............",
];
const MOUTH_AH: Sprite = &[
    "...######...",
    "..########..",
    "..########..",
    "...######...",
];
const MOUTH_EH: Sprite = &[
    "............",
    "...######...",
    "...######...",
    "............",
];
const MOUTH_EE: Sprite = &[
    "............",
    ".##########.",
    ".##########.",
    "............",
];
const MOUTH_OO: Sprite = &[
    "....####....",
    "...######...",
    "...######...",
    "....####....",
];
const MOUTH_MM: Sprite = &[
    "............",
    "....####....",
    "............",
    "............",
];
const Z: Sprite = &["###", "..#", ".#.", "###"];

/// The eyes a mood wears.
fn eyes(mood: Mood) -> Sprite {
    match mood {
        Mood::Listening | Mood::Surprised => EYE_WIDE,
        Mood::Thinking => EYE_THINK,
        Mood::Happy | Mood::Delighted | Mood::Done => EYE_HAPPY,
        Mood::Sad => EYE_SAD,
        Mood::Annoyed => EYE_HALF,
        Mood::Sleepy => EYE_SHUT,
        Mood::Love => EYE_LOVE,
        Mood::Idle | Mood::Focused | Mood::Speaking => EYE_OPEN,
    }
}

/// The mouth: while the voice plays, the sound under the playhead picks the shape (snapping, as a sprite
/// would); otherwise the mood's.
fn mouth(face: &Face) -> Sprite {
    if face.voice.is_some() || face.talk > 0.5 {
        let (hiss, dark) = face.sound.unwrap_or((0.0, 0.0));
        return match face.mouth {
            m if m < 0.12 => MOUTH_MM,
            _ if dark > 0.5 => MOUTH_OO,
            _ if hiss > 0.5 => MOUTH_EE,
            m if m < 0.45 => MOUTH_EH,
            _ => MOUTH_AH,
        };
    }
    match face.mood {
        Mood::Happy | Mood::Delighted | Mood::Love | Mood::Done => MOUTH_SMILE,
        Mood::Sad | Mood::Annoyed => MOUTH_FROWN,
        Mood::Surprised => MOUTH_OO,
        Mood::Sleepy | Mood::Thinking => MOUTH_MM,
        _ => MOUTH_REST,
    }
}

/// A blink in frames, open -> half -> shut -> shut -> half, every 4.4 s.
fn blink(t: f64) -> Option<Sprite> {
    match ((t % 4.4) * 12.0) as u32 {
        0 | 3 => Some(EYE_HALF),
        1 | 2 => Some(EYE_SHUT),
        _ => None,
    }
}

fn stamp(s: Sprite, ox: i32, oy: i32, lvl: u8, buf: &mut [u8], (gw, gh): (usize, usize)) {
    for (y, row) in s.iter().enumerate() {
        for (x, c) in row.bytes().enumerate() {
            let (x, y) = (ox + x as i32, oy + y as i32);
            if c == b'#' && x >= 0 && y >= 0 && (x as usize) < gw && (y as usize) < gh {
                let p = &mut buf[y as usize * gw + x as usize];
                *p = (*p).max(lvl);
            }
        }
    }
}

/// Draw `face` at time `t` into `out`, the panel's `w`x`h` pixels (0x00RRGGBB).
pub fn draw(face: &Face, t: f64, (w, h): (usize, usize), out: &mut Vec<u32>) {
    let n = (w / COLS).max(1);
    let (gw, gh) = (w / n, h / n);
    let mut buf = vec![0u8; gw * gh];
    let g = (gw, gh);
    // the gaze in whole pixels: the eyes shift a little, the pupils inside them more
    let (ex, ey) = (face.gx.round() as i32, (face.gy * 0.75).round() as i32);
    let (px, py) = (
        ((face.gx * 2.0).round() as i32).clamp(-2, 2),
        ((face.gy * 2.0).round() as i32).clamp(-2, 2),
    );
    let (cx, top) = (gw as i32 / 2, (gh as i32 - 18) / 2 + ey);
    let gap = (gw as i32 * 12 / 100).max(4);
    let eye = match face.glyph {
        _ if face.g < 0.5 => blink(t)
            .filter(|_| {
                !matches!(
                    face.mood,
                    Mood::Sleepy | Mood::Happy | Mood::Delighted | Mood::Love | Mood::Done
                )
            })
            .unwrap_or_else(|| eyes(face.mood)),
        Glyph::Heart => EYE_LOVE,
        Glyph::Star => STAR,
        Glyph::Check => CHECK,
        Glyph::Cross => CROSS,
        Glyph::Diamond => DIAMOND,
        Glyph::None => eyes(face.mood),
    };
    stamp(eye, cx - gap - 8 + ex, top, 4, &mut buf, g);
    stamp(eye, cx + gap + ex, top, 4, &mut buf, g);
    stamp(mouth(face), cx - 6 + ex / 2, top + 14, 4, &mut buf, g);
    if face.mood == Mood::Sleepy {
        let k = (t * 2.0) as i32 % 3;
        for i in 0..=k {
            stamp(
                Z,
                cx + gap + 10 + i * 3,
                top - 3 - i * 4,
                if i == k { 3 } else { 2 },
                &mut buf,
                g,
            );
        }
    }
    // the glow: a dotted ring of dim cells around anything lit
    let lit = buf.clone();
    for y in 0..gh {
        for x in 0..gw {
            if lit[y * gw + x] > 0 {
                continue;
            }
            let mut near = 0;
            for (dx, dy) in [
                (-1, -1),
                (0, -1),
                (1, -1),
                (-1, 0),
                (1, 0),
                (-1, 1),
                (0, 1),
                (1, 1),
            ] {
                let (x, y) = (x as i32 + dx, y as i32 + dy);
                if x >= 0
                    && y >= 0
                    && (x as usize) < gw
                    && (y as usize) < gh
                    && lit[y as usize * gw + x as usize] >= 3
                {
                    near += 1;
                }
            }
            if near > 2 || (near > 0 && (x + y) % 2 == 1) {
                buf[y * gw + x] = 1;
            }
        }
    }
    // the pupils, carved dark out of the lit eye after the glow so they stay dark; dilated up close and by mood
    if face.g < 0.5
        && [EYE_OPEN, EYE_WIDE, EYE_THINK, EYE_SAD, EYE_HALF]
            .iter()
            .any(|e| std::ptr::eq(*e, eye))
    {
        let size = face.pose.pupil * (1.0 + 0.18 * face.closeness);
        let (pw, ph) = match size {
            s if s > 1.08 => (3, 4),
            s if s < 0.85 => (2, 2),
            _ => (2, 3),
        };
        for ox in [cx - gap - 8 + ex, cx + gap + ex] {
            let (x0, y0) = (ox + 4 - pw / 2 + px, top + 5 - ph / 2 + py);
            for y in y0..y0 + ph {
                for x in x0..x0 + pw {
                    if x >= 0
                        && y >= 0
                        && (x as usize) < gw
                        && (y as usize) < gh
                        && buf[y as usize * gw + x as usize] == 4
                    {
                        buf[y as usize * gw + x as usize] = 0;
                    }
                }
            }
        }
    }
    // up to the panel: n x n cells with a dark seam, centred
    out.clear();
    out.resize(w * h, BG);
    let (ox, oy) = ((w - gw * n) / 2, (h - gh * n) / 2);
    let seam = (n / 8).max(2);
    for y in 0..gh * n {
        let row = &mut out[(oy + y) * w + ox..][..gw * n];
        if y % n >= n - seam {
            continue;
        }
        for (x, o) in row.iter_mut().enumerate() {
            if x % n < n - seam {
                *o = MINT[buf[(y / n) * gw + x / n] as usize];
            }
        }
    }
}
