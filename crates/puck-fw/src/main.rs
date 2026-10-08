mod display;

use display::{Display, W};
use puck::canvas::Canvas;
use std::time::Instant;

/// Big-endian RGB565 for `rows` rows of the canvas starting at `y0`.
fn to_565(cv: &Canvas, y0: usize, rows: usize, out: &mut [u8]) {
    let src = &cv.px[y0 * W..(y0 + rows) * W];
    for (p, o) in src.iter().zip(out.chunks_exact_mut(2)) {
        let [r, g, b] = p.map(|v| v.clamp(0.0, 1.0));
        let v = ((r * 31.0 + 0.5) as u16) << 11 | ((g * 63.0 + 0.5) as u16) << 5 | (b * 31.0 + 0.5) as u16;
        o.copy_from_slice(&v.to_be_bytes());
    }
}

fn main() {
    esp_idf_svc::sys::link_patches();
    esp_idf_svc::log::EspLogger::initialize_default();
    let mut lcd = Display::new();
    let ui = puck::ui::Ui::new();
    let mut p = puck::model::Puck::new("~/frog", "your Mac");
    let mut eyes = puck::eyes::Eyes::new();
    let mut cv = Canvas::new(W, display::H);
    // Past the boot animation, idle and looking ahead.
    let t = 6.0;
    p.tick(t);
    eyes.step(1.0);
    let s = Instant::now();
    ui.draw(&mut cv, &p, &eyes, t);
    let draw = s.elapsed();
    let s = Instant::now();
    lcd.frame(|y, rows, out| to_565(&cv, y, rows, out));
    log::info!("one frame: draw {draw:?}, convert+push {:?}", s.elapsed());
    loop {
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}
