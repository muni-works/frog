//! The CO5300 466×466 AMOLED on QSPI, driven through esp_lcd's SPI panel IO.
//!
//! Pins, init sequence and the 6-column offset come from Waveshare's BSP for this board
//! (`esp32_s3_touch_amoled_1_75.c`). Commands go out on one line as `0x02 cmd`; pixels go out on
//! four lines as `0x32 0x2C` followed by big-endian RGB565.

use esp_idf_svc::sys::*;
use std::ptr;

pub const W: usize = 466;
pub const H: usize = 466;
/// The panel's RAM is 480 wide; the glass starts at column 6.
const X_OFF: u16 = 6;

const CS: i32 = 12;
const SCLK: i32 = 38;
const D: [i32; 4] = [4, 5, 6, 7];
const RESET: i32 = 39;
const PCLK_HZ: u32 = 40_000_000;

/// Rows per transfer. Windows must start on an even row and be an even number of rows tall;
/// 466 = 29·16 + 2, so every strip, the last included, is even.
pub const STRIP: usize = 16;
const STRIP_BYTES: usize = W * STRIP * 2;

/// (command, parameters, delay after in ms), verbatim from the BSP.
const INIT: &[(u8, &[u8], u32)] = &[
    (0xFE, &[0x20], 0),
    (0x19, &[0x10], 0),
    (0x1C, &[0xA0], 0),
    (0xFE, &[0x00], 0),
    (0xC4, &[0x80], 0),
    (0x3A, &[0x55], 0), // RGB565
    (0x35, &[0x00], 0), // tearing-effect line on
    (0x53, &[0x20], 0),
    (0x51, &[0xFF], 0), // brightness
    (0x63, &[0xFF], 0),
    (0x2A, &[0x00, 0x06, 0x01, 0xD7], 0),
    (0x2B, &[0x00, 0x00, 0x01, 0xD1], 600),
    (0x11, &[], 600), // sleep out
    (0x29, &[], 0),   // display on
];

pub struct Display {
    io: esp_lcd_panel_io_handle_t,
    /// Two DMA-capable strips in internal RAM: one fills while the other is on the wire.
    bufs: [*mut u8; 2],
}

fn check(e: esp_err_t, what: &str) {
    if e != ESP_OK {
        panic!("{what}: esp_err {e}");
    }
}

impl Display {
    pub fn new() -> Self {
        unsafe {
            let mut bus: spi_bus_config_t = Default::default();
            bus.sclk_io_num = SCLK;
            bus.__bindgen_anon_1.data0_io_num = D[0];
            bus.__bindgen_anon_2.data1_io_num = D[1];
            bus.__bindgen_anon_3.data2_io_num = D[2];
            bus.__bindgen_anon_4.data3_io_num = D[3];
            bus.data4_io_num = -1;
            bus.data5_io_num = -1;
            bus.data6_io_num = -1;
            bus.data7_io_num = -1;
            bus.max_transfer_sz = STRIP_BYTES as i32;
            bus.flags = SPICOMMON_BUSFLAG_MASTER | SPICOMMON_BUSFLAG_QUAD;
            check(
                spi_bus_initialize(spi_host_device_t_SPI2_HOST, &bus, spi_common_dma_t_SPI_DMA_CH_AUTO),
                "spi bus",
            );

            let mut cfg: esp_lcd_panel_io_spi_config_t = Default::default();
            cfg.cs_gpio_num = CS;
            cfg.dc_gpio_num = -1;
            cfg.spi_mode = 0;
            cfg.pclk_hz = PCLK_HZ;
            cfg.trans_queue_depth = 4;
            cfg.lcd_cmd_bits = 32;
            cfg.lcd_param_bits = 8;
            cfg.flags.set_quad_mode(1);
            let mut io = ptr::null_mut();
            check(
                esp_lcd_new_panel_io_spi(spi_host_device_t_SPI2_HOST as _, &cfg, &mut io),
                "panel io",
            );

            let caps = MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL;
            let bufs = [0, 1].map(|_| {
                let p = heap_caps_malloc(STRIP_BYTES, caps) as *mut u8;
                assert!(!p.is_null(), "strip buffer");
                p
            });

            let d = Self { io, bufs };
            d.reset();
            for &(c, p, ms) in INIT {
                d.cmd(c, p);
                if ms > 0 {
                    std::thread::sleep(std::time::Duration::from_millis(ms as u64));
                }
            }
            d
        }
    }

    fn reset(&self) {
        unsafe {
            gpio_reset_pin(RESET);
            gpio_set_direction(RESET, gpio_mode_t_GPIO_MODE_OUTPUT);
            gpio_set_level(RESET, 1);
            std::thread::sleep(std::time::Duration::from_millis(10));
            gpio_set_level(RESET, 0);
            std::thread::sleep(std::time::Duration::from_millis(10));
            gpio_set_level(RESET, 1);
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
    }

    fn cmd(&self, c: u8, params: &[u8]) {
        let op = (0x02 << 24) | ((c as i32) << 8);
        let p = if params.is_empty() { ptr::null() } else { params.as_ptr() as *const _ };
        unsafe { check(esp_lcd_panel_io_tx_param(self.io, op, p, params.len()), "tx_param") };
    }

    fn window(&self, x0: u16, y0: u16, x1: u16, y1: u16) {
        let (x0, x1) = (x0 + X_OFF, x1 + X_OFF);
        self.cmd(0x2A, &[(x0 >> 8) as u8, x0 as u8, (x1 >> 8) as u8, x1 as u8]);
        self.cmd(0x2B, &[(y0 >> 8) as u8, y0 as u8, (y1 >> 8) as u8, y1 as u8]);
    }

    pub fn set_brightness(&self, b: u8) {
        self.cmd(0x51, &[b]);
    }

    /// Push a whole frame. `fill(row0, rows, out)` writes `rows` rows of big-endian RGB565 into
    /// `out`; it runs for the next strip while the previous one is still being sent.
    pub fn frame(&mut self, mut fill: impl FnMut(usize, usize, &mut [u8])) {
        let mut y = 0;
        let mut i = 0;
        while y < H {
            let rows = STRIP.min(H - y);
            let buf = unsafe { std::slice::from_raw_parts_mut(self.bufs[i], W * rows * 2) };
            fill(y, rows, buf);
            // Setting the window waits for the strip before this one to finish.
            self.window(0, y as u16, W as u16 - 1, (y + rows - 1) as u16);
            let op = (0x32 << 24) | (0x2C << 8);
            unsafe {
                check(
                    esp_lcd_panel_io_tx_color(self.io, op, buf.as_ptr() as *const _, buf.len()),
                    "tx_color",
                )
            };
            y += rows;
            i ^= 1;
        }
    }
}
