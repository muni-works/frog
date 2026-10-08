//! A framebuffer with anti-aliased shapes drawn from signed distance functions.
//!
//! Coordinates are glass pixels (0..466); `origin` shifts them, so the simulator can draw the
//! glass inside a larger window with a bezel around it.

// Drawing primitives take a shape, a color and an alpha; bundling them would only add noise.
#![allow(clippy::too_many_arguments)]

pub type Rgb = [f32; 3];

pub const fn hex(c: u32) -> Rgb {
    [
        ((c >> 16) & 0xff) as f32 / 255.0,
        ((c >> 8) & 0xff) as f32 / 255.0,
        (c & 0xff) as f32 / 255.0,
    ]
}

pub fn lerp(a: Rgb, b: Rgb, t: f32) -> Rgb {
    [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    ]
}

pub struct Canvas {
    pub w: usize,
    pub h: usize,
    pub px: Vec<Rgb>,
    pub origin: (f32, f32),
}

impl Canvas {
    pub fn new(w: usize, h: usize) -> Self {
        Self {
            w,
            h,
            px: vec![[0.0; 3]; w * h],
            origin: (0.0, 0.0),
        }
    }

    pub fn clear(&mut self, c: Rgb) {
        self.px.fill(c);
    }

    /// Alpha-blend `c` over the pixel at glass coordinates (`x`, `y`).
    #[inline]
    pub fn blend(&mut self, x: i32, y: i32, c: Rgb, a: f32) {
        let (x, y) = (x + self.origin.0 as i32, y + self.origin.1 as i32);
        if a <= 0.0 || x < 0 || y < 0 || x as usize >= self.w || y as usize >= self.h {
            return;
        }
        let p = &mut self.px[y as usize * self.w + x as usize];
        let a = a.min(1.0);
        *p = [
            p[0] + (c[0] - p[0]) * a,
            p[1] + (c[1] - p[1]) * a,
            p[2] + (c[2] - p[2]) * a,
        ];
    }

    /// Add light: how the rim glow lands on the black glass.
    #[inline]
    pub fn add(&mut self, x: i32, y: i32, c: Rgb, a: f32) {
        let (x, y) = (x + self.origin.0 as i32, y + self.origin.1 as i32);
        if a <= 0.0 || x < 0 || y < 0 || x as usize >= self.w || y as usize >= self.h {
            return;
        }
        let p = &mut self.px[y as usize * self.w + x as usize];
        *p = [
            (p[0] + c[0] * a).min(1.0),
            (p[1] + c[1] * a).min(1.0),
            (p[2] + c[2] * a).min(1.0),
        ];
    }

    /// Fill everything where `sdf` < 0 inside the box, with one pixel of anti-aliasing.
    pub fn fill_sdf(
        &mut self,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        c: Rgb,
        a: f32,
        sdf: impl Fn(f32, f32) -> f32,
    ) {
        for y in (y0.floor() as i32 - 1)..=(y1.ceil() as i32 + 1) {
            for x in (x0.floor() as i32 - 1)..=(x1.ceil() as i32 + 1) {
                let cov = (0.5 - sdf(x as f32 + 0.5, y as f32 + 0.5)).clamp(0.0, 1.0);
                if cov > 0.0 {
                    self.blend(x, y, c, a * cov);
                }
            }
        }
    }

    pub fn circle(&mut self, cx: f32, cy: f32, r: f32, c: Rgb, a: f32) {
        self.fill_sdf(cx - r, cy - r, cx + r, cy + r, c, a, |x, y| {
            ((x - cx).hypot(y - cy)) - r
        });
    }

    pub fn ellipse(&mut self, cx: f32, cy: f32, rx: f32, ry: f32, c: Rgb, a: f32) {
        // Scaled-circle distance: exact enough for one pixel of edge.
        self.fill_sdf(cx - rx, cy - ry, cx + rx, cy + ry, c, a, |x, y| {
            let (u, v) = ((x - cx) / rx, (y - cy) / ry);
            ((u * u + v * v).sqrt() - 1.0) * rx.min(ry)
        });
    }

    pub fn rrect(&mut self, x: f32, y: f32, w: f32, h: f32, r: f32, c: Rgb, a: f32) {
        let (cx, cy, hx, hy) = (x + w / 2.0, y + h / 2.0, w / 2.0 - r, h / 2.0 - r);
        self.fill_sdf(x, y, x + w, y + h, c, a, |px, py| {
            let (dx, dy) = (
                ((px - cx).abs() - hx).max(0.0),
                ((py - cy).abs() - hy).max(0.0),
            );
            dx.hypot(dy) - r
        });
    }

    /// A round-capped stroke.
    pub fn line(&mut self, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, c: Rgb, a: f32) {
        let r = width / 2.0;
        let (dx, dy) = (x1 - x0, y1 - y0);
        let len2 = (dx * dx + dy * dy).max(1e-6);
        self.fill_sdf(
            x0.min(x1) - r,
            y0.min(y1) - r,
            x0.max(x1) + r,
            y0.max(y1) + r,
            c,
            a,
            |px, py| {
                let t = (((px - x0) * dx + (py - y0) * dy) / len2).clamp(0.0, 1.0);
                (px - (x0 + t * dx)).hypot(py - (y0 + t * dy)) - r
            },
        );
    }

    /// 0x00RRGGBB per pixel, as minifb wants.
    pub fn to_u32(&self, out: &mut Vec<u32>) {
        out.clear();
        out.extend(self.px.iter().map(|p| {
            let [r, g, b] = p.map(|v| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u32);
            (r << 16) | (g << 8) | b
        }));
    }

    pub fn to_rgb8(&self) -> Vec<u8> {
        self.px
            .iter()
            .flat_map(|p| p.map(|v| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8))
            .collect()
    }

    #[cfg(feature = "host")]
    pub fn save_png(&self, path: &std::path::Path) -> anyhow::Result<()> {
        let f = std::io::BufWriter::new(std::fs::File::create(path)?);
        let mut enc = png::Encoder::new(f, self.w as u32, self.h as u32);
        enc.set_color(png::ColorType::Rgb);
        enc.set_depth(png::BitDepth::Eight);
        enc.write_header()?.write_image_data(&self.to_rgb8())?;
        Ok(())
    }
}
