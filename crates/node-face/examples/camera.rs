//! What the camera sees, twice a second for 10 s: where the nearest face is, as the face's gaze.
//! `cargo run --release -p node-face --features camera --example camera -- [INDEX]`.

use node_face::camera::{Eyes, default_model};
use std::time::Duration;

fn main() -> anyhow::Result<()> {
    let index = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let eyes = Eyes::spawn(index, default_model())?;
    for _ in 0..20 {
        std::thread::sleep(Duration::from_millis(500));
        match eyes.person() {
            Some((x, y)) => println!("person at x {x:+.2} y {y:+.2}"),
            None => println!("nobody"),
        }
    }
    Ok(())
}
