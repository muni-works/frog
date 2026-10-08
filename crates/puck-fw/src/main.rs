mod display;

use display::Display;

fn main() {
    esp_idf_svc::sys::link_patches();
    esp_idf_svc::log::EspLogger::initialize_default();
    log::info!("frog puck: panel bring-up");
    let mut lcd = Display::new();
    // red, green, blue, white: checks the byte order and the colour order at a glance
    let colors: [u16; 4] = [0xF800, 0x07E0, 0x001F, 0xFFFF];
    for c in colors.iter().cycle() {
        let t = std::time::Instant::now();
        lcd.frame(|_, _, out| {
            for px in out.chunks_exact_mut(2) {
                px.copy_from_slice(&c.to_be_bytes());
            }
        });
        log::info!("fill {c:04x} in {:?}", t.elapsed());
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}
