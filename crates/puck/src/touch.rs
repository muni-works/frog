//! One finger on the glass: tap, hold to interrupt, drag the knob to approve, ✕ to decline.
//! The simulator feeds it the mouse; the device feeds it the touch panel.

use crate::C;
use crate::model::{Mode, Puck};
use serde_json::Value;

/// The approve slider's knob: its center at `slide` = 0 and = 1, its y, and its radius.
const KNOB_X0: f32 = 132.0;
const KNOB_TRAVEL: f32 = 202.0;
const KNOB_Y: f32 = 296.0;
const KNOB_R: f32 = 34.0;
/// The decline button.
const DENY: (f32, f32, f32) = (C, 372.0, 26.0);
/// A press this long, while frog is busy, interrupts it.
const HOLD_SECS: f64 = 0.6;

#[derive(Default)]
pub struct Touch {
    /// Where and when the finger went down, and whether it caught the knob.
    press: Option<(f32, f32, f64, bool)>,
    held: bool,
}

impl Touch {
    /// Feed the finger's position in glass pixels (`None` when lifted) at time `now`. Returns
    /// whatever should go to frog.
    pub fn update(&mut self, p: &mut Puck, at: Option<(f32, f32)>, now: f64) -> Vec<Value> {
        let mut ops = Vec::new();
        match (at, self.press) {
            (Some((x, y)), None) => {
                let on_knob = p.mode == Mode::Ask
                    && (x - (KNOB_X0 + p.slide * KNOB_TRAVEL)).hypot(y - KNOB_Y) < KNOB_R;
                self.press = Some((x, y, now, on_knob));
                self.held = false;
            }
            (Some((x, _)), Some((_, _, t0, knob))) => {
                if knob {
                    p.slide = ((x - KNOB_X0) / KNOB_TRAVEL).clamp(0.0, 1.0);
                } else if now - t0 > HOLD_SECS && !self.held && p.busy() {
                    ops.extend(p.interrupt());
                    self.held = true;
                }
            }
            (None, Some((x0, y0, _, knob))) => {
                if knob {
                    if p.slide > 0.95 {
                        ops.extend(p.approve());
                    } else {
                        p.slide = 0.0;
                    }
                } else if !self.held {
                    let on_x = p.mode == Mode::Ask && (x0 - DENY.0).hypot(y0 - DENY.1) < DENY.2;
                    let on_glass = (x0 - C).hypot(y0 - C) < C;
                    if on_x {
                        ops.extend(p.deny());
                    } else if on_glass {
                        ops.extend(p.tap(now));
                    }
                }
                self.press = None;
            }
            (None, None) => {}
        }
        ops
    }
}
