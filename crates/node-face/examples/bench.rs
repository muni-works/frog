//! How long one frame takes to draw, without a window: idle and speaking, at a panel's size.
//! `cargo run --release -p node-face --example bench -- [720 720]`.

use node_face::draw::{self, Style};
use node_face::face::{Face, Mood};
use puck::canvas::Canvas;
use std::time::Instant;

fn main() {
    let a: Vec<usize> = std::env::args()
        .skip(1)
        .filter_map(|s| s.parse().ok())
        .collect();
    let (w, h) = (
        a.first().copied().unwrap_or(720),
        a.get(1).copied().unwrap_or(720),
    );
    let mut cv = Canvas::new(w, h);
    for (name, talk, glow) in [
        ("idle", 0.0, true),
        ("speaking", 1.0, true),
        ("speaking, no glow", 1.0, false),
    ] {
        let st = Style {
            glow,
            ..Style::default()
        };
        let mut face = Face::new();
        face.talk = talk;
        face.mouth = talk;
        face.phone = (talk > 0.0).then_some('ɑ');
        face.settle(
            if talk > 0.0 {
                Mood::Speaking
            } else {
                Mood::Idle
            },
            2.0,
        );
        let n = 60;
        let t0 = Instant::now();
        for i in 0..n {
            draw::draw(&mut cv, &face, &st, 2.0 + i as f64 / 60.0);
        }
        let ms = t0.elapsed().as_secs_f64() * 1e3 / n as f64;
        println!("{name}: {ms:.1} ms/frame at {w}x{h}");
    }
}
