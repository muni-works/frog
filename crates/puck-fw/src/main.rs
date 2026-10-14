mod board;
mod display;
mod worker;

use display::{Display, STRIP, W};
use puck::canvas::Canvas;
use board::Input;
use esp_idf_svc::hal::gpio::{PinDriver, Pull};
use puck::demo::{self, Player, Sim};
use puck::touch::Touch;
use std::time::{Duration, Instant};

/// Big-endian RGB565 for the first `rows` rows of the band.
fn to_565(band: &Canvas, rows: usize, out: &mut [u8]) {
    // Canvas pixels stay within 0..=1 (blend lerps between colors, add clamps), so the only
    // guard needed is against rounding past the top.
    #[inline(always)]
    fn q(v: f32, max: f32) -> u16 {
        (unsafe { (v * max + 0.5).to_int_unchecked::<u32>() }).min(max as u32) as u16
    }
    let out: &mut [[u8; 2]] =
        unsafe { std::slice::from_raw_parts_mut(out.as_mut_ptr().cast(), out.len() / 2) };
    for (p, o) in band.px[..rows * W].iter().zip(out) {
        *o = (q(p[0], 31.0) << 11 | q(p[1], 63.0) << 5 | q(p[2], 31.0)).to_be_bytes();
    }
}

/// Rows each core draws per strip.
const HALF: usize = STRIP / 2;

/// A canvas half a strip tall, in internal RAM: drawing into PSRAM is several times slower.
fn band() -> Canvas {
    let n = W * HALF;
    let bytes = n * std::mem::size_of::<puck::canvas::Rgb>();
    let caps = esp_idf_svc::sys::MALLOC_CAP_INTERNAL | esp_idf_svc::sys::MALLOC_CAP_8BIT;
    let p = unsafe { esp_idf_svc::sys::heap_caps_malloc(bytes, caps) } as *mut puck::canvas::Rgb;
    assert!(!p.is_null(), "band canvas");
    let mut cv = Canvas::new(0, 0);
    // The global allocator is malloc/free, so a Vec may own heap_caps memory.
    cv.px = unsafe {
        std::ptr::write_bytes(p, 0, n);
        Vec::from_raw_parts(p, n, n)
    };
    (cv.w, cv.h) = (W, HALF);
    cv
}

/// Draw glass rows `y..y + rows` through `band` and convert them into `out`.
pub fn draw_rows(band: &mut Canvas, sim: &Sim, y: usize, rows: usize, out: &mut [u8]) {
    band.origin = (0.0, -(y as f32));
    sim.ui.draw(band, &sim.puck, &sim.eyes, sim.t);
    to_565(band, rows, out);
}

/// The demo's sim, with the eyes stepped at a rate the device can keep up with.
fn new_sim() -> Sim {
    let mut sim = Sim::new("~/frog", "your Mac");
    sim.eyes = puck::eyes::Eyes::with_rate(EYES_HZ);
    sim
}

/// f64 is software on the S3: one step of both pendulums is ~4 ms.
const EYES_HZ: f64 = 60.0;

/// Running totals for one stage of the frame, reported as a mean.
#[derive(Default)]
struct Timer(Duration, u32);

impl Timer {
    fn time<R>(&mut self, f: impl FnOnce() -> R) -> R {
        let s = Instant::now();
        let r = f();
        self.0 += s.elapsed();
        self.1 += 1;
        r
    }

    fn take(&mut self) -> f32 {
        let ms = self.0.as_secs_f32() * 1000.0 / self.1.max(1) as f32;
        *self = Self::default();
        ms
    }
}

fn main() {
    esp_idf_svc::sys::link_patches();
    esp_idf_svc::log::EspLogger::initialize_default();
    let p = esp_idf_svc::hal::peripherals::Peripherals::take().expect("peripherals");
    let bus = board::Bus::new(p.i2c0, p.pins.gpio15.into(), p.pins.gpio14.into());
    let touch_rst = PinDriver::output(p.pins.gpio40).expect("touch reset");
    let boot = PinDriver::input(p.pins.gpio0, Pull::Up).expect("boot button");
    let inputs = board::spawn(bus, touch_rst, boot);
    let mut touch = Touch::default();
    let mut finger = None;
    // The scripted turn plays until someone touches the puck.
    let mut scripted = true;
    let mut band = band();
    let worker = worker::Worker::spawn(self::band());
    let mut lcd = Display::new();
    let mut sim = new_sim();
    let bands = display::H.div_ceil(STRIP) as f32;
    let mut player = Player::new(demo::script());
    let [mut physics, mut draw, mut frame] = [(); 3].map(|_| Timer::default());
    let mut last = Instant::now();
    let mut report = Instant::now();
    let mut frames = 0;
    loop {
        let dt = last.elapsed().as_secs_f64().min(0.1);
        last = Instant::now();
        let now = sim.t;
        let mut ops = Vec::new();
        for i in inputs.try_iter() {
            match i {
                Input::Touch(f) => {
                    log::info!("touch {f:?} ({:?})", sim.puck.mode);
                    scripted = false;
                    finger = f;
                    ops.extend(touch.update(&mut sim.puck, f, now));
                }
                Input::Motion(down, shake) => (sim.down, sim.shake) = (down, shake),
                Input::Button => {
                    scripted = false;
                    ops.extend(sim.puck.approve());
                }
            }
        }
        // Again with nothing new, so a held finger can count as a hold.
        ops.extend(touch.update(&mut sim.puck, finger, now));
        for op in ops {
            // No bridge to frog yet.
            log::info!("op: {op}");
        }
        if scripted {
            player.run(&mut sim);
        }
        physics.time(|| sim.step(dt));
        // Each strip is drawn into the band, then sent while the next one draws.
        let s = Instant::now();
        lcd.frame(|y, rows, out| {
            // The top half of the strip draws here, the bottom half on the other core.
            draw.time(|| {
                let top = rows.min(HALF);
                let (out_a, out_b) = out.split_at_mut(W * top * 2);
                let other = rows > top;
                if other {
                    // SAFETY: `sim` and `out_b` aren't touched again until `wait`.
                    unsafe { worker.start(&sim, y + top, rows - top, out_b) };
                }
                draw_rows(&mut band, &sim, y, top, out_a);
                if other {
                    worker.wait();
                }
            });
        });
        frame.0 += s.elapsed();
        frame.1 += 1;
        frames += 1;
        // Let the idle task run: without it the USB-Serial-JTAG stops answering espflash's reset.
        std::thread::sleep(Duration::from_millis(1));
        if report.elapsed() >= Duration::from_secs(2) {
            let fps = frames as f32 / report.elapsed().as_secs_f32();
            log::info!(
                "t={:5.1} {:?}: {fps:4.1} fps · physics {:5.1} · draw+convert {:5.1} · frame {:5.1} ms (per frame)",
                sim.t,
                sim.puck.mode,
                physics.take(),
                draw.take() * bands,
                frame.take()
            );
            (frames, report) = (0, Instant::now());
        }
        // Once the script has played out, start over.
        if scripted && player.done() && sim.t > 38.0 {
            sim = new_sim();
            player = Player::new(demo::script());
        }
    }
}
