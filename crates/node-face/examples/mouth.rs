//! Every emotion's face, settled, plus the speaking mouth quiet to loud:
//! `cargo run -p node-face --example mouth -- out.png`.

use node_face::draw::{self, Style};
use node_face::face::{Face, Mood};
use puck::canvas::Canvas;

const MOODS: [(Mood, f32, f32); 12] = [
    (Mood::Idle, 0.0, 0.0),
    (Mood::Listening, 0.2, 0.5),
    (Mood::Thinking, 0.0, 0.2),
    (Mood::Happy, 0.9, 0.45),
    (Mood::Delighted, 1.0, 0.9),
    (Mood::Surprised, 0.2, 1.0),
    (Mood::Annoyed, -0.7, 0.6),
    (Mood::Sad, -0.75, -0.4),
    (Mood::Sleepy, 0.05, -1.0),
    (Mood::Focused, 0.0, -0.2),
    (Mood::Love, 1.0, 0.4),
    (Mood::Done, 0.7, 0.2),
];

fn main() -> anyhow::Result<()> {
    let out = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "mouth.png".into());
    let (w, h, cols, scale) = (720usize, 720usize, 6usize, 3usize);
    let n = MOODS.len() + 10;
    let (tw, th) = (w / scale, h / scale);
    let mut sheet = Canvas::new(tw * cols, th * n.div_ceil(cols));
    let mut cv = Canvas::new(w, h);
    for i in 0..n {
        let mut face = Face::new();
        if let Some(&(m, v, a)) = MOODS.get(i) {
            face.v = v;
            face.a = a;
            face.listen = (m == Mood::Listening) as u8 as f32;
            face.think = (m == Mood::Thinking) as u8 as f32;
            face.settle(m, 2.0);
        } else {
            // speaking, quiet to loud
            face.v = 0.35;
            face.a = 0.25;
            face.talk = 1.0;
            // quiet to loud, then phonemes at speaking volume: "ah", "ee", "oo", "m", "f", "oh", "s"
            let k = i - MOODS.len();
            face.mouth = [0.2, 0.6, 1.0, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8][k];
            face.phone = [
                None,
                None,
                None,
                Some('ɑ'),
                Some('i'),
                Some('u'),
                Some('m'),
                Some('f'),
                Some('O'),
                Some('s'),
            ][k];
            face.settle(Mood::Speaking, 2.0);
        }
        draw::draw(&mut cv, &face, &Style::default(), 2.0);
        let (ox, oy) = ((i % cols) * tw, (i / cols) * th);
        for y in 0..th {
            for x in 0..tw {
                let mut s = [0.0f32; 3];
                for dy in 0..scale {
                    for dx in 0..scale {
                        let p = cv.px[(y * scale + dy) * w + x * scale + dx];
                        for c in 0..3 {
                            s[c] += p[c] / (scale * scale) as f32;
                        }
                    }
                }
                sheet.px[(oy + y) * sheet.w + ox + x] = s;
            }
        }
    }
    sheet.save_png(std::path::Path::new(&out))
}
