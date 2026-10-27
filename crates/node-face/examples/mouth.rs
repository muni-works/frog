//! The speaking mouth at six openings, side by side: `cargo run -p node-face --example mouth -- out.png`.

use node_face::draw::{self, Style};
use node_face::face::Face;
use puck::canvas::Canvas;

fn main() -> anyhow::Result<()> {
    let out = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "mouth.png".into());
    let (w, h, n) = (720usize, 720usize, 6usize);
    let (top, rows) = (430usize, 220usize); // the band of the frame the mouth is in
    let mut sheet = Canvas::new(w * 3 / 2, rows * 2);
    let mut cv = Canvas::new(w, h);
    for i in 0..n {
        let mut face = Face::new();
        face.a = 0.0;
        face.v = 0.35;
        face.gy = 0.0;
        face.talk = 1.0;
        face.mouth = (i as f32 + 0.5) / n as f32;
        draw::draw(&mut cv, &face, &Style::default(), 2.0 + i as f64 * 0.37);
        // half size, two rows of three
        let (ox, oy) = ((i % 3) * w / 2, (i / 3) * rows);
        for y in 0..rows {
            for x in 0..w / 2 {
                let mut s = [0.0f32; 3];
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let p = cv.px[(top + y / 2 * 2 + dy).min(h - 1) * w + x * 2 + dx];
                    for c in 0..3 {
                        s[c] += p[c] / 4.0;
                    }
                }
                sheet.px[(oy + y) * sheet.w + ox + x] = s;
            }
        }
    }
    sheet.save_png(std::path::Path::new(&out))
}
