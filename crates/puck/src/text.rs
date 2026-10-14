//! Text: three faces, rasterized with fontdue and cached per glyph and size.

use crate::canvas::{Canvas, Rgb};
use fontdue::{Font, FontSettings, Metrics};
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Face {
    Regular,
    Bold,
    Mono,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Anchor {
    Start,
    Middle,
    End,
}

/// A rasterized glyph, keyed by face, character and size in quarter pixels.
type Glyphs = HashMap<(Face, char, u32), (Metrics, Vec<u8>)>;
/// A glyph's advance, keyed by face, character and the size's bits.
type Advances = HashMap<(Face, char, u32), f32>;
/// A finished `fit`, keyed by everything it was given.
type Fits = HashMap<(Face, Vec<u32>, String, u32, usize), (f32, Vec<String>)>;

/// Past this many remembered fits, start over: the text on the glass changes, and old fits are
/// never asked for again.
const FITS: usize = 64;

pub struct Fonts {
    faces: [Font; 3],
    cache: Mutex<Glyphs>,
    // Layout runs on every frame, and on the device once per band of every frame. Behind mutexes
    // so the device can draw bands on both cores from one `Fonts`.
    advances: Mutex<Advances>,
    fits: Mutex<Fits>,
}

impl Default for Fonts {
    fn default() -> Self {
        Self::new()
    }
}

impl Fonts {
    pub fn new() -> Self {
        let load =
            |b: &[u8]| Font::from_bytes(b, FontSettings::default()).expect("embedded font parses");
        // fontdue builds every glyph's outline up front: 9.5 MB for the full faces, more than the
        // device's PSRAM. `small-fonts` swaps in Latin-only subsets (assets/small, ~3 MB).
        macro_rules! face {
            ($f:literal) => {
                if cfg!(feature = "small-fonts") {
                    include_bytes!(concat!("../assets/small/", $f)).as_slice()
                } else {
                    include_bytes!(concat!("../assets/", $f)).as_slice()
                }
            };
        }
        Self {
            faces: [
                load(face!("Nunito-Regular.ttf")),
                load(face!("Nunito-Bold.ttf")),
                load(face!("JetBrainsMono-Medium.ttf")),
            ],
            cache: Mutex::default(),
            advances: Mutex::default(),
            fits: Mutex::default(),
        }
    }

    fn font(&self, f: Face) -> &Font {
        &self.faces[f as usize]
    }

    fn glyph<R>(
        &self,
        f: Face,
        ch: char,
        size: f32,
        use_it: impl FnOnce(&Metrics, &[u8]) -> R,
    ) -> R {
        let key = (f, ch, (size * 4.0) as u32);
        let mut cache = self.cache.lock().unwrap();
        let (m, bmp) = cache
            .entry(key)
            .or_insert_with(|| self.font(f).rasterize(ch, size));
        use_it(m, bmp)
    }

    pub fn width(&self, f: Face, size: f32, s: &str, spacing: f32) -> f32 {
        let n = s.chars().count() as f32;
        let mut adv = self.advances.lock().unwrap();
        s.chars()
            .map(|ch| {
                *adv.entry((f, ch, size.to_bits()))
                    .or_insert_with(|| self.font(f).metrics(ch, size).advance_width)
            })
            .sum::<f32>()
            + spacing * (n - 1.0).max(0.0)
    }

    /// Draw `s` with its baseline at `y`.
    #[allow(clippy::too_many_arguments)]
    pub fn draw(
        &self,
        cv: &mut Canvas,
        f: Face,
        size: f32,
        x: f32,
        y: f32,
        s: &str,
        anchor: Anchor,
        c: Rgb,
        a: f32,
        spacing: f32,
    ) {
        // Glyphs stay within a size above and half a size below the baseline; when the canvas
        // holds none of those rows (a band elsewhere on the glass), skip the layout too.
        let rows = cv.rows();
        if y + size * 0.5 < rows.start as f32 || y - size * 1.5 > rows.end as f32 {
            return;
        }
        let w = self.width(f, size, s, spacing);
        let mut pen = match anchor {
            Anchor::Start => x,
            Anchor::Middle => x - w / 2.0,
            Anchor::End => x - w,
        };
        for ch in s.chars() {
            self.glyph(f, ch, size, |m, bmp| {
                let gx = (pen + m.xmin as f32).round() as i32;
                let gy = (y - (m.height as i32 + m.ymin) as f32).round() as i32;
                for row in 0..m.height {
                    for col in 0..m.width {
                        let cov = bmp[row * m.width + col] as f32 / 255.0;
                        if cov > 0.0 {
                            cv.blend(gx + col as i32, gy + row as i32, c, a * cov);
                        }
                    }
                }
                pen += m.advance_width + spacing;
            });
        }
    }

    /// Greedy word wrap to `max` pixels. A word wider than a line is split by characters.
    pub fn wrap(&self, f: Face, size: f32, s: &str, max: f32) -> Vec<String> {
        let mut lines = Vec::new();
        let mut cur = String::new();
        for word in s.split_whitespace() {
            let try_ = if cur.is_empty() {
                word.to_string()
            } else {
                format!("{cur} {word}")
            };
            if self.width(f, size, &try_, 0.0) <= max {
                cur = try_;
                continue;
            }
            if !cur.is_empty() {
                lines.push(std::mem::take(&mut cur));
            }
            for ch in word.chars() {
                cur.push(ch);
                if self.width(f, size, &cur, 0.0) > max {
                    cur.pop();
                    lines.push(std::mem::take(&mut cur));
                    cur.push(ch);
                }
            }
        }
        if !cur.is_empty() {
            lines.push(cur);
        }
        lines
    }

    /// The largest size from `sizes` that fits `s` in `max_lines` lines of `max` pixels. Past the
    /// smallest size, the last line ends in an ellipsis.
    pub fn fit(
        &self,
        f: Face,
        sizes: &[f32],
        s: &str,
        max: f32,
        max_lines: usize,
    ) -> (f32, Vec<String>) {
        let key = (
            f,
            sizes.iter().map(|s| s.to_bits()).collect(),
            s.to_string(),
            max.to_bits(),
            max_lines,
        );
        if let Some(hit) = self.fits.lock().unwrap().get(&key) {
            return hit.clone();
        }
        let fit = self.fit_uncached(f, sizes, s, max, max_lines);
        let mut fits = self.fits.lock().unwrap();
        if fits.len() >= FITS {
            fits.clear();
        }
        fits.insert(key, fit.clone());
        fit
    }

    fn fit_uncached(
        &self,
        f: Face,
        sizes: &[f32],
        s: &str,
        max: f32,
        max_lines: usize,
    ) -> (f32, Vec<String>) {
        for &size in sizes {
            let lines = self.wrap(f, size, s, max);
            if lines.len() <= max_lines {
                return (size, lines);
            }
        }
        let size = *sizes.last().unwrap_or(&16.0);
        let mut lines = self.wrap(f, size, s, max);
        lines.truncate(max_lines);
        if let Some(last) = lines.last_mut() {
            while !last.is_empty() && self.width(f, size, &format!("{last}…"), 0.0) > max {
                last.pop();
            }
            last.push('…');
        }
        (size, lines)
    }
}
