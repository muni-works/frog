//! Everything on the board's I²C bus except the display: touch, motion sensor, the power button
//! (read through the IO expander), and the audio codec's control port.
//!
//! Addresses and pins from Waveshare's BSP for this board; the touch protocol from SensorLib's
//! `TouchDrvCST92xx`.

use esp_idf_svc::hal::delay::BLOCK;
use esp_idf_svc::hal::gpio::{self, AnyIOPin, Output, PinDriver};
use esp_idf_svc::hal::i2c::{I2C0, I2cConfig, I2cDriver};
use esp_idf_svc::hal::units::Hertz;
use std::sync::mpsc::{Receiver, channel};
use std::time::Duration;

pub const TOUCH: u8 = 0x5A;
pub const IMU: u8 = 0x6B;
pub const EXPANDER: u8 = 0x20;
pub const CODEC: u8 = 0x18;

/// What the input thread reports, as it changes.
pub enum Input {
    /// The finger, in glass pixels, or `None` once lifted.
    Touch(Option<(f32, f32)>),
    /// Gravity's direction and the hand's acceleration in g, both in the device frame.
    Motion([f64; 3], [f64; 3]),
    /// The side (power) button or BOOT went down.
    Button,
}

pub struct Bus(pub I2cDriver<'static>);

impl Bus {
    pub fn new(i2c: I2C0<'static>, sda: AnyIOPin<'static>, scl: AnyIOPin<'static>) -> Self {
        let cfg = I2cConfig::new().baudrate(Hertz(400_000));
        Self(I2cDriver::new(i2c, sda, scl, &cfg).expect("i2c"))
    }

    pub fn write(&mut self, addr: u8, bytes: &[u8]) -> bool {
        self.0.write(addr, bytes, BLOCK).is_ok()
    }

    pub fn read(&mut self, addr: u8, reg: &[u8], out: &mut [u8]) -> bool {
        self.0.write_read(addr, reg, out, BLOCK).is_ok()
    }
}

/// CST9217: up to two fingers; we follow the first.
fn touch(bus: &mut Bus) -> Option<Option<(f32, f32)>> {
    let mut b = [0u8; 2 * 5 + 5];
    if !bus.read(TOUCH, &[0xD0, 0x00], &mut b) {
        return None;
    }
    // Acknowledge the read, or the controller holds the same report.
    bus.write(TOUCH, &[0xD0, 0x00, 0xAB]);
    if b[0] == 0xAB || b[6] != 0xAB || b[0] == 0 {
        return Some(None);
    }
    let n = b[5] & 0x7F;
    let (event, x, y) = (
        b[0] & 0x0F,
        (b[1] as u16) << 4 | (b[3] >> 4) as u16,
        (b[2] as u16) << 4 | (b[3] & 0x0F) as u16,
    );
    // Event 6 is "pressed".
    Some((n > 0 && event == 0x06).then_some((x as f32, y as f32)))
}

/// QMI8658: accelerometer only, ±4 g at 250 Hz.
fn imu_init(bus: &mut Bus) -> bool {
    let mut who = [0u8];
    if !bus.read(IMU, &[0x00], &mut who) || who[0] != 0x05 {
        log::warn!("motion sensor: WHO_AM_I {:#x}, expected 0x05", who[0]);
        return false;
    }
    bus.write(IMU, &[0x02, 0x40]) // CTRL1: register auto-increment
        && bus.write(IMU, &[0x03, 0x15]) // CTRL2: ±4 g, 250 Hz
        && bus.write(IMU, &[0x08, 0x01]) // CTRL7: accelerometer on
}

/// Acceleration in g, in the sensor's frame.
fn imu_read(bus: &mut Bus) -> Option<[f64; 3]> {
    let mut b = [0u8; 6];
    bus.read(IMU, &[0x35], &mut b).then(|| {
        [0, 1, 2].map(|i| i16::from_le_bytes([b[2 * i], b[2 * i + 1]]) as f64 / 8192.0)
    })
}

/// The sensor's axes in the device frame (x right, y up the glass, z out of the glass).
/// Checked on the board by tilting it; see the README.
fn to_device(a: [f64; 3]) -> [f64; 3] {
    [a[0], a[1], a[2]]
}

/// The power button's level, through the TCA9554 (P4, high while pressed).
fn power_button(bus: &mut Bus) -> Option<bool> {
    let mut b = [0u8];
    bus.read(EXPANDER, &[0x00], &mut b).then_some(b[0] & 0x10 != 0)
}

/// Poll the inputs at 100 Hz on their own thread and send what changes.
pub fn spawn(
    mut bus: Bus,
    mut touch_rst: PinDriver<'static, Output>,
    boot: PinDriver<'static, gpio::Input>,
) -> Receiver<Input> {
    let (tx, rx) = channel();
    std::thread::Builder::new()
        .name("inputs".into())
        .stack_size(8 * 1024)
        .spawn(move || {
            let _ = touch_rst.set_low();
            std::thread::sleep(Duration::from_millis(10));
            let _ = touch_rst.set_high();
            std::thread::sleep(Duration::from_millis(50));
            let imu = imu_init(&mut bus);
            log::info!("inputs: motion sensor {}", if imu { "up" } else { "missing" });
            let mut finger = None;
            let mut slow = [0.0, 0.0, 1.0];
            let mut was_down = false;
            let mut n = 0u32;
            loop {
                if let Some(f) = touch(&mut bus)
                    && f != finger
                {
                    finger = f;
                    if tx.send(Input::Touch(f)).is_err() {
                        return;
                    }
                }
                if imu && let Some(a) = imu_read(&mut bus).map(to_device) {
                    // The slow average is gravity (the sensor reads +1 g away from the earth);
                    // what's left over is the hand.
                    for i in 0..3 {
                        slow[i] += (a[i] - slow[i]) * 0.08;
                    }
                    let down = slow.map(|v| -v);
                    let shake = [0, 1, 2].map(|i| a[i] - slow[i]);
                    let _ = tx.send(Input::Motion(down, shake));
                    n += 1;
                    if n % 200 == 0 {
                        log::info!("accel (device frame, g): {a:.2?}");
                    }
                }
                let down = power_button(&mut bus).unwrap_or(false) || boot.is_low();
                if down && !was_down {
                    let _ = tx.send(Input::Button);
                }
                was_down = down;
                std::thread::sleep(Duration::from_millis(10));
            }
        })
        .expect("input thread");
    rx
}
